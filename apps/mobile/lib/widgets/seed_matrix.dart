import 'package:flutter/material.dart';

/// Compact 16×16 heat grid derived from the local bio seed (demo only).
class SeedMatrix extends StatelessWidget {
  const SeedMatrix({super.key, required this.matrix, this.size = 168});

  final List<List<int>>? matrix;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MatrixPainter(
          matrix: matrix,
          empty: scheme.surfaceContainerHighest,
          ink: scheme.primary,
        ),
      ),
    );
  }
}

class _MatrixPainter extends CustomPainter {
  _MatrixPainter({
    required this.matrix,
    required this.empty,
    required this.ink,
  });

  final List<List<int>>? matrix;
  final Color empty;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 16;
    final cellW = size.width / n;
    final cellH = size.height / n;
    final emptyPaint = Paint()..color = empty;
    canvas.drawRect(Offset.zero & size, emptyPaint);

    final m = matrix;
    if (m == null || m.length != n) return;

    for (var r = 0; r < n; r++) {
      final row = m[r];
      if (row.length != n) continue;
      for (var c = 0; c < n; c++) {
        final t = (row[c] & 0xff) / 255.0;
        final paint = Paint()..color = Color.lerp(empty, ink, 0.25 + 0.75 * t)!;
        canvas.drawRect(
          Rect.fromLTWH(c * cellW, r * cellH, cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixPainter oldDelegate) =>
      oldDelegate.matrix != matrix ||
      oldDelegate.empty != empty ||
      oldDelegate.ink != ink;
}
