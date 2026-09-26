import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'eyebrow.dart';

/// Écran pas encore construit : ce qu'il montrera, en une phrase.
class ComingSoon extends StatelessWidget {
  const ComingSoon({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MpSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(MpSpace.lg),
                child: Icon(icon, size: 32, color: colors.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: MpSpace.lg),
            const Eyebrow('Bientôt'),
            const SizedBox(height: MpSpace.xs),
            Text(title, style: context.text.headlineSmall),
            const SizedBox(height: MpSpace.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: context.text.bodyMedium!.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
