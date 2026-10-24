import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pointycastle/export.dart';

import 'ecdh_b163.dart';

/// Crypto do New Auth Protocol Huami 2021 (Mi Band+).
/// ECDH = NIST **B-163** (tiny-ECDH), AES = **ECB/NoPadding** (Gadgetbridge).
class HuamiCrypto {
  HuamiCrypto._();

  static Uint8List hexToBytes(String h) =>
      Uint8List.fromList(hex.decode(h.replaceAll(' ', '')));

  static String bytesToHex(Uint8List b) => hex.encode(b);

  /// private 24 B + public 48 B (formato wire Huami / tiny-ECDH).
  static ({Uint8List privateKey, Uint8List publicKey}) generateEcdhKeyPair([
    Random? random,
  ]) {
    final rnd = random ?? Random.secure();
    for (var attempt = 0; attempt < 32; attempt++) {
      final privateKey = Uint8List.fromList(
        List.generate(EcdhB163.ECC_PRV_KEY_SIZE, (_) => rnd.nextInt(256)),
      );
      final publicKey = EcdhB163.ecdhGeneratePublic(privateKey);
      if (publicKey != null) {
        return (privateKey: privateKey, publicKey: publicKey);
      }
    }
    throw StateError('Falha a gerar par ECDH B-163');
  }

  /// Shared secret 48 B (mesmo layout do tiny-ECDH).
  static Uint8List sharedSecret(Uint8List privateKey, Uint8List remotePublic) {
    final sec = EcdhB163.ecdhGenerateShared(privateKey, remotePublic);
    if (sec == null) {
      throw StateError('ECDH B-163 shared secret inválido (remote pub off-curve?)');
    }
    return sec;
  }

  /// AES/ECB/NoPadding — para 1 bloco de 16 B equivale a CBC com IV zero.
  static Uint8List aesEcbEncrypt(Uint8List key16, Uint8List block16) {
    if (key16.length != 16 || block16.length != 16) {
      throw ArgumentError('AES-ECB Huami espera key e bloco de 16 bytes');
    }
    final cipher = ECBBlockCipher(AESEngine())..init(true, KeyParameter(key16));
    final out = Uint8List(16);
    cipher.processBlock(block16, 0, out, 0);
    return out;
  }
}
