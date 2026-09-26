import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum Signal { ok, attention, danger }

/// Bandeau teinté des maquettes : « ✓ Données à jour il y a 2 s ».
class SignalPill extends StatelessWidget {
  const SignalPill({
    super.key,
    required this.signal,
    required this.icon,
    required this.text,
    this.details = const [],
  });

  final Signal signal;
  final IconData icon;
  final String text;

  /// Lignes en dessous, en petit : âge, que faire.
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final (vivid, ink) = switch (signal) {
      Signal.ok => (mp.ok, mp.okText),
      Signal.attention => (mp.attention, mp.attentionText),
      Signal.danger => (mp.danger, mp.dangerText),
    };
    final small = context.text.bodySmall!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MpColors.tint(vivid),
        borderRadius: MpRadius.control,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MpSpace.md + 2,
          vertical: MpSpace.md - 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: ink),
            const SizedBox(width: MpSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: context.text.bodyMedium!.figures.copyWith(
                      color: ink,
                      fontWeight: details.isEmpty
                          ? FontWeight.w500
                          : FontWeight.w700,
                    ),
                  ),
                  for (final line in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(line, style: small.figures),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
