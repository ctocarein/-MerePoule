import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:merepoule/utils/format.dart';

// Espace insécable et moins typographique.
const nb = ' ';
const minus = '−';

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  test('montants', () {
    expect(MpFormat.money(1234.5, currency: 'USD'), '1${nb}234,50$nb\$');
    expect(MpFormat.money(-440.37, currency: 'USD'), '${minus}440,37$nb\$');
    expect(MpFormat.money(286, currency: 'EUR', signed: true), '+286,00$nb€');
    expect(MpFormat.money(0, currency: 'USD', signed: true), '0,00$nb\$');
    expect(MpFormat.money(12, currency: 'CHF'), '12,00${nb}CHF');
    expect(MpFormat.money(1234567.891), '1${nb}234${nb}567,89');
  });

  test('nombres et pourcentages', () {
    expect(MpFormat.number(0.2), '0,20');
    expect(MpFormat.number(3, decimals: 0), '3');
    expect(MpFormat.percent(12.5), '12,5$nb%');
    expect(MpFormat.percent(-1.5, signed: true), '${minus}1,5$nb%');
    expect(MpFormat.percent(25, decimals: 0, signed: true), '+25$nb%');
  });

  test('âges', () {
    expect(MpFormat.age(Duration.zero), 'à l’instant');
    expect(MpFormat.age(const Duration(seconds: -3)), 'à l’instant');
    expect(MpFormat.age(const Duration(seconds: 42)), 'il y a 42${nb}s');
    expect(
      MpFormat.age(const Duration(minutes: 5, seconds: 59)),
      'il y a 5${nb}min',
    );
    expect(
      MpFormat.age(const Duration(hours: 2, minutes: 30)),
      'il y a 2${nb}h',
    );
    expect(MpFormat.age(const Duration(days: 3, hours: 1)), 'il y a 3${nb}j');
  });

  test('heures', () {
    final t = DateTime(2026, 9, 25, 7, 13);
    expect(MpFormat.time(t), '07:13');
    expect(MpFormat.dateTime(t), '25 sept. 07:13');
    expect(MpFormat.day(t), '25 sept.');
    expect(MpFormat.weekday(t), 'ven.');
  });
}
