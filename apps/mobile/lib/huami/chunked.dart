import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_write.dart';

/// Framing chunked transfer 2021 (Mi Band+ / Gadgetbridge).
class ChunkedWriter {
  ChunkedWriter(this._writeChar);

  final BluetoothCharacteristic _writeChar;
  int _handle = 0;

  int nextHandle() => _handle++;

  Future<void> write(int endpointType, int handle, Uint8List data) async {
    var remaining = data.length;
    var count = 0;
    var headerSize = 11;
    // ATT default; Huami chunked usa write-without-response
    const mtu = 23;

    while (remaining > 0) {
      final maxChunk = mtu - 3 - headerSize;
      final copyBytes = remaining < maxChunk ? remaining : maxChunk;
      final chunk = Uint8List(copyBytes + headerSize);

      var flags = 0;
      if (count == 0) {
        flags |= 0x01;
        chunk[5] = data.length & 0xff;
        chunk[6] = (data.length >> 8) & 0xff;
        chunk[7] = (data.length >> 16) & 0xff;
        chunk[8] = (data.length >> 24) & 0xff;
        chunk[9] = endpointType & 0xff;
        chunk[10] = (endpointType >> 8) & 0xff;
      }
      if (remaining <= maxChunk) {
        flags |= 0x06;
      }

      chunk[0] = 0x03;
      chunk[1] = flags;
      chunk[2] = 0;
      chunk[3] = handle & 0xff;
      chunk[4] = count & 0xff;

      final start = data.length - remaining;
      chunk.setRange(headerSize, headerSize + copyBytes, data, start);

      await bleWrite(_writeChar, chunk);
      // pequeno espaçamento evita overflow no buffer da band
      await Future<void>.delayed(const Duration(milliseconds: 30));
      remaining -= copyBytes;
      headerSize = 5;
      count++;
    }
  }
}
