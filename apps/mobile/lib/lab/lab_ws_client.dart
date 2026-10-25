import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_ticket.dart';
import 'presence_proof.dart';
import 'qr_payload.dart';
import 'ws_messages.dart';

enum LabWsStatus {
  disconnected,
  connecting,
  paired,
  challengeInProgress,
  result,
  error,
}

/// Cliente WS lab: pair.register + challenge.result.
/// Nunca envia BPM/seed — só ok, MAC, presence proof + PQC audit digests.
class LabWsClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  PairingQr? _pairing;
  PairingSessionPqc? _session;

  final _statusCtrl = StreamController<LabWsStatus>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();
  final _challengeCtrl = StreamController<ChallengeRequest>.broadcast();
  final _resultCtrl = StreamController<ChallengeResultMessage>.broadcast();

  LabWsStatus _status = LabWsStatus.disconnected;
  LabWsStatus get status => _status;
  PairingQr? get pairing => _pairing;
  PairingSessionPqc? get session => _session;
  ChallengeResultMessage? lastResult;

  Stream<LabWsStatus> get status$ => _statusCtrl.stream;
  Stream<String> get log$ => _logCtrl.stream;
  Stream<ChallengeRequest> get challenge$ => _challengeCtrl.stream;
  Stream<ChallengeResultMessage> get result$ => _resultCtrl.stream;

  void _setStatus(LabWsStatus s) {
    _status = s;
    _statusCtrl.add(s);
  }

  void _log(String m) {
    debugPrint('[LabWs] $m');
    _logCtrl.add(m);
  }

  Future<void> connectAndRegister({
    required PairingQr qr,
    required String bandMac,
    String deviceLabel = 'phone',
  }) async {
    await disconnect();
    _pairing = qr;
    lastResult = null;
    _session = createPairingSessionPqc();
    _setStatus(LabWsStatus.connecting);
    _log('WS → ${qr.wsUrl} (${qr.desktopName})');

    final uri = Uri.parse(qr.wsUrl);
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;

    try {
      await channel.ready.timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      _setStatus(LabWsStatus.error);
      _log('WS connect falhou: $e');
      await disconnect();
      rethrow;
    }

    _sub = channel.stream.listen(
      _onMessage,
      onError: (Object e) {
        _log('WS erro: $e');
        _setStatus(LabWsStatus.error);
      },
      onDone: () {
        _log('WS fechado');
        if (_status != LabWsStatus.error) {
          _setStatus(LabWsStatus.disconnected);
        }
      },
    );

    final session = _session!;
    final reg = PairRegisterMessage(
      pairingNonce: qr.pairingNonce,
      bandMac: bandMac,
      deviceLabel: deviceLabel,
      kemPublicKey: session.publicKeyHex,
      kemPubFp: session.kemPubFpHex,
    );
    _send(reg.toJson());
    _log(
      'pair.register enviado (bandMac=$bandMac, '
      'kemPubFp=${session.kemPubFpHex.substring(0, 16)}…)',
    );
    _setStatus(LabWsStatus.paired);

    final ticketId = qr.apiTicketId;
    final apiBase = qr.apiBaseUrl;
    if (ticketId != null && ticketId.isNotEmpty) {
      if (apiBase == null || apiBase.isEmpty) {
        _log('apiTicketId presente sem apiBaseUrl — skip ticket complete');
      } else {
        // Best-effort audit only; never fails local pairing. No BPM on wire.
        unawaited(
          completePairingTicketBestEffort(
            apiBaseUrl: apiBase,
            ticketId: ticketId,
            bandMac: bandMac,
            deviceLabel: deviceLabel,
          ),
        );
      }
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['v'] != 1) return;
      final type = decoded['type'];
      if (type == 'challenge.request') {
        final req = ChallengeRequest.fromJson(decoded);
        _log('challenge.request id=${req.challengeId} purpose=${req.purpose}');
        _setStatus(LabWsStatus.challengeInProgress);
        _challengeCtrl.add(req);
      } else {
        _log('msg type=$type (ignorado)');
      }
    } on Object catch (e) {
      _log('parse WS: $e');
    }
  }

  void sendChallengeResult(ChallengeResultMessage result) {
    _send(result.toJson());
    lastResult = result;
    _resultCtrl.add(result);
    _setStatus(LabWsStatus.result);
    _log(
      'challenge.result ok=${result.ok}'
      '${result.reason != null ? " reason=${result.reason}" : ""}',
    );
  }

  /// Tell desktop whether the band is live (no BPM). No-op if WS down.
  void sendPresenceUpdate({required String bandMac, required bool bandReady}) {
    if (_channel == null) return;
    if (_status == LabWsStatus.disconnected ||
        _status == LabWsStatus.connecting ||
        _status == LabWsStatus.error) {
      return;
    }
    try {
      _send(
        PresenceUpdateMessage(bandMac: bandMac, bandReady: bandReady).toJson(),
      );
      _log('presence.update bandReady=$bandReady');
    } on Object catch (e) {
      _log('presence.update falhou: $e');
    }
  }

  bool get isSessionLive =>
      _channel != null &&
      (_status == LabWsStatus.paired ||
          _status == LabWsStatus.challengeInProgress ||
          _status == LabWsStatus.result);

  void _send(Map<String, dynamic> json) {
    final ch = _channel;
    if (ch == null) {
      throw StateError('WS não ligado');
    }
    ch.sink.add(jsonEncode(json));
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _session?.wipe();
    _session = null;
    if (_status != LabWsStatus.disconnected) {
      _setStatus(LabWsStatus.disconnected);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _statusCtrl.close();
    await _logCtrl.close();
    await _challengeCtrl.close();
    await _resultCtrl.close();
  }
}
