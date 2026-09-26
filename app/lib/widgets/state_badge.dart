import 'package:flutter/material.dart';

import '../models/account_state.dart';
import '../theme/theme.dart';

/// Pastille RUN, PAUSE ou KILL : icône en couleur, mot en toutes lettres.
class StateBadge extends StatelessWidget {
  const StateBadge(this.state, {super.key});

  final AccountState state;

  static Color colorOf(BuildContext context, AccountState state) {
    final mp = context.mp;
    return switch (state) {
      AccountState.run => mp.ok,
      AccountState.pause => mp.attention,
      AccountState.kill => mp.danger,
    };
  }

  static IconData iconOf(AccountState state) => switch (state) {
    AccountState.run => MpIcons.run,
    AccountState.pause => MpIcons.pause,
    AccountState.kill => MpIcons.kill,
  };

  @override
  Widget build(BuildContext context) {
    final color = colorOf(context, state);
    return Semantics(
      label: 'État : ${state.label}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: MpColors.tint(color),
          borderRadius: MpRadius.pill,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MpSpace.sm,
            MpSpace.xs,
            MpSpace.md,
            MpSpace.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconOf(state), size: 16, color: color),
              const SizedBox(width: 6),
              Text(state.label, style: context.text.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}
