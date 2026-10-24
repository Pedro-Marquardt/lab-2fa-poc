import 'dart:typed_data';

/// Decoder chunked 2021 (Gadgetbridge `Huami2021ChunkedDecoder`).
class ChunkedDecodeResult {
  ChunkedDecodeResult({
    required this.needsAck,
    this.payload,
    this.endpoint,
  });

  final bool needsAck;
  final Uint8List? payload; // só quando lastChunk
  final int? endpoint;
}

class Huami2021ChunkedDecoder {
  Huami2021ChunkedDecoder({this.force2021Protocol = true});

  final bool force2021Protocol;

  int? _currentHandle;
  int _currentType = 0;
  int _currentLength = 0;
  BytesBuilder? _reassembly;

  int lastHandle = 0;
  int lastCount = 0;

  ChunkedDecodeResult decode(Uint8List data) {
    if (data.isEmpty || data[0] != 0x03) {
      return ChunkedDecodeResult(needsAck: false);
    }

    var i = 1;
    final flags = data[i++];
    final firstChunk = (flags & 0x01) == 0x01;
    final lastChunk = (flags & 0x02) == 0x02;
    final needsAck = (flags & 0x04) == 0x04;

    if (force2021Protocol) {
      i++; // extended header
    }
    final handle = data[i++];
    if (_currentHandle != null && _currentHandle != handle) {
      return ChunkedDecodeResult(needsAck: false);
    }
    lastHandle = handle;
    lastCount = data[i++];

    if (firstChunk) {
      _currentLength = data[i] |
          (data[i + 1] << 8) |
          (data[i + 2] << 16) |
          (data[i + 3] << 24);
      i += 4;
      _reassembly = BytesBuilder(copy: false);
      _currentType = data[i] | (data[i + 1] << 8);
      i += 2;
      _currentHandle = handle;
    }

    if (i < data.length) {
      _reassembly?.add(data.sublist(i));
    }

    if (lastChunk) {
      final buf = _reassembly?.toBytes() ?? Uint8List(0);
      final endpoint = _currentType;
      // length no header = tamanho do payload (sem os 2 B do endpoint)
      final payload = buf.length >= _currentLength
          ? Uint8List.fromList(buf.sublist(0, _currentLength))
          : Uint8List.fromList(buf);
      _currentHandle = null;
      _currentType = 0;
      _reassembly = null;
      return ChunkedDecodeResult(
        needsAck: needsAck,
        payload: payload,
        endpoint: endpoint,
      );
    }

    return ChunkedDecodeResult(needsAck: needsAck);
  }

  /// ACK: write na characteristic **read** (0x0017).
  Uint8List buildAck() =>
      Uint8List.fromList([0x04, 0x00, lastHandle, 0x01, lastCount]);
}
