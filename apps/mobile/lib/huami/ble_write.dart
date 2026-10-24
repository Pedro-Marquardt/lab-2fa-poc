import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Escreve respeitando as properties GATT da characteristic.
/// Mi Band / Huami quase sempre usa **Write Without Response**.
Future<void> bleWrite(BluetoothCharacteristic c, List<int> value) async {
  final props = c.properties;
  final data = value is Uint8List ? value : Uint8List.fromList(value);

  if (props.writeWithoutResponse) {
    await c.write(data, withoutResponse: true);
    return;
  }
  if (props.write) {
    await c.write(data, withoutResponse: false);
    return;
  }
  throw StateError(
    'Characteristic ${c.uuid} não suporta WRITE '
    '(write=${props.write}, writeWithoutResponse=${props.writeWithoutResponse}, '
    'notify=${props.notify}, read=${props.read})',
  );
}
