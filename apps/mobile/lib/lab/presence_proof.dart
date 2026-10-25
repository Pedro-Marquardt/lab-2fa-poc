import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pqcrypto/pqcrypto.dart';

/// Session material established at pair (local WS after QR).
///
/// Desktop stores [presenceKeyHex] and verifies unlock proofs.
/// [kemPubFpHex] is audit/UI only — shows ML-KEM ran at pair.
class PairingSessionPqc {
  const PairingSessionPqc({
    required this.presenceKeyHex,
    required this.kemPubFpHex,
  });

  /// 32-byte key, hex — used to MAC challenges (never physio).
  final String presenceKeyHex;

  /// SHA3-256(ML-KEM-512 public key), hex.
  final String kemPubFpHex;
}

/// Fresh ML-KEM-512 session → presence key + pubkey fingerprint.
PairingSessionPqc createPairingSessionPqc() {
  final seed = _randomBytes(64);
  final kem = KyberKem(KyberLevel.kem512);
  final (pk, sk) = kem.generateKeyPair(seed);
  secureZero(seed);

  // Presence key is derived from the secret key material (local pair channel).
  final presenceKey = sha3256(sk);
  final kemPubFp = sha3256(pk);

  final out = PairingSessionPqc(
    presenceKeyHex: hex.encode(presenceKey),
    kemPubFpHex: hex.encode(kemPubFp),
  );

  secureZero(sk);
  secureZero(pk);
  secureZero(presenceKey);
  secureZero(kemPubFp);
  return out;
}

/// Verifiable unlock proof:
/// `SHA3(presenceKey ‖ challengeId ‖ bandMac ‖ seedDigest)`.
///
/// [seedDigestHex] is SHA3 of the on-device bio seed (not the seed itself).
String computePresenceProof({
  required String presenceKeyHex,
  required String challengeId,
  required String bandMac,
  required String seedDigestHex,
}) {
  final key = Uint8List.fromList(hex.decode(presenceKeyHex));
  final mac = bandMac.trim().toUpperCase();
  final material = BytesBuilder(copy: false)
    ..add(key)
    ..add(utf8.encode(challengeId))
    ..addByte(0x00)
    ..add(utf8.encode(mac))
    ..addByte(0x00)
    ..add(Uint8List.fromList(hex.decode(seedDigestHex)));
  final bytes = material.toBytes();
  final digest = sha3256(bytes);
  final out = hex.encode(digest);
  secureZero(key);
  secureZero(bytes);
  secureZero(digest);
  return out;
}

String seedDigestHex(Uint8List seed32) => hex.encode(sha3256(seed32));

Uint8List _randomBytes(int n) {
  final rnd = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
}
