import 'package:bioentropy_mobile/lab/bio_seed.dart';
import 'package:bioentropy_mobile/lab/pqc_demo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deriveBioSeed', () {
    test('is deterministic for same input', () {
      final input = BioSeedInput(
        bpmSamples: [72, 74, 73, 75],
        bandMac: 'AA:BB:CC:DD:EE:FF',
        capturedAtMs: 1_700_000_000_000,
        spo2: 97,
        steps: 4200,
        distanceM: 3100,
        calories: 180,
      );
      final a = deriveBioSeed(input);
      final b = deriveBioSeed(input);
      expect(a.seed32, equals(b.seed32));
      expect(a.matrix, equals(b.matrix));
      a.wipe();
      b.wipe();
    });

    test('steps change the seed', () {
      final base = BioSeedInput(
        bpmSamples: [70, 71],
        bandMac: 'D5:5E:C7:2F:62:0E',
        capturedAtMs: 42,
        spo2: 96,
        steps: 100,
      );
      final withMoreSteps = BioSeedInput(
        bpmSamples: base.bpmSamples,
        bandMac: base.bandMac,
        capturedAtMs: base.capturedAtMs,
        spo2: base.spo2,
        steps: 101,
      );
      final a = deriveBioSeed(base);
      final b = deriveBioSeed(withMoreSteps);
      expect(a.seed32, isNot(equals(b.seed32)));
      a.wipe();
      b.wipe();
    });

    test('wipe clears seed bytes', () {
      final r = deriveBioSeed(
        BioSeedInput(
          bpmSamples: [80],
          bandMac: '11:22:33:44:55:66',
          capturedAtMs: 1,
          steps: 9,
        ),
      );
      expect(r.seed32.any((b) => b != 0), isTrue);
      r.wipe();
      expect(r.seed32.every((b) => b == 0), isTrue);
      expect(r.usedBpm, isEmpty);
    });
  });

  group('runPqcDemo', () {
    test('stable SHA3 + ML-KEM fingerprint for fixed seed', () {
      final bio = deriveBioSeed(
        BioSeedInput(
          bpmSamples: [66, 67, 68],
          bandMac: '00:11:22:33:44:55',
          capturedAtMs: 99,
          spo2: 98,
          steps: 12,
        ),
      );
      final a = runPqcDemo(bio.seed32);
      final b = runPqcDemo(bio.seed32);
      expect(a.sha3Hex, equals(b.sha3Hex));
      expect(a.mlKemPubFpHex, equals(b.mlKemPubFpHex));
      expect(a.sha3Hex.length, 64);
      expect(a.mlKemPubFpHex.length, 64);
      expect(a.publicKeyBytes, greaterThan(0));
      bio.wipe();
    });
  });
}
