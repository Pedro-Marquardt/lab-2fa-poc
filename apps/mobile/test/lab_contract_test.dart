import 'dart:async';

import 'package:bioentropy_mobile/lab/bpm_gate.dart';
import 'package:bioentropy_mobile/lab/qr_payload.dart';
import 'package:bioentropy_mobile/lab/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairingQr', () {
    test('parses frozen QR payload', () {
      final q = PairingQr.fromJson({
        'v': 1,
        'wsUrl': 'ws://192.168.1.2:8787',
        'pairingNonce': 'abc',
        'desktopName': 'lab-pc',
        'apiTicketId': null,
      });
      expect(q.wsUrl, 'ws://192.168.1.2:8787');
      expect(q.apiTicketId, isNull);
    });

    test('parses optional apiTicketId + apiBaseUrl', () {
      final q = PairingQr.fromJson({
        'v': 1,
        'wsUrl': 'ws://192.168.1.2:8787',
        'pairingNonce': 'abc',
        'desktopName': 'lab-pc',
        'apiTicketId': 't1',
        'apiBaseUrl': 'http://192.168.1.2:8000',
      });
      expect(q.apiTicketId, 't1');
      expect(q.apiBaseUrl, 'http://192.168.1.2:8000');
    });

    test('rejects wrong version', () {
      expect(
        () => PairingQr.fromJson({
          'v': 2,
          'wsUrl': 'ws://x',
          'pairingNonce': 'n',
          'desktopName': 'd',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('WS messages', () {
    test('pair.register shape', () {
      final m = PairRegisterMessage(
        pairingNonce: 'n',
        bandMac: 'AA:BB:CC:DD:EE:FF',
        deviceLabel: 'phone',
      );
      final j = m.toJson();
      expect(j['type'], 'pair.register');
      expect(j.containsKey('bpm'), isFalse);
    });

    test('challenge.result never includes bpm', () {
      final m = ChallengeResultMessage(
        challengeId: 'c1',
        ok: true,
        bandMac: 'AA:BB:CC:DD:EE:FF',
      );
      final j = m.toJson();
      expect(j.keys.toSet().containsAll(['v', 'type', 'challengeId', 'ok', 'bandMac']), isTrue);
      expect(j.containsKey('bpm'), isFalse);
      expect(j.containsKey('heartRate'), isFalse);
    });

    test('presence.update never includes bpm', () {
      final m = PresenceUpdateMessage(
        bandMac: 'AA:BB:CC:DD:EE:FF',
        bandReady: true,
      );
      final j = m.toJson();
      expect(j['type'], 'presence.update');
      expect(j['bandReady'], isTrue);
      expect(j.containsKey('bpm'), isFalse);
    });

    test('challenge.request parse', () {
      final r = ChallengeRequest.fromJson({
        'v': 1,
        'type': 'challenge.request',
        'challengeId': 'c1',
        'purpose': 'open_app',
        'appId': 'app.x',
        'expiresAt': '2026-10-14T00:00:00Z',
      });
      expect(r.challengeId, 'c1');
      expect(r.purpose, 'open_app');
    });
  });

  group('waitValidBpm', () {
    test('requires span + distinct samples', () async {
      final ctrl = StreamController<int?>();
      final future = waitValidBpm(
        heartRate$: ctrl.stream,
        timeout: const Duration(seconds: 3),
        minSamples: 3,
        minDistinct: 2,
        minSampleGap: Duration.zero,
        minSpan: const Duration(milliseconds: 50),
      );
      ctrl.add(72);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ctrl.add(72);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ctrl.add(74);
      expect(await future, isTrue);
      await ctrl.close();
    });

    test('identical BPM only is not enough', () async {
      final ctrl = StreamController<int?>();
      final future = waitValidBpm(
        heartRate$: ctrl.stream,
        timeout: const Duration(milliseconds: 200),
        minSamples: 3,
        minDistinct: 2,
        minSampleGap: Duration.zero,
        minSpan: Duration.zero,
      );
      ctrl.add(72);
      ctrl.add(72);
      ctrl.add(72);
      expect(await future, isFalse);
      await ctrl.close();
    });

    test('one sample alone is not enough', () async {
      final ctrl = StreamController<int?>();
      final future = waitValidBpm(
        heartRate$: ctrl.stream,
        timeout: const Duration(milliseconds: 80),
        minSamples: 3,
        minDistinct: 2,
        minSampleGap: Duration.zero,
      );
      ctrl.add(72);
      expect(await future, isFalse);
      await ctrl.close();
    });

    test('null clears sample count', () async {
      final ctrl = StreamController<int?>();
      final future = waitValidBpm(
        heartRate$: ctrl.stream,
        timeout: const Duration(milliseconds: 150),
        minSamples: 3,
        minDistinct: 2,
        minSampleGap: Duration.zero,
        minSpan: Duration.zero,
      );
      ctrl.add(72);
      ctrl.add(74);
      ctrl.add(null);
      ctrl.add(76);
      expect(await future, isFalse);
      await ctrl.close();
    });

    test('times out without valid bpm', () async {
      final ctrl = StreamController<int?>();
      final future = waitValidBpm(
        heartRate$: ctrl.stream,
        timeout: const Duration(milliseconds: 80),
        minSampleGap: Duration.zero,
      );
      ctrl.add(10);
      ctrl.add(250);
      expect(await future, isFalse);
      await ctrl.close();
    });
  });
}
