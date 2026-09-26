import 'package:flutter/material.dart';

/// Piles de pièces orange de la carte « Le compte tient encore ».
class CoinsIllustration extends StatelessWidget {
  const CoinsIllustration({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: const _CoinsPainter(),
      ),
    );
  }
}

class _CoinsPainter extends CustomPainter {
  const _CoinsPainter();

  static const _face = [Color(0xFFFFD676), Color(0xFFFFB33A)];
  static const _side = [Color(0xFFFFA62B), Color(0xFFF08A00)];
  static const _rim = Color(0xFFFFE3A3);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // De l'arrière vers l'avant : chaque pile recouvre la précédente.
    _stack(canvas, Offset(s * 0.62, s * 0.62), s * 0.2, 4);
    _stack(canvas, Offset(s * 0.36, s * 0.8), s * 0.2, 3);
    _stack(canvas, Offset(s * 0.7, s * 0.96), s * 0.18, 2);
  }

  /// Pile de [count] pièces de rayon [r], posée sur [base] (bas de la pile).
  void _stack(Canvas canvas, Offset base, double r, int count) {
    final thick = r * 0.34;
    final ry = r * 0.42;
    for (var i = 0; i < count; i++) {
      final y = base.dy - ry - thick * (i + 1);
      final top = Rect.fromCenter(
        center: Offset(base.dx, y),
        width: r * 2,
        height: ry * 2,
      );
      final bottom = top.shift(Offset(0, thick));
      final sideRect = Rect.fromLTRB(
        top.left,
        top.center.dy,
        top.right,
        bottom.bottom,
      );
      final sidePaint = Paint()
        ..shader = const LinearGradient(colors: _side).createShader(sideRect);
      canvas.drawOval(bottom, sidePaint);
      canvas.drawRect(
        Rect.fromLTRB(top.left, top.center.dy, top.right, bottom.center.dy),
        sidePaint,
      );
      canvas.drawOval(
        top,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _face,
          ).createShader(top),
      );
      canvas.drawOval(
        top.deflate(r * 0.12),
        Paint()
          ..color = _rim.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
