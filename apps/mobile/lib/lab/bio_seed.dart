import 'dart:convert';
import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';

/// Snapshot used only on-device to derive a demo seed. Never leave the phone.
class BioSeedInput {
  const BioSeedInput({
    required this.bpmSamples,
    required this.bandMac,
    required this.capturedAtMs,
    this.spo2,
    this.steps,
    this.distanceM,
    this.calories,
  });

  final List<int> bpmSamples;
  final String bandMac;
  final int capturedAtMs;
  final int? spo2;
  final int? steps;
  final int? distanceM;
  final int? calories;
}

class BioSeedResult {
  BioSeedResult({
    required this.seed32,
    required this.matrix,
    required this.usedBpm,
    required this.usedSpo2,
    required this.usedSteps,
  });

  final Uint8List seed32;

  /// 16×16 cells derived from the seed (demo visualization only).
  final List<List<int>> matrix;
  final List<int> usedBpm;
  final int? usedSpo2;
  final int? usedSteps;

  void wipe() {
    secureZero(seed32);
    for (final row in matrix) {
      for (var i = 0; i < row.length; i++) {
        row[i] = 0;
      }
    }
    usedBpm.clear();
  }
}

/// Canonical bytes → SHAKE-256 → 32-byte seed + 16×16 matrix.
BioSeedResult deriveBioSeed(BioSeedInput input) {
  if (input.bpmSamples.isEmpty) {
    throw ArgumentError('bpmSamples must not be empty');
  }
  final mac = input.bandMac.trim().toUpperCase();
  if (mac.isEmpty) {
    throw ArgumentError('bandMac required');
  }

  final buf = BytesBuilder(copy: false);
  buf.add(utf8.encode('lab2fa-bio-seed-v1'));
  buf.addByte(0x00);
  buf.add(utf8.encode(mac));
  buf.addByte(0x00);

  final bpm = List<int>.from(input.bpmSamples);
  buf.addByte(bpm.length & 0xff);
  for (final b in bpm) {
    buf.addByte(b.clamp(0, 255));
  }

  _writeOptionalU16(buf, 0x01, input.spo2);
  _writeOptionalU32(buf, 0x02, input.steps);
  _writeOptionalU32(buf, 0x03, input.distanceM);
  _writeOptionalU32(buf, 0x04, input.calories);

  final ts = ByteData(8)..setUint64(0, input.capturedAtMs, Endian.big);
  buf.add(ts.buffer.asUint8List());

  final material = buf.toBytes();
  final expanded = Shake256.shake(material, 32 + 256);
  secureZero(material);

  final seed32 = Uint8List.fromList(expanded.sublist(0, 32));
  final matrixBytes = Uint8List.fromList(expanded.sublist(32, 32 + 256));
  secureZero(expanded);

  final matrix = List.generate(
    16,
    (r) => List<int>.generate(16, (c) => matrixBytes[r * 16 + c]),
  );
  secureZero(matrixBytes);

  return BioSeedResult(
    seed32: seed32,
    matrix: matrix,
    usedBpm: bpm,
    usedSpo2: input.spo2,
    usedSteps: input.steps,
  );
}

void _writeOptionalU16(BytesBuilder buf, int tag, int? value) {
  if (value == null) return;
  buf.addByte(tag);
  final bd = ByteData(2)..setUint16(0, value & 0xffff, Endian.big);
  buf.add(bd.buffer.asUint8List());
}

void _writeOptionalU32(BytesBuilder buf, int tag, int? value) {
  if (value == null) return;
  buf.addByte(tag);
  final bd = ByteData(4)..setUint32(0, value & 0xffffffff, Endian.big);
  buf.add(bd.buffer.asUint8List());
}
