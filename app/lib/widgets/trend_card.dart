import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/theme.dart';
import 'amount_text.dart';
import 'line_chart.dart';
import 'mp_card.dart';
import 'pill.dart';

/// Carte d'un chiffre et de sa tendance : icône, nom, pastille de variation,
/// menu ⋯ de la période, grand chiffre, variation en devise, petite courbe.
class TrendCard extends StatefulWidget {
  const TrendCard({
    super.key,
    required this.icon,
    required this.label,
    required this.tone,
    required this.value,
    required this.history,
    this.changeCurrency,
  });

  final IconData icon;
  final String label;

  /// Couleur de l'icône, de la courbe, et de la pastille quand ça monte.
  final Tone tone;

  /// Le chiffre actuel, en grand.
  final Widget value;

  final Map<BalancePeriod, Series> history;

  /// Si présent, la variation de la période s'affiche en devise sous le
  /// chiffre.
  final String? changeCurrency;

  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  BalancePeriod _period = BalancePeriod.week;

  @override
  Widget build(BuildContext context) {
    final mp = context.mp;
    final series = widget.history[_period];
    final color = mp.vivid(widget.tone);
    return MpCard(
      padding: const EdgeInsets.fromLTRB(
        MpSpace.lg + 2,
        MpSpace.sm,
        MpSpace.sm,
        MpSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(widget.icon, color: color, size: 26),
              const SizedBox(width: MpSpace.sm + 2),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyLarge!.copyWith(
                    color: context.colors.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (series != null)
                TrendPill(percent: series.changePercent, tone: widget.tone),
              _PeriodMenu(
                selected: _period,
                onSelected: (p) => setState(() => _period = p),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: MpSpace.sm + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: widget.value,
                ),
                if (series != null && widget.changeCurrency != null)
                  AmountText(
                    series.change,
                    currency: widget.changeCurrency,
                    style: context.text.bodyLarge,
                    suffix: ' en ${_period.short}',
                  ),
                if (series != null) ...[
                  const SizedBox(height: MpSpace.md),
                  MpSparkline(series.values, color: color),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodMenu extends StatelessWidget {
  const _PeriodMenu({required this.selected, required this.onSelected});

  final BalancePeriod selected;
  final ValueChanged<BalancePeriod> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<BalancePeriod>(
      tooltip: 'Période',
      icon: Icon(MpIcons.more, color: context.mp.textMuted),
      position: PopupMenuPosition.under,
      shape: const RoundedRectangleBorder(borderRadius: MpRadius.control),
      color: context.colors.surfaceContainerLowest,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final p in BalancePeriod.values)
          PopupMenuItem(
            value: p,
            child: Row(
              children: [
                Expanded(child: Text(p.label)),
                if (p == selected)
                  Icon(MpIcons.check, size: 18, color: context.colors.primary),
              ],
            ),
          ),
      ],
    );
  }
}
