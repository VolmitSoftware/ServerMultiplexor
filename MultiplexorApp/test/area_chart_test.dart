import 'package:multiplexor/utils/charts/area_chart.dart';
import 'package:multiplexor/utils/charts/braille_chart.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 7, 29, 12);
final DateTime _end = DateTime.utc(2026, 7, 29, 13);

/// A sample at [fraction] of the way through the window.
ChartPoint _at(double fraction, double? value) => ChartPoint(
  ts: _start.add(
    Duration(
      microseconds: (_end.difference(_start).inMicroseconds * fraction).round(),
    ),
  ),
  value: value,
);

/// [count] samples spread evenly across the window, all at [value].
List<ChartPoint> _flat(double value, {int count = 120}) => <ChartPoint>[
  for (int i = 0; i < count; i++) _at(i / (count - 1), value),
];

List<String> _render(
  List<ChartPoint> points, {
  int width = 40,
  int height = 6,
  MonitorTheme? theme,
  double? low = 0,
  double? high = 100,
}) => renderAreaChart(
  points: points,
  width: width,
  height: height,
  start: _start,
  end: _end,
  theme: theme ?? MonitorTheme.plain(),
  forcedLow: low,
  forcedHigh: high,
);

/// The plot cells of every plot row: the gutter ends at the axis glyph.
List<String> _plot(List<String> rows) {
  final int gutter = Ansi.strip(rows.first).indexOf('┤') + 1;
  return <String>[
    for (final String row in rows.sublist(0, rows.length - 1))
      Ansi.strip(row).substring(gutter),
  ];
}

void main() {
  test('renders exactly the requested rows and visible columns', () {
    final List<String> rows = _render(_flat(50), width: 37, height: 7);
    expect(rows, hasLength(7));
    for (final String row in rows) {
      expect(Ansi.strip(row).length, 37);
    }
  });

  test('fills solid from the baseline up to the value', () {
    final List<String> plot = _plot(_render(_flat(100)));
    for (final String row in plot) {
      expect(row.trim(), matches(RegExp(r'^█+$')), reason: row);
    }

    final List<String> half = _plot(_render(_flat(50), height: 5));
    expect(half[0].trim(), isEmpty);
    expect(half[1].trim(), isEmpty);
    expect(half[2].trim(), matches(RegExp(r'^█+$')));
    expect(half[3].trim(), matches(RegExp(r'^█+$')));
  });

  test('tops a column with the partial block for its remainder', () {
    final List<String> plot = _plot(_render(_flat(30), height: 5));
    // 30% of 4 rows is 1.2 rows: one full row and a 2/8 cap above it.
    expect(plot[3].trim(), matches(RegExp(r'^█+$')));
    expect(plot[2].trim(), matches(RegExp(r'^▂+$')));
  });

  test('draws a measured zero as a baseline, never as a gap', () {
    final List<String> plot = _plot(_render(_flat(0)));
    expect(plot.last.trim(), matches(RegExp(r'^▁+$')));
  });

  test('bridges short sampling gaps and keeps long ones empty', () {
    final List<String> bridged = _plot(
      _render(<ChartPoint>[
        for (int i = 0; i <= 20; i++) _at(i / 20, 100),
      ], width: 42),
    );
    expect(bridged.last.trimRight(), isNot(contains(' ')));

    final List<String> gapped = _plot(
      _render(<ChartPoint>[
        for (int i = 0; i <= 10; i++) _at(i / 40, 100),
        for (int i = 30; i <= 40; i++) _at(i / 40, 100),
      ], width: 42),
    );
    expect(gapped.last, contains('      '), reason: gapped.last);
  });

  test('draws no gridline dots across the plot', () {
    final List<String> plot = _plot(_render(_flat(40), height: 9));
    expect(plot.join(), isNot(contains('·')));
  });

  test('says n/a when nothing in the window can be drawn', () {
    final List<String> rows = _render(<ChartPoint>[_at(0.5, null)]);
    expect(rows.map(Ansi.strip).join('\n'), contains('n/a'));
  });

  test('uses hash marks under the ASCII glyph set', () {
    final List<String> plot = _plot(
      renderAreaChart(
        points: _flat(100),
        width: 30,
        height: 5,
        start: _start,
        end: _end,
        theme: MonitorTheme.plainAscii(),
        forcedLow: 0,
        forcedHigh: 100,
      ).map((String row) => row.replaceAll('+', '┤')).toList(),
    );
    expect(plot.first.trim(), matches(RegExp(r'^#+$')));
  });
}
