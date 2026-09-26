import 'dart:math' as math;

import '../models/account.dart';
import '../models/account_state.dart';
import '../models/journal_event.dart';
import '../models/news_item.dart';
import '../theme/colors.dart';

/// Comptes de démonstration : chiffres d'exemple, repris des maquettes, pour
/// voir les écrans sans passerelle. Rien n'en part vers MT5.
abstract final class Demo {
  /// Heure « actuelle » des données d'exemple.
  static final now = DateTime(2026, 9, 25, 14, 5);

  static final List<AccountData> accounts = [
    _account(
      const AccountSnapshot(
        label: 'Compte Démo',
        login: '123456',
        broker: 'Weltrade',
        platform: 'MT5',
        initial: 'R',
        tone: Tone.orange,
        currency: 'USD',
        state: AccountState.run,
        trust: TrustLevel.live,
        statusAge: Duration(seconds: 2),
        chartsOpen: 4,
        chartsTotal: 4,
        balance: 2614.85,
        equity: 7173.06,
        marginLevel: 452,
        stopOut: StopOutDistance(points: 6380, symbol: 'MAX PainX 2000'),
        gauges: [
          RiskGauge(
            label: 'Marge',
            value: '452 % · alerte sous 500 %',
            fraction: 0.9,
            level: GaugeLevel.near,
          ),
          RiskGauge(
            label: 'Perte flottante',
            value: 'aucune · coupe à −440 \$',
            fraction: 0,
            level: GaugeLevel.calm,
          ),
          RiskGauge(
            label: 'Recul depuis le plus haut',
            value: '3 % sur 20 %',
            fraction: 0.15,
            level: GaugeLevel.calm,
          ),
          RiskGauge(
            label: 'Positions sans stop loss',
            value: '0 · Bouclier actif',
            fraction: 0,
            level: GaugeLevel.calm,
          ),
        ],
      ),
      seed: 3,
      balance: (0.8, 21.3, 48),
      equity: (1.2, 18.7, 61),
      floating: (3.1, 12.4, 35),
      margin: (-1.4, 5.2, 9),
      stopOut: (0.5, 14, 22),
      journal: [
        JournalEvent(
          kind: JournalKind.command,
          title: 'PAUSE demandée',
          detail: '4 graphiques mis de côté · positions gardées',
          time: DateTime(2026, 9, 25, 14, 2),
        ),
        JournalEvent(
          kind: JournalKind.shield,
          title: 'Bouclier : 5 stop loss posés',
          detail: 'MAX PainX 2000',
          time: DateTime(2026, 9, 25, 13, 47),
        ),
        JournalEvent(
          kind: JournalKind.alert,
          title: 'Alerte : marge basse',
          detail: '452 % sous le seuil de 500 %',
          time: DateTime(2026, 9, 25, 13, 30),
        ),
        JournalEvent(
          kind: JournalKind.restart,
          title: 'Machine redémarrée',
          detail: 'Arrêt de 2 min · état : RUN',
          time: DateTime(2026, 9, 25, 9, 12),
        ),
        JournalEvent(
          kind: JournalKind.stop,
          title: 'KILL : perte flottante',
          detail: 'Positions fermées · bilan envoyé',
          time: DateTime(2026, 9, 25, 7, 13),
        ),
      ],
    ),
    _account(
      const AccountSnapshot(
        label: 'Compte Live',
        login: '789012',
        broker: 'Weltrade',
        platform: 'MT5',
        initial: 'L',
        tone: Tone.blue,
        currency: 'USD',
        state: AccountState.run,
        trust: TrustLevel.live,
        statusAge: Duration(seconds: 1),
        chartsOpen: 2,
        chartsTotal: 2,
        balance: 10250.40,
        equity: 10118.75,
        marginLevel: 1840,
        stopOut: StopOutDistance(points: 12400, symbol: 'MAX GainX 1000'),
        gauges: [
          RiskGauge(
            label: 'Marge',
            value: '1 840 % · alerte sous 500 %',
            fraction: 0.2,
            level: GaugeLevel.calm,
          ),
          RiskGauge(
            label: 'Perte flottante',
            value: '−132 \$ sur −440 \$',
            fraction: 0.3,
            level: GaugeLevel.calm,
          ),
          RiskGauge(
            label: 'Recul depuis le plus haut',
            value: '1 % sur 20 %',
            fraction: 0.05,
            level: GaugeLevel.calm,
          ),
        ],
      ),
      seed: 11,
      balance: (0.3, 2.1, 6.5),
      equity: (-0.4, 1.6, 5.8),
      floating: (40, 25, 60),
      margin: (2.2, 4.1, 3.5),
      stopOut: (0.2, 3, 8),
      journal: [
        JournalEvent(
          kind: JournalKind.shield,
          title: 'Bouclier : 2 stop loss posés',
          detail: 'MAX GainX 1000',
          time: DateTime(2026, 9, 25, 11, 20),
        ),
        JournalEvent(
          kind: JournalKind.command,
          title: 'Relance demandée',
          detail: 'Robot en marche · marché favorable',
          time: DateTime(2026, 9, 24, 18, 40),
        ),
      ],
    ),
    _account(
      const AccountSnapshot(
        label: 'Petit Poussin',
        login: '345678',
        broker: 'Weltrade',
        platform: 'MT5',
        initial: 'P',
        tone: Tone.green,
        currency: 'USD',
        state: AccountState.pause,
        trust: TrustLevel.watchdogSilent,
        statusAge: Duration(minutes: 3),
        chartsOpen: 0,
        chartsTotal: 3,
        balance: 1480.20,
        equity: 1512.90,
        marginLevel: 2950,
        stopOut: StopOutDistance(points: 9100, symbol: 'SFX Vol 80'),
        gauges: [
          RiskGauge(
            label: 'Marge',
            value: '2 950 % · alerte sous 500 %',
            fraction: 0.1,
            level: GaugeLevel.calm,
          ),
          RiskGauge(
            label: 'Recul depuis le plus haut',
            value: '12 % sur 20 %',
            fraction: 0.6,
            level: GaugeLevel.near,
          ),
        ],
      ),
      seed: 23,
      balance: (-0.6, -3.2, 4.4),
      equity: (-0.9, -2.7, 5.1),
      floating: (8, -18, 30),
      margin: (-2.5, -6.1, 3),
      stopOut: (-0.4, -5, 2),
      journal: [
        JournalEvent(
          kind: JournalKind.command,
          title: 'PAUSE demandée',
          detail: '3 graphiques mis de côté · positions gardées',
          time: DateTime(2026, 9, 25, 12, 55),
        ),
      ],
    ),
  ];

  static const _news = [
    NewsItem(
      category: NewsCategory.forex,
      kind: NewsKind.market,
      title: 'EUR / USD — marché',
      text: 'Mouvements récents et contexte économique.',
    ),
    NewsItem(
      category: NewsCategory.macro,
      kind: NewsKind.calendar,
      title: 'Calendrier économique',
      text: 'Annonces qui peuvent faire bouger fortement le marché.',
    ),
    NewsItem(
      category: NewsCategory.indices,
      kind: NewsKind.volatility,
      title: 'Alertes de volatilité',
      text: 'Moments agités signalés à la surveillance.',
    ),
  ];

  /// Variations en % sur 24 h, 7 jours et 30 jours.
  static AccountData _account(
    AccountSnapshot a, {
    required int seed,
    required (double, double, double) balance,
    required (double, double, double) equity,
    required (double, double, double) floating,
    required (double, double, double) margin,
    required (double, double, double) stopOut,
    required List<JournalEvent> journal,
  }) {
    return AccountData(
      account: a,
      history: {
        Metric.balance: _periods(a.balance, balance, seed),
        Metric.equity: _periods(a.equity, equity, seed + 1),
        Metric.floating: _periods(a.floating, floating, seed + 2),
        Metric.margin: _periods(a.marginLevel ?? 0, margin, seed + 3),
        Metric.stopOut: _periods(
          (a.stopOut?.points ?? 0).toDouble(),
          stopOut,
          seed + 4,
        ),
      },
      news: _news,
      newsAge: const Duration(minutes: 2),
      journal: journal,
    );
  }

  static Map<BalancePeriod, Series> _periods(
    double end,
    (double, double, double) pct,
    int seed,
  ) => {
    BalancePeriod.day: _series(end, pct.$1, BalancePeriod.day, seed),
    BalancePeriod.week: _series(end, pct.$2, BalancePeriod.week, seed + 7),
    BalancePeriod.month: _series(end, pct.$3, BalancePeriod.month, seed + 31),
  };

  /// Courbe en dents de scie qui finit à [end] après une variation de [pct] %.
  static Series _series(
    double end,
    double pct,
    BalancePeriod period,
    int seed,
  ) {
    const n = 28;
    final start = end / (1 + pct / 100);
    final amplitude = (end - start).abs() * 0.14 + end.abs() * 0.004;
    var state = seed * 7919 + 17;
    double random() {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      return state / 0x7fffffff;
    }

    final values = [
      for (var i = 0; i < n; i++)
        if (i == 0)
          start
        else if (i == n - 1)
          end
        else
          start +
              (end - start) * i / (n - 1) +
              (math.sin(i * 1.3 + seed) * 0.6 + random() - 0.5) * amplitude,
    ];
    return Series(values, end: now, period: period);
  }
}
