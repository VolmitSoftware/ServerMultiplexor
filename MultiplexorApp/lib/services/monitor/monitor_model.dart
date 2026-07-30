import '../../utils/charts/braille_chart.dart';
import '../../utils/charts/meter.dart';
import '../../utils/charts/sparkline.dart';
import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';

/// Rows for the header panel (two content rows plus borders) and the footer.
const int _headerRows = 4;
const int _footerRows = 1;

/// Terminal height at or above which the bottom band (chart + host card) is
/// drawn, the smallest band that can carry a readable chart (two panel
/// borders plus five plot rows), and the tallest band worth drawing. Below
/// [_bandMinRows] the servers panel takes the frame instead; above
/// [_bandMaxRows] the extra rows go to the servers panel, where blank rows
/// read as room for more servers rather than as a stretched host card.
const int _bandMinLines = 30;
const int _bandMinRows = 7;
const int _bandMaxRows = 16;

/// Bounds on a server row's elastic TPS trend, and the cells in the host
/// card's MEM and CPU meters. The trend absorbs the slack a wide terminal
/// leaves — spending it on data rather than on a gap — but stops at
/// [_maxRowSparkCells], past which a typical history no longer fills it and
/// the row degenerates into a run of gap glyphs.
const int _minRowSparkCells = 16;
const int _maxRowSparkCells = 48;
const int _hostMeterCells = 12;

/// Server-row column widths: the name column's ceiling, the state name
/// (`restarting` is the longest state), `:port`, `players/max`, and the
/// trailing TPS reading.
const int _maxNameColumn = 20;
const int _stateColumn = 10;
const int _portColumn = 6;
const int _playersColumn = 7;
const int _tpsColumn = 4;

/// Columns a server row spends outside its name column and its trailing
/// trend: the selector, the state glyph, the state name, the port, the
/// player count, and the five single spaces between them.
const int _rowFixedColumns =
    1 + 1 + 1 + 1 + 1 + _stateColumn + 1 + _portColumn + 1 + _playersColumn;

/// Separator between footer hints.
const String _hintSeparator = ' · ';

/// The footer key hints in display order — the row exactly as it renders on
/// a terminal wide enough for all of it.
const String _monitorFooterHints =
    '[enter] open · d detail · R restart · S stop · X kill · O console · '
    'g consoles · n new · b build · c consumer · r range · q quit';

/// The order hints are given up in when the terminal is too narrow for all
/// of them (comma-separated). A hint always leaves whole — a footer clipped
/// mid-word hides a binding without admitting to it — and the three absent
/// here (`[enter] open`, `d detail`, `q quit`) are never dropped at all.
const String _footerDropOrder =
    'b build,c consumer,n new,g consoles,O console,X kill,S stop,'
    'R restart,r range';

/// Everything the dashboard needs to draw one frame: which instances exist,
/// their metric history (chronological, oldest first), the active consumer
/// profile's name, and which instance is the active one.
class MonitorSnapshot {
  const MonitorSnapshot({
    required this.instances,
    required this.history,
    required this.consumerName,
    this.activeInstance,
  });

  /// Instance names in display order.
  final List<String> instances;

  /// Metric history per instance, oldest sample first. An instance with no
  /// entry (or an empty list) has no readings yet and renders as such —
  /// never as zeros.
  final Map<String, List<MetricSample>> history;

  /// Name of the consumer profile the workspace is pointed at.
  final String consumerName;

  /// The instance marked active in the workspace, if any.
  final String? activeInstance;

  /// [instance]'s history, or an empty list when it has none.
  List<MetricSample> historyFor(String instance) =>
      history[instance] ?? const <MetricSample>[];

  /// [instance]'s most recent sample, or null when it has none.
  MetricSample? latestFor(String instance) {
    final List<MetricSample> samples = historyFor(instance);
    return samples.isEmpty ? null : samples.last;
  }
}

/// The resolved row geometry of a monitor frame: the servers panel's total
/// rows (borders included), how many instances got a row, how many did not
/// fit (summarised on the last content row), and the bottom band's rows
/// (zero when there is no band).
///
/// [buildMonitorFrame] derives both the rendered rows and the server-row
/// hitboxes from this, so a click target can never drift from what was
/// drawn.
class _MonitorLayout {
  const _MonitorLayout({
    required this.serverPanelRows,
    required this.visibleInstances,
    required this.hiddenInstances,
    required this.bandRows,
  });

  final int serverPanelRows;
  final int visibleInstances;
  final int hiddenInstances;
  final int bandRows;

  /// Content rows inside the servers panel.
  int get serverContentRows => serverPanelRows < 2 ? 0 : serverPanelRows - 2;

  /// Absolute, zero-based frame row of the first instance row.
  int get firstServerContentRow => _headerRows + 1;
}

/// Splits [lines] between the servers panel and the bottom band. The band
/// only appears at [_bandMinLines] and above, with at least one instance,
/// and only when both it and a non-degenerate servers panel fit. It is
/// capped at [_bandMaxRows]: the servers panel absorbs whatever a tall
/// terminal leaves over.
_MonitorLayout _resolveLayout({
  required int instanceCount,
  required int lines,
}) {
  final int available = lines - _headerRows - _footerRows;
  final int body = available < 0 ? 0 : available;

  int serverPanelRows = body;
  int bandRows = 0;
  if (lines >= _bandMinLines && instanceCount > 0) {
    final int natural = instanceCount + 2;
    final int capped = body - _bandMinRows;
    int panel = natural < capped ? natural : capped;
    if (panel >= 3) {
      int band = body - panel;
      if (band > _bandMaxRows) {
        band = _bandMaxRows;
        panel = body - band;
      }
      serverPanelRows = panel;
      bandRows = band;
    }
  }

  final int contentRows = serverPanelRows < 2 ? 0 : serverPanelRows - 2;
  int visible = instanceCount < contentRows ? instanceCount : contentRows;
  if (visible < instanceCount && visible > 0) {
    // The last content row is spent on the overflow note instead of a row
    // nobody could click.
    visible -= 1;
  }
  return _MonitorLayout(
    serverPanelRows: serverPanelRows,
    visibleInstances: visible,
    hiddenInstances: instanceCount - visible,
    bandRows: bandRows,
  );
}

/// Builds the full-screen dashboard frame: exactly [lines] rows of exactly
/// [columns] visible columns, ready to be painted as-is.
///
/// Below the [monitorMinColumns] x [monitorMinLines] floor the frame
/// degrades to [buildResizeRequiredFrame]. Above it the layout is a header
/// panel, a servers panel (one row per instance), an optional bottom band
/// (TPS chart plus host card for the selected instance, from
/// [_bandMinLines] rows up), and a one-row footer hint.
///
/// Pure: no clock reads and no IO. [now] must be UTC — sample timestamps
/// are UTC and chart windows are `[now - range, now]` — and is the only
/// notion of "current" the frame has. The header clock is rendered in local
/// time from it.
///
/// [hoveredId] and [pressedId] are accepted but not yet consumed by any
/// layout decision — they exist so callers can thread hover/press state
/// through now; the frame renders identically regardless of their value
/// until a later change reads them.
MonitorFrame buildMonitorFrame({
  required MonitorSnapshot snapshot,
  required int selectedIndex,
  required int frame,
  required int columns,
  required int lines,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
  String? hoveredId,
  String? pressedId,
}) {
  if (columns < monitorMinColumns || lines < monitorMinLines) {
    return MonitorFrame(
      rows: buildResizeRequiredFrame(
        columns: columns,
        lines: lines,
        theme: theme,
      ),
      hitboxes: const <MonitorHitbox>[],
    );
  }

  final _MonitorLayout layout = _resolveLayout(
    instanceCount: snapshot.instances.length,
    lines: lines,
  );

  final List<String> rows = <String>[
    ..._headerPanel(
      snapshot: snapshot,
      frame: frame,
      columns: columns,
      theme: theme,
      range: range,
      now: now,
    ),
    ..._serversPanel(
      snapshot: snapshot,
      layout: layout,
      selectedIndex: selectedIndex,
      columns: columns,
      theme: theme,
      range: range,
      now: now,
    ),
    if (layout.bandRows > 0)
      ..._bottomBand(
        snapshot: snapshot,
        selectedIndex: selectedIndex,
        rows: layout.bandRows,
        columns: columns,
        theme: theme,
        range: range,
        now: now,
      ),
    theme.paint(_footerHints(columns), theme.faint),
  ];

  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    for (int index = 0; index < layout.visibleInstances; index++)
      MonitorHitbox(
        id: 'server:${snapshot.instances[index]}',
        kind: MonitorHitKind.serverRow,
        row: layout.firstServerContentRow + index,
        colStart: 0,
        colEnd: columns,
      ),
  ];

  return padFrame(
    MonitorFrame(rows: rows, hitboxes: hitboxes),
    columns: columns,
    lines: lines,
  );
}

/// The footer hint row for a [columns]-wide frame: as many of
/// [_monitorFooterHints] as fit, dropped whole and highest rank first, so
/// the row never ends mid-hint and never hides `q quit`.
String _footerHints(int columns) {
  final List<String> shown = _monitorFooterHints.split(_hintSeparator);
  for (final String hint in _footerDropOrder.split(',')) {
    if (shown.join(_hintSeparator).length <= columns) {
      break;
    }
    shown.remove(hint);
  }
  return shown.join(_hintSeparator);
}

/// The header panel: brand wordmark, spinner/consumer/clock badge, a
/// fleet roll-up row and a faint workspace-facts row.
List<String> _headerPanel({
  required MonitorSnapshot snapshot,
  required int frame,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;
  final DateTime local = now.toLocal();
  final String clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  int up = 0;
  int down = 0;
  int players = 0;
  bool anyPlayers = false;
  double tpsTotal = 0;
  int tpsCount = 0;
  for (final String instance in snapshot.instances) {
    final MetricSample? latest = snapshot.latestFor(instance);
    // Unsampled is neither up nor down, so these can sum under SERVERS.
    if (latest?.state == RuntimeState.stopped) {
      down += 1;
    } else if (latest != null) {
      up += 1;
    }
    final int? instancePlayers = latest?.players;
    if (instancePlayers != null) {
      players += instancePlayers;
      anyPlayers = true;
    }
    final double? tps = latest?.tps;
    if (tps != null) {
      tpsTotal += tps;
      tpsCount += 1;
    }
  }
  final double? averageTps = tpsCount == 0 ? null : tpsTotal / tpsCount;

  final String upTone = up > 0 ? theme.ok : theme.faint;
  final String summary =
      '${theme.paint(glyphs.bulletOn, upTone)} '
      '${theme.paint('$up UP', upTone)} · '
      '${theme.paint('$down DOWN', theme.faint)}'
      '   PLAYERS ${theme.paint(anyPlayers ? '$players' : 'n/a', anyPlayers && players > 0 ? theme.accent : theme.faint)}'
      '   AVG TPS ${theme.paint(averageTps == null ? 'n/a' : averageTps.toStringAsFixed(1), theme.tpsTone(averageTps))}';

  final String facts =
      'ACTIVE ${snapshot.activeInstance ?? 'none'} · '
      'RANGE ${rangeLabel(range)} · '
      '${snapshot.instances.length} SERVERS';

  return renderPanel(
    // The wordmark is the one title the panel does not style itself: the
    // gradient is a caller-owned run, inlaid verbatim. At ColorDepth.none
    // gradientTitle returns the plain text, so a plain frame stays free of
    // escape bytes.
    title: 'MULTIPLEXOR',
    styledTitle: theme.gradientTitle('MULTIPLEXOR'),
    badge: '${monitorSpinner(theme, frame)} ${snapshot.consumerName} $clock',
    content: <String>[summary, theme.paint(facts, theme.faint)],
    width: columns,
    theme: theme,
  );
}

/// The servers panel: one row per instance, or the empty-workspace prompt.
List<String> _serversPanel({
  required MonitorSnapshot snapshot,
  required _MonitorLayout layout,
  required int selectedIndex,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  final int inner = columns - 4 < 0 ? 0 : columns - 4;
  final int contentRows = layout.serverContentRows;
  final List<String> content = <String>[];

  // UP means non-stopped here, exactly as the header roll-up counts it, so
  // the badge and the row above it can never disagree about the same fleet.
  // A starting or restarting server is not down.
  int up = 0;
  for (final String instance in snapshot.instances) {
    final MetricSample? latest = snapshot.latestFor(instance);
    if (latest != null && latest.state != RuntimeState.stopped) {
      up += 1;
    }
  }

  if (snapshot.instances.isEmpty) {
    const String prompt = 'NO SERVERS — press n to create one';
    final int blank = (contentRows - 1) ~/ 2;
    for (int index = 0; index < contentRows; index++) {
      content.add(
        index == blank
            ? _center(theme.paint(prompt, theme.faint), prompt.length, inner)
            : '',
      );
    }
  } else {
    int nameColumn = 4;
    for (int index = 0; index < layout.visibleInstances; index++) {
      final int length = snapshot.instances[index].length;
      if (length > nameColumn) {
        nameColumn = length;
      }
    }
    if (nameColumn > _maxNameColumn) {
      nameColumn = _maxNameColumn;
    }
    // The trend takes everything the fixed columns, one gap and the TPS
    // reading leave; too little for a readable trend and it is dropped so
    // the reading itself still lands on the right edge.
    int sparkCells = inner - nameColumn - _rowFixedColumns - _tpsColumn - 2;
    if (sparkCells > _maxRowSparkCells) {
      sparkCells = _maxRowSparkCells;
    }
    if (sparkCells < _minRowSparkCells) {
      sparkCells = 0;
      final int room = inner - _rowFixedColumns - _tpsColumn - 1;
      if (nameColumn > room) {
        nameColumn = room < 4 ? 4 : room;
      }
    }

    final DateTime windowStart = now.subtract(range);
    for (int index = 0; index < layout.visibleInstances; index++) {
      final String instance = snapshot.instances[index];
      content.add(
        _serverRow(
          instance: instance,
          latest: snapshot.latestFor(instance),
          history: snapshot.historyFor(instance),
          selected: index == selectedIndex,
          active: instance == snapshot.activeInstance,
          nameColumn: nameColumn,
          sparkCells: sparkCells,
          inner: inner,
          theme: theme,
          windowStart: windowStart,
          windowEnd: now,
        ),
      );
    }
    if (layout.hiddenInstances > 0 && content.length < contentRows) {
      content.add(
        theme.paint(
          '  ${theme.glyphs.dash} ${layout.hiddenInstances} more '
          '(resize to see every server)',
          theme.faint,
        ),
      );
    }
    while (content.length < contentRows) {
      content.add('');
    }
  }

  return renderPanel(
    title: 'SERVERS',
    badge: '$up/${snapshot.instances.length} UP',
    content: content,
    width: columns,
    theme: theme,
    emphasis: PanelEmphasis.active,
  );
}

/// One instance row. A stopped or unsampled instance never fabricates a
/// number: its port, players, trend and TPS all render as dashes.
String _serverRow({
  required String instance,
  required MetricSample? latest,
  required List<MetricSample> history,
  required bool selected,
  required bool active,
  required int nameColumn,
  required int sparkCells,
  required int inner,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;
  final RuntimeState? state = latest?.state;
  final bool live = state != null && state != RuntimeState.stopped;

  final String selector = selected
      ? theme.paint(glyphs.selector, theme.accent)
      : ' ';
  final String name = theme.paint(
    _fit(instance, nameColumn),
    selected || active ? theme.textStrong : theme.text,
  );

  final String glyph = live
      ? theme.paint(
          glyphs.bulletOn,
          state == RuntimeState.running ? theme.ok : theme.warn,
        )
      : theme.paint(glyphs.bulletOff, theme.faint);
  final String stateText = theme.paint(
    _fit(monitorStateText(latest), _stateColumn),
    state == null ? theme.faint : theme.statusTone(state),
  );

  final int? port = latest?.port;
  final String portText = theme.paint(
    _fit(port == null ? glyphs.dash : ':$port', _portColumn),
    live && port != null ? theme.muted : theme.faint,
  );

  final int? players = latest?.players;
  final String playersText = theme.paint(
    _fit(monitorPlayersText(latest, theme), _playersColumn),
    players != null && players > 0 ? theme.accent : theme.faint,
  );

  final double? tps = latest?.tps;
  final String tpsText = theme.paint(
    monitorTpsText(tps, theme).padLeft(_tpsColumn),
    theme.tpsTone(tps),
  );

  String right = tpsText;
  if (sparkCells > 0) {
    final String trend = live
        ? renderSparkline(
            values: _tpsWindow(history, windowStart, windowEnd),
            width: sparkCells,
            theme: theme,
            min: 0,
            max: 20,
          )
        : theme.paint(glyphs.dash * sparkCells, theme.faint);
    right = '$trend $right';
  }

  final String left =
      '$selector $name $glyph $stateText $portText $playersText';
  final int leftWidth = inner - Ansi.visibleLength(right) - 1;
  if (leftWidth <= 0) {
    return Ansi.clipVisible(left, inner);
  }
  return '${Ansi.padVisible(Ansi.clipVisible(left, leftWidth), leftWidth)} '
      '$right';
}

/// The bottom band: the selected instance's TPS chart beside its host card.
List<String> _bottomBand({
  required MonitorSnapshot snapshot,
  required int selectedIndex,
  required int rows,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  final int index = selectedIndex < 0
      ? 0
      : (selectedIndex >= snapshot.instances.length
            ? snapshot.instances.length - 1
            : selectedIndex);
  final String instance = snapshot.instances[index];
  final List<MetricSample> history = snapshot.historyFor(instance);
  final String label = instance.toUpperCase();

  final int leftWidth = columns * 3 ~/ 5;
  final int rightWidth = columns - leftWidth - 1;
  final int innerRows = rows - 2;

  final List<String> chart = renderBrailleChart(
    series: <ChartSeries>[
      ChartSeries(
        label: 'tps',
        points: <ChartPoint>[
          for (final MetricSample sample in history)
            ChartPoint(ts: sample.ts, value: sample.tps),
        ],
      ),
    ],
    width: leftWidth - 4,
    height: innerRows,
    start: now.subtract(range),
    end: now,
    theme: theme,
    forcedLow: 0,
    forcedHigh: 20,
  );

  return joinBlocks(<List<String>>[
    renderPanel(
      title: '$label · TPS',
      badge: rangeLabel(range),
      content: chart,
      width: leftWidth,
      theme: theme,
    ),
    renderPanel(
      title: '$label · HOST',
      content: _hostCard(
        latest: history.isEmpty ? null : history.last,
        history: history,
        rows: innerRows,
        theme: theme,
      ),
      width: rightWidth,
      theme: theme,
    ),
  ]);
}

/// The host card's content rows: memory and CPU meters over the observed
/// window, then uptime/players and ping/version. Padded to [rows] so the
/// card keeps its own bottom border when joined beside a taller chart.
List<String> _hostCard({
  required MetricSample? latest,
  required List<MetricSample> history,
  required int rows,
  required MonitorTheme theme,
}) {
  int? peakRss;
  for (final MetricSample sample in history) {
    final int? seen = sample.rssBytes;
    if (seen != null && (peakRss == null || seen > peakRss)) {
      peakRss = seen;
    }
  }
  final int? rss = latest?.rssBytes;
  final double? memFraction = rss == null || peakRss == null || peakRss <= 0
      ? null
      : rss / peakRss;
  final double? cpu = latest?.cpuPercent;
  final double? cpuFraction = cpu == null
      ? null
      : (cpu / 100).clamp(0.0, 1.0).toDouble();
  final int? uptime = latest?.uptimeSeconds;
  final int? latency = latest?.latencyMs;
  // A blank version string is missing data, not a version.
  final String? version = latest?.version;
  final String versionText = version == null || version.isEmpty
      ? theme.glyphs.dash
      : version;

  final List<String> content = <String>[
    'MEM  ${renderMeter(fraction: memFraction, cells: _hostMeterCells, theme: theme)} '
        '${theme.paint(formatBytes(rss), rss == null ? theme.faint : theme.text)}',
    'CPU  ${renderMeter(fraction: cpuFraction, cells: _hostMeterCells, theme: theme)} '
        '${theme.paint(formatCpuPercent(cpu), cpu == null ? theme.faint : theme.text)}',
    theme.paint(
      'UP ${uptime == null ? 'n/a' : formatCompactDuration(Duration(seconds: uptime))}'
      ' · ${monitorNumberText(latest?.players, theme)} PLAYERS',
      theme.muted,
    ),
    theme.paint(
      'PING ${latency == null ? 'n/a' : '${latency}ms'} · $versionText',
      theme.muted,
    ),
  ];
  final List<String> sized = content.take(rows < 0 ? 0 : rows).toList();
  while (sized.length < rows) {
    sized.add('');
  }
  return sized;
}

/// The `n/a`-safe TPS series for the sparkline: every in-window sample in
/// order, nulls kept so a gap stays a gap.
List<double?> _tpsWindow(
  List<MetricSample> history,
  DateTime start,
  DateTime end,
) => <double?>[
  for (final MetricSample sample in history)
    if (!sample.ts.isBefore(start) && !sample.ts.isAfter(end)) sample.tps,
];

/// Clips or pads the already-plain [text] to exactly [width] columns.
String _fit(String text, int width) =>
    text.length > width ? text.substring(0, width) : text.padRight(width);

/// Centers [painted] (whose visible width is [visible]) in [width] columns.
String _center(String painted, int visible, int width) =>
    visible >= width ? painted : '${' ' * ((width - visible) ~/ 2)}$painted';
