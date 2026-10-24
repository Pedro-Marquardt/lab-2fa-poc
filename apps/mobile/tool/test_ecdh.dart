import 'dart:typed_data';
import 'package:convert/convert.dart';
import '../lib/huami/ecdh_b163.dart';

Uint8List h(String s) => Uint8List.fromList(hex.decode(s.replaceAll(' ', '')));

void main() {
  final priv = h('0b42b9e61c23340e35c16e2e7de433f4b5859a72ec114027');
  final remote = h('e6016aba1de7ac0f0c7f0ff7e2243e6662b5e03b01000000ad8a4bedc76a1efde7725cc662b54835513e3d5705000000');
  final pub = EcdhB163.ecdhGeneratePublic(Uint8List.fromList(priv));
  final shared = EcdhB163.ecdhGenerateShared(Uint8List.fromList(priv), remote);
  print('pub   = ${pub == null ? "NULL" : hex.encode(pub)}');
  print('shared= ${shared == null ? "NULL" : hex.encode(shared)}');
}
