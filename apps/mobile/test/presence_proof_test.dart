import 'dart:typed_data';

import 'package:bioentropy_mobile/lab/presence_proof.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing session produces 32-byte presence key + kem fp', () {
    final s = createPairingSessionPqc();
    expect(s.presenceKeyHex.length, 64);
    expect(s.kemPubFpHex.length, 64);
  });

  test('presence proof binds challengeId and seed digest', () {
    final presenceKeyHex = List.filled(32, 0).map((_) => '00').join();
    final seed = Uint8List.fromList(List.filled(32, 0x11));
    final digest = seedDigestHex(seed);
    final a = computePresenceProof(
      presenceKeyHex: presenceKeyHex,
      challengeId: 'chal-1',
      bandMac: 'aa:bb:cc:dd:ee:ff',
      seedDigestHex: digest,
    );
    final b = computePresenceProof(
      presenceKeyHex: presenceKeyHex,
      challengeId: 'chal-1',
      bandMac: 'AA:BB:CC:DD:EE:FF',
      seedDigestHex: digest,
    );
    final c = computePresenceProof(
      presenceKeyHex: presenceKeyHex,
      challengeId: 'chal-2',
      bandMac: 'AA:BB:CC:DD:EE:FF',
      seedDigestHex: digest,
    );
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.length, 64);
  });
}
