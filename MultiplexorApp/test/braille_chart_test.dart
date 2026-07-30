import 'package:multiplexor/utils/charts/braille_chart.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

final DateTime _windowStart = DateTime.utc(2026, 7, 29, 12);
final DateTime _windowEnd = DateTime.utc(2026, 7, 29, 13);

/// [count] evenly spaced samples across `[start, end]` whose value is their
/// own zero-based index — a strictly rising line with no gaps.
List<ChartPoint> _ramp({required int count, DateTime? start, DateTime? end}) {
  final DateTime from = start ?? _windowStart;
  final DateTime to = end ?? _windowEnd;
  final int spanMicros = to.difference(from).inMicroseconds;
  return List<ChartPoint>.generate(count, (int index) {
    final int offset = count < 2
        ? 0
        : (spanMicros * index / (count - 1)).round();
    return ChartPoint(
      ts: from.add(Duration(microseconds: offset)),
      value: index.toDouble(),
    );
  });
}

/// A sample at [fraction] of the way through the window, carrying [value]
/// (`null` renders as a gap, never a zero).
ChartPoint _at(double fraction, double? value) {
  final int spanMicros = _windowEnd.difference(_windowStart).inMicroseconds;
  return ChartPoint(
    ts: _windowStart.add(
      Duration(microseconds: (spanMicros * fraction).round()),
    ),
    value: value,
  );
}

/// Width of the Y-axis gutter, read back off the rendered frame: the axis
/// glyph is the gutter's last column, and never appears in a tick label.
int _gutterWidth(List<String> rows, MonitorGlyphs glyphs) =>
    Ansi.strip(rows.first).indexOf(glyphs.axisTick) + 1;

/// The plot cells of [row] (everything right of the gutter), escapes stripped.
String _plotOf(String row, int gutterWidth) =>
    Ansi.strip(row).substring(gutterWidth);

/// Every plot row's cells, escapes stripped (the trailing time-axis row is
/// dropped).
List<String> _plotRows(List<String> rows, int gutterWidth) => rows
    .sublist(0, rows.length - 1)
    .map((String row) => _plotOf(row, gutterWidth))
    .toList();

/// Whether [glyph] is plotted data ink: a braille cell or the latest marker.
bool _isInk(String glyph) {
  final int code = glyph.codeUnitAt(0);
  return (code > 0x2800 && code <= 0x28FF) || glyph == '◆';
}

/// For each plot column, the row indices that carry data ink.
List<List<int>> _inkRowsByColumn(List<String> plotRows, int plotWidth) {
  final List<List<int>> columns = List<List<int>>.generate(
    plotWidth,
    (int _) => <int>[],
  );
  for (int row = 0; row < plotRows.length; row++) {
    for (int column = 0; column < plotWidth; column++) {
      if (_isInk(plotRows[row][column])) {
        columns[column].add(row);
      }
    }
  }
  return columns;
}

void main() {
  group('ChartPoint', () {
    test('carries a timestamp and a nullable value', () {
      final ChartPoint point = ChartPoint(ts: _windowStart, value: null);
      expect(point.ts, _windowStart);
      expect(point.value, isNull);
    });
  });

  group('ChartSeries', () {
    test('defaults toneIndex to 0', () {
      const ChartSeries series = ChartSeries(
        label: 'tps',
        points: <ChartPoint>[],
      );
      expect(series.toneIndex, 0);
      expect(series.label, 'tps');
      expect(series.points, isEmpty);
    });
  });

  group('renderBrailleChart', () {
    test('returns exactly height rows', () {
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: MonitorTheme.plain(),
      );
      expect(rows.length, 8);
    });

    test('every row is exactly width visible columns, at several sizes', () {
      const List<List<int>> sizes = <List<int>>[
        <int>[40, 8],
        <int>[24, 3],
        <int>[80, 12],
        <int>[120, 20],
        <int>[13, 5],
      ];
      for (final List<int> size in sizes) {
        final List<String> rows = renderBrailleChart(
          series: <ChartSeries>[
            ChartSeries(label: 'cpu', points: _ramp(count: 60)),
          ],
          width: size[0],
          height: size[1],
          start: _windowStart,
          end: _windowEnd,
          theme: MonitorTheme.plain(),
          events: <DateTime>[_windowStart.add(const Duration(minutes: 30))],
        );
        expect(rows.length, size[1], reason: 'height for $size');
        for (final String row in rows) {
          expect(
            Ansi.visibleLength(row),
            size[0],
            reason: 'row "$row" at $size',
          );
        }
      }
    });

    test('draws a vertically connected polyline for a contiguous ramp', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      final int plotWidth = plot.first.length;
      final List<List<int>> ink = _inkRowsByColumn(plot, plotWidth);

      int first = -1;
      int last = -1;
      for (int column = 0; column < plotWidth; column++) {
        if (ink[column].isNotEmpty) {
          if (first < 0) {
            first = column;
          }
          last = column;
        }
      }
      expect(first, 0, reason: 'the ramp starts at the window start');
      expect(last, plotWidth - 1, reason: 'the ramp ends at the window end');

      for (int column = first; column <= last; column++) {
        final List<int> inked = ink[column];
        expect(inked, isNotEmpty, reason: 'column $column carries no ink');
        expect(
          inked.last - inked.first + 1,
          inked.length,
          reason: 'column $column has a vertical gap in its ink',
        );
      }
    });

    test(
      'plot cells only ever hold braille, grid, event, marker, or space',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        final List<String> rows = renderBrailleChart(
          series: <ChartSeries>[
            ChartSeries(label: 'cpu', points: _ramp(count: 60)),
          ],
          width: 48,
          height: 10,
          start: _windowStart,
          end: _windowEnd,
          theme: theme,
          events: <DateTime>[_windowStart.add(const Duration(minutes: 45))],
        );
        final int gutterWidth = _gutterWidth(rows, theme.glyphs);
        for (final String plotRow in _plotRows(rows, gutterWidth)) {
          for (int index = 0; index < plotRow.length; index++) {
            final String glyph = plotRow[index];
            final int code = glyph.codeUnitAt(0);
            final bool legal =
                (code >= 0x2800 && code <= 0x28FF) ||
                glyph == '·' ||
                glyph == '┊' ||
                glyph == '◆' ||
                glyph == ' ';
            expect(
              legal,
              isTrue,
              reason:
                  'illegal plot glyph "$glyph" (U+${code.toRadixString(16)})',
            );
          }
        }
      },
    );

    test('forced 0..20 bounds label the top row 20 and the bottom row 0', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'tps', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        forcedLow: 0,
        forcedHigh: 20,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final String top = Ansi.strip(rows.first);
      final String bottom = Ansi.strip(rows[rows.length - 2]);
      expect(top.substring(0, gutterWidth - 2).trim(), '20');
      expect(bottom.substring(0, gutterWidth - 2).trim(), '0');
      expect(bottom[gutterWidth - 1], theme.glyphs.axisBase);
      expect(top[gutterWidth - 1], theme.glyphs.axisTick);
    });

    test('rows without a tick carry a blank gutter label', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'tps', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 12,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        forcedLow: 0,
        forcedHigh: 20,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> labels = rows
          .sublist(0, rows.length - 1)
          .map((String row) => Ansi.strip(row).substring(0, gutterWidth - 2))
          .toList();
      expect(
        labels.where((String label) => label.trim().isEmpty),
        isNotEmpty,
        reason: 'an 11-row plot cannot have a tick on every row',
      );
      for (final String label in labels) {
        expect(label.length, gutterWidth - 2);
      }
    });

    test('an empty series list renders an n/a frame', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      expect(rows.length, 8);
      for (final String row in rows) {
        expect(Ansi.visibleLength(row), 40);
      }
      expect(
        rows.any((String row) => Ansi.strip(row).contains('n/a')),
        isTrue,
        reason: 'missing data must read n/a, never a fabricated zero line',
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      expect(gutterWidth, greaterThan(2), reason: 'the frame keeps its gutter');
    });

    test('an all-null series renders an n/a frame, not a zero line', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(
            label: 'cpu',
            points: <ChartPoint>[
              _at(0.1, null),
              _at(0.5, null),
              _at(0.9, null),
            ],
          ),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      expect(plot.any((String row) => row.contains('n/a')), isTrue);
      for (final String row in plot) {
        expect(row.split('').any(_isInk), isFalse);
      }
    });

    test('a null run wider than the bridge limit leaves a real gap', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<ChartPoint> points = <ChartPoint>[];
      for (int index = 0; index <= 40; index++) {
        final double fraction = index / 40;
        final bool hole = fraction > 0.35 && fraction < 0.65;
        points.add(_at(fraction, hole ? null : 10 + index.toDouble()));
      }
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[ChartSeries(label: 'cpu', points: points)],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      final int plotWidth = plot.first.length;
      final List<List<int>> ink = _inkRowsByColumn(plot, plotWidth);
      final int middle = plotWidth ~/ 2;
      expect(ink[middle], isEmpty, reason: 'the null run must read as a gap');
      expect(ink[0], isNotEmpty);
      expect(ink[plotWidth - 1], isNotEmpty);
    });

    test('an event column renders the event glyph where no data covers it', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<ChartPoint> points = <ChartPoint>[
        for (int index = 0; index <= 20; index++)
          _at(index / 20 * 0.4, 10 + index.toDouble()),
      ];
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[ChartSeries(label: 'cpu', points: points)],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        events: <DateTime>[_windowStart.add(const Duration(minutes: 48))],
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      final int plotWidth = plot.first.length;
      final int column = (0.8 * (plotWidth - 1)).round();
      for (int row = 0; row < plot.length; row++) {
        expect(
          plot[row][column],
          '┊',
          reason: 'event column $column, row $row',
        );
      }
    });

    test('an event glyph never overwrites plotted data ink', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        events: <DateTime>[_windowStart.add(const Duration(minutes: 30))],
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      final int plotWidth = plot.first.length;
      final int column = (0.5 * (plotWidth - 1)).round();
      final List<List<int>> ink = _inkRowsByColumn(plot, plotWidth);
      expect(ink[column], isNotEmpty);
      for (final int row in ink[column]) {
        expect(plot[row][column], isNot('┊'));
      }
    });

    test('grid dots land on tick rows at every second column', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        forcedLow: 0,
        forcedHigh: 20,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final String top = _plotOf(rows.first, gutterWidth);
      expect(top[0], '·');
      expect(top[1], ' ');
      expect(top[2], '·');
    });

    test('the final row is a faint time axis under the plot area', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final String axis = Ansi.strip(rows.last);
      expect(axis.substring(0, gutterWidth).trim(), isEmpty);
      expect(RegExp(r'\d\d:\d\d').hasMatch(axis), isTrue);
      expect(axis.startsWith(' ' * gutterWidth), isTrue);
    });

    test('a plot area narrower than four columns degrades to an n/a card', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 6,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      expect(rows.length, 8);
      for (final String row in rows) {
        expect(Ansi.visibleLength(row), 6);
      }
      expect(Ansi.strip(rows[4]).contains('n/a'), isTrue);
    });

    test('a height below three degrades to an n/a card', () {
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 20,
        height: 2,
        start: _windowStart,
        end: _windowEnd,
        theme: MonitorTheme.plain(),
      );
      expect(rows.length, 2);
      for (final String row in rows) {
        expect(Ansi.visibleLength(row), 20);
      }
      expect(Ansi.strip(rows[1]).contains('n/a'), isTrue);
    });

    test('a non-positive height renders no rows at all', () {
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[],
        width: 20,
        height: 0,
        start: _windowStart,
        end: _windowEnd,
        theme: MonitorTheme.plain(),
      );
      expect(rows, isEmpty);
    });

    test('a non-positive window renders an n/a frame', () {
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowStart,
        theme: MonitorTheme.plain(),
      );
      expect(rows.length, 8);
      expect(rows.any((String row) => Ansi.strip(row).contains('n/a')), isTrue);
    });

    test('the ascii theme renders pure ASCII', () {
      final MonitorTheme theme = MonitorTheme.plainAscii();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        events: <DateTime>[_windowStart.add(const Duration(minutes: 45))],
      );
      expect(rows.length, 8);
      for (final String row in rows) {
        expect(Ansi.visibleLength(row), 40);
        for (final int code in row.codeUnits) {
          expect(
            code < 128,
            isTrue,
            reason: 'non-ascii U+${code.toRadixString(16)} in "$row"',
          );
        }
      }
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      expect(
        _plotRows(rows, gutterWidth).any((String row) => row.contains('#')),
        isTrue,
        reason: 'ascii data marks render as #',
      );
    });

    test(
      'the latest sample of the first series is an accent-painted marker',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        );
        final List<String> rows = renderBrailleChart(
          series: <ChartSeries>[
            ChartSeries(label: 'cpu', points: _ramp(count: 60)),
          ],
          width: 40,
          height: 8,
          start: _windowStart,
          end: _windowEnd,
          theme: theme,
        );
        final String joined = rows.join('\n');
        expect(joined.contains('${theme.accent}◆${theme.reset}'), isTrue);
        expect('\u25C6'.allMatches(Ansi.strip(joined)).length, 1);
      },
    );

    test('a cell owned by two series is painted the mixed tone', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final List<ChartPoint> shared = _ramp(count: 60);
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'a', points: shared),
          ChartSeries(label: 'b', points: shared, toneIndex: 1),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      expect(rows.join('\n').contains(theme.textStrong), isTrue);
    });

    test('two disjoint series keep their own tones', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(
            label: 'a',
            points: <ChartPoint>[
              for (int index = 0; index <= 20; index++)
                _at(index / 20, 10 + index * 0.01),
            ],
          ),
          ChartSeries(
            label: 'b',
            toneIndex: 1,
            points: <ChartPoint>[
              for (int index = 0; index <= 20; index++)
                _at(index / 20, 90 + index * 0.01),
            ],
          ),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final String joined = rows.join('\n');
      expect(joined.contains(theme.accent), isTrue);
      expect(joined.contains(theme.info), isTrue);
    });

    test('a single series is painted with the vertical load gradient', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        forcedLow: 0,
        forcedHigh: 59,
      );
      final String hottest = theme.rampTone(MonitorRamp.load, 1);
      final String coolest = theme.rampTone(MonitorRamp.load, 0);
      expect(rows.first.contains(hottest), isTrue);
      expect(rows[rows.length - 2].contains(coolest), isTrue);
    });

    test('adjacent cells sharing a tone share one escape sequence', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        forcedLow: 0,
        forcedHigh: 20,
      );
      // The top row is one uninterrupted faint run of grid dots and spaces:
      // gutter escape + reset, then a single plot escape + reset.
      expect('\x1B['.allMatches(rows.first).length, 4);
    });

    test('samples outside the window are ignored', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final List<String> rows = renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(
            label: 'cpu',
            points: <ChartPoint>[
              ChartPoint(
                ts: _windowStart.subtract(const Duration(hours: 5)),
                value: 5000,
              ),
              _at(0.5, 10),
              ChartPoint(
                ts: _windowEnd.add(const Duration(hours: 5)),
                value: -5000,
              ),
            ],
          ),
        ],
        width: 40,
        height: 8,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
      );
      final int gutterWidth = _gutterWidth(rows, theme.glyphs);
      final List<String> plot = _plotRows(rows, gutterWidth);
      final int plotWidth = plot.first.length;
      final List<List<int>> ink = _inkRowsByColumn(plot, plotWidth);
      final int inkedColumns = ink
          .where((List<int> rows) => rows.isNotEmpty)
          .length;
      expect(inkedColumns, 1, reason: 'only the in-window sample is plotted');
      expect(
        Ansi.strip(rows.first).substring(0, gutterWidth - 2).trim(),
        isNot('5000'),
        reason: 'out-of-window extremes must not stretch the scale',
      );
    });

    test('is pure: identical inputs render identical rows', () {
      final MonitorTheme theme = MonitorTheme.plain();
      List<String> render() => renderBrailleChart(
        series: <ChartSeries>[
          ChartSeries(label: 'cpu', points: _ramp(count: 60)),
        ],
        width: 60,
        height: 10,
        start: _windowStart,
        end: _windowEnd,
        theme: theme,
        events: <DateTime>[_windowStart.add(const Duration(minutes: 12))],
      );
      expect(render(), render());
    });
  });
}
