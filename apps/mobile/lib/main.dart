import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/env.dart';
import 'huami/miband.dart';
import 'lab/bpm_gate.dart';
import 'lab/lab_ws_client.dart';
import 'lab/qr_payload.dart';
import 'lab/ws_messages.dart';
import 'permissions/ble_permissions.dart';
import 'screens/qr_scan_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const BioentropyApp());
}

class BioentropyApp extends StatelessWidget {
  const BioentropyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bioentropy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E4F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final MiBandClient _client;
  late final LabWsClient _ws;
  MiBandState _bandState = MiBandState.idle;
  LabWsStatus _labStatus = LabWsStatus.disconnected;
  int? _bpm;
  final _logs = <String>[];
  String? _error;
  String? _desktopName;
  ChallengeResultMessage? _lastChallengeResult;
  bool _challengeBusy = false;

  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _client = MiBandClient(authKeyHex: AppEnv.authKey);
    _ws = LabWsClient();

    _subs.add(_client.state$.listen((s) {
      if (mounted) setState(() => _bandState = s);
      _pushPresence();
    }));
    _subs.add(_client.heartRate$.listen((bpm) {
      // UI only — never log stream values or send over WS.
      if (mounted) setState(() => _bpm = bpm);
    }));
    _subs.add(_client.log$.listen(_pushLog));
    _subs.add(_ws.status$.listen((s) {
      if (mounted) setState(() => _labStatus = s);
    }));
    _subs.add(_ws.log$.listen(_pushLog));
    _subs.add(_ws.challenge$.listen(_onChallenge));
    _subs.add(_ws.result$.listen((r) {
      if (mounted) setState(() => _lastChallengeResult = r);
    }));
  }

  void _pushLog(String m) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, m);
      if (_logs.length > 40) _logs.removeLast();
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_ws.dispose());
    unawaited(_client.dispose());
    super.dispose();
  }

  String get _bandMac {
    return _client.bandMac ?? AppEnv.mac ?? '';
  }

  String get _labStateLabel {
    final bandLive = _client.isStreamingHr;
    return switch (_labStatus) {
      LabWsStatus.disconnected => 'Não sincronizado',
      LabWsStatus.connecting => 'A emparelhar…',
      LabWsStatus.paired =>
        bandLive ? 'Sincronizado' : 'Desktop ligado · band offline',
      LabWsStatus.challengeInProgress => 'Challenge em curso…',
      LabWsStatus.result => _lastChallengeResult?.ok == true
          ? (bandLive ? 'Sincronizado · OK' : 'Result OK · band offline')
          : 'Result: FAIL',
      LabWsStatus.error => 'WS erro',
    };
  }

  void _pushPresence() {
    if (!_ws.isSessionLive) return;
    final mac = _bandMac;
    if (mac.isEmpty) return;
    _ws.sendPresenceUpdate(
      bandMac: mac,
      bandReady: _client.isStreamingHr,
    );
  }

  Future<void> _connectBand() async {
    setState(() {
      _error = null;
      _bpm = null;
    });
    try {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permissões Xiaomi'),
            content: const Text(
              'No Android 14 o popup NÃO se chama "Bluetooth".\n\n'
              'Chama-se "Dispositivos próximos" / "Nearby devices".\n\n'
              'Também liga o ícone de Localização (GPS) na barra de estado.\n\n'
              'Se já tiveres dado permissão antes, pode não voltar a pedir.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Continuar'),
              ),
            ],
          ),
        );
      }

      final permError = await BlePermissions.ensure(
        onLog: _pushLog,
      );
      if (permError != null) {
        throw StateError(permError);
      }

      await _client.connect(preferredMac: AppEnv.mac);
    } on PlatformException catch (e) {
      setState(() {
        _error =
            'PlatformException [${e.code}]: ${e.message}\n${e.details ?? ""}';
        _logs.insert(0, _error!);
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _logs.insert(0, _error!);
      });
    }
  }

  Future<void> _ensureBandReady() async {
    if (_client.isStreamingHr) return;
    await _connectBand();
    if (!_client.isStreamingHr) {
      throw StateError('Mi Band não está a transmitir HR');
    }
  }

  Future<void> _scanAndPair() async {
    setState(() {
      _error = null;
      _lastChallengeResult = null;
    });

    final qr = await Navigator.of(context).push<PairingQr>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (qr == null || !mounted) return;

    setState(() => _desktopName = qr.desktopName);

    try {
      await _ensureBandReady();
      final mac = _bandMac;
      if (mac.isEmpty) {
        throw StateError(
          'Sem bandMac — conecta a Mi Band ou define MIBAND_MAC no .env',
        );
      }
      await _ws.connectAndRegister(qr: qr, bandMac: mac);
      _pushPresence();
    } on Object catch (e) {
      setState(() {
        _error = e.toString();
        _logs.insert(0, _error!);
      });
    }
  }

  Future<void> _onChallenge(ChallengeRequest req) async {
    if (_challengeBusy) {
      _pushLog('challenge: BUSY — denying ${req.challengeId}');
      _ws.sendChallengeResult(
        ChallengeResultMessage(
          challengeId: req.challengeId,
          ok: false,
          bandMac: _bandMac.isEmpty ? (AppEnv.mac ?? '00:00:00:00:00:00') : _bandMac,
          reason: 'busy',
        ),
      );
      return;
    }
    _challengeBusy = true;
    final mac = _bandMac;
    try {
      String? reason;
      var ok = false;

      try {
        await _ensureBandReady();
        if (mac.isEmpty) {
          reason = 'no_band_mac';
        } else if (!_client.isStreamingHr) {
          reason = 'hr_not_streaming';
          _pushLog('challenge: FAIL hr_not_streaming');
        } else {
          // Presença: 3 amostras ao vivo, ≥2 BPM distintos, span ≥2s.
          // Sem seed/cache. Logs BPM só no telemóvel.
          _pushLog(
            'challenge: waiting presence '
            '(fresh=${_client.hasFreshHr()} last=${_client.lastHeartRate ?? "-"})…',
          );
          final valid = await waitValidBpm(
            heartRate$: _client.heartRate$,
            minSamples: 3,
            minDistinct: 2,
            minSpan: const Duration(seconds: 2),
            onEvent: _pushLog,
          );
          if (valid && _client.hasFreshHr()) {
            ok = true;
            _pushLog('challenge: presence OK');
          } else if (valid && !_client.hasFreshHr()) {
            reason = 'hr_stale';
            _pushLog('challenge: presence FAIL (hr_stale after samples)');
          } else {
            reason = 'no_valid_bpm';
            _pushLog('challenge: presence FAIL (no_valid_bpm)');
          }
        }
      } on Object catch (e) {
        reason = 'band_error';
        _pushLog('challenge band: $e');
      }

      final result = ChallengeResultMessage(
        challengeId: req.challengeId,
        ok: ok,
        bandMac: mac.isEmpty ? (AppEnv.mac ?? '00:00:00:00:00:00') : mac,
        reason: ok ? null : reason,
      );
      _pushLog(
        'challenge.result ok=$ok reason=${reason ?? "-"} (BPM not sent to desktop)',
      );
      _ws.sendChallengeResult(result);
    } finally {
      _challengeBusy = false;
    }
  }

  Future<void> _unpair() async {
    await _ws.disconnect();
    setState(() {
      _desktopName = null;
      _lastChallengeResult = null;
    });
  }

  Future<void> _openPermSettings() async {
    await openAppSettings();
  }

  Future<void> _disconnectBand() => _client.disconnect();

  String get _bandStateLabel => switch (_bandState) {
        MiBandState.idle => 'Parado',
        MiBandState.scanning => 'A procurar…',
        MiBandState.connecting => 'A conectar…',
        MiBandState.authenticating => 'A autenticar…',
        MiBandState.authenticated => 'Autenticado',
        MiBandState.streamingHr => 'HR ao vivo',
        MiBandState.error => 'Erro',
      };

  @override
  Widget build(BuildContext context) {
    final busy = _bandState == MiBandState.scanning ||
        _bandState == MiBandState.connecting ||
        _bandState == MiBandState.authenticating;
    final paired = _labStatus == LabWsStatus.paired ||
        _labStatus == LabWsStatus.challengeInProgress ||
        _labStatus == LabWsStatus.result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bioentropy · lab 2FA'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Key: ${AppEnv.authKeyMasked}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'MAC: ${_bandMac.isEmpty ? (AppEnv.mac ?? "—") : _bandMac}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _StatusChip(
              label: 'Band: $_bandStateLabel',
              tone: _bandState == MiBandState.streamingHr
                  ? _ChipTone.ok
                  : _ChipTone.neutral,
            ),
            const SizedBox(height: 6),
            _StatusChip(
              label: 'Lab: $_labStateLabel'
                  '${_desktopName != null ? " · $_desktopName" : ""}',
              tone: switch (_labStatus) {
                LabWsStatus.paired =>
                  _client.isStreamingHr ? _ChipTone.ok : _ChipTone.warn,
                LabWsStatus.challengeInProgress => _ChipTone.warn,
                LabWsStatus.result => _lastChallengeResult?.ok != true
                    ? _ChipTone.err
                    : (_client.isStreamingHr ? _ChipTone.ok : _ChipTone.warn),
                LabWsStatus.error => _ChipTone.err,
                _ => _ChipTone.neutral,
              },
            ),
            if (_lastChallengeResult != null &&
                _labStatus == LabWsStatus.result) ...[
              const SizedBox(height: 6),
              Text(
                _lastChallengeResult!.ok
                    ? 'Último challenge: aceite'
                    : 'Último challenge: rejeitado'
                        '${_lastChallengeResult!.reason != null ? " (${_lastChallengeResult!.reason})" : ""}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Column(
                children: [
                  Text(
                    _bpm?.toString() ?? '—',
                    style: Theme.of(context).textTheme.displayLarge,
                  ),
                  const Text('BPM (local only)'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : _connectBand,
              child: const Text('Conectar Mi Band'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _labStatus == LabWsStatus.connecting ? null : _scanAndPair,
              child: Text(paired ? 'Re-scan QR / re-pair' : 'Scan QR desktop'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: paired ? _unpair : null,
              child: const Text('Unpair desktop'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _bandState == MiBandState.idle ? null : _disconnectBand,
              child: const Text('Desconectar band'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _openPermSettings,
              child: const Text('Abrir permissões do app'),
            ),
            const SizedBox(height: 16),
            Text('Log', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Text(
                  _logs[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ChipTone { neutral, ok, warn, err }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = switch (tone) {
      _ChipTone.ok => scheme.primaryContainer,
      _ChipTone.warn => scheme.tertiaryContainer,
      _ChipTone.err => scheme.errorContainer,
      _ChipTone.neutral => scheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label),
    );
  }
}
