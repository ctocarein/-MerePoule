import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';

/// Une jauge de règle : nom, où l'on en est, barre verte, orange ou rouge.
class GaugeBar extends StatelessWidget {
  const GaugeBar(this.gauge, {super.key});

  final RiskGauge gauge;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final color = switch (gauge.level) {
      GaugeLevel.calm => mp.ok,
      GaugeLevel.near => mp.attention,
      GaugeLevel.crossed => mp.danger,
    };
    final muted = context.text.bodyMedium!.copyWith(color: mp.textMuted);
    final calm = gauge.level == GaugeLevel.calm;
    return Semantics(
      label: '${gauge.label} : ${gauge.value}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // La valeur prend au plus 60 % de la ligne, le nom le reste.
          LayoutBuilder(
            builder: (context, constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(gauge.label, style: muted)),
                const SizedBox(width: MpSpace.sm),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.6,
                  ),
                  child: Text(
                    gauge.value,
                    textAlign: TextAlign.end,
                    style: muted.figures.copyWith(
                      fontWeight: calm ? FontWeight.w400 : FontWeight.w700,
                      color: calm ? mp.textMuted : context.colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: MpSpace.sm),
          ClipRRect(
            borderRadius: MpRadius.pill,
            child: SizedBox(
              height: 8,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: mp.track),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    // Un filet reste visible à zéro, comme sur les maquettes.
                    widthFactor: gauge.fraction.clamp(0.04, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: MpRadius.pill,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
