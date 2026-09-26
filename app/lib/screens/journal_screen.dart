import 'package:flutter/material.dart';

import '../models/journal_event.dart';
import '../theme/theme.dart';
import '../utils/format.dart';
import '../widgets/icon_bubble.dart';
import '../widgets/mp_card.dart';
import '../widgets/page_title.dart';
import '../widgets/segmented.dart';

/// Arrêts, alertes, commandes (qui, quand, quel téléphone), relances ;
/// filtre par type.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key, required this.events});

  /// Du plus récent au plus ancien.
  final List<JournalEvent> events;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  JournalFilter _filter = JournalFilter.all;

  static IconData _icon(JournalKind kind) => switch (kind) {
    JournalKind.stop => MpIcons.killed,
    JournalKind.alert => MpIcons.alert,
    JournalKind.shield => MpIcons.shield,
    JournalKind.restart => MpIcons.restart,
    JournalKind.command => MpIcons.pauseAction,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final muted = t.bodySmall!.copyWith(color: context.mp.textMuted);
    final events = widget.events.where((e) => _filter.accepts(e.kind)).toList();

    return ListView(
      padding: MpSpace.screen,
      children: [
        const PageTitle('Journal', 'Toutes les actions importantes du robot.'),
        MpSegmented<JournalFilter>(
          values: JournalFilter.values,
          label: (f) => f.label,
          selected: _filter,
          onChanged: (f) => setState(() => _filter = f),
        ),
        const SizedBox(height: MpSpace.lg),
        MpCard(
          padding: const EdgeInsets.symmetric(
            horizontal: MpSpace.gutter,
            vertical: MpSpace.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: MpSpace.xl),
                  child: Text(
                    'Rien de ce type pour l’instant.',
                    style: t.bodyMedium!.copyWith(color: context.mp.textMuted),
                  ),
                ),
              for (final (i, event) in events.indexed) ...[
                if (i > 0) const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: MpSpace.lg),
                  child: Row(
                    children: [
                      IconBubble(_icon(event.kind)),
                      const SizedBox(width: MpSpace.md + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title, style: t.titleMedium),
                            const SizedBox(height: 2),
                            Text(event.detail, style: muted),
                          ],
                        ),
                      ),
                      const SizedBox(width: MpSpace.sm),
                      Text(MpFormat.time(event.time), style: muted.figures),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
