import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../widgets/coming_soon.dart';

/// Seuils actifs et plafonds (modifiables : biométrie et PIN), téléphones
/// enregistrés, diagnostic 24 h, notifications.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComingSoon(
      icon: MpIcons.thresholds,
      title: 'Réglages',
      text:
          'Les seuils d’arrêt, les téléphones enregistrés et les '
          'notifications.',
    );
  }
}
