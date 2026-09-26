import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';
import '../utils/format.dart';

/// Repères sous la courbe d'une série : l'heure sur 24 h, le jour de la
/// semaine sur 7 jours, la date sur 30 jours.
List<String> seriesLabels(Series series) => [
  for (final t in series.ticks)
    switch (series.period) {
      BalancePeriod.day => MpFormat.time(t),
      BalancePeriod.week => MpFormat.weekday(t),
      BalancePeriod.month => MpFormat.day(t),
    },
];

/// Petite courbe des maquettes : trait coloré, aire en dégradé, point au
/// bout, repères verticaux en pointillé. [labels] s'affichent dessous.
class MpSparkline extends StatelessWidget {
  const MpSparkline(
    this.values, {
    super.key,
    required this.color,
    this.height = 72,
    this.labels = const [],
  });

  final List<double> values;
  final Color color;
  final double height;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall!.figures.copyWith(
      color: context.mp.textMuted,
      fontSize: 11,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _SparkPainter(
              values,
              color: color,
              grid: context.colors.outlineVariant,
              ring: context.colors.surfaceContainer,
            ),
          ),
        ),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: MpSpace.xs + 2),
          // Une case par repère : le premier calé à gauche, le dernier à
          // droite ; un repère trop long rapetisse au lieu de déborder.
          Row(
            children: [
              for (final (i, l) in labels.indexed)
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: i == 0
                        ? Alignment.centerLeft
                        : i == labels.length - 1
                        ? Alignment.centerRight
                        : Alignment.center,
                    child: Text(l, maxLines: 1, style: muted),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Grande courbe de l'écran Solde, dans un cadre.
/// Les repères d'arrêt et de relance viendront avec `fl_chart`.
class MpLineChart extends StatelessWidget {
  const MpLineChart(
    this.points, {
    super.key,
    required this.semanticsLabel,
    this.labels = const [],
    this.height = 200,
  });

  final List<double> points;
  final String semanticsLabel;
  final List<String> labels;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      image: true,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          MpSpace.lg,
          MpSpace.xl,
          MpSpace.lg,
          MpSpace.md,
        ),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(MpRadius.md)),
          border: Border.all(color: context.colors.outlineVariant),
        ),
        child: MpSparkline(
          points,
          color: MpPalette.orangeLine,
          height: height,
          labels: labels,
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(
    this.values, {
    required this.color,
    required this.grid,
    required this.ring,
  });

  final List<double> values;
  final Color color;
  final Color grid;
  final Color ring;

  static const _dot = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Repères verticaux en pointillé.
    final dash = Paint()
      ..color = grid.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var c = 1; c < 6; c++) {
      final x = size.width * c / 6;
      for (var y = 0.0; y < size.height; y += 7) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 3), dash);
      }
    }
    if (values.length < 2) return;

    var low = values.first;
    var high = values.first;
    for (final v in values) {
      if (v < low) low = v;
      if (v > high) high = v;
    }
    final span = high - low == 0 ? 1 : high - low;
    // De l'air en haut pour le point, un peu en bas pour l'aire.
    const top = _dot + 3;
    final bottom = size.height * 0.92;
    final right = size.width - _dot - 3;
    final points = [
      for (var i = 0; i < values.length; i++)
        Offset(
          right * i / (values.length - 1),
          top + (bottom - top) * (1 - (values[i] - low) / span),
        ),
    ];

    // Trait lissé : on passe par le milieu de chaque segment.
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset.lerp(points[i], points[i + 1], 0.5)!;
      line.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    line.lineTo(points.last.dx, points.last.dy);

    final area = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final end = points.last;
    canvas.drawCircle(
      end,
      _dot + 4,
      Paint()..color = color.withValues(alpha: 0.2),
    );
    canvas.drawCircle(end, _dot + 1.5, Paint()..color = ring);
    canvas.drawCircle(end, _dot - 0.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values ||
      old.color != color ||
      old.grid != grid ||
      old.ring != ring;
}
