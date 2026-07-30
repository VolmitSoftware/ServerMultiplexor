import '../../utils/charts/braille_chart.dart';
import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import 'metric_sample.dart';
import 'monitor_model.dart';

/// Rows the detail header panel occupies: one content row plus its borders.
const int _headerRows = 3;

/// Rows the footer hint occupies.
const int _footerRows = 1;

/// Smallest chart panel that can carry a readable plot: two borders plus
/// three plot rows (the braille renderer's own floor).
const int _minChartPanelRows = 5;

/// Smallest log panel: two borders plus two lines of log.
const int _minLogRows = 4;

/// Largest slice of the frame the log panel takes before the charts stop
/// growing on its behalf.
const int _maxLogRows = 12;

/// Terminal width at or above which the charts lay out as a 2x2 grid rather
/// than stacking full width.
const int _gridMinColumns = 100;

/// Bytes in a mebibyte — the MEM chart plots MiB so its gutter stays a
/// readable number instead of a byte count.
const double _bytesPerMib = 1048576;

const String _detailFooterHint =
    '[esc] back · r range · R restart · S stop · X kill · O console';

/// Splits log paths on either separator so a recorded Windows path still
/// yields its filename on a POSIX host.
final RegExp _pathSeparator = RegExp(r'[\\/]');

/// One chart in the detail grid: its panel title, the series it plots, and
/// the bounds pinned on its vertical axis (null means auto-scaled).
class _DetailChart {
  const _DetailChart({
    required this.title,
    required this.points,
    this.forcedLow,
    this.forcedHigh,
  });

  final String title;
  final List<ChartPoint> points;
  final double? forcedLow;
  final double? forcedHigh;
}

/// Builds the single-instance detail frame: exactly [lines] rows of exactly
/// [columns] visible columns.
///
/// Below the [monitorMinColumns] x [monitorMinLines] floor the frame
/// degrades to [buildResizeRequiredFrame]. Above it: a header panel, up to
/// four charts (a 2x2 grid from [_gridMinColumns] columns, otherwise
/// stacked full width, dropping to the TPS and MEM charts and then to TPS
/// alone when the rows for a readable plot are not there), a log panel
/// filling what is left, and a one-row footer hint.
///
/// Pure: no clock reads and no IO. [now] must be UTC, matching the UTC
/// timestamps on [history]; every chart window is `[now - range, now]`.
List<String> buildDetailFrame({
  required String instance,
  required List<MetricSample> history,
  required List<String> logLines,
  required int frame,
  required int columns,
  required int lines,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  if (columns < monitorMinColumns || lines < monitorMinLines) {
    return buildResizeRequiredFrame(
      columns: columns,
      lines: lines,
      theme: theme,
    );
  }

  final MetricSample? latest = history.isEmpty ? null : history.last;
  final bool grid = columns >= _gridMinColumns;
  final int available = lines - _headerRows - _footerRows;
  final List<int> chartHeights = _planChartHeights(
    available: available,
    grid: grid,
  );
  final int chartRows = chartHeights.fold<int>(0, (int a, int b) => a + b);
  final int logRows = available - chartRows;

  final List<String> rows = <String>[
    ..._headerPanel(
      instance: instance,
      latest: latest,
      frame: frame,
      columns: columns,
      theme: theme,
      range: range,
    ),
    ..._charts(
      heights: chartHeights,
      charts: _resolveCharts(
        history: history,
        count: grid ? chartHeights.length * 2 : chartHeights.length,
      ),
      grid: grid,
      columns: columns,
      theme: theme,
      range: range,
      now: now,
    ),
    ..._logPanel(
      latest: latest,
      logLines: logLines,
      rows: logRows,
      columns: columns,
      theme: theme,
    ),
    theme.paint(_detailFooterHint, theme.faint),
  ];

  return padMonitorFrame(rows: rows, columns: columns, lines: lines);
}

/// Splits the rows between charts and the log, then between the charts.
///
/// In grid mode each entry is one row of two charts; stacked, each entry is
/// one chart. The log keeps [_minLogRows] no matter what, and a chart is
/// only planned when it clears [_minChartPanelRows] — better two honest
/// charts than four slivers.
List<int> _planChartHeights({required int available, required bool grid}) {
  int logRows = available ~/ 4;
  if (logRows < _minLogRows) {
    logRows = _minLogRows;
  }
  if (logRows > _maxLogRows) {
    logRows = _maxLogRows;
  }
  final int area = available - logRows;
  if (area < _minChartPanelRows) {
    return const <int>[];
  }

  final int slots = grid ? 2 : 4;
  int used = slots;
  while (used > 1 && area ~/ used < _minChartPanelRows) {
    used = used ~/ 2;
  }
  if (area ~/ used < _minChartPanelRows) {
    return const <int>[];
  }

  final int base = area ~/ used;
  final int extra = area - base * used;
  return List<int>.generate(
    used,
    (int index) => base + (index < extra ? 1 : 0),
  );
}

/// The [count] highest-priority charts, rendered back in canonical order.
/// TPS and memory outrank CPU and players: they are the two that explain a
/// struggling server.
List<_DetailChart> _resolveCharts({
  required List<MetricSample> history,
  required int count,
}) {
  double? peakMaxPlayers;
  for (final MetricSample sample in history) {
    final int? max = sample.maxPlayers;
    if (max != null && (peakMaxPlayers == null || max > peakMaxPlayers)) {
      peakMaxPlayers = max.toDouble();
    }
  }

  final List<_DetailChart> canonical = <_DetailChart>[
    _DetailChart(
      title: 'TPS',
      points: _series(history, (MetricSample s) => s.tps),
      forcedLow: 0,
      forcedHigh: 20,
    ),
    _DetailChart(
      title: 'CPU %',
      points: _series(history, (MetricSample s) => s.cpuPercent),
      forcedLow: 0,
      forcedHigh: 100,
    ),
    _DetailChart(
      title: 'MEM MiB',
      points: _series(
        history,
        (MetricSample s) =>
            s.rssBytes == null ? null : s.rssBytes! / _bytesPerMib,
      ),
    ),
    _DetailChart(
      title: 'PLAYERS',
      points: _series(history, (MetricSample s) => s.players?.toDouble()),
      forcedLow: peakMaxPlayers == null ? null : 0,
      forcedHigh: peakMaxPlayers,
    ),
  ];

  const List<int> priority = <int>[0, 2, 1, 3];
  final Set<int> chosen = priority.take(count).toSet();
  return <_DetailChart>[
    for (int index = 0; index < canonical.length; index++)
      if (chosen.contains(index)) canonical[index],
  ];
}

/// Maps [history] to chart points via [read], keeping nulls as gaps.
List<ChartPoint> _series(
  List<MetricSample> history,
  double? Function(MetricSample sample) read,
) {
  return <ChartPoint>[
    for (final MetricSample sample in history)
      ChartPoint(ts: sample.ts, value: read(sample)),
  ];
}

/// The header panel: the instance name inlaid in the border, a spinner and
/// range badge, and one `n/a`-disciplined roll-up row of the latest sample.
List<String> _headerPanel({
  required String instance,
  required MetricSample? latest,
  required int frame,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
}) {
  final double? tps = latest?.tps;
  final int? uptime = latest?.uptimeSeconds;
  final List<String> facts = <String>[
    'STATE ${theme.paint(monitorStateText(latest), latest == null ? theme.faint : theme.statusTone(latest.state))}',
    'PORT ${monitorNumberText(latest?.port, theme)}',
    'PLAYERS ${monitorPlayersText(latest, theme)}',
    'TPS ${theme.paint(monitorTpsText(tps, theme), theme.tpsTone(tps))}',
    'CPU ${formatCpuPercent(latest?.cpuPercent)}',
    'MEM ${formatBytes(latest?.rssBytes)}',
    'UP ${uptime == null ? 'n/a' : formatCompactDuration(Duration(seconds: uptime))}',
  ];
  // Drop trailing facts rather than let the row be clipped mid-word on a
  // narrow terminal; state, port and players always survive.
  final int inner = columns - 4;
  while (facts.length > 3 && Ansi.visibleLength(facts.join(' · ')) > inner) {
    facts.removeLast();
  }

  return renderPanel(
    title: instance,
    badge: '${monitorSpinner(theme, frame)} DETAIL · ${rangeLabel(range)}',
    content: <String>[theme.paint(facts.join(' · '), theme.text)],
    width: columns,
    theme: theme,
    emphasis: PanelEmphasis.active,
  );
}

/// Renders [charts] into the planned [heights], either two per row (grid)
/// or one per row (stacked).
List<String> _charts({
  required List<int> heights,
  required List<_DetailChart> charts,
  required bool grid,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  if (heights.isEmpty || charts.isEmpty) {
    return const <String>[];
  }
  final DateTime start = now.subtract(range);
  final String badge = rangeLabel(range);
  final List<String> rows = <String>[];

  for (int index = 0; index < heights.length; index++) {
    final int height = heights[index];
    if (!grid) {
      rows.addAll(
        _chartPanel(
          chart: charts[index],
          width: columns,
          height: height,
          badge: badge,
          theme: theme,
          start: start,
          end: now,
        ),
      );
      continue;
    }
    final int leftWidth = columns ~/ 2;
    final int rightWidth = columns - leftWidth - 1;
    final int left = index * 2;
    final int right = left + 1;
    if (left >= charts.length) {
      rows.addAll(List<String>.filled(height, ' ' * columns));
      continue;
    }
    rows.addAll(
      joinBlocks(<List<String>>[
        _chartPanel(
          chart: charts[left],
          width: leftWidth,
          height: height,
          badge: badge,
          theme: theme,
          start: start,
          end: now,
        ),
        if (right < charts.length)
          _chartPanel(
            chart: charts[right],
            width: rightWidth,
            height: height,
            badge: badge,
            theme: theme,
            start: start,
            end: now,
          )
        else
          List<String>.filled(height, ' ' * rightWidth),
      ]),
    );
  }
  return rows;
}

/// One titled chart panel, exactly [height] rows of [width] columns.
List<String> _chartPanel({
  required _DetailChart chart,
  required int width,
  required int height,
  required String badge,
  required MonitorTheme theme,
  required DateTime start,
  required DateTime end,
}) {
  return renderPanel(
    title: chart.title,
    badge: badge,
    content: renderBrailleChart(
      series: <ChartSeries>[
        ChartSeries(label: chart.title, points: chart.points),
      ],
      width: width - 4,
      height: height - 2,
      start: start,
      end: end,
      theme: theme,
      forcedLow: chart.forcedLow,
      forcedHigh: chart.forcedHigh,
    ),
    width: width,
    theme: theme,
  );
}

/// The log panel: the tail of [logLines] that fits, raw and faint. An empty
/// tail says so rather than rendering an empty box.
List<String> _logPanel({
  required MetricSample? latest,
  required List<String> logLines,
  required int rows,
  required int columns,
  required MonitorTheme theme,
}) {
  if (rows < 3) {
    return const <String>[];
  }
  final int inner = rows - 2;
  final String? logPath = latest?.logPath;
  final String badge = logPath == null || logPath.isEmpty
      ? 'no log'
      : logPath.split(_pathSeparator).last;

  final List<String> content = <String>[];
  if (logLines.isEmpty) {
    content.add(theme.paint('log empty', theme.faint));
  } else {
    final int from = logLines.length > inner ? logLines.length - inner : 0;
    for (int index = from; index < logLines.length; index++) {
      content.add(theme.paint(logLines[index], theme.faint));
    }
  }
  while (content.length < inner) {
    content.add('');
  }

  return renderPanel(
    title: 'LOG',
    badge: badge,
    content: content,
    width: columns,
    theme: theme,
  );
}
