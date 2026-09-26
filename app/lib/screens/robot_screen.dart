import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../widgets/coming_soon.dart';

/// Graphiques du robot ouverts ou non, santé du robot, exposition par symbole,
/// réglages de chaque graphique ; changer un réglage autorisé dans ses bornes
/// (biométrie et PIN).
class RobotScreen extends StatelessWidget {
  const RobotScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComingSoon(
      icon: MpIcons.robot,
      title: 'Robot',
      text: 'Les graphiques du robot, sa santé et ses réglages.',
    );
  }
}
