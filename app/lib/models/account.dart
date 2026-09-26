import '../theme/colors.dart';
import 'account_state.dart';
import 'journal_event.dart';
import 'news_item.dart';

/// Tout ce que l'app montre d'un compte. Viendra de la passerelle (statut,
/// historique, événements) ; aujourd'hui, des comptes de démonstration.
class AccountData {
  const AccountData({
    required this.account,
    required this.history,
    required this.news,
    required this.newsAge,
    required this.journal,
  });

  final AccountSnapshot account;

  /// Évolution de chaque chiffre, par période.
  final Map<Metric, Map<BalancePeriod, Series>> history;

  final List<NewsItem> news;

  /// Âge de la dernière actualité reçue.
  final Duration newsAge;

  /// Du plus récent au plus ancien.
  final List<JournalEvent> journal;
}

/// Photo d'un compte à un instant : état, chiffres, jauges des règles.
class AccountSnapshot {
  const AccountSnapshot({
    required this.label,
    required this.login,
    required this.broker,
    required this.platform,
    required this.initial,
    required this.tone,
    required this.currency,
    required this.state,
    required this.trust,
    required this.statusAge,
    required this.chartsOpen,
    required this.chartsTotal,
    required this.balance,
    required this.equity,
    required this.marginLevel,
    required this.stopOut,
    required this.gauges,
  });

  /// « Compte Démo ».
  final String label;

  /// Numéro du compte chez le courtier.
  final String login;

  /// « Weltrade », « MT5 ».
  final String broker;
  final String platform;

  /// Lettre et couleur de l'avatar dans le sélecteur de compte.
  final String initial;
  final Tone tone;

  /// Devise du compte : `USD`, `EUR`…
  final String currency;

  final AccountState state;
  final TrustLevel trust;

  /// Âge du dernier statut reçu.
  final Duration statusAge;

  /// Graphiques du robot ouverts, sur ceux connus du Watchdog.
  final int chartsOpen;
  final int chartsTotal;

  final double balance;
  final double equity;

  /// Niveau de marge en %, ou null sans position ouverte.
  final double? marginLevel;

  /// Distance au stop-out du courtier, sur le symbole le plus exposé.
  final StopOutDistance? stopOut;

  final List<RiskGauge> gauges;

  /// Gain ou perte des positions ouvertes.
  double get floating => equity - balance;
}

class StopOutDistance {
  const StopOutDistance({required this.points, required this.symbol});

  final int points;
  final String symbol;
}

/// Où en est une règle par rapport à son seuil.
enum GaugeLevel { calm, near, crossed }

class RiskGauge {
  const RiskGauge({
    required this.label,
    required this.value,
    required this.fraction,
    required this.level,
  });

  /// « Marge ».
  final String label;

  /// « 452 % · alerte sous 500 % ».
  final String value;

  /// Part de la jauge remplie, de 0 à 1.
  final double fraction;

  final GaugeLevel level;
}

/// Chiffres suivis dans le temps.
enum Metric { balance, equity, floating, margin, stopOut }

enum BalancePeriod {
  day('24 h', '24 h', Duration(hours: 24)),
  week('7 jours', '7 j', Duration(days: 7)),
  month('30 jours', '30 j', Duration(days: 30));

  const BalancePeriod(this.label, this.short, this.span);

  final String label;
  final String short;
  final Duration span;
}

/// Un chiffre sur une période, du plus ancien au plus récent point.
class Series {
  const Series(this.values, {required this.end, required this.period});

  final List<double> values;
  final DateTime end;
  final BalancePeriod period;

  DateTime get start => end.subtract(period.span);

  double get change => values.last - values.first;

  /// Variation en %, signée : négative quand le chiffre baisse.
  double get changePercent =>
      values.first == 0 ? 0 : change / values.first.abs() * 100;

  double get high => values.reduce((a, b) => a > b ? a : b);

  /// Instants des repères sous la courbe : un par jour sur 7 jours, sinon
  /// cinq, régulièrement espacés.
  List<DateTime> get ticks {
    final n = period == BalancePeriod.week ? 8 : 5;
    return [for (var i = 0; i < n; i++) start.add(period.span * (i / (n - 1)))];
  }
}
