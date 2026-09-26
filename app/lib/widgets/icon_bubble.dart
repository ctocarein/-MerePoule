import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Icône orange dans un rond gris, en tête des lignes du Journal et de
/// l'Actualité.
class IconBubble extends StatelessWidget {
  const IconBubble(this.icon, {super.key, this.color});

  final IconData icon;

  /// Orange de la marque par défaut.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: context.mp.bubble,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: color ?? context.colors.primary),
    );
  }
}
