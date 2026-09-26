import 'package:flutter_test/flutter_test.dart';
import 'package:merepoule/demo/demo_data.dart';
import 'package:merepoule/models/account.dart';

void main() {
  final end = DateTime(2026, 9, 25, 14);

  test('variation d’une série, en devise et en %', () {
    final up = Series(
      const [100, 90, 121.3],
      end: end,
      period: BalancePeriod.week,
    );
    expect(up.change, closeTo(21.3, 1e-9));
    expect(up.changePercent, closeTo(21.3, 1e-9));
    expect(up.high, 121.3);

    // Une perte qui se creuse : la variation est négative.
    final down = Series(
      const [-100, -125],
      end: end,
      period: BalancePeriod.day,
    );
    expect(down.changePercent, closeTo(-25, 1e-9));
  });

  test('repères : un par jour sur 7 jours, cinq sinon', () {
    final week = Series(const [1, 2], end: end, period: BalancePeriod.week);
    expect(week.ticks, hasLength(8));
    expect(week.ticks.first, end.subtract(const Duration(days: 7)));
    expect(week.ticks.last, end);
    expect(week.ticks[1], end.subtract(const Duration(days: 6)));

    final month = Series(const [1, 2], end: end, period: BalancePeriod.month);
    expect(month.ticks, hasLength(5));
    expect(month.ticks.last, end);
  });

  test(
    'comptes de démonstration : courbes qui finissent sur le chiffre affiché',
    () {
      for (final data in Demo.accounts) {
        final a = data.account;
        for (final period in BalancePeriod.values) {
          expect(
            data.history[Metric.balance]![period]!.values.last,
            closeTo(a.balance, 1e-6),
          );
          expect(
            data.history[Metric.equity]![period]!.values.last,
            closeTo(a.equity, 1e-6),
          );
        }
      }
      // Les pourcentages des maquettes, sur 7 jours.
      final demo = Demo.accounts.first.history;
      expect(
        demo[Metric.balance]![BalancePeriod.week]!.changePercent,
        closeTo(21.3, 1e-9),
      );
      expect(
        demo[Metric.equity]![BalancePeriod.week]!.changePercent,
        closeTo(18.7, 1e-9),
      );
    },
  );
}
