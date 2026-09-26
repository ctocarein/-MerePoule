import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';
import '../theme/theme.dart';

/// Logo des maquettes : œuf orange, goutte sombre au centre.
class MpLogo extends StatelessWidget {
  const MpLogo({super.key, this.height = 96});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: MpConfig.appName,
      image: true,
      child: CustomPaint(
        size: Size(height * 0.8, height),
        painter: const _EggPainter(),
      ),
    );
  }
}

/// Pastille ronde orange de l'en-tête, la goutte au centre.
class MpLogoBadge extends StatelessWidget {
  const MpLogoBadge({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    final orange = context.colors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: orange,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: orange.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: CustomPaint(
        size: Size(size * 0.36, size * 0.46),
        painter: const _DropPainter(),
      ),
    );
  }
}

/// « MerePoule » : Mere à l'encre, Poule en orange.
class MpWordmark extends StatelessWidget {
  const MpWordmark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Mere'),
          TextSpan(
            text: 'Poule',
            style: TextStyle(color: context.colors.primary),
          ),
        ],
      ),
      semanticsLabel: MpConfig.appName,
      style: TextStyle(
        fontSize: size,
        height: 1.1,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.02 * size,
        color: context.colors.onSurface,
      ),
    );
  }
}

/// Œuf : plus étroit en haut. [size] donne la boîte ; l'œuf la remplit.
Path _eggPath(Size size) {
  final cx = size.width / 2;
  final cy = size.height / 2;
  final a = size.width / 2 / 1.06;
  final b = size.height / 2;
  final path = Path();
  for (var i = 0; i <= 180; i++) {
    final t = 2 * math.pi * i / 180;
    final s = math.sin(t);
    final p = Offset(cx + a * math.cos(t) * (1 - 0.12 * s), cy - b * s);
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

/// Goutte, pointe en haut, dans la boîte [rect].
Path _dropPath(Rect rect) {
  final w = rect.width / 2;
  final h = rect.height;
  final cx = rect.center.dx;
  final top = rect.top;
  final bottom = rect.bottom;
  final belly = top + h * 0.62;
  return Path()
    ..moveTo(cx, top)
    ..cubicTo(
      cx + w * 0.55,
      top + h * 0.28,
      cx + w,
      top + h * 0.42,
      cx + w,
      belly,
    )
    ..cubicTo(cx + w, bottom - h * 0.1, cx + w * 0.55, bottom, cx, bottom)
    ..cubicTo(cx - w * 0.55, bottom, cx - w, bottom - h * 0.1, cx - w, belly)
    ..cubicTo(cx - w, top + h * 0.42, cx - w * 0.55, top + h * 0.28, cx, top)
    ..close();
}

class _EggPainter extends CustomPainter {
  const _EggPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawPath(
      _eggPath(size),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFBE55), MpPalette.orange, Color(0xFFF08A00)],
        ).createShader(rect),
    );
    final drop = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.55),
      width: size.width * 0.42,
      height: size.height * 0.5,
    );
    canvas.drawPath(_dropPath(drop), Paint()..color = const Color(0xFF5A3208));
    final inner = Rect.fromLTRB(
      drop.left + drop.width * 0.12,
      drop.top + drop.height * 0.2,
      drop.right - drop.width * 0.12,
      drop.bottom - drop.height * 0.06,
    );
    canvas.drawPath(_dropPath(inner), Paint()..color = const Color(0xFF111111));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DropPainter extends CustomPainter {
  const _DropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _dropPath(Offset.zero & size),
      Paint()..color = const Color(0xFF111111),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
