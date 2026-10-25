import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_write.dart';
import 'chunked.dart';
import 'chunked_decoder.dart';
import 'crypto_huami.dart';
import 'uuids.dart';

enum MiBandState {
  idle,
  scanning,
  connecting,
  authenticating,
  authenticated,
  streamingHr,
  error,
}

class MiBandClient {
  MiBandClient({required this.authKeyHex});

  final String authKeyHex;

  BluetoothDevice? _device;
  ChunkedWriter? _chunked;
  BluetoothCharacteristic? _chunkedRead;
  final _decoder = Huami2021ChunkedDecoder();
  StreamSubscription<List<int>>? _chunkedSub;
  StreamSubscription<List<int>>? _hrSub;
  StreamSubscription<List<int>>? _stepsSub;
  Timer? _hrPing;

  final _stateCtrl = StreamController<MiBandState>.broadcast();
  final _hrCtrl = StreamController<int?>.broadcast();
  final _stepsCtrl = StreamController<int>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();

  Stream<MiBandState> get state$ => _stateCtrl.stream;

  /// BPM ao vivo; `null` = amostra inválida / off-wrist / limpeza (não usar cache).
  Stream<int?> get heartRate$ => _hrCtrl.stream;
  Stream<int> get steps$ => _stepsCtrl.stream;
  Stream<String> get log$ => _logCtrl.stream;

  MiBandState _state = MiBandState.idle;
  MiBandState get state => _state;

  /// MAC da pulseira ligada (remoteId BLE), se houver.
  String? get bandMac {
    final id = _device?.remoteId.str;
    if (id == null || id.isEmpty) return null;
    return _normMac(id);
  }

  bool get isStreamingHr => _state == MiBandState.streamingHr;

  /// Último BPM em memória (UI / gate local). Nunca serializar para rede.
  int? lastHeartRate;

  /// Momento da última amostra HR válida (para freshness / off-wrist).
  DateTime? lastHrAt;

  /// Passos do dia (realtime Huami). Só UI / seed local.
  int? lastSteps;
  int? lastDistanceM;
  int? lastCalories;
  DateTime? lastStepsAt;

  /// Último SpO₂ conhecido na sessão (cache local; sem medição sob demanda).
  int? lastSpo2;
  DateTime? lastSpo2At;

  Timer? _hrIdleWatch;

  /// HR válido nos últimos [maxAge] (presença recente).
  bool hasFreshHr({Duration maxAge = const Duration(seconds: 3)}) {
    final at = lastHrAt;
    final bpm = lastHeartRate;
    if (at == null || bpm == null) return false;
    return DateTime.now().difference(at) <= maxAge;
  }

  Completer<void>? _authCompleter;

  Uint8List? _privateKey;
  int _chunkedPackets = 0;
  bool _sentSecondAuth = false;

  static const _endpointAuth = 0x82;

  void _setState(MiBandState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  void _log(String m) {
    debugPrint('[MiBand] $m');
    _logCtrl.add(m);
  }

  static String _normMac(String mac) =>
      mac.replaceAll('-', ':').replaceAll(' ', '').toUpperCase();

  static bool _macEq(String a, String b) => _normMac(a) == _normMac(b);

  static bool _looksLikeMiBand(String name) {
    final n = name.toLowerCase();
    return n.contains('mi smart band 6') ||
        n.contains('mi band 6') ||
        n.contains('miband 6') ||
        (n.contains('band 6') && n.contains('mi'));
  }

  Future<void> _ensureBluetoothOn() async {
    var state = FlutterBluePlus.adapterStateNow;
    if (state == BluetoothAdapterState.on) return;

    _log('Bluetooth off — abre as definições e liga o BT (Xiaomi bloqueia turnOn).');
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      _log('turnOn bloqueado ($e) — à espera do Bluetooth…');
    }

    state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw StateError(
        'Bluetooth desligado. Liga o Bluetooth nas definições e tenta de novo.',
      ),
    );
  }

  Future<BluetoothDevice?> _findDevice({
    String? preferredMac,
    Duration scanTimeout = const Duration(seconds: 20),
  }) async {
    final macNorm = preferredMac == null || preferredMac.isEmpty
        ? null
        : _normMac(preferredMac);

    if (macNorm != null) {
      _log('A tentar ligação direta ao MAC $macNorm…');
      try {
        return BluetoothDevice.fromId(macNorm);
      } catch (e) {
        _log('fromId falhou: $e');
      }
    }

    try {
      final system = await FlutterBluePlus.systemDevices([HuamiUuids.miband1]);
      for (final d in system) {
        if (macNorm != null && _macEq(d.remoteId.str, macNorm)) {
          _log('Encontrada no systemDevices: ${d.remoteId.str}');
          return d;
        }
        if (_looksLikeMiBand(d.platformName)) {
          _log('Encontrada (system) ${d.platformName} ${d.remoteId.str}');
          return d;
        }
      }
    } catch (e) {
      _log('systemDevices: $e');
    }

    BluetoothDevice? found;
    void consider(ScanResult r) {
      final id = r.device.remoteId.str;
      final name = r.advertisementData.advName.isNotEmpty
          ? r.advertisementData.advName
          : r.device.platformName;
      final matchMac = macNorm != null && _macEq(id, macNorm);
      final matchName = _looksLikeMiBand(name);
      if (matchMac || matchName) {
        found = r.device;
        _log('Scan: $name ($id)');
      }
    }

    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        consider(r);
      }
    });

    try {
      _log('Scan BLE (${scanTimeout.inSeconds}s)…');
      await FlutterBluePlus.startScan(
        timeout: scanTimeout,
        androidUsesFineLocation: true,
      );
      await FlutterBluePlus.isScanning.where((v) => v == false).first;
    } on Object catch (e) {
      _log('startScan erro: $e');
      rethrow;
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }

    return found;
  }

  Future<void> connect({
    String? preferredMac,
    Duration scanTimeout = const Duration(seconds: 20),
  }) async {
    await disconnect();
    _setState(MiBandState.scanning);
    _log('A preparar Bluetooth…');

    await _ensureBluetoothOn();

    BluetoothDevice? found;
    try {
      found = await _findDevice(
        preferredMac: preferredMac,
        scanTimeout: scanTimeout,
      );
    } on Object catch (e) {
      _setState(MiBandState.error);
      throw StateError('Falha no scan BLE: $e');
    }

    if (found == null) {
      _setState(MiBandState.error);
      _log('Pulseira não encontrada. Force-stop Mi Fitness, BT ligado, band perto.');
      throw StateError('Mi Band não encontrada');
    }

    _device = found;
    _setState(MiBandState.connecting);
    _log('A conectar a ${_device!.remoteId.str}…');
    try {
      await _device!.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 20),
        mtu: null,
      );
    } on Object catch (e) {
      _setState(MiBandState.error);
      throw StateError(
        'Falha ao conectar: $e\n'
        '(Mi Fitness a correr? Force-stop e tenta outra vez.)',
      );
    }

    // MTU negociado pode fazer a band cortar em alguns firmwares — ATT default basta
    // para chunked com mtu=23 no writer.
    await _device!.discoverServices();

    final services = _device!.servicesList;
    BluetoothCharacteristic? chunkedWrite;
    BluetoothCharacteristic? chunkedRead;
    BluetoothCharacteristic? hrControl;
    BluetoothCharacteristic? hrMeasure;
    BluetoothCharacteristic? stepsChar;
    BluetoothCharacteristic? batteryChar;

    for (final s in services) {
      for (final c in s.characteristics) {
        final u = c.uuid;
        final p = c.properties;
        _log(
          'GATT $u write=${p.write} wrNoRsp=${p.writeWithoutResponse} '
          'notify=${p.notify} read=${p.read}',
        );
        if (u == HuamiUuids.chunkedWrite) chunkedWrite = c;
        if (u == HuamiUuids.chunkedRead) chunkedRead = c;
        if (u == HuamiUuids.hrControl) hrControl = c;
        if (u == HuamiUuids.hrMeasure) hrMeasure = c;
        if (u == HuamiUuids.realtimeSteps) stepsChar = c;
        if (u == HuamiUuids.batteryLevel) batteryChar = c;
        if (chunkedWrite == null &&
            u.str128.toLowerCase().contains('00000016-0000-3512') &&
            (p.writeWithoutResponse || p.write)) {
          chunkedWrite = c;
        }
        if (chunkedRead == null &&
            u.str128.toLowerCase().contains('00000017-0000-3512') &&
            p.notify) {
          chunkedRead = c;
        }
        if (stepsChar == null &&
            u.str128.toLowerCase().contains('00000007-0000-3512')) {
          stepsChar = c;
        }
      }
    }

    if (chunkedWrite == null || chunkedRead == null) {
      _setState(MiBandState.error);
      throw StateError('Características chunked 2021 não encontradas');
    }
    _log(
      'chunkedWrite props: write=${chunkedWrite.properties.write} '
      'wrNoRsp=${chunkedWrite.properties.writeWithoutResponse}',
    );

    _chunked = ChunkedWriter(chunkedWrite);
    _chunkedRead = chunkedRead;
    _chunkedPackets = 0;
    _sentSecondAuth = false;

    _chunkedSub = chunkedRead.onValueReceived.listen(
      _onChunkedNotify,
      onError: (Object e) => _log('chunked notify error: $e'),
    );
    final notifyOk = await chunkedRead.setNotifyValue(true);
    _log('chunkedRead notify=$notifyOk');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    _setState(MiBandState.authenticating);
    _log('New Auth Protocol (ECDH B-163)…');
    _authCompleter = Completer<void>();
    await _startAuth();

    try {
      await _authCompleter!.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      _setState(MiBandState.error);
      throw TimeoutException(
        'Auth timeout (pacotes chunked recebidos: $_chunkedPackets, '
        '2º auth enviado: $_sentSecondAuth). '
        'Confirma a auth key no .env e force-stop no Mi Fitness.',
      );
    }

    _setState(MiBandState.authenticated);
    _log('Autenticado ✓');

    if (stepsChar != null) {
      await _startSteps(stepsChar);
    } else {
      _log('Realtime steps char não encontrada');
    }

    if (batteryChar != null) {
      try {
        final raw = await batteryChar.read();
        if (raw.isNotEmpty) {
          _log('Battery ${raw[0]}%');
        }
      } catch (e) {
        _log('Battery read falhou: $e');
      }
    }

    if (hrControl != null && hrMeasure != null) {
      await _startHr(hrControl, hrMeasure);
    }
  }

  Future<void> _startAuth() async {
    final pair = HuamiCrypto.generateEcdhKeyPair();
    _privateKey = pair.privateKey;
    final authCmd = Uint8List.fromList([0x04, 0x02, 0x00, 0x02, ...pair.publicKey]);
    _log('A enviar 1º pacote auth (${authCmd.length} B, pub=${pair.publicKey.length})…');
    await _chunked!.write(_endpointAuth, _chunked!.nextHandle(), authCmd);
  }

  void _onChunkedNotify(List<int> raw) {
    final value = Uint8List.fromList(raw);
    _chunkedPackets++;
    _log(
      '← chunked[${value.length}]: ${HuamiCrypto.bytesToHex(value.length > 24 ? value.sublist(0, 24) : value)}…',
    );

    final result = _decoder.decode(value);
    if (result.needsAck) {
      unawaited(_sendAck());
    }

    final payload = result.payload;
    final endpoint = result.endpoint;
    if (payload == null || endpoint == null) return;

    _log('payload ep=0x${endpoint.toRadixString(16)} len=${payload.length}');
    if (endpoint != _endpointAuth) {
      _log('endpoint não-auth ignorado');
      return;
    }
    unawaited(_handleAuthPayload(payload));
  }

  Future<void> _sendAck() async {
    final read = _chunkedRead;
    if (read == null) return;
    final ack = _decoder.buildAck();
    _log('→ ACK ${HuamiCrypto.bytesToHex(ack)}');
    try {
      await bleWrite(read, ack);
    } catch (e) {
      _log('ACK falhou: $e');
    }
  }

  Future<void> _handleAuthPayload(Uint8List payload) async {
    if (payload.length < 3) return;

    // RESPONSE=0x10, SUCCESS=0x01
    if (payload[0] == 0x10 && payload[1] == 0x04 && payload[2] == 0x01) {
      if (_sentSecondAuth || _privateKey == null) return;
      if (payload.length < 67) {
        _log('challenge curto (${payload.length})');
        return;
      }
      await _finishAuthChallenge(payload);
      return;
    }

    if (payload[0] == 0x10 && payload[1] == 0x05 && payload[2] == 0x01) {
      _log('Auth OK da pulseira');
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _authCompleter!.complete();
      }
      return;
    }

    if (payload[0] == 0x10 && payload[1] == 0x05 && payload[2] == 0x25) {
      final err = StateError('Auth falhou (0x25) — key errada?');
      _log('$err');
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _authCompleter!.completeError(err);
      }
      return;
    }

    _log('auth payload não tratado: ${HuamiCrypto.bytesToHex(payload.length > 16 ? payload.sublist(0, 16) : payload)}');
  }

  Future<void> _finishAuthChallenge(Uint8List payload) async {
    if (_sentSecondAuth) return;
    _sentSecondAuth = true;
    try {
      final remoteRandom = Uint8List.fromList(payload.sublist(3, 19));
      final remotePublic = Uint8List.fromList(payload.sublist(19, 67));
      _log('challenge ok, ECDH B-163…');

      final sec = HuamiCrypto.sharedSecret(_privateKey!, remotePublic);
      final secretKey = HuamiCrypto.hexToBytes(authKeyHex);
      final sessionAes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        sessionAes[i] = sec[i + 8] ^ secretKey[i];
      }

      final out1 = HuamiCrypto.aesEcbEncrypt(secretKey, remoteRandom);
      final out2 = HuamiCrypto.aesEcbEncrypt(sessionAes, remoteRandom);
      final command = Uint8List(33);
      command[0] = 0x05;
      command.setRange(1, 17, out1);
      command.setRange(17, 33, out2);

      _log('A enviar 2º pacote auth…');
      await _chunked!.write(_endpointAuth, _chunked!.nextHandle(), command);
    } catch (e, st) {
      _log('Erro no 2º auth: $e\n$st');
      _sentSecondAuth = false;
      if (_authCompleter != null && !_authCompleter!.isCompleted) {
        _authCompleter!.completeError(e);
      }
    }
  }

  Future<void> _startSteps(BluetoothCharacteristic stepsChar) async {
    _log('A subscrever realtime steps…');
    try {
      if (stepsChar.properties.notify) {
        await stepsChar.setNotifyValue(true);
        _stepsSub = stepsChar.onValueReceived.listen(_onStepsPayload);
      }
      if (stepsChar.properties.read) {
        final raw = await stepsChar.read();
        _onStepsPayload(raw);
      }
    } catch (e) {
      _log('Steps setup falhou: $e');
    }
  }

  void _onStepsPayload(List<int> data) {
    if (data.length < 3) return;
    // Common Huami layout: [?, steps_lo, steps_hi, ...] with LE u16 steps.
    final steps = data[1] | (data[2] << 8);
    int? meters;
    int? calories;
    if (data.length >= 7) {
      meters = data[5] | (data[6] << 8);
    }
    if (data.length >= 10) {
      calories = data[9];
    } else if (data.length >= 9) {
      calories = data[7] | (data[8] << 8);
    }
    lastSteps = steps;
    lastDistanceM = meters;
    lastCalories = calories;
    lastStepsAt = DateTime.now();
    if (!_stepsCtrl.isClosed) {
      _stepsCtrl.add(steps);
    }
    _log(
      'Steps=$steps'
      '${meters != null ? " m=$meters" : ""}'
      '${calories != null ? " kcal=$calories" : ""}',
    );
  }

  /// Atualiza o cache local de SpO₂ (ex.: último valor conhecido na sessão).
  void rememberSpo2(int? spo2) {
    if (spo2 == null) return;
    if (spo2 < 70 || spo2 > 100) return;
    lastSpo2 = spo2;
    lastSpo2At = DateTime.now();
  }

  Future<void> _startHr(
    BluetoothCharacteristic hrControl,
    BluetoothCharacteristic hrMeasure,
  ) async {
    _log('A iniciar HR contínuo…');
    await bleWrite(hrControl, [0x15, 0x02, 0x00]);
    await bleWrite(hrControl, [0x15, 0x01, 0x00]);
    await hrMeasure.setNotifyValue(true);
    _hrSub = hrMeasure.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      int bpm;
      if (data.length >= 2 && (data[0] & 0x01) == 0) {
        bpm = data[1];
      } else if (data.length >= 3) {
        bpm = data[1] | (data[2] << 8);
      } else {
        bpm = data.length == 1 ? data[0] : 0;
      }
      if (bpm != 0 && bpm != 255) {
        lastHeartRate = bpm;
        lastHrAt = DateTime.now();
        _hrCtrl.add(bpm);
        debugPrint('[MiBand] HR bpm=$bpm');
      } else {
        // 0 / 255 → tipicamente off-wrist.
        _clearHr('invalid bpm=$bpm');
      }
    });
    await bleWrite(hrControl, [0x15, 0x01, 0x01]);
    _hrPing?.cancel();
    _hrPing = Timer.periodic(const Duration(seconds: 12), (_) {
      bleWrite(hrControl, [0x16]);
    });
    _hrIdleWatch?.cancel();
    _hrIdleWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isStreamingHr) return;
      if (!hasFreshHr(maxAge: const Duration(seconds: 3))) {
        if (lastHeartRate != null || lastHrAt != null) {
          _clearHr('stale >3s (off-wrist?)');
        }
      }
    });
    _setState(MiBandState.streamingHr);
    _log('HR a transmitir');
  }

  void _clearHr(String why) {
    if (lastHeartRate == null && lastHrAt == null) return;
    _log('HR clear: $why');
    lastHeartRate = null;
    lastHrAt = null;
    if (!_hrCtrl.isClosed) {
      _hrCtrl.add(null);
    }
  }

  Future<void> disconnect() async {
    _hrPing?.cancel();
    _hrPing = null;
    _hrIdleWatch?.cancel();
    _hrIdleWatch = null;
    await _chunkedSub?.cancel();
    await _hrSub?.cancel();
    await _stepsSub?.cancel();
    _chunkedSub = null;
    _hrSub = null;
    _stepsSub = null;
    _chunkedRead = null;
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }
    _device = null;
    _chunked = null;
    _privateKey = null;
    lastSteps = null;
    lastDistanceM = null;
    lastCalories = null;
    lastStepsAt = null;
    // lastSpo2 kept as session cache for the on-device PQC demo.
    _clearHr('disconnect');
    _setState(MiBandState.idle);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateCtrl.close();
    await _hrCtrl.close();
    await _stepsCtrl.close();
    await _logCtrl.close();
  }
}
