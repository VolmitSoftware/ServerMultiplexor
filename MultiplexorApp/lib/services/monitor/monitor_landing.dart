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

import 'dart:math' as math;

import '../../utils/charts/area_chart.dart';
import '../../utils/charts/braille_chart.dart';
import '../../utils/charts/chart_scale.dart';
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
import 'monitor_groups.dart';
import 'monitor_hitbox.dart';
import 'monitor_network_tree.dart';

/// Columns before the name: checkbox, focus selector, status, and spacing.
const int _tablePrefix = 8;

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
const int _maxTrendCells = 48;

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

/// The tallest the card's charts grow (plot rows and time axis). Past this a
/// taller plot shows nothing new, so the rows go to the log tail instead.
const int _maxChartRows = 18;

/// The fewest rows worth spending on the card's log tail: a gap, the `LOG`
/// rule, and two lines.
const int _minLogRows = 4;

/// The chart height a stacked row of charts is planned at, and the log rows
/// stacking leaves free when there is a log to show.
const int _stackChartRows = 12;
const int _stackLogReserve = 12;

/// The tallest a live card gets without a log tail to fill: its borders,
/// the chart header, charts at [_maxChartRows], a blank, facts, and the
/// network row. Metadata rows come on top.
const int monitorLiveCardMaxRows = _maxChartRows + 6;

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
  final MonitorNetworkRow? network = snapshot.networkRows[instance];
  if (network != null) {
    lines.addAll(
      _wrappedMetadata(
        'NETWORK',
        network.isProxy
            ? '${network.network} · Velocity · port ${network.port}'
            : '${network.network} · via ${network.proxy} · ${network.alias}:${network.port}',
        inner,
      ),
    );
  }
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
enum _TableColumn {
  name,
  port,
  state,
  players,
  tps,
  trend,
  mem,
  cpu,
  up,
  primary,
}

/// The column headers, and which columns right-align (the numeric readings,
/// so their units line up down the table).
const Map<_TableColumn, String> _tableHeaders = <_TableColumn, String>{
  _TableColumn.name: 'NAME',
  _TableColumn.port: 'PORT',
  _TableColumn.state: 'STATE',
  _TableColumn.players: 'PLAYERS',
  _TableColumn.tps: 'TPS',
  _TableColumn.trend: 'TREND',
  _TableColumn.mem: 'MEM',
  _TableColumn.cpu: 'CPU',
  _TableColumn.up: 'UP',
  _TableColumn.primary: 'PRIMARY',
};
const Set<_TableColumn> _rightAligned = <_TableColumn>{
  _TableColumn.port,
  _TableColumn.players,
  _TableColumn.tps,
  _TableColumn.mem,
  _TableColumn.cpu,
  _TableColumn.up,
};

/// The order columns give way in when the terminal cannot hold them all.
/// The trend goes first: the selected card carries the real charts, and a
/// sparkline is the one cell whose loss hides no number. On the narrowest
/// terminals the name then shrinks to [_colNameMinWidth], and only after
/// that do the state word (the row's bullet still carries its color) and
/// the primary checkbox go.
const List<_TableColumn> _tableDropOrder = <_TableColumn>[
  _TableColumn.trend,
  _TableColumn.up,
  _TableColumn.cpu,
  _TableColumn.mem,
  _TableColumn.players,
  _TableColumn.tps,
  _TableColumn.port,
];
const List<_TableColumn> _tableLastDrops = <_TableColumn>[
  _TableColumn.state,
  _TableColumn.primary,
];

/// The narrowest a server name column shrinks to before whole columns go.
const int _colNameMinWidth = 10;

/// The columns that fit in [inner] and their widths: fixed widths, dropped
/// whole in [_tableDropOrder] until the row fits, with a wide terminal's
/// slack going to the trend sparkline (up to [_maxTrendCells]).
({List<_TableColumn> columns, Map<_TableColumn, int> widths}) _planTable(
  int inner, {
  bool networkTree = false,
  bool grouped = false,
}) {
  final Map<_TableColumn, int> widths = <_TableColumn, int>{
    _TableColumn.name: networkTree ? 28 : _colNameWidth,
    _TableColumn.port: 5,
    _TableColumn.state: _colStateWidth,
    _TableColumn.players: _colPlayersWidth,
    _TableColumn.tps: _colTpsWidth,
    _TableColumn.trend: _colTrendWidth,
    _TableColumn.mem: _colMemWidth,
    _TableColumn.cpu: _colCpuWidth,
    _TableColumn.up: _colUpWidth,
    _TableColumn.primary: 7,
  };
  final List<_TableColumn> columns = _TableColumn.values.toList();
  if (grouped) {
    columns.remove(_TableColumn.port);
    columns.add(_TableColumn.port);
    columns.remove(_TableColumn.primary);
    columns.add(_TableColumn.primary);
  } else {
    columns.remove(_TableColumn.primary);
    if (!networkTree) columns.remove(_TableColumn.port);
  }

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
  if (needed() > inner) {
    widths[_TableColumn.name] = _clampInt(
      widths[_TableColumn.name]! - (needed() - inner),
      _colNameMinWidth,
      widths[_TableColumn.name]!,
    );
  }
  for (final _TableColumn drop in _tableLastDrops) {
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

  if (grouped && needed() < inner) {
    widths[_TableColumn.name] = widths[_TableColumn.name]! + inner - needed();
  }

  return (columns: columns, widths: widths);
}

MonitorPanelRender renderGroupedServerList({
  required MonitorSnapshot snapshot,
  required int selectedIndex,
  required int rows,
  required int width,
  required int topRow,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
  Set<String> checkedInstances = const <String>{},
  String? focusedGroup,
  String? hoveredId,
}) {
  String? selectedInstance =
      focusedGroup == null &&
          selectedIndex >= 0 &&
          selectedIndex < snapshot.instances.length
      ? snapshot.instances[selectedIndex]
      : null;
  ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan =
      _planTable(
        width - 4,
        grouped: true,
        networkTree: snapshot.networkRows.isNotEmpty,
      );
  List<MonitorConsumerGroup> groups = planMonitorConsumerGroups(
    snapshot: snapshot,
    rows: rows,
    selectedInstance: selectedInstance,
  );
  int checkedCount = snapshot.instances.where(checkedInstances.contains).length;
  List<String> output = <String>[
    '  ${_tableHeaderRow(plan: plan, theme: theme, selectionMark: checkedCount == 0
        ? '[ ]'
        : checkedCount == snapshot.instances.length
        ? '[x]'
        : '[-]', hovered: hoveredId == selectAllHitId)}  ',
  ];
  List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    if (snapshot.instances.isNotEmpty)
      MonitorHitbox(
        id: selectAllHitId,
        row: topRow,
        colStart: 2,
        colEnd: 9,
        kind: MonitorHitKind.checkbox,
      ),
  ];
  for (MonitorConsumerGroup group in groups) {
    int groupTop = topRow + output.length;
    String id = '$groupNewHitPrefix${group.consumer.shortName}';
    bool focused = focusedGroup == group.consumer.shortName;
    bool active = focused || group.instances.contains(selectedInstance);
    bool empty = group.instances.isEmpty;
    String badge = empty ? '[+ Create first server]' : '[+ New]';
    String title =
        '${focused ? '${theme.glyphs.selector} ' : ''}'
        '${monitorConsumerLabel(group.consumer)}';
    if (group.collapsed) {
      title += ' (${group.instances.length})';
    } else if (group.visibleInstances.length < group.instances.length) {
      title +=
          ' ${group.offset + 1}-${group.offset + group.visibleInstances.length}'
          '/${group.instances.length}';
    }
    if (snapshot.networkTopologyStale &&
        group.instances.any(snapshot.networkRows.containsKey)) {
      title += ' · NETWORKS STALE';
    }
    List<String> content = <String>[];
    for (String instance in group.visibleInstances) {
      int row = groupTop + content.length + 1;
      hitboxes.addAll(<MonitorHitbox>[
        MonitorHitbox(
          id: '$serverHitPrefix$instance',
          row: row,
          colStart: 0,
          colEnd: width,
          kind: MonitorHitKind.serverRow,
        ),
        MonitorHitbox(
          id: '$serverCheckHitPrefix$instance',
          row: row,
          colStart: 2,
          colEnd: 5,
          kind: MonitorHitKind.checkbox,
        ),
        if (plan.columns.contains(_TableColumn.primary))
          MonitorHitbox(
            id: '$primaryHitPrefix$instance',
            row: row,
            colStart: width - 9,
            colEnd: width - 2,
            kind: MonitorHitKind.checkbox,
          ),
      ]);
      content.add(
        _serverTableRow(
          plan: plan,
          instance: snapshot.displayNameFor(instance),
          network: snapshot.networkRows[instance],
          latest: snapshot.latestFor(instance),
          history: snapshot.historyFor(instance),
          selected: selectedInstance == instance,
          checked: checkedInstances.contains(instance),
          checkboxHovered: hoveredId == '$serverCheckHitPrefix$instance',
          hovered: hoveredId == '$serverHitPrefix$instance',
          active: snapshot.isPrimary(instance),
          primaryHovered: hoveredId == '$primaryHitPrefix$instance',
          port: snapshot.portFor(instance),
          theme: theme,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      );
    }
    while (content.length < group.contentRows) {
      hitboxes.add(
        MonitorHitbox(
          id: 'group:area:${group.consumer.shortName}:${content.length}',
          row: groupTop + content.length + 1,
          colStart: 0,
          colEnd: width,
          kind: MonitorHitKind.listArea,
        ),
      );
      content.add('');
    }
    List<String> panel = renderPanel(
      title: title,
      badge: badge,
      styledBadge: theme.paint(
        badge,
        focused || hoveredId == id ? theme.accent : theme.text,
      ),
      content: content,
      width: width,
      theme: theme,
      emphasis: active ? PanelEmphasis.active : PanelEmphasis.normal,
    );
    if (empty || group.collapsed) {
      output.add(panel.first);
    } else {
      output.addAll(panel);
    }
    hitboxes.add(
      MonitorHitbox(
        id: id,
        row: groupTop,
        colStart: empty ? 0 : width - badge.length - 3,
        colEnd: empty ? width : width - 3,
        kind: MonitorHitKind.button,
      ),
    );
  }
  while (output.length < rows) {
    output.add('');
  }
  if (output.length > rows) {
    // Even folded groups overflow a frame this short: keep the frame's own
    // rows below the list (bars, footer) by clipping the list itself.
    final int bottom = topRow + rows;
    return MonitorPanelRender(
      rows: output.sublist(0, rows < 0 ? 0 : rows),
      hitboxes: <MonitorHitbox>[
        for (final MonitorHitbox hitbox in hitboxes)
          if (hitbox.row < bottom) hitbox,
      ],
    );
  }
  return MonitorPanelRender(rows: output, hitboxes: hitboxes);
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
  Set<String> checkedInstances = const <String>{},
  String? hoveredId,
}) {
  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = width - 4 < 0 ? 0 : width - 4;
  final int total = snapshot.instances.length;
  final int checkedCount = snapshot.instances
      .where(checkedInstances.contains)
      .length;
  final ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan =
      _planTable(inner, networkTree: snapshot.networkRows.isNotEmpty);

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
    content.add(
      _tableHeaderRow(
        plan: plan,
        theme: theme,
        selectionMark: checkedCount == 0
            ? '[ ]'
            : checkedCount == total
            ? '[x]'
            : '[-]',
        hovered: total > 0 && hoveredId == selectAllHitId,
      ),
    );
    if (total > 0 && inner >= 3) {
      hitboxes.add(
        MonitorHitbox(
          id: selectAllHitId,
          kind: MonitorHitKind.checkbox,
          row: topRow + 1,
          colStart: 2,
          colEnd: inner >= 7 ? 9 : 5,
        ),
      );
    }
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
    if (inner >= 3) {
      hitboxes.add(
        MonitorHitbox(
          id: '$serverCheckHitPrefix$instance',
          kind: MonitorHitKind.checkbox,
          row: topRow + 1 + content.length,
          colStart: 2,
          colEnd: 5,
        ),
      );
    }
    content.add(
      _serverTableRow(
        plan: plan,
        instance: snapshot.displayNameFor(instance),
        network: snapshot.networkRows[instance],
        latest: snapshot.latestFor(instance),
        history: snapshot.historyFor(instance),
        selected: index == selectedIndex,
        checked: checkedInstances.contains(instance),
        checkboxHovered: hoveredId == '$serverCheckHitPrefix$instance',
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
      title: <String>[
        'SERVERS',
        if (checkedCount > 0) '$checkedCount SELECTED',
        if (snapshot.networkTopologyStale) 'NETWORKS STALE',
      ].join(' · '),
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
  required String selectionMark,
  required bool hovered,
}) {
  final StringBuffer row = StringBuffer();
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
  return '${theme.paint('$selectionMark ALL ', hovered ? theme.accent : theme.faint)}'
      '${theme.paint(row.toString(), theme.faint)}';
}

/// One reading row of the fleet table: `[ ] ▸ ● name  state  …`. The selector
/// marks the selection and the hovered row alike; the name is strong for
/// the selection and the workspace's active instance; every missing reading
/// is the dash glyph, never a zero.
String _serverTableRow({
  required ({List<_TableColumn> columns, Map<_TableColumn, int> widths}) plan,
  required String instance,
  required MonitorNetworkRow? network,
  required MetricSample? latest,
  required List<MetricSample> history,
  required bool selected,
  required bool checked,
  required bool checkboxHovered,
  required bool hovered,
  required bool active,
  required MonitorTheme theme,
  required DateTime windowStart,
  required DateTime windowEnd,
  bool primaryHovered = false,
  int? port,
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

  final String checkbox = theme.paint(
    checked ? '[x]' : '[ ]',
    checked || checkboxHovered ? theme.accent : theme.faint,
  );
  final StringBuffer row = StringBuffer('$checkbox $selector $bullet ');
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
        final String label;
        if (network == null) {
          label = instance;
        } else if (network.isProxy) {
          label = 'Velocity / ${network.network}';
        } else {
          final String branch = theme.glyphs.isAscii
              ? (network.lastChild ? '`- ' : '|- ')
              : (network.lastChild ? '└─ ' : '├─ ');
          final String alias = network.alias == instance
              ? ''
              : ' (${network.alias})';
          label = '$branch$instance$alias';
        }
        final String activeMark =
            active &&
                network != null &&
                !plan.columns.contains(_TableColumn.primary)
            ? ' *'
            : '';
        row.write(
          theme.paint(
            '${_fitCell(label, cellWidth - activeMark.length)}$activeMark',
            tone,
          ),
        );
      case _TableColumn.port:
        row.write(
          theme.paint(
            _fitCell(
              '${port ?? network?.port ?? latest?.port ?? dash}',
              cellWidth,
              right: true,
            ),
            theme.text,
          ),
        );
      case _TableColumn.state:
        final String tone = live ? theme.statusTone(state) : theme.faint;
        row.write(
          theme.paint(_fitCell(monitorStateText(latest), cellWidth), tone),
        );
      case _TableColumn.primary:
        row.write(
          theme.paint(
            _fitCell(active ? '  [x]' : '  [ ]', cellWidth),
            active || primaryHovered ? theme.accent : theme.faint,
          ),
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
/// server without RCON still has). A window with neither stays blank.
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
  if (!anyTps && cpu.every((double? value) => value == null)) {
    return ' ' * cells;
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
  List<String>? logLines,
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
          logLines: logLines,
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

/// The live card's content: a header row of current readings, charts side
/// by side (TPS, CPU and memory, then network and players as the width
/// allows), a blank, the facts row, and a compact RX/TX network row unless
/// network has its own chart. When rows tighten, the blank, facts, header,
/// and network row give way in that order. Charts stop growing at
/// [_maxChartRows]; [logLines] fill whatever the card has left below them.
List<String> _liveCard({
  required List<MetricSample> history,
  required MetricSample latest,
  required int inner,
  required int contentRows,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
  List<String>? logLines,
}) {
  if (contentRows < _minChartRows) {
    return <String>[
      if (contentRows > 0)
        _summaryRow(latest: latest, inner: inner, theme: theme),
    ];
  }
  final DateTime start = chartWindowStart(
    history: history,
    now: now,
    range: range,
  );
  final List<_CardChart> candidates = _cardCharts(
    history: history,
    latest: latest,
    start: start,
    now: now,
    theme: theme,
  );
  int fit = 1;
  for (int count = candidates.length; count >= 1; count--) {
    if (count * _minChartWidth + (count - 1) * _chartGap <= inner) {
      fit = count;
      break;
    }
  }

  // A tall card narrower than its charts stacks the rest in further rows of
  // the same width, keeping room for the log tail below them.
  final int maxStacks = (candidates.length + fit - 1) ~/ fit;
  final bool hasLog = logLines != null && logLines.isNotEmpty;
  final int stackRoom = contentRows - 3 - (hasLog ? _stackLogReserve : 0);
  final int stacks = _clampInt(
    stackRoom ~/ (1 + _stackChartRows),
    1,
    maxStacks,
  );
  final List<List<_CardChart>> rowsOfCharts = <List<_CardChart>>[
    for (int stack = 0; stack < stacks; stack++)
      candidates.skip(stack * fit).take(fit).toList(),
  ];
  final List<_CardChart> charts = <_CardChart>[
    for (final List<_CardChart> row in rowsOfCharts) ...row,
  ];

  bool labels = true;
  bool blank = true;
  bool facts = true;
  bool network = !charts.any((_CardChart chart) => chart.secondary != null);
  int chartRowsLeft() =>
      (contentRows -
          (stacks - 1) -
          (stacks > 1 && hasLog ? _stackLogReserve : 0) -
          (labels ? stacks : 0) -
          (blank ? 1 : 0) -
          (facts ? 1 : 0) -
          (network ? 1 : 0)) ~/
      stacks;
  if (chartRowsLeft() < _minChartRows) blank = false;
  if (chartRowsLeft() < _minChartRows) facts = false;
  if (chartRowsLeft() < _minChartRows) labels = false;
  if (chartRowsLeft() < _minChartRows) network = false;
  final int chartRows = _clampInt(chartRowsLeft(), 0, _maxChartRows);

  final List<String> content = <String>[];
  for (int stack = 0; stack < rowsOfCharts.length; stack++) {
    final List<_CardChart> row = rowsOfCharts[stack];
    final int count = row.length;
    final List<int> widths = List<int>.generate(count, (int index) {
      final int base = (inner - _chartGap * (count - 1)) ~/ count;
      if (index < count - 1) {
        return base;
      }
      return inner - _chartGap * (count - 1) - base * (count - 1);
    });
    if (stack > 0) {
      content.add('');
    }
    if (labels) {
      content.add(
        <String>[
          for (int index = 0; index < count; index++)
            _chartHeader(row[index], widths[index], theme),
        ].join(' ' * _chartGap),
      );
    }
    content.addAll(
      joinBlocks(<List<String>>[
        for (int index = 0; index < count; index++)
          row[index].secondary == null
              ? renderAreaChart(
                  points: row[index].points,
                  width: widths[index],
                  height: chartRows,
                  start: start,
                  end: now,
                  theme: theme,
                  forcedLow: row[index].low,
                  forcedHigh: row[index].high,
                )
              : renderBrailleChart(
                  series: <ChartSeries>[
                    ChartSeries(label: 'RX', points: row[index].points),
                    ChartSeries(
                      label: 'TX',
                      points: row[index].secondary!,
                      toneIndex: 1,
                    ),
                  ],
                  width: widths[index],
                  height: chartRows,
                  start: start,
                  end: now,
                  theme: theme,
                  forcedLow: row[index].low,
                ),
      ], gap: ' ' * _chartGap),
    );
  }
  if (blank) {
    content.add('');
  }
  if (facts) {
    content.add(
      _factsRow(
        latest: latest,
        inner: inner,
        theme: theme,
        charted: <String>{
          if (labels)
            for (final _CardChart chart in charts) chart.title,
        },
      ),
    );
  }
  if (network) {
    content.add(
      _networkMonitorRow(
        history: <MetricSample>[
          for (final MetricSample sample in history)
            if (!sample.ts.isBefore(start) && !sample.ts.isAfter(now)) sample,
        ],
        latest: latest,
        inner: inner,
        theme: theme,
      ),
    );
  }
  final int logRows = contentRows - content.length;
  if (logLines != null && logLines.isNotEmpty && logRows >= _minLogRows) {
    content
      ..add('')
      ..add(
        theme.paint(
          'LOG ${theme.glyphs.frameH * (inner - 4 < 0 ? 0 : inner - 4)}',
          theme.faint,
        ),
      );
    final int shown = logRows - 2;
    final List<String> tail = logLines.length > shown
        ? logLines.sublist(logLines.length - shown)
        : logLines;
    for (final String line in tail) {
      content.add(
        theme.paint(Ansi.clipVisible(Ansi.strip(line), inner), theme.muted),
      );
    }
  }
  return content;
}

/// One chart in the live card: the reading its header leads with, the
/// window extreme beside it, and the series it plots.
class _CardChart {
  const _CardChart({
    required this.title,
    required this.value,
    required this.valueTone,
    required this.stat,
    required this.points,
    this.secondary,
    this.legend,
    this.low,
    this.high,
  });

  final String title;
  final String value;
  final String valueTone;
  final String stat;
  final List<ChartPoint> points;

  /// A second series drawn as a line beside [points] (TX next to RX), which
  /// makes the chart a two-line chart instead of a filled area.
  final List<ChartPoint>? secondary;

  /// A painted header replacing `title value`, for a chart whose readings
  /// need their series marks beside them.
  final String? legend;
  final double? low;
  final double? high;
}

/// TPS (when the server reports it), CPU, memory, network (when it has
/// readings), and players, in the order a narrower card gives them up.
///
/// Each header carries the current reading and the extreme that matters:
/// the TPS low, the CPU, memory, network, and player peaks. CPU keeps a
/// 0-100 axis until a multi-core reading passes 100. Memory plots GiB from
/// zero up to the server's memory limit when one is known. Network draws RX
/// and TX as two lines, marked in the header by their line colors. Players
/// plot up to the server's slot count.
List<_CardChart> _cardCharts({
  required List<MetricSample> history,
  required MetricSample latest,
  required DateTime start,
  required DateTime now,
  required MonitorTheme theme,
}) {
  final (double?, double?) tps = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => s.tps,
  );
  final (double?, double?) cpu = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => s.cpuPercent,
  );
  final (double?, double?) memory = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => s.rssBytes?.toDouble(),
  );
  final double? cpuPeak = cpu.$2;
  final double? memoryPeak = memory.$2;
  final int? limit = latest.memoryLimitBytes;
  final NetworkRateUnit? unit = preferredNetworkRateUnit(history);
  final (double?, double?) rx = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => networkRxRate(s, unit),
  );
  final (double?, double?) tx = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => networkTxRate(s, unit),
  );
  final double? networkPeak = rx.$2 == null && tx.$2 == null
      ? null
      : math.max(rx.$2 ?? 0, tx.$2 ?? 0);
  final (double?, double?) players = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => s.players?.toDouble(),
  );
  final (double?, double?) slots = _windowExtent(
    history,
    start,
    now,
    (MetricSample s) => s.maxPlayers?.toDouble(),
  );
  final String mark = theme.glyphs.isAscii ? '=' : '━';
  return <_CardChart>[
    if (tps.$1 != null)
      _CardChart(
        title: 'TPS',
        value: latest.tps?.toStringAsFixed(1) ?? 'n/a',
        valueTone: theme.tpsTone(latest.tps),
        stat: 'min ${tps.$1!.toStringAsFixed(1)}',
        points: _chartPoints(history, (MetricSample s) => s.tps),
        low: 0,
        high: 20,
      ),
    _CardChart(
      title: 'CPU',
      value: _wholePercent(latest.cpuPercent),
      valueTone: theme.textStrong,
      stat: cpuPeak == null ? '' : 'peak ${cpuPeak.round()}%',
      points: _chartPoints(history, (MetricSample s) => s.cpuPercent),
      low: 0,
      high: cpuPeak == null || cpuPeak <= 100
          ? 100
          : (cpuPeak / 50).ceil() * 50.0,
    ),
    _CardChart(
      title: 'MEM',
      value: formatBytes(latest.rssBytes),
      valueTone: theme.textStrong,
      stat: memoryPeak == null ? '' : 'peak ${formatBytes(memoryPeak.round())}',
      points: _chartPoints(
        history,
        (MetricSample s) => s.rssBytes == null ? null : s.rssBytes! / _gib,
      ),
      low: 0,
      high: limit != null && (memoryPeak == null || limit >= memoryPeak)
          ? limit / _gib
          : memoryPeak == null
          ? null
          : roomyCeiling(memoryPeak / _gib),
    ),
    if (networkPeak != null)
      _CardChart(
        title: 'NET',
        value: '',
        valueTone: theme.textStrong,
        stat: 'peak ${_networkRateText(networkPeak, unit)}',
        points: _chartPoints(
          history,
          (MetricSample s) => networkRxRate(s, unit),
        ),
        secondary: _chartPoints(
          history,
          (MetricSample s) => networkTxRate(s, unit),
        ),
        legend:
            '${theme.paint('NET', theme.muted)} '
            '${theme.paint(mark, theme.accent)} '
            '${theme.paint('RX ${_networkRateText(networkRxRate(latest, unit), unit)}', '${theme.bold}${theme.textStrong}')} '
            '${theme.paint(mark, theme.info)} '
            '${theme.paint('TX ${_networkRateText(networkTxRate(latest, unit), unit)}', '${theme.bold}${theme.textStrong}')}',
        low: 0,
      ),
    if (players.$2 != null)
      _CardChart(
        title: 'PLAYERS',
        value: monitorPlayersText(latest, MonitorTheme.plain()),
        valueTone: theme.textStrong,
        stat: 'peak ${players.$2!.round()}',
        points: _chartPoints(
          history,
          (MetricSample s) => s.players?.toDouble(),
        ),
        low: 0,
        high: slots.$2 ?? roomyCeiling(players.$2!),
      ),
  ];
}

const double _gib = 1073741824;

/// The lowest and highest reading [read] returns inside `[start, now]`.
(double?, double?) _windowExtent(
  List<MetricSample> history,
  DateTime start,
  DateTime now,
  double? Function(MetricSample sample) read,
) {
  double? low;
  double? high;
  for (final MetricSample sample in history) {
    if (sample.ts.isBefore(start) || sample.ts.isAfter(now)) continue;
    final double? value = read(sample);
    if (value == null || !value.isFinite) continue;
    if (low == null || value < low) low = value;
    if (high == null || value > high) high = value;
  }
  return (low, high);
}

/// A chart's header, exactly [width] columns: its title and current reading
/// on the left, the window extreme faint on the right when it fits.
String _chartHeader(_CardChart chart, int width, MonitorTheme theme) {
  final String? legend = chart.legend;
  if (legend != null) {
    final int visible = Ansi.visibleLength(legend);
    if (visible >= width) {
      return Ansi.padVisible(Ansi.clipVisible(legend, width), width);
    }
    final String stat = visible + 1 + chart.stat.length <= width
        ? chart.stat
        : '';
    return '$legend${' ' * (width - visible - stat.length)}'
        '${stat.isEmpty ? '' : theme.paint(stat, theme.faint)}';
  }
  final String left = '${chart.title} ${chart.value}';
  if (left.length >= width) {
    return theme.paint(_fitCell(left, width), theme.muted);
  }
  final String stat = left.length + 1 + chart.stat.length <= width
      ? chart.stat
      : '';
  return '${theme.paint(chart.title, theme.muted)} '
      '${theme.paint(chart.value, '${theme.bold}${chart.valueTone}')}'
      '${' ' * (width - left.length - stat.length)}'
      '${stat.isEmpty ? '' : theme.paint(stat, theme.faint)}';
}

/// Maps [history] to chart points via [read], keeping nulls as gaps.
List<ChartPoint> _chartPoints(
  List<MetricSample> history,
  double? Function(MetricSample sample) read,
) => <ChartPoint>[
  for (final MetricSample sample in history)
    ChartPoint(ts: sample.ts, value: read(sample)),
];

/// One compact, bottom-anchored network monitor over the charts' window.
/// macOS Local samples use
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
  if (peak != null && peak <= 0) {
    return theme.paint('$summary · idle', theme.muted);
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

/// A live card with no room for charts: its state and current readings on
/// one line.
String _summaryRow({
  required MetricSample latest,
  required int inner,
  required MonitorTheme theme,
}) {
  final int? uptime = latest.uptimeSeconds;
  final List<String> facts = <String>[
    if (latest.tps != null) 'TPS ${latest.tps!.toStringAsFixed(1)}',
    if (latest.cpuPercent != null) 'CPU ${_wholePercent(latest.cpuPercent)}',
    if (latest.rssBytes != null) 'MEM ${formatBytes(latest.rssBytes)}',
    if (latest.players != null)
      '${monitorPlayersText(latest, MonitorTheme.plain())} PLAYERS',
    if (uptime != null)
      'UP ${formatCompactDuration(Duration(seconds: uptime))}',
  ];
  final String state = monitorStateText(latest);
  final String rest = facts.isEmpty ? '' : ' · ${facts.join(' · ')}';
  return Ansi.clipVisible(
    '${theme.paint(state, theme.statusTone(latest.state))}'
    '${theme.paint(rest, theme.muted)}',
    inner,
  );
}

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
  Set<String> charted = const <String>{},
}) {
  final int? uptime = latest?.uptimeSeconds;
  final int? latency = latest?.latencyMs;
  // A blank version string is missing data, not a version.
  final String? version = latest?.version;
  final int? disk = latest?.diskBytes;
  final int? diskLimit = latest?.diskLimitBytes;
  final List<String> facts = <String>[
    if (uptime != null)
      'UP ${formatCompactDuration(Duration(seconds: uptime))}',
    if (!charted.contains('PLAYERS'))
      '${monitorPlayersText(latest, theme)} PLAYERS',
    if (latency != null) 'PING ${latency}ms',
    if (!charted.contains('CPU') && latest?.cpuPercent != null)
      'CPU ${formatCpuPercent(latest?.cpuPercent)}',
    if (!charted.contains('MEM') && latest?.rssBytes != null)
      'MEM ${formatBytes(latest?.rssBytes)}',
    if (disk != null)
      'DISK ${formatBytes(disk)}${diskLimit == null ? '' : '/${formatBytes(diskLimit)}'}',
    if (version != null && version.isNotEmpty) version,
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
