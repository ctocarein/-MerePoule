import 'package:flutter/material.dart';

import '../models/news_item.dart';
import '../theme/theme.dart';
import '../utils/format.dart';
import '../widgets/icon_bubble.dart';
import '../widgets/mp_card.dart';
import '../widgets/page_title.dart';
import '../widgets/segmented.dart';
import '../widgets/signal_pill.dart';

/// Annonces du courtier, calendrier économique si Forex, bilan du jour.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, required this.items, required this.age});

  final List<NewsItem> items;

  /// Âge de la dernière actualité reçue.
  final Duration age;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  NewsFilter _filter = NewsFilter.all;

  static IconData _icon(NewsKind kind) => switch (kind) {
    NewsKind.market => MpIcons.forex,
    NewsKind.calendar => MpIcons.calendar,
    NewsKind.volatility => MpIcons.alert,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final muted = t.bodyMedium!.copyWith(color: context.mp.textMuted);
    final items = widget.items.where(_filter.accepts).toList();

    return ListView(
      padding: MpSpace.screen,
      children: [
        const PageTitle('Actualités', 'Annonces et événements du marché.'),
        MpSegmented<NewsFilter>(
          values: NewsFilter.values,
          label: (f) => f.label,
          selected: _filter,
          onChanged: (f) => setState(() => _filter = f),
        ),
        const SizedBox(height: MpSpace.lg),
        MpCard(
          padding: const EdgeInsets.fromLTRB(
            MpSpace.gutter,
            MpSpace.gutter,
            MpSpace.gutter,
            MpSpace.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('À la une', style: t.titleLarge)),
                  Text('Aujourd’hui', style: muted),
                ],
              ),
              const SizedBox(height: MpSpace.xs),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: MpSpace.lg),
                  child: Text(
                    'Rien dans cette catégorie aujourd’hui.',
                    style: muted,
                  ),
                ),
              for (final (i, item) in items.indexed) ...[
                if (i > 0) const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: MpSpace.md + 2),
                  child: Row(
                    children: [
                      IconBubble(_icon(item.kind)),
                      const SizedBox(width: MpSpace.md + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title, style: t.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              item.text,
                              style: t.bodySmall!.copyWith(
                                color: context.mp.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: MpSpace.md),
        MpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Flux d’actualités', style: muted),
              const SizedBox(height: MpSpace.md),
              Row(
                children: [
                  Expanded(child: Text('Dernière mise à jour', style: muted)),
                  Text(MpFormat.age(widget.age), style: muted.figures),
                ],
              ),
              const SizedBox(height: MpSpace.md),
              const SignalPill(
                signal: Signal.ok,
                icon: MpIcons.ok,
                text: 'Flux actualisé',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
