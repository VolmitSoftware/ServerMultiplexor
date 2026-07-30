import 'package:multiplexor/utils/charts/chart_scale.dart';
import 'package:test/test.dart';

void main() {
  group('niceStep — 1/2/2.5/5 ladder', () {
    test('rounds each fraction up to its ladder candidate', () {
      expect(niceStep(0.7), closeTo(1.0, 1e-9));
      expect(niceStep(1.2), closeTo(2.0, 1e-9));
      expect(niceStep(2.3), closeTo(2.5, 1e-9));
      expect(niceStep(3), closeTo(5.0, 1e-9));
      expect(niceStep(7), closeTo(10.0, 1e-9));
      expect(niceStep(23), closeTo(25.0, 1e-9));
    });

    test('an exact ladder value returns itself, not the next rung up', () {
      expect(niceStep(5), closeTo(5.0, 1e-9));
      expect(niceStep(10), closeTo(10.0, 1e-9));
      expect(niceStep(2.5), closeTo(2.5, 1e-9));
    });

    test('non-positive input always returns 1.0', () {
      expect(niceStep(0), closeTo(1.0, 1e-9));
      expect(niceStep(-4), closeTo(1.0, 1e-9));
    });
  });

  group('resolveChartScale — no data, no forced bounds', () {
    test('defaults to 0..1 with ticks at the top and bottom row', () {
      final ChartScale scale = resolveChartScale(
        dataLow: null,
        dataHigh: null,
        rows: 6,
      );
      expect(scale.low, closeTo(0.0, 1e-9));
      expect(scale.high, closeTo(1.0, 1e-9));
      expect(
        scale.ticks.any((ChartTick t) => t.row == 0 && t.value == scale.high),
        isTrue,
      );
      expect(
        scale.ticks.any((ChartTick t) => t.row == 5 && t.value == scale.low),
        isTrue,
      );
    });
  });

  group('resolveChartScale — forced bounds win verbatim', () {
    test(
      'both bounds forced (TPS chart 0..20) ignores data, headroom, and snapping',
      () {
        final ChartScale scale = resolveChartScale(
          dataLow: 19.9,
          dataHigh: 20.05,
          rows: 12,
          forcedLow: 0,
          forcedHigh: 20,
        );
        expect(scale.low, closeTo(0.0, 1e-9));
        expect(scale.high, closeTo(20.0, 1e-9));
      },
    );

    test('both bounds forced with no data at all still resolves verbatim', () {
      final ChartScale scale = resolveChartScale(
        dataLow: null,
        dataHigh: null,
        rows: 12,
        forcedLow: 0,
        forcedHigh: 20,
      );
      expect(scale.low, closeTo(0.0, 1e-9));
      expect(scale.high, closeTo(20.0, 1e-9));
    });
  });

  group('resolveChartScale — zero floor', () {
    test('low near zero relative to high (<= 35%) is floored to exactly 0', () {
      final ChartScale scale = resolveChartScale(
        dataLow: 0.5,
        dataHigh: 20,
        rows: 12,
      );
      expect(scale.low, closeTo(0.0, 1e-9));
      expect(scale.high, closeTo(30.0, 1e-9));
    });

    test(
      'low far from zero relative to high (> 35%) is left alone, only snapped',
      () {
        final ChartScale scale = resolveChartScale(
          dataLow: 18,
          dataHigh: 20,
          rows: 12,
        );
        expect(scale.low, closeTo(18.0, 1e-9));
        expect(scale.high, closeTo(21.0, 1e-9));
        expect(scale.low, isNot(closeTo(0.0, 1e-9)));
      },
    );

    test('unforced high snaps to the tick step, not a coarser whole-range step '
        '(0..59 resolves to 0..80, not 0..100)', () {
      final ChartScale scale = resolveChartScale(
        dataLow: 0,
        dataHigh: 59,
        rows: 12,
      );
      expect(scale.low, closeTo(0.0, 1e-9));
      expect(scale.high, closeTo(80.0, 1e-9));

      final List<double> tickValues =
          scale.ticks.map((ChartTick t) => t.value).toList()..sort();
      expect(tickValues, <double>[0, 20, 40, 60, 80]);

      final Set<int> rows = scale.ticks.map((ChartTick t) => t.row).toSet();
      expect(
        rows.length,
        scale.ticks.length,
        reason: 'no two ticks share a row',
      );
      expect(rows, contains(0));
      expect(rows, contains(11));
    });

    test('a forced low bypasses the zero-floor rule entirely', () {
      final ChartScale scale = resolveChartScale(
        dataLow: 0.5,
        dataHigh: 20,
        rows: 12,
        forcedLow: 3,
      );
      expect(scale.low, closeTo(3.0, 1e-9));
    });
  });

  group('resolveChartScale — degenerate flat data', () {
    test('dataLow == dataHigh still yields a usable span (high > low)', () {
      final ChartScale positive = resolveChartScale(
        dataLow: 5,
        dataHigh: 5,
        rows: 8,
      );
      expect(positive.high, greaterThan(positive.low));

      final ChartScale atZero = resolveChartScale(
        dataLow: 0,
        dataHigh: 0,
        rows: 8,
      );
      expect(atZero.high, greaterThan(atZero.low));
    });
  });

  group('resolveChartScale — ticks', () {
    test('rows stay unique, and row 0 / row (rows - 1) are always present', () {
      final ChartScale scale = resolveChartScale(
        dataLow: null,
        dataHigh: null,
        rows: 12,
        forcedLow: 0,
        forcedHigh: 20,
      );
      final List<int> rows = scale.ticks.map((ChartTick t) => t.row).toList();
      expect(
        rows.toSet().length,
        rows.length,
        reason: 'no two ticks share a row',
      );
      expect(rows, contains(0));
      expect(rows, contains(11));

      final Map<int, ChartTick> byRow = <int, ChartTick>{
        for (final ChartTick t in scale.ticks) t.row: t,
      };
      expect(byRow[0]!.value, closeTo(20.0, 1e-9));
      expect(byRow[0]!.label, '20');
      expect(byRow[3]!.value, closeTo(15.0, 1e-9));
      expect(byRow[6]!.value, closeTo(10.0, 1e-9));
      expect(byRow[8]!.value, closeTo(5.0, 1e-9));
      expect(byRow[11]!.value, closeTo(0.0, 1e-9));
      expect(byRow[11]!.label, '0');
    });

    test(
      'a nice multiple that lands on the edge row is overridden by the true bound',
      () {
        // tickStep=5 places a "5" tick at row 0 first; the forced high (9) must
        // still win that row rather than leaving the nice multiple in place.
        final ChartScale scale = resolveChartScale(
          dataLow: null,
          dataHigh: null,
          rows: 2,
          forcedLow: 0,
          forcedHigh: 9,
        );
        expect(scale.ticks.length, 2);
        final Map<int, ChartTick> byRow = <int, ChartTick>{
          for (final ChartTick t in scale.ticks) t.row: t,
        };
        expect(byRow[0]!.value, closeTo(9.0, 1e-9));
        expect(byRow[1]!.value, closeTo(0.0, 1e-9));
      },
    );
  });

  group('resolveChartScale — tick label formatting', () {
    test('whole-number values trim the trailing .0', () {
      final ChartScale scale = resolveChartScale(
        dataLow: null,
        dataHigh: null,
        rows: 12,
        forcedLow: 0,
        forcedHigh: 20,
      );
      for (final ChartTick tick in scale.ticks) {
        expect(tick.label, isNot(contains('.0')));
      }
    });

    test(
      'a label wider than 6 chars drops the fraction, never the leading digits',
      () {
        final ChartScale scale = resolveChartScale(
          dataLow: null,
          dataHigh: null,
          rows: 6,
          forcedLow: 0,
          forcedHigh: 123457.5,
        );
        final ChartTick top = scale.ticks.firstWhere(
          (ChartTick t) => t.row == 0,
        );
        expect(top.value, closeTo(123457.5, 1e-9));
        expect(top.label, '123457');
        expect(top.label.length, lessThanOrEqualTo(7));
      },
    );
  });

  group('planTimeAxis — labels', () {
    test('renders zero-padded 24h HH:mm for spans under 24h', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 2));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 3,
      );
      expect(ticks.map((TimeTick t) => t.label).toList(), <String>[
        '08:14',
        '09:14',
        '10:14',
      ]);
    });

    test('prefixes MM-dd when the span exceeds 24h', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 30));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 2,
      );
      expect(ticks.map((TimeTick t) => t.label).toList(), <String>[
        '07-29 08:14',
        '07-30 14:14',
      ]);
    });

    test('a span of exactly 24h does not get the date prefix', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 24));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 2,
      );
      for (final TimeTick tick in ticks) {
        expect(tick.label.length, 5);
      }
    });

    test('renders UTC instants in local time, not UTC', () {
      // Samples are stamped UTC and the dashboard passes UTC window bounds,
      // but the frame's clock and its log tail are local. An axis labelled
      // in UTC would read hours off from both in any non-UTC zone.
      final DateTime start = DateTime.utc(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 2));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 3,
      );
      expect(ticks.map((TimeTick t) => t.label).toList(), <String>[
        for (final DateTime moment in <DateTime>[
          start,
          start.add(const Duration(hours: 1)),
          end,
        ])
          '${moment.toLocal().hour.toString().padLeft(2, '0')}:'
              '${moment.toLocal().minute.toString().padLeft(2, '0')}',
      ]);
    });

    test('picks the date prefix from the local calendar day', () {
      // 23:30 UTC is the previous day in the Americas and the next day in
      // much of Asia. The prefix has to agree with the clock beside it.
      final DateTime start = DateTime.utc(2026, 7, 29, 23, 30);
      final DateTime end = start.add(const Duration(hours: 30));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 2,
      );
      expect(ticks.map((TimeTick t) => t.label).toList(), <String>[
        for (final DateTime moment in <DateTime>[start, end])
          '${moment.toLocal().month.toString().padLeft(2, '0')}-'
              '${moment.toLocal().day.toString().padLeft(2, '0')} '
              '${moment.toLocal().hour.toString().padLeft(2, '0')}:'
              '${moment.toLocal().minute.toString().padLeft(2, '0')}',
      ]);
    });
  });

  group('planTimeAxis — layout', () {
    test('the first tick is left-anchored at column 0', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 2));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 3,
      );
      expect(ticks.first.column, 0);
    });

    test('the last tick is right-anchored at width - label length', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 2));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 40,
        targetTicks: 3,
      );
      expect(ticks.last.column, 40 - ticks.last.label.length);
    });

    test('labels never overlap at width 30 with 6 target ticks', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 6));
      final List<TimeTick> ticks = planTimeAxis(
        start: start,
        end: end,
        width: 30,
        targetTicks: 6,
      );
      expect(ticks, isNotEmpty);
      for (int i = 1; i < ticks.length; i++) {
        final TimeTick previous = ticks[i - 1];
        final TimeTick current = ticks[i];
        expect(
          current.column,
          greaterThanOrEqualTo(previous.column + previous.label.length + 2),
          reason: 'tick $i overlaps the previous label',
        );
      }
      for (final TimeTick tick in ticks) {
        expect(tick.column + tick.label.length, lessThanOrEqualTo(30));
      }
    });

    test(
      'a width too small to fit even the first label returns an empty list',
      () {
        final DateTime start = DateTime(2026, 7, 29, 8, 14);
        final DateTime end = start.add(const Duration(hours: 2));
        final List<TimeTick> ticks = planTimeAxis(
          start: start,
          end: end,
          width: 3,
          targetTicks: 4,
        );
        expect(ticks, isEmpty);
      },
    );

    test('a non-positive width returns an empty list', () {
      final DateTime start = DateTime(2026, 7, 29, 8, 14);
      final DateTime end = start.add(const Duration(hours: 2));
      expect(
        planTimeAxis(start: start, end: end, width: 0, targetTicks: 4),
        isEmpty,
      );
      expect(
        planTimeAxis(start: start, end: end, width: -5, targetTicks: 4),
        isEmpty,
      );
    });
  });
}
