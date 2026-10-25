import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pqcrypto/pqcrypto.dart';

class PqcDemoResult {
  const PqcDemoResult({
    required this.sha3Hex,
    required this.mlKemPubFpHex,
    required this.publicKeyBytes,
  });

  final String sha3Hex;
  final String mlKemPubFpHex;
  final int publicKeyBytes;
}

/// SHA3-256(seed) + deterministic ML-KEM-512 keygen fingerprint (pubkey SHA3).
PqcDemoResult runPqcDemo(Uint8List seed32) {
  if (seed32.length != 32) {
    throw ArgumentError('seed must be 32 bytes');
  }

  final hash = sha3256(seed32);
  final sha3Hex = hex.encode(hash);

  // Expand to 64 bytes (d||z) so keygen is fully deterministic from the seed.
  final kemSeed = Shake256.shake(seed32, 64);
  final kem = KyberKem(KyberLevel.kem512);
  final (pk, sk) = kem.generateKeyPair(kemSeed);
  secureZero(kemSeed);
  secureZero(sk);

  final pubFp = sha3256(pk);
  final mlKemPubFpHex = hex.encode(pubFp);
  final pkLen = pk.length;
  secureZero(pk);
  secureZero(hash);
  secureZero(pubFp);

  return PqcDemoResult(
    sha3Hex: sha3Hex,
    mlKemPubFpHex: mlKemPubFpHex,
    publicKeyBytes: pkLen,
  );
}
