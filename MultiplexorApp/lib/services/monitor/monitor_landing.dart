/// The landing view's panels: the fleet roll-up every card reads, the KPI
/// strip across the top, the full-width fleet table, the compact
/// selected-server card and the empty-workspace prompt.
///
/// `monitor_model.dart` owns the frame's row budget and composes these into
/// one frame; each function here renders one block of exactly the size it is
/// handed, and reports the clickable regions it drew.
///
/// Everything in this library is pure: no clock reads and no IO.
library;

import '../../utils/charts/braille_chart.dart';
import '../../utils/charts/meter.dart';
import '../../utils/charts/sparkline.dart';
import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';

/// Columns the fleet table spends left of its first column: the selector,
/// the status bullet and the space after each.
const int _tablePrefix = 4;

/// Columns between adjacent fleet-table columns.
const int _tableGap = 2;

/// The fleet table's fixed column widths. NAME, STATE and TPS always render;
/// the rest give way whole — a clipped reading hides data without admitting
/// to it — in [_tableDropOrder] as the terminal narrows.
const int _colNameWidth = 20;
const int _colStateWidth = 10;
const int _colPlayersWidth = 7;
const int _colTpsWidth = 5;
const int _colTrendWidth = 14;
const int _colMemWidth = 6;
const int _colCpuWidth = 5;
const int _colUpWidth = 7;

/// Cells the trend sparkline may grow to when a wide terminal leaves slack;
/// past this a typical window no longer fills it.
const int _maxTrendCells = 26;

/// The KPI strip's fleet card. The brief sizes it by its content —
/// `N/M UP · P PLAYERS`, 18 columns at one digit per count — and a panel
/// spends four more on its rule and padding. A wider fleet (three-digit
/// counts) grows the card rather than clipping it.
const int _kpiFleetWidth = 22;

/// Columns the fleet card reserves for the player count. Right-aligning it
/// keeps the card (and so the two cards beside it) from shifting a column
/// sideways every time a player joins.
const int _kpiPlayersColumn = 2;

/// How the remainder of the strip is split between the TPS and HOST cards,
/// as a percentage given to HOST. HOST's fixed content — a label, two
/// readings and a separator — is the longer of the two, so an even split
/// would leave it the tighter card.
const int _kpiHostPercent = 55;

/// Columns the TPS card spends outside its trend (a four-column reading and
/// a space), and the bounds on the trend itself. The trend absorbs whatever
/// a wide terminal leaves over, but stops at [_kpiMaxSparkCells], past which
/// a typical history no longer fills it.
const int _kpiTpsFixed = 5;
const int _kpiMinSparkCells = 12;
const int _kpiMaxSparkCells = 48;

/// Columns the HOST card spends outside its meter and its two readings:
/// `MEM `, the space after the meter, and ` · CPU `.
///
/// The readings are measured as rendered rather than budgeted at their
/// widest, because a budget that guesses low clips the number itself — a
/// `CPU 150%` reading losing its `%` reads as a smaller load, which is worse
/// than a shorter bar. The meter gives up its cells first, down to none.
const int _kpiHostFixed = 12;
const int _kpiMaxMeterCells = 16;

/// Rows the selected-server card keeps for its charts at minimum (three plot
/// rows and the time axis), the narrowest chart the card lays side by side,
/// and the gap between adjacent charts.
const int _minChartRows = 4;
const int _minChartWidth = 36;
const int _chartGap = 2;

/// A rendered block plus the clickable regions drawn on it, in absolute
/// frame coordinates.
class MonitorPanelRender {
  const MonitorPanelRender({required this.rows, required this.hitboxes});

  final List<String> rows;
  final List<MonitorHitbox> hitboxes;
}

final class _SelectedMetadataLine {
  const _SelectedMetadataLine({required this.text, required this.blocked});

  final String text;
  final bool blocked;
}

/// Rows needed to render every provider-status and endpoint value without
/// clipping it at [inner] visible columns.
int selectedMetadataRowCount({
  required MonitorSnapshot snapshot,
  required String instance,
  required int inner,
}) => _selectedMetadataLines(
  snapshot: snapshot,
  instance: instance,
  inner: inner,
).length;

List<_SelectedMetadataLine> _selectedMetadataLines({
  required MonitorSnapshot snapshot,
  required String instance,
  required int inner,
}) {
  final List<_SelectedMetadataLine> lines = <_SelectedMetadataLine>[];
  final String? reason = snapshot.operationBlockReasonFor(instance);
  if (reason != null) {
    lines.addAll(_wrappedMetadata('BLOCKED:', reason, inner, blocked: true));
  }
  final List<String> advertised = snapshot.advertisedEndpointsFor(instance);
  if (advertised.isNotEmpty) {
    lines.addAll(_wrappedMetadata('ADVERTISED', advertised.join(' · '), inner));
  }
  final List<String> binds = snapshot.bindEndpointsFor(instance);
  if (binds.isNotEmpty) {
    lines.addAll(_wrappedMetadata('BIND', binds.join(' · '), inner));
  }
  return lines;
}

List<_SelectedMetadataLine> _wrappedMetadata(
  String label,
  String value,
  int width, {
  bool blocked = false,
}) {
  final String prefix = '$label ';
  final int valueWidth = width - prefix.length;
  if (valueWidth <= 0) {
    return <_SelectedMetadataLine>[
      _SelectedMetadataLine(text: '$prefix$value', blocked: blocked),
    ];
  }
  final List<_SelectedMetadataLine> lines = <_SelectedMetadataLine>[];
  for (int offset = 0; offset < value.length; offset += valueWidth) {
    final int end = offset + valueWidth < value.length
        ? offset + valueWidth
        : value.length;
    lines.add(
      _SelectedMetadataLine(
        text:
            '${offset == 0 ? prefix : ' ' * prefix.length}'
            '${value.substring(offset, end)}',
        blocked: blocked,
      ),
    );
  }
  if (lines.isEmpty) {
    lines.add(_SelectedMetadataLine(text: label, blocked: blocked));
  }
  return lines;
}

/// The fleet-wide readings the KPI strip is drawn from — one pass over the
/// snapshot, so no two cards can disagree about the same fleet.
///
/// Counts follow the snapshot's own discipline: an instance nothing has been
/// sampled from is neither up nor down, and a missing reading is missing —
/// it never sums in as a zero.
class MonitorRollup {
  const MonitorRollup({
    required this.up,
    required this.total,
    required this.players,
    required this.anyPlayers,
    required this.meanTps,
    required this.tpsSeries,
    required this.rssSum,
    required this.peakRssSum,
    required this.memoryLimitSum,
    required this.meanCpu,
  });

  /// Instances that have been sampled and are not stopped. An instance
  /// nothing has been heard from is not one of these — and is not down
  /// either, which is why the fleet card reads `up/total` rather than
  /// claiming a state for every member.
  final int up;

  /// Instances in the workspace, sampled or not.
  final int total;

  /// Players across every instance that reported a count, and whether any
  /// did — a fleet nobody has counted reads `n/a`, not `0`.
  final int players;
  final bool anyPlayers;

  /// Mean of the latest TPS reading across the instances that have one.
  final double? meanTps;

  /// Fleet-mean TPS per sample time within the window, oldest first. Every
  /// sweep stamps its instances with one timestamp, so a group is one sweep.
  final List<double?> tpsSeries;

  /// Resident bytes across the instances that reported them, and the largest
  /// such sum seen anywhere in the window (the scale the meter reads
  /// against).
  final int? rssSum;
  final int? peakRssSum;

  /// Sum of configured memory limits where the provider exposes them.
  final int? memoryLimitSum;

  /// Mean of the latest CPU reading across the instances that have one.
  final double? meanCpu;

  /// Rolls [snapshot] up, reading its history over `[windowStart, windowEnd]`.
  factory MonitorRollup.of(
    MonitorSnapshot snapshot, {
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    int up = 0;
    int players = 0;
    bool anyPlayers = false;
    double tpsTotal = 0;
    int tpsCount = 0;
    int rssTotal = 0;
    bool anyRss = false;
    int memoryLimitTotal = 0;
    bool anyMemoryLimit = false;
    double cpuTotal = 0;
    int cpuCount = 0;

    // Keyed by sample time: one sweep stamps every instance it read with the
    // same instant, so a key is one fleet-wide observation.
    final Map<int, _TimeSlice> slices = <int, _TimeSlice>{};

    for (final String instance in snapshot.instances) {
      final MetricSample? latest = snapshot.latestFor(instance);
      if (latest != null && latest.state != RuntimeState.stopped) {
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
      final int? rss = latest?.rssBytes;
      if (rss != null) {
        rssTotal += rss;
        anyRss = true;
      }
      final double? cpu = latest?.cpuPercent;
      if (cpu != null) {
        cpuTotal += cpu;
        cpuCount += 1;
      }
      final int? memoryLimit = latest?.memoryLimitBytes;
      if (memoryLimit != null) {
        memoryLimitTotal += memoryLimit;
        anyMemoryLimit = true;
      }

      for (final MetricSample sample in snapshot.historyFor(instance)) {
        if (sample.ts.isBefore(windowStart) || sample.ts.isAfter(windowEnd)) {
          continue;
        }
        final double? sampleTps = sample.tps;
        final int? sampleRss = sample.rssBytes;
        if (sampleTps == null && sampleRss == null) {
          continue;
        }
        final _TimeSlice slice = slices.putIfAbsent(
          sample.ts.microsecondsSinceEpoch,
          _TimeSlice.new,
        );
        if (sampleTps != null) {
          slice.tpsTotal += sampleTps;
          slice.tpsCount += 1;
        }
        if (sampleRss != null) {
          slice.rssTotal += sampleRss;
        }
      }
    }

    final List<int> times = slices.keys.toList()..sort();
    final List<double?> series = <double?>[];
    int? peakRssSum;
    for (final int time in times) {
      final _TimeSlice slice = slices[time]!;
      if (slice.tpsCount > 0) {
        series.add(slice.tpsTotal / slice.tpsCount);
      }
      if (slice.rssTotal > 0 &&
          (peakRssSum == null || slice.rssTotal > peakRssSum)) {
        peakRssSum = slice.rssTotal;
      }
    }

    return MonitorRollup(
      up: up,
      total: snapshot.instances.length,
      players: players,
      anyPlayers: anyPlayers,
      meanTps: tpsCount == 0 ? null : tpsTotal / tpsCount,
      tpsSeries: series,
      rssSum: anyRss ? rssTotal : null,
      peakRssSum: peakRssSum,
      memoryLimitSum: anyMemoryLimit ? memoryLimitTotal : null,
      meanCpu: cpuCount == 0 ? null : cpuTotal / cpuCount,
    );
  }
}

/// One sweep's running totals while [MonitorRollup.of] groups history by
/// sample time.
class _TimeSlice {
  double tpsTotal = 0;
  int tpsCount = 0;
  int rssTotal = 0;
}

/// The KPI strip: three cards side by side, one content row each.
///
/// FLEET is sized to its own reading; TPS and HOST split what is left, with
/// their trend and meter absorbing the slack a wide terminal leaves. Every
/// missing reading renders `n/a` and every unread meter a dash run — never a
/// measured zero.
List<String> renderKpiStrip({
  required MonitorRollup rollup,
  required int columns,
  required MonitorTheme theme,
}) {
  final String countsText = '${rollup.up}/${rollup.total} UP';
  final String playersText = (rollup.anyPlayers ? '${rollup.players}' : 'n/a')
      .padLeft(_kpiPlayersColumn);
  final String fleetPlain = '$countsText · $playersText PLAYERS';
  final int fleetWidth = fleetPlain.length + 4 > _kpiFleetWidth
      ? fleetPlain.length + 4
      : _kpiFleetWidth;

  final int remainder = columns - fleetWidth - 2;
  final int hostWidth = remainder * _kpiHostPercent ~/ 100;
  final int tpsWidth = remainder - hostWidth;

  final String fleet =
      '${theme.paint(countsText, rollup.up > 0 ? theme.ok : theme.faint)} · '
      '${theme.paint(playersText, rollup.anyPlayers && rollup.players > 0 ? theme.accent : theme.faint)}'
      ' PLAYERS';

  final double? meanTps = rollup.meanTps;
  final int sparkCells = _clampInt(
    tpsWidth - 4 - _kpiTpsFixed,
    _kpiMinSparkCells,
    _kpiMaxSparkCells,
  );
  final String tps =
      '${theme.paint((meanTps == null ? 'n/a' : meanTps.toStringAsFixed(1)).padLeft(4), theme.tpsTone(meanTps))} '
      '${renderSparkline(values: rollup.tpsSeries, width: sparkCells, theme: theme, min: 0, max: 20, ramp: MonitorRamp.tps)}';

  final int? rssSum = rollup.rssSum;
  final int? peakRssSum = rollup.memoryLimitSum ?? rollup.peakRssSum;
  final double? memFraction =
      rssSum == null || peakRssSum == null || peakRssSum <= 0
      ? null
      : rssSum / peakRssSum;
  final double? meanCpu = rollup.meanCpu;
  final String memText = formatBytes(rssSum);
  final String cpuText = _wholePercent(meanCpu);
  final int meterCells = _clampInt(
    hostWidth - 4 - _kpiHostFixed - memText.length - cpuText.length,
    0,
    _kpiMaxMeterCells,
  );
  final String host =
      'MEM ${renderMeter(fraction: memFraction, cells: meterCells, theme: theme)} '
      '${theme.paint(memText, rssSum == null ? theme.faint : theme.text)}'
      ' · CPU '
      '${theme.paint(cpuText, meanCpu == null ? theme.faint : theme.text)}';

  return joinBlocks(<List<String>>[
    renderPanel(
      title: 'FLEET',
      content: <String>[fleet],
      width: fleetWidth,
      theme: theme,
    ),
    renderPanel(
      title: 'TPS',
      content: <String>[tps],
      width: tpsWidth,
      theme: theme,
    ),
    renderPanel(
      title: 'HOST',
      content: <String>[host],
      width: hostWidth,
      theme: theme,
    ),
  ]);
}

/// One column of the fleet table.
enum _TableColumn { name, state, players, tps, trend, mem, cpu, up }

/// The column headers, and which columns right-align (the numeric readings,
/// so their units line up down the table).
const Map<_TableColumn, String> _tableHeaders = <_TableColumn, String>{
  _TableColumn.name: 'NAME',
  _TableColumn.state: 'STATE',
  _TableColumn.players: 'PLAYERS',
  _TableColumn.tps: 'TPS',
  _TableColumn.trend: 'TREND',
  _TableColumn.mem: 'MEM',
  _TableColumn.cpu: 'CPU',
  _TableColumn.up: 'UP',
};
const Set<_TableColumn> _rightAligned = <_TableColumn>{
  _TableColumn.players,
  _TableColumn.tps,
  _TableColumn.mem,
  _TableColumn.cpu,
  _TableColumn.up,
};

/// The order columns give way in when the terminal cannot hold them all.
/// The trend goes first: the selected card carries the real charts, and a
/// sparkline is the one cell whose loss hides no number.
const List<_TableColumn> _tableDropOrder = <_TableColumn>[
  _TableColumn.trend,
  _TableColumn.up,
  _TableColumn.cpu,
  _TableColumn.mem,
  _TableColumn.players,
];

/// The columns that fit in [inner] and their widths: fixed widths, dropped
/// whole in [_tableDropOrder] until the row fits, with a wide terminal's
/// slack going to the trend sparkline (up to [_maxTrendCells]).
({List<_TableColumn> columns, Map<_TableColumn, int> widths}) _planTable(
  int inner,
) {
  final Map<_TableColumn, int> widths = <_TableColumn, int>{
    _TableColumn.name: _colNameWidth,
    _TableColumn.state: _colStateWidth,
    _TableColumn.players: _colPlayersWidth,
    _TableColumn.tps: _colTpsWidth,
    _TableColumn.trend: _colTrendWidth,
    _TableColumn.mem: _colMemWidth,
    _TableColumn.cpu: _colCpuWidth,
    _TableColumn.up: _colUpWidth,
  };
  final List<_TableColumn> columns = _TableColumn.values.toList();

  int needed() {
    int total = _tablePrefix + _tableGap * (columns.length - 1);
    for (final _TableColumn column in columns) {
      total += widths[column]!;
    }
    return total;
  }

  for (final _TableColumn drop in _tableDropOrder) {
    if (needed() <= inner) {
      break;
    }
    columns.remove(drop);
  }

  if (columns.contains(_TableColumn.trend)) {
    final int slack = inner - needed();
    if (slack > 0) {
      widths[_TableColumn.trend] = _clampInt(
        _colTrendWidth + slack,
        _colTrendWidth,
        _maxTrendCells,
      );
    }
  }

  return (columns: columns, widths: widths);
}

/// The full-width fleet table: a faint column-header row, then one reading
/// row per instance the panel can show, exactly [rows] rows tall (borders
/// included), with a full-width server-row hitbox under every instance row.
///
/// A fleet taller than the panel scrolls: the window follows the selection,
/// and each clipped end spends one row on a faint `+N more` marker. A marker
/// is a label, not a target, so it gets no hitbox. Rows the fleet does not
/// need stay blank — an empty table viewport, not a fabricated reading.
MonitorPanelRender renderServerList({
  required MonitorSnapshot snapshot,
  required MonitorRollup rollup,
  required int selectedIndex,
  required int rows,
  required int width,
  required int topRow,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
  String? hoveredId,
}) {
  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = width - 4 < 0 ? 0 : width - 4;
  final int total = snapshot.instances.length;
  final ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan =
      _planTable(inner);

  // The header row comes out of the content budget first: a table whose
  // columns nothing names is a guessing game.
  final int serverArea = contentRows < 1 ? 0 : contentRows - 1;

  int slots = serverArea;
  int offset = 0;
  if (total > serverArea) {
    // Something is always clipped, so at least one row goes to a marker; a
    // window with fleet on both sides needs two.
    slots = serverArea - 1;
    offset = _windowOffset(selectedIndex, slots, total);
    if (offset > 0 && offset + slots < total) {
      slots = serverArea - 2;
      offset = _windowOffset(selectedIndex, slots, total);
    }
    if (slots < 1 && serverArea > 0) {
      // A panel too short for a window and its markers still shows the
      // selection: the row the user is on outranks the note saying there is
      // more of the fleet elsewhere.
      slots = 1;
      offset = _windowOffset(selectedIndex, slots, total);
    }
  }
  if (slots < 0) {
    slots = 0;
  }
  final int end = offset + slots < total ? offset + slots : total;

  // Markers are drawn only out of rows the window itself did not need, so
  // the panel can never be handed more content than it has room for.
  int spare = serverArea - (end - offset);
  bool above = offset > 0 && spare > 0;
  if (above) {
    spare -= 1;
  }
  final bool below = end < total && spare > 0;

  final List<String> content = <String>[];
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[];
  if (contentRows > 0) {
    content.add(_tableHeaderRow(plan: plan, theme: theme));
  }
  if (above) {
    content.add(theme.paint('+$offset more', theme.faint));
  }
  for (int index = offset; index < end; index++) {
    final String instance = snapshot.instances[index];
    hitboxes.add(
      MonitorHitbox(
        id: '$serverHitPrefix$instance',
        kind: MonitorHitKind.serverRow,
        row: topRow + 1 + content.length,
        colStart: 0,
        colEnd: width,
      ),
    );
    content.add(
      _serverTableRow(
        plan: plan,
        instance: snapshot.displayNameFor(instance),
        latest: snapshot.latestFor(instance),
        history: snapshot.historyFor(instance),
        selected: index == selectedIndex,
        hovered: hoveredId == '$serverHitPrefix$instance',
        active: instance == snapshot.activeInstance,
        theme: theme,
        windowStart: windowStart,
        windowEnd: windowEnd,
      ),
    );
  }
  if (below) {
    content.add(theme.paint('+${total - end} more', theme.faint));
  }
  while (content.length < contentRows) {
    content.add('');
  }

  return MonitorPanelRender(
    rows: renderPanel(
      title: 'SERVERS',
      badge: '${rollup.up}/${rollup.total} UP',
      content: content,
      width: width,
      theme: theme,
      emphasis: PanelEmphasis.active,
    ),
    hitboxes: hitboxes,
  );
}

/// The table's column-header row, faint, aligned exactly as the reading
/// rows below it are.
String _tableHeaderRow({
  required ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan,
  required MonitorTheme theme,
}) {
  final StringBuffer row = StringBuffer(' ' * _tablePrefix);
  for (int index = 0; index < plan.columns.length; index++) {
    if (index > 0) {
      row.write(' ' * _tableGap);
    }
    final _TableColumn column = plan.columns[index];
    row.write(
      _fitCell(
        _tableHeaders[column]!,
        plan.widths[column]!,
        right: _rightAligned.contains(column),
      ),
    );
  }
  return theme.paint(row.toString(), theme.faint);
}

/// One reading row of the fleet table: `▸ ● name  state  …`. The selector
/// marks the selection and the hovered row alike; the name is strong for
/// the selection and the workspace's active instance; every missing reading
/// is the dash glyph, never a zero.
String _serverTableRow({
  required ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan,
  required String instance,
  required MetricSample? latest,
  required List<MetricSample> history,
  required bool selected,
  required bool hovered,
  required bool active,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;
  final RuntimeState? state = latest?.state;
  final bool live = state != null && state != RuntimeState.stopped;
  final String dash = glyphs.dash;

  final String selector = selected || hovered
      ? theme.paint(glyphs.selector, theme.accent)
      : ' ';
  final String bullet = live
      ? theme.paint(glyphs.bulletOn, theme.statusTone(state))
      : theme.paint(glyphs.bulletOff, theme.faint);

  final StringBuffer row = StringBuffer('$selector $bullet ');
  for (int index = 0; index < plan.columns.length; index++) {
    if (index > 0) {
      row.write(' ' * _tableGap);
    }
    final _TableColumn column = plan.columns[index];
    final int cellWidth = plan.widths[column]!;
    switch (column) {
      case _TableColumn.name:
        final String tone = selected || active
            ? theme.textStrong
            : (live ? theme.text : theme.faint);
        row.write(theme.paint(_fitCell(instance, cellWidth), tone));
      case _TableColumn.state:
        final String tone = live ? theme.statusTone(state) : theme.faint;
        row.write(
          theme.paint(_fitCell(monitorStateText(latest), cellWidth), tone),
        );
      case _TableColumn.players:
        final String text = monitorPlayersText(latest, theme);
        final String tone = latest?.players == null ? theme.faint : theme.text;
        row.write(theme.paint(_fitCell(text, cellWidth, right: true), tone));
      case _TableColumn.tps:
        final double? tps = latest?.tps;
        row.write(
          theme.paint(
            _fitCell(monitorTpsText(tps, theme), cellWidth, right: true),
            theme.tpsTone(tps),
          ),
        );
      case _TableColumn.trend:
        row.write(
          _trendCell(
            history: history,
            cells: cellWidth,
            theme: theme,
            windowStart: windowStart,
            windowEnd: windowEnd,
          ),
        );
      case _TableColumn.mem:
        final int? rss = latest?.rssBytes;
        row.write(
          theme.paint(
            _fitCell(
              rss == null ? dash : formatBytes(rss),
              cellWidth,
              right: true,
            ),
            rss == null ? theme.faint : theme.text,
          ),
        );
      case _TableColumn.cpu:
        final double? cpu = latest?.cpuPercent;
        row.write(
          theme.paint(
            _fitCell(
              cpu == null ? dash : _wholePercent(cpu),
              cellWidth,
              right: true,
            ),
            cpu == null ? theme.faint : theme.text,
          ),
        );
      case _TableColumn.up:
        final int? uptime = latest?.uptimeSeconds;
        row.write(
          theme.paint(
            _fitCell(
              uptime == null
                  ? dash
                  : formatCompactDuration(Duration(seconds: uptime)),
              cellWidth,
              right: true,
            ),
            uptime == null ? theme.faint : theme.text,
          ),
        );
    }
  }
  return row.toString();
}

/// One instance's trend sparkline over the window: its TPS when it has any
/// (pinned `0..20`), otherwise its CPU (pinned `0..100`, the reading a mod
/// server without RCON still has). A window with neither renders gaps.
String _trendCell({
  required List<MetricSample> history,
  required int cells,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  final List<double?> tps = <double?>[];
  final List<double?> cpu = <double?>[];
  bool anyTps = false;
  for (final MetricSample sample in history) {
    if (sample.ts.isBefore(windowStart) || sample.ts.isAfter(windowEnd)) {
      continue;
    }
    if (sample.tps != null) {
      anyTps = true;
    }
    tps.add(sample.tps);
    cpu.add(sample.cpuPercent);
  }
  return renderSparkline(
    values: anyTps ? tps : cpu,
    width: cells,
    theme: theme,
    min: 0,
    max: anyTps ? 20 : 100,
    ramp: anyTps ? MonitorRamp.tps : MonitorRamp.load,
  );
}

/// The selected-server card: compact, and sized by `monitor_model.dart` to
/// the selection's own state — a live server gets small charts side by side
/// (TPS when the window has any, then CPU and memory as the width allows)
/// over a facts row; a stopped or unsampled one gets a single quiet line,
/// because there is nothing live to plot.
///
/// The badge — `<state> · <range>` — is a range chip: clicking it cycles the
/// window, exactly as `r` does. It only becomes a target when the panel is
/// actually wide enough to inlay it, and it answers [hoveredId] the way
/// every other target does: under the pointer it takes the accent tone the
/// button chips use, so a clickable badge does not look like decoration.
MonitorPanelRender renderSelectedPanel({
  required MonitorSnapshot snapshot,
  required int selectedIndex,
  required int rows,
  required int width,
  required int topRow,
  required int colOffset,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
  String? hoveredId,
}) {
  final String instance = snapshot.instances[selectedIndex];
  final List<MetricSample> history = snapshot.historyFor(instance);
  final MetricSample? latest = snapshot.latestFor(instance);
  final String? operationBlockReason = snapshot.operationBlockReasonFor(
    instance,
  );
  final String title = snapshot.displayNameFor(instance).toUpperCase();
  final String badge = operationBlockReason == null
      ? '${monitorStateText(latest)} · ${rangeLabel(range)}'
      : 'BLOCKED · ${rangeLabel(range)}';

  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = width - 4 < 0 ? 0 : width - 4;
  final bool live = latest != null && latest.state != RuntimeState.stopped;

  final List<String> metadata = <String>[
    for (final _SelectedMetadataLine line in _selectedMetadataLines(
      snapshot: snapshot,
      instance: instance,
      inner: inner,
    ))
      theme.paint(line.text, line.blocked ? theme.danger : theme.muted),
  ];
  final int primaryRows = contentRows - metadata.length;
  final List<String> content = live
      ? _liveCard(
          history: history,
          latest: latest,
          inner: inner,
          contentRows: primaryRows < 0 ? 0 : primaryRows,
          theme: theme,
          range: range,
          now: now,
        )
      : <String>[if (primaryRows > 0) _idleRow(latest: latest, theme: theme)];
  for (final String line in metadata) {
    if (content.length >= contentRows) {
      break;
    }
    content.add(line);
  }
  while (content.length < contentRows) {
    content.add('');
  }

  // Where renderPanel inlays the badge: three columns of corner and rule at
  // the right edge, the badge, and the fill it drops the badge for when the
  // title and badge together do not fit.
  final bool badgeFits = width - 8 - title.length - badge.length >= 0;
  // Hover is only honored where the chip is actually a target: a badge the
  // panel dropped for width has no hitbox, so nothing can be over it.
  final bool badgeHovered = badgeFits && hoveredId == rangeHitId;
  return MonitorPanelRender(
    rows: renderPanel(
      title: title,
      badge: badge,
      styledBadge: badgeHovered
          ? theme.paint(badge, '${theme.bold}${theme.accent}')
          : null,
      content: content,
      width: width,
      theme: theme,
    ),
    hitboxes: badgeFits
        ? <MonitorHitbox>[
            MonitorHitbox(
              id: rangeHitId,
              kind: MonitorHitKind.rangeChip,
              row: topRow,
              colStart: colOffset + width - 3 - badge.length,
              colEnd: colOffset + width - 3,
            ),
          ]
        : const <MonitorHitbox>[],
  );
}

/// The live card's content: a faint label row, up to three small charts side
/// by side, a blank, the facts row, and a compact RX/TX network monitor at
/// the bottom. When rows tighten, the blank, facts, and labels give way in
/// that order; the charts and network monitor are the live card's signal.
List<String> _liveCard({
  required List<MetricSample> history,
  required MetricSample latest,
  required int inner,
  required int contentRows,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
}) {
  bool labels = true;
  bool blank = true;
  bool facts = true;
  bool network = true;
  int chartRows = contentRows - 4;
  if (chartRows < _minChartRows) {
    blank = false;
    chartRows = contentRows - 3;
  }
  if (chartRows < _minChartRows) {
    facts = false;
    chartRows = contentRows - 2;
  }
  if (chartRows < _minChartRows) {
    labels = false;
    chartRows = contentRows - 1;
  }
  if (chartRows < _minChartRows) {
    network = false;
    chartRows = contentRows;
  }
  if (chartRows < 0) {
    chartRows = 0;
  }

  final DateTime start = now.subtract(range);
  bool anyTps = false;
  for (final MetricSample sample in history) {
    if (sample.tps != null &&
        !sample.ts.isBefore(start) &&
        !sample.ts.isAfter(now)) {
      anyTps = true;
      break;
    }
  }

  final List<
    ({
      String title,
      List<ChartPoint> points,
      double? low,
      double? high,
      MonitorRamp ramp,
    })
  >
  candidates =
      <
        ({
          String title,
          List<ChartPoint> points,
          double? low,
          double? high,
          MonitorRamp ramp,
        })
      >[
        if (anyTps)
          (
            title: 'TPS',
            points: _chartPoints(history, (MetricSample s) => s.tps),
            low: 0,
            high: 20,
            ramp: MonitorRamp.tps,
          ),
        (
          title: 'CPU %',
          points: _chartPoints(history, (MetricSample s) => s.cpuPercent),
          low: 0,
          high: 100,
          ramp: MonitorRamp.load,
        ),
        (
          title: 'MEM MiB',
          points: _chartPoints(
            history,
            (MetricSample s) =>
                s.rssBytes == null ? null : s.rssBytes! / 1048576,
          ),
          low: null,
          high: null,
          ramp: MonitorRamp.load,
        ),
      ];

  int fit = 1;
  for (int count = candidates.length; count >= 1; count--) {
    if (count * _minChartWidth + (count - 1) * _chartGap <= inner) {
      fit = count;
      break;
    }
  }
  final List<int> widths = List<int>.generate(fit, (int index) {
    final int base = (inner - _chartGap * (fit - 1)) ~/ fit;
    if (index < fit - 1) {
      return base;
    }
    return inner - _chartGap * (fit - 1) - base * (fit - 1);
  });

  final List<String> content = <String>[];
  if (labels) {
    final StringBuffer labelRow = StringBuffer();
    for (int index = 0; index < fit; index++) {
      if (index > 0) {
        labelRow.write(' ' * _chartGap);
      }
      labelRow.write(_fitCell(candidates[index].title, widths[index]));
    }
    content.add(theme.paint(labelRow.toString(), theme.muted));
  }
  content.addAll(
    joinBlocks(<List<String>>[
      for (int index = 0; index < fit; index++)
        renderBrailleChart(
          series: <ChartSeries>[
            ChartSeries(
              label: candidates[index].title,
              points: candidates[index].points,
            ),
          ],
          width: widths[index],
          height: chartRows,
          start: start,
          end: now,
          theme: theme,
          forcedLow: candidates[index].low,
          forcedHigh: candidates[index].high,
          ramp: candidates[index].ramp,
        ),
    ], gap: ' ' * _chartGap),
  );
  if (blank) {
    content.add('');
  }
  if (facts) {
    content.add(_factsRow(latest: latest, inner: inner, theme: theme));
  }
  if (network) {
    content.add(
      _networkMonitorRow(
        history: history,
        latest: latest,
        inner: inner,
        theme: theme,
      ),
    );
  }
  return content;
}

/// Maps [history] to chart points via [read], keeping nulls as gaps.
List<ChartPoint> _chartPoints(
  List<MetricSample> history,
  double? Function(MetricSample sample) read,
) => <ChartPoint>[
  for (final MetricSample sample in history)
    ChartPoint(ts: sample.ts, value: read(sample)),
];

/// One compact, bottom-anchored network monitor. macOS Local samples use
/// true per-process packet rates; Remote samples fall back to byte
/// throughput because Pterodactyl does not expose packet counters.
String _networkMonitorRow({
  required List<MetricSample> history,
  required MetricSample latest,
  required int inner,
  required MonitorTheme theme,
}) {
  final NetworkRateUnit? unit = preferredNetworkRateUnit(history);
  final double? rx = networkRxRate(latest, unit);
  final double? tx = networkTxRate(latest, unit);
  final String label = switch (unit) {
    NetworkRateUnit.packetsPerSecond => 'NETWORK PPS',
    NetworkRateUnit.bytesPerSecond => 'NETWORK B/s',
    null => 'NETWORK',
  };
  final String rxText = _networkRateText(rx, unit);
  final String txText = _networkRateText(tx, unit);
  final String summary = '$label · RX $rxText · TX $txText';

  final List<double?> rxSeries = <double?>[
    for (final MetricSample sample in history) networkRxRate(sample, unit),
  ];
  final List<double?> txSeries = <double?>[
    for (final MetricSample sample in history) networkTxRate(sample, unit),
  ];
  double? peak;
  for (final double? value in <double?>[...rxSeries, ...txSeries]) {
    if (value != null && (peak == null || value > peak)) {
      peak = value;
    }
  }
  final int sparkCells = _clampInt((inner - summary.length - 2) ~/ 2, 0, 24);
  if (sparkCells == 0) {
    return theme.paint(summary, theme.muted);
  }
  final double? high = peak == null ? null : (peak <= 0 ? 1 : peak);
  final String rxSpark = renderSparkline(
    values: rxSeries,
    width: sparkCells,
    theme: theme,
    min: 0,
    max: high,
    ramp: MonitorRamp.title,
  );
  final String txSpark = renderSparkline(
    values: txSeries,
    width: sparkCells,
    theme: theme,
    min: 0,
    max: high,
    ramp: MonitorRamp.title,
  );
  return '${theme.paint('$label · RX $rxText ', theme.muted)}$rxSpark'
      '${theme.paint(' · TX $txText ', theme.muted)}$txSpark';
}

String _networkRateText(double? rate, NetworkRateUnit? unit) => switch (unit) {
  NetworkRateUnit.packetsPerSecond => formatPacketsPerSecond(rate),
  NetworkRateUnit.bytesPerSecond => formatBytesPerSecond(rate),
  null => 'n/a',
};

/// The idle card's one line: the state in its own tone, and what would bring
/// the server to life — no fabricated facts, no empty chart grid.
String _idleRow({required MetricSample? latest, required MonitorTheme theme}) {
  final String state = monitorStateText(latest);
  final String tone = latest == null
      ? theme.faint
      : theme.statusTone(latest.state);
  final String hint = latest == null
      ? 'waiting for a first sample'
      : 'START to launch';
  return '${theme.paint(state, tone)}${theme.paint(' · $hint', theme.faint)}';
}

/// The body of a workspace with nothing in it: a centered prompt over a
/// centered `+ NEW` chip, in a full-width panel.
MonitorPanelRender renderEmptyBody({
  required int rows,
  required int columns,
  required int topRow,
  required MonitorTheme theme,
  bool remoteDisconnected = false,
  String? hoveredId,
  String? pressedId,
}) {
  final String prompt = remoteDisconnected
      ? 'REMOTE NOT CONNECTED'
      : 'NO SERVERS';
  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = columns - 4 < 0 ? 0 : columns - 4;
  final ButtonSpec chip = remoteDisconnected
      ? const ButtonSpec(id: wsConnectHitId, label: 'CONNECTION')
      : newInstanceButton;
  final int chipWidth = chip.label.length + 4;
  final ButtonRowRender button = layoutButtonRow(
    buttons: <ButtonSpec>[chip],
    width: inner,
    theme: theme,
    hoveredId: hoveredId,
    pressedId: pressedId,
    indent: (inner - chipWidth) ~/ 2 < 0 ? 0 : (inner - chipWidth) ~/ 2,
  );

  final int promptRow = contentRows < 2 ? 0 : (contentRows - 2) ~/ 2;
  final List<String> content = <String>[
    for (int index = 0; index < contentRows; index++)
      if (index == promptRow)
        _center(theme.paint(prompt, theme.faint), prompt.length, inner)
      else if (index == promptRow + 1)
        button.row
      else
        '',
  ];

  return MonitorPanelRender(
    rows: renderPanel(
      title: 'SERVERS',
      badge: '0/0 UP',
      content: content,
      width: columns,
      theme: theme,
      emphasis: PanelEmphasis.active,
    ),
    hitboxes: <MonitorHitbox>[
      // Only when the chip row was actually drawn: a target over a row the
      // panel had no room for is a click that does something invisible.
      if (promptRow + 1 < contentRows)
        for (final ButtonSpan span in button.spans)
          MonitorHitbox(
            id: span.id,
            kind: MonitorHitKind.button,
            // Two columns of panel chrome sit left of every content column.
            row: topRow + 1 + promptRow + 1,
            colStart: span.colStart + 2,
            colEnd: span.colEnd + 2,
          ),
    ],
  );
}

/// The `+ NEW` button, shared by the workspace bar and the empty-workspace
/// prompt so both routes carry the same id.
const ButtonSpec newInstanceButton = ButtonSpec(id: wsNewHitId, label: '+ NEW');

/// The selected-server card's facts row. A fact leaves whole when the row
/// runs out of columns — a clipped fact hides a reading without admitting to
/// it — and every missing reading is a dash or an `n/a`, never a zero.
String _factsRow({
  required MetricSample? latest,
  required int inner,
  required MonitorTheme theme,
}) {
  final int? uptime = latest?.uptimeSeconds;
  final int? latency = latest?.latencyMs;
  // A blank version string is missing data, not a version.
  final String? version = latest?.version;
  final int? disk = latest?.diskBytes;
  final int? diskLimit = latest?.diskLimitBytes;
  final NetworkRateUnit? networkUnit = latest == null
      ? null
      : preferredNetworkRateUnit(<MetricSample>[latest]);
  final double? networkRx = latest == null
      ? null
      : networkRxRate(latest, networkUnit);
  final double? networkTx = latest == null
      ? null
      : networkTxRate(latest, networkUnit);
  final List<String> facts = <String>[
    'UP ${uptime == null ? 'n/a' : formatCompactDuration(Duration(seconds: uptime))}',
    '${monitorPlayersText(latest, theme)} PLAYERS',
    'PING ${latency == null ? 'n/a' : '${latency}ms'}',
    'NET RX ${_networkRateText(networkRx, networkUnit)} TX ${_networkRateText(networkTx, networkUnit)}',
    'MEM ${formatBytes(latest?.rssBytes)}',
    'CPU ${formatCpuPercent(latest?.cpuPercent)}',
    'DISK ${formatBytes(disk)}${diskLimit == null ? '' : '/${formatBytes(diskLimit)}'}',
    version == null || version.isEmpty ? theme.glyphs.dash : version,
  ];
  while (facts.length > 1 && facts.join(' · ').length > inner) {
    facts.removeLast();
  }
  return theme.paint(facts.join(' · '), theme.muted);
}

/// The first index of a [slots]-row window over [total] instances that keeps
/// [selected] visible: the window sits at the top until the selection walks
/// past its bottom edge, then follows it.
int _windowOffset(int selected, int slots, int total) {
  if (slots <= 0) {
    return 0;
  }
  int offset = selected >= slots ? selected - slots + 1 : 0;
  if (offset > total - slots) {
    offset = total - slots;
  }
  return offset < 0 ? 0 : offset;
}

/// [percent] rounded to a whole percent, or `n/a` when there is no reading.
/// The KPI strip and the fleet table trade the decimal place for the columns
/// it costs.
String _wholePercent(double? percent) =>
    percent == null ? 'n/a' : '${percent.round()}%';

/// Clips or pads the already-plain [text] to exactly [width] columns,
/// left-aligned unless [right].
String _fitCell(String text, int width, {bool right = false}) {
  if (text.length > width) {
    return text.substring(0, width);
  }
  return right ? text.padLeft(width) : text.padRight(width);
}

/// Centers [painted] (whose visible width is [visible]) in [width] columns.
String _center(String painted, int visible, int width) => visible >= width
    ? painted
    : Ansi.padVisible('${' ' * ((width - visible) ~/ 2)}$painted', width);

int _clampInt(int value, int low, int high) {
  if (value < low) {
    return low;
  }
  return value > high ? high : value;
}
