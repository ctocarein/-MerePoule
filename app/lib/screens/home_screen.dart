import 'package:flutter/material.dart';

import '../models/account.dart';
import '../models/account_state.dart';
import '../theme/theme.dart';
import '../utils/format.dart';
import '../widgets/amount_text.dart';
import '../widgets/coins.dart';
import '../widgets/gauge_bar.dart';
import '../widgets/line_chart.dart';
import '../widgets/metric_card.dart';
import '../widgets/mp_card.dart';
import '../widgets/page_title.dart';
import '../widgets/pill.dart';
import '../widgets/trend_card.dart';
import '../widgets/trust_banner.dart';

/// État RUN, PAUSE ou KILL ; bandeau de confiance ; solde, equity, gain latent,
/// marge et leur tendance ; distance au stop-out ; jauges des règles. Aucune
/// action.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.data});

  final AccountData data;

  /// Au-delà, deux cartes par ligne comme sur les maquettes ; en dessous, sur
  /// un téléphone, une par ligne pour que l'en-tête de chaque carte tienne.
  static const _twoColumns = 560.0;

  @override
  Widget build(BuildContext context) {
    final a = data.account;
    final big = context.text.displaySmall!;
    const gap = SizedBox(height: MpSpace.md);

    final cards = [
      TrendCard(
        icon: MpIcons.wallet,
        label: 'Solde',
        tone: Tone.green,
        history: data.history[Metric.balance] ?? const {},
        changeCurrency: a.currency,
        value: AmountText(
          a.balance,
          currency: a.currency,
          style: big,
          signed: false,
          colored: false,
        ),
      ),
      TrendCard(
        icon: MpIcons.equity,
        label: 'Equity',
        tone: Tone.orange,
        history: data.history[Metric.equity] ?? const {},
        changeCurrency: a.currency,
        value: AmountText(
          a.equity,
          currency: a.currency,
          style: big,
          signed: false,
          colored: false,
        ),
      ),
      TrendCard(
        icon: MpIcons.floating,
        label: 'Gain latent',
        tone: a.floating < 0 ? Tone.red : Tone.green,
        history: data.history[Metric.floating] ?? const {},
        value: AmountText(a.floating, currency: a.currency, style: big),
      ),
      TrendCard(
        icon: MpIcons.margin,
        label: 'Niveau de marge',
        tone: Tone.blue,
        history: a.marginLevel == null
            ? const {}
            : data.history[Metric.margin] ?? const {},
        value: Text(
          a.marginLevel == null
              ? 'aucune position'
              : MpFormat.percent(a.marginLevel!, decimals: 0),
          style: big.figures,
        ),
      ),
    ];

    return ListView(
      padding: MpSpace.screen,
      children: [
        const PageTitle(
          'Tableau de bord',
          'Votre robot veille sur votre capital.',
        ),
        _StatusCard(a),
        gap,
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= _twoColumns) {
              return Column(
                children: [
                  MetricRow(cards[0], cards[1]),
                  gap,
                  MetricRow(cards[2], cards[3]),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, card) in cards.indexed) ...[
                  if (i > 0) gap,
                  card,
                ],
              ],
            );
          },
        ),
        if (a.stopOut case final stopOut?) ...[
          gap,
          _StopOutCard(
            stopOut,
            data.history[Metric.stopOut]?[BalancePeriod.week],
          ),
        ],
        gap,
        _GaugesCard(a.gauges),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard(this.account);

  final AccountSnapshot account;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final color = switch (account.state) {
      AccountState.run => mp.ok,
      AccountState.pause => mp.attention,
      AccountState.kill => mp.danger,
    };
    return MpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StateDot(color),
              const SizedBox(width: MpSpace.md),
              Semantics(
                label: 'État : ${account.state.label}',
                excludeSemantics: true,
                child: Text(
                  account.state.code,
                  style: context.text.headlineMedium,
                ),
              ),
              const SizedBox(width: MpSpace.md),
              Expanded(
                child: Text(
                  '${account.chartsOpen}/${account.chartsTotal} graphiques',
                  textAlign: TextAlign.end,
                  style: context.text.bodyMedium!.figures.copyWith(
                    color: mp.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MpSpace.lg),
          TrustBanner(level: account.trust, age: account.statusAge),
        ],
      ),
    );
  }
}

/// Point de couleur de l'état, dans son halo.
class _StateDot extends StatelessWidget {
  const _StateDot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: MpColors.tint(color),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// « Le compte tient encore 6 380 points » : pièces, distance, tendance sur
/// 7 jours et sa courbe.
class _StopOutCard extends StatelessWidget {
  const _StopOutCard(this.stopOut, this.week);

  final StopOutDistance stopOut;
  final Series? week;

  @override
  Widget build(BuildContext context) {
    final orange = context.colors.primary;
    final card = context.colors.surfaceContainer;
    final muted = context.text.bodyMedium!.copyWith(
      color: context.mp.textMuted,
    );

    final figures = Row(
      children: [
        const CoinsIllustration(),
        const SizedBox(width: MpSpace.md + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Le compte tient encore', style: muted),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '${MpFormat.number(stopOut.points, decimals: 0)} points',
                  style: context.text.displaySmall!.figures.copyWith(
                    color: orange,
                  ),
                ),
              ),
              Text(
                'avant la coupure du courtier (${stopOut.symbol})',
                style: muted,
              ),
            ],
          ),
        ),
      ],
    );

    final series = week;
    final trend = series == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: _TrendLabel(series.changePercent),
              ),
              const SizedBox(height: MpSpace.sm),
              MpSparkline(
                series.values,
                color: orange,
                height: 64,
                labels: seriesLabels(series),
              ),
            ],
          );

    return MpCard(
      gradient: LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color.alphaBlend(orange.withValues(alpha: 0.07), card),
          Color.alphaBlend(orange.withValues(alpha: 0.18), card),
        ],
      ),
      borderColor: orange.withValues(alpha: 0.4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (trend == null) return figures;
          if (constraints.maxWidth >= HomeScreen._twoColumns) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 5, child: figures),
                const SizedBox(width: MpSpace.lg),
                Expanded(flex: 6, child: trend),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              figures,
              const SizedBox(height: MpSpace.md),
              trend,
            ],
          );
        },
      ),
    );
  }
}

/// « Tendance positive » quand la distance au stop-out grandit.
class _TrendLabel extends StatelessWidget {
  const _TrendLabel(this.percent);

  final double percent;

  @override
  Widget build(BuildContext context) {
    final (text, tone) = percent > 1
        ? ('Tendance positive', Tone.orange)
        : percent < -1
        ? ('Tendance négative', Tone.red)
        : ('Stable', Tone.grey);
    return MpPill(tone: tone, icon: MpIcons.clock, text: text);
  }
}

class _GaugesCard extends StatelessWidget {
  const _GaugesCard(this.gauges);

  final List<RiskGauge> gauges;

  @override
  Widget build(BuildContext context) {
    return MpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Jauges de risque', style: context.text.titleLarge),
          for (final gauge in gauges) ...[
            const SizedBox(height: MpSpace.lg),
            GaugeBar(gauge),
          ],
        ],
      ),
    );
  }
}
