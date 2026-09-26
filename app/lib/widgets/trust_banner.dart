import 'package:flutter/material.dart';

import '../models/account_state.dart';
import '../theme/theme.dart';
import '../utils/format.dart';
import 'signal_pill.dart';

/// Bandeau de confiance : vert, orange ou rouge, toujours avec l'âge du
/// statut, car un chiffre n'est jamais affiché sans son âge.
class TrustBanner extends StatelessWidget {
  const TrustBanner({super.key, required this.level, required this.age});

  final TrustLevel level;

  /// Âge du dernier statut reçu.
  final Duration age;

  @override
  Widget build(BuildContext context) {
    final when = MpFormat.age(age);
    return switch (level) {
      TrustLevel.live => SignalPill(
        signal: Signal.ok,
        icon: MpIcons.live,
        text: '${level.title} $when',
      ),
      TrustLevel.watchdogSilent => SignalPill(
        signal: Signal.attention,
        icon: MpIcons.watchdogSilent,
        text: level.title,
        details: ['Dernière donnée $when', level.advice!],
      ),
      TrustLevel.unreachable => SignalPill(
        signal: Signal.danger,
        icon: MpIcons.unreachable,
        text: level.title,
        details: ['Dernière donnée $when', level.advice!],
      ),
    };
  }
}
