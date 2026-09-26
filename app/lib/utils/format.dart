import 'package:intl/intl.dart';

/// Nombres, montants et âges à la française : « 1 234,50 $ », « −12,5 % »,
/// « il y a 3 s ».
///
/// Les polices n'ont pas l'espace fine insécable qu'emploie `intl` : elle est
/// remplacée par l'espace insécable. Le moins est le signe typographique.
abstract final class MpFormat {
  static const _locale = 'fr_FR';
  static const _symbols = {'USD': r'$', 'EUR': '€', 'GBP': '£', 'JPY': '¥'};

  /// `money(-1234.5, currency: 'USD')` → « −1 234,50 $ ».
  /// `signed` ajoute « + » devant un gain.
  static String money(num value, {String? currency, bool signed = false}) {
    final format = NumberFormat.currency(
      locale: _locale,
      symbol: currency == null ? '' : (_symbols[currency] ?? currency),
      decimalDigits: 2,
    );
    return _sign(value, format.format(value).trim(), signed);
  }

  /// `number(1234.567)` → « 1 234,57 ».
  static String number(num value, {int decimals = 2, bool signed = false}) {
    final format = NumberFormat.decimalPatternDigits(
      locale: _locale,
      decimalDigits: decimals,
    );
    return _sign(value, format.format(value), signed);
  }

  /// `percent(12.5)` → « 12,5 % » : la valeur est déjà en pourcent.
  static String percent(num value, {int decimals = 1, bool signed = false}) {
    return '${number(value, decimals: decimals, signed: signed)} %';
  }

  /// Âge d'une donnée : « à l'instant », « il y a 42 s », « il y a 5 min »,
  /// « il y a 2 h », « il y a 3 j ».
  static String age(Duration age) {
    final s = age.inSeconds;
    if (s < 1) return 'à l’instant';
    if (s < 60) return 'il y a $s s';
    if (age.inMinutes < 60) return 'il y a ${age.inMinutes} min';
    if (age.inHours < 24) return 'il y a ${age.inHours} h';
    return 'il y a ${age.inDays} j';
  }

  /// `time(t)` → « 14:05 ».
  static String time(DateTime t) => DateFormat.Hm(_locale).format(t);

  /// `weekday(t)` → « ven. ».
  static String weekday(DateTime t) => DateFormat.E(_locale).format(t);

  /// `day(t)` → « 25 sept. ».
  static String day(DateTime t) => DateFormat.MMMd(_locale).format(t);

  /// `dateTime(t)` → « 25 sept. 14:05 ».
  static String dateTime(DateTime t) => '${day(t)} ${time(t)}';

  static String _sign(num value, String text, bool signed) {
    final clean = text.replaceAll(' ', ' ').replaceAll('-', '−');
    return signed && value > 0 ? '+$clean' : clean;
  }
}
