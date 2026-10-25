import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pqcrypto/pqcrypto.dart';

/// ML-KEM-512 session established at pair (phone keeps [secretKey]).
class PairingSessionPqc {
  PairingSessionPqc({
    required this.publicKeyHex,
    required this.secretKey,
    required this.kemPubFpHex,
  });

  /// ML-KEM-512 public key (hex) — sent to desktop at pair.
  final String publicKeyHex;

  /// Decapsulation key kept only in phone memory for this WS session.
  final Uint8List secretKey;

  /// SHA3-256(pk) for UI / audit.
  final String kemPubFpHex;

  void wipe() {
    secureZero(secretKey);
  }
}

/// Fresh ML-KEM-512 keypair for the pairing session.
PairingSessionPqc createPairingSessionPqc() {
  final seed = _randomBytes(64);
  final kem = KyberKem(KyberLevel.kem512);
  final (pk, sk) = kem.generateKeyPair(seed);
  secureZero(seed);

  final kemPubFp = sha3256(pk);
  final out = PairingSessionPqc(
    publicKeyHex: hex.encode(pk),
    secretKey: Uint8List.fromList(sk),
    kemPubFpHex: hex.encode(kemPubFp),
  );
  secureZero(pk);
  secureZero(sk);
  secureZero(kemPubFp);
  return out;
}

/// Decapsulate desktop ciphertext → 32-byte shared secret.
Uint8List decapsulateChallenge({
  required Uint8List secretKey,
  required String kemCiphertextHex,
}) {
  final ct = Uint8List.fromList(hex.decode(kemCiphertextHex.trim()));
  final kem = KyberKem(KyberLevel.kem512);
  return kem.decapsulate(secretKey, ct);
}

/// Unlock proof (Option A):
/// `SHA3(ss ‖ challengeId ‖ bandMac ‖ seedDigest)`.
String computePresenceProof({
  required Uint8List sharedSecret,
  required String challengeId,
  required String bandMac,
  required String seedDigestHex,
}) {
  if (sharedSecret.length != 32) {
    throw ArgumentError('sharedSecret must be 32 bytes');
  }
  final mac = bandMac.trim().toUpperCase();
  final material = BytesBuilder(copy: false)
    ..add(sharedSecret)
    ..add(utf8.encode(challengeId))
    ..addByte(0x00)
    ..add(utf8.encode(mac))
    ..addByte(0x00)
    ..add(Uint8List.fromList(hex.decode(seedDigestHex)));
  final bytes = material.toBytes();
  final digest = sha3256(bytes);
  final out = hex.encode(digest);
  secureZero(bytes);
  secureZero(digest);
  return out;
}

String seedDigestHex(Uint8List seed32) => hex.encode(sha3256(seed32));

Uint8List _randomBytes(int n) {
  final rnd = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
}
