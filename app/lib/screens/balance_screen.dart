import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';
import '../utils/format.dart';
import '../widgets/amount_text.dart';
import '../widgets/line_chart.dart';
import '../widgets/metric_card.dart';
import '../widgets/mp_card.dart';
import '../widgets/page_title.dart';
import '../widgets/segmented.dart';

/// Courbes du solde et de l'equity sur 24 h, 7 j, 30 j ; résultat par jour et
/// par semaine ; marqueurs d'arrêt, pause et relance.
class BalanceScreen extends StatefulWidget {
  const BalanceScreen({
    super.key,
    required this.account,
    required this.history,
  });

  final AccountSnapshot account;

  /// Equity par période.
  final Map<BalancePeriod, Series> history;

  @override
  State<BalanceScreen> createState() => _BalanceScreenState();
}

class _BalanceScreenState extends State<BalanceScreen> {
  BalancePeriod _period = BalancePeriod.week;

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final history = widget.history[_period];
    final t = context.text;
    final mp = context.mp;
    final muted = t.bodyMedium!.copyWith(color: mp.textMuted);

    return ListView(
      padding: MpSpace.screen,
      children: [
        const PageTitle('Solde', 'Évolution du solde et de l’equity.'),
        MpSegmented<BalancePeriod>(
          values: BalancePeriod.values,
          label: (p) => p.label,
          selected: _period,
          onChanged: (p) => setState(() => _period = p),
        ),
        const SizedBox(height: MpSpace.lg),
        MpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Equity actuelle', style: muted),
              const SizedBox(height: MpSpace.xs),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  a.equity,
                  currency: a.currency,
                  style: t.displayMedium,
                  signed: false,
                  colored: false,
                ),
              ),
              const SizedBox(height: MpSpace.xs),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text:
                          'Solde ${MpFormat.money(a.balance, currency: a.currency)}'
                          ' · Gain latent ',
                    ),
                    TextSpan(
                      text: MpFormat.money(
                        a.floating,
                        currency: a.currency,
                        signed: true,
                      ),
                      style: TextStyle(
                        color: a.floating >= 0 ? mp.okText : mp.dangerText,
                      ),
                    ),
                  ],
                ),
                style: muted.figures,
              ),
              const SizedBox(height: MpSpace.lg),
              if (history != null)
                MpLineChart(
                  history.values,
                  semanticsLabel:
                      'Courbe de l’equity sur ${_period.label}, de '
                      '${MpFormat.money(history.values.first, currency: a.currency)} à '
                      '${MpFormat.money(history.values.last, currency: a.currency)}',
                  labels: seriesLabels(history),
                ),
            ],
          ),
        ),
        if (history != null) ...[
          const SizedBox(height: MpSpace.md),
          MetricRow(
            MetricCard(
              label: 'Résultat ${_period.short}',
              value: AmountText(
                history.change,
                currency: a.currency,
                style: t.headlineSmall,
              ),
            ),
            MetricCard(
              label: 'Plus haut',
              value: AmountText(
                history.high,
                currency: a.currency,
                style: t.headlineSmall,
                signed: false,
                colored: false,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
