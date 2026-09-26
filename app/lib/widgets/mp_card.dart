import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Carte des maquettes : blanche, coins de 20, filet gris, ombre légère.
class MpCard extends StatelessWidget {
  const MpCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(MpSpace.lg + 2),
    this.gradient,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Remplace le fond blanc, pour une carte teintée.
  final Gradient? gradient;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? colors.surfaceContainer : null,
        gradient: gradient,
        borderRadius: MpRadius.card,
        border: Border.all(color: borderColor ?? colors.outlineVariant),
        boxShadow: context.mp.cardShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
