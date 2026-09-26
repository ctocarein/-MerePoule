import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../utils/format.dart';

/// Petite pastille teintée : « ↗ +21,3 % », « Tendance positive ».
class MpPill extends StatelessWidget {
  const MpPill({super.key, required this.tone, required this.text, this.icon});

  final Tone tone;
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final ink = mp.ink(tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: mp.vivid(tone).withValues(alpha: 0.1),
        borderRadius: MpRadius.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?) ...[
              Icon(icon, size: 15, color: ink),
              const SizedBox(width: MpSpace.xs),
            ],
            Text(
              text,
              style: context.text.labelMedium!.figures.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pastille de variation : flèche et % ; rouge quand le chiffre baisse.
class TrendPill extends StatelessWidget {
  const TrendPill({super.key, required this.percent, required this.tone});

  final double percent;

  /// Couleur quand le chiffre monte.
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (icon, t) = percent > 0.05
        ? (MpIcons.rise, tone)
        : percent < -0.05
        ? (MpIcons.fall, Tone.red)
        : (MpIcons.flat, Tone.grey);
    return MpPill(
      tone: t,
      icon: icon,
      text: MpFormat.percent(percent, signed: true),
    );
  }
}
