import 'dart:math' as math;

import 'package:flutter/material.dart';

/// « G » quatre couleurs du bouton Continuer avec Google.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: const _GPainter());
  }
}

class _GPainter extends CustomPainter {
  const _GPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final r = (size.width - stroke) / 2;
    final c = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: c, radius: r);
    double deg(double d) => d * math.pi / 180;
    Paint pen(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    canvas.drawArc(rect, deg(-40), deg(85), false, pen(_blue));
    canvas.drawArc(rect, deg(45), deg(95), false, pen(_green));
    canvas.drawArc(rect, deg(140), deg(80), false, pen(_yellow));
    canvas.drawArc(rect, deg(220), deg(100), false, pen(_red));
    canvas.drawRect(
      Rect.fromLTRB(
        c.dx,
        c.dy - stroke / 2,
        c.dx + r + stroke / 2,
        c.dy + stroke / 2,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
