import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Titre d'écran des maquettes : « Tableau de bord », et sa phrase.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, this.subtitle, {super.key});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: MpSpace.sm, bottom: MpSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.text.headlineLarge),
          const SizedBox(height: MpSpace.xs),
          Text(
            subtitle,
            style: context.text.bodyMedium!.copyWith(
              color: context.mp.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
