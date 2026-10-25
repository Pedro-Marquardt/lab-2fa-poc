import 'dart:typed_data';

import 'package:bioentropy_mobile/lab/presence_proof.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pqcrypto/pqcrypto.dart';

void main() {
  test('pairing session produces ML-KEM-512 pk/sk', () {
    final s = createPairingSessionPqc();
    expect(hex.decode(s.publicKeyHex).length, 800);
    expect(s.secretKey.length, 1632);
    expect(s.kemPubFpHex.length, 64);
    s.wipe();
  });

  test('presence proof binds challengeId and seed digest via ss', () {
    final ss = Uint8List(32);
    final seed = Uint8List.fromList(List.filled(32, 0x11));
    final digest = seedDigestHex(seed);
    final a = computePresenceProof(
      sharedSecret: ss,
      challengeId: 'chal-1',
      bandMac: 'aa:bb:cc:dd:ee:ff',
      seedDigestHex: digest,
    );
    final b = computePresenceProof(
      sharedSecret: ss,
      challengeId: 'chal-1',
      bandMac: 'AA:BB:CC:DD:EE:FF',
      seedDigestHex: digest,
    );
    final c = computePresenceProof(
      sharedSecret: ss,
      challengeId: 'chal-2',
      bandMac: 'AA:BB:CC:DD:EE:FF',
      seedDigestHex: digest,
    );
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.length, 64);
  });

  test('self encaps/decaps roundtrip for challenge path', () {
    final session = createPairingSessionPqc();
    final kem = KyberKem(KyberLevel.kem512);
    final pk = Uint8List.fromList(hex.decode(session.publicKeyHex));
    final (ct, ssSend) = kem.encapsulate(pk);
    final ssRecv = decapsulateChallenge(
      secretKey: session.secretKey,
      kemCiphertextHex: hex.encode(ct),
    );
    expect(ssRecv, equals(ssSend));
    session.wipe();
  });
}
