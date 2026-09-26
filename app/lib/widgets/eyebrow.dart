import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Surtitre en capitales espacées, orange de la marque.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: context.text.labelSmall!.copyWith(
        color: context.mp.accentText,
        letterSpacing: 1.6,
      ),
    );
  }
}
