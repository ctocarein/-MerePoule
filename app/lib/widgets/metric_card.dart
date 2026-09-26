import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'mp_card.dart';

/// Carte d'un chiffre : légende, valeur en gros, ligne facultative dessous.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.footer,
  });

  final String label;
  final Widget value;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return MpCard(
      padding: const EdgeInsets.all(MpSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.text.bodyMedium!.copyWith(
              color: context.mp.textMuted,
            ),
          ),
          const SizedBox(height: MpSpace.sm),
          // Un gros solde rapetisse au lieu de déborder.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: value,
          ),
          if (footer case final footer?) ...[
            const SizedBox(height: MpSpace.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: footer,
            ),
          ],
        ],
      ),
    );
  }
}

/// Deux cartes côte à côte, de même hauteur.
class MetricRow extends StatelessWidget {
  const MetricRow(this.left, this.right, {super.key});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: MpSpace.md),
          Expanded(child: right),
        ],
      ),
    );
  }
}
