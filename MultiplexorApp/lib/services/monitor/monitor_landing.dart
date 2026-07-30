/// The landing view's panels: the fleet roll-up every card reads, the KPI
/// strip across the top, the slim server list, the big selected-server panel
/// and the empty-workspace prompt.
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

/// Width of the slim server list, and the columns its name field gets: the
/// panel's four columns of chrome, the selector, the status bullet and the
/// single space on either side of the name.
const int serverListWidth = 28;
const int _serverNameColumn = serverListWidth - 8;

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

/// Columns the selected-server panel's meter row spends outside its two
/// meters and its two readings (`MEM `, a space, `  CPU `, a space), and the
/// ceiling on each meter. Sized against the rendered readings for the same
/// reason as [_kpiHostFixed].
const int _panelMetersFixed = 12;
const int _panelMeterCells = 14;

/// Content rows the selected-server panel keeps for its chart at minimum,
/// and the rows below it: a blank, the meter row and the facts row.
const int _minChartRows = 4;
const int _panelTrailerRows = 3;

/// A rendered block plus the clickable regions drawn on it, in absolute
/// frame coordinates.
class MonitorPanelRender {
  const MonitorPanelRender({required this.rows, required this.hitboxes});

  final List<String> rows;
  final List<MonitorHitbox> hitboxes;
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
      '${renderSparkline(values: rollup.tpsSeries, width: sparkCells, theme: theme, min: 0, max: 20)}';

  final int? rssSum = rollup.rssSum;
  final int? peakRssSum = rollup.peakRssSum;
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

/// The slim server list: one `▸ name ●` row per instance the panel can show,
/// exactly [rows] rows tall (borders included), with a server-row hitbox
/// under every instance row.
///
/// A fleet taller than the panel scrolls: the window follows the selection,
/// and each clipped end spends one row on a faint `+N more` marker. A marker
/// is a label, not a target, so it gets no hitbox.
MonitorPanelRender renderServerList({
  required MonitorSnapshot snapshot,
  required MonitorRollup rollup,
  required int selectedIndex,
  required int rows,
  required int topRow,
  required MonitorTheme theme,
  String? hoveredId,
}) {
  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int total = snapshot.instances.length;

  int slots = contentRows;
  int offset = 0;
  if (total > contentRows) {
    // Something is always clipped, so at least one row goes to a marker; a
    // window with fleet on both sides needs two.
    slots = contentRows - 1;
    offset = _windowOffset(selectedIndex, slots, total);
    if (offset > 0 && offset + slots < total) {
      slots = contentRows - 2;
      offset = _windowOffset(selectedIndex, slots, total);
    }
    if (slots < 1 && contentRows > 0) {
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
  int spare = contentRows - (end - offset);
  bool above = offset > 0 && spare > 0;
  if (above) {
    spare -= 1;
  }
  final bool below = end < total && spare > 0;

  final List<String> content = <String>[];
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[];
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
        colEnd: serverListWidth,
      ),
    );
    content.add(
      _serverListRow(
        instance: instance,
        latest: snapshot.latestFor(instance),
        selected: index == selectedIndex,
        hovered: hoveredId == '$serverHitPrefix$instance',
        active: instance == snapshot.activeInstance,
        theme: theme,
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
      width: serverListWidth,
      theme: theme,
      emphasis: PanelEmphasis.active,
    ),
    hitboxes: hitboxes,
  );
}

/// The selected-server panel: a forced `0..20` TPS chart over the window,
/// then a memory/CPU meter row and a facts row.
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
  final String title = instance.toUpperCase();
  final String badge = '${monitorStateText(latest)} · ${rangeLabel(range)}';

  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = width - 4 < 0 ? 0 : width - 4;

  // The facts row is the first thing a tight panel gives up, then the meter
  // row; the chart is the panel's reason to exist. Unreachable at any size
  // the frame floor admits (24 lines leave 12 content rows) — it is here so
  // a future row budget cannot silently produce a broken panel.
  int trailer = _panelTrailerRows;
  if (contentRows - trailer < _minChartRows) {
    trailer = _panelTrailerRows - 1;
  }
  if (contentRows - trailer < _minChartRows) {
    trailer = 0;
  }
  final int chartRows = contentRows - trailer;

  final List<String> content = <String>[
    ...renderBrailleChart(
      series: <ChartSeries>[
        ChartSeries(
          label: 'tps',
          points: <ChartPoint>[
            for (final MetricSample sample in history)
              ChartPoint(ts: sample.ts, value: sample.tps),
          ],
        ),
      ],
      width: inner,
      height: chartRows,
      start: now.subtract(range),
      end: now,
      theme: theme,
      forcedLow: 0,
      forcedHigh: 20,
    ),
    if (trailer > 0) ...<String>[
      '',
      _metersRow(latest: latest, history: history, inner: inner, theme: theme),
    ],
    if (trailer > _panelTrailerRows - 1)
      _factsRow(latest: latest, inner: inner, theme: theme),
  ];
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

/// The body of a workspace with nothing in it: a centered prompt over a
/// centered `+ NEW` chip, in a full-width panel.
MonitorPanelRender renderEmptyBody({
  required int rows,
  required int columns,
  required int topRow,
  required MonitorTheme theme,
  String? hoveredId,
  String? pressedId,
}) {
  const String prompt = 'NO SERVERS';
  final int contentRows = rows < 2 ? 0 : rows - 2;
  final int inner = columns - 4 < 0 ? 0 : columns - 4;
  final ButtonSpec chip = newInstanceButton;
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

/// One row of the slim list: `▸ name ●`. The selector marks the selection
/// and the hovered row alike; the name is strong for the selection and the
/// workspace's active instance; a stopped instance's whole row goes faint,
/// because there is nothing live about it to read.
String _serverListRow({
  required String instance,
  required MetricSample? latest,
  required bool selected,
  required bool hovered,
  required bool active,
  required MonitorTheme theme,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;
  final RuntimeState? state = latest?.state;
  final bool live = state != null && state != RuntimeState.stopped;

  final String selector = selected || hovered
      ? theme.paint(glyphs.selector, theme.accent)
      : ' ';
  final String nameTone = selected || active
      ? theme.textStrong
      : (live ? theme.text : theme.faint);
  final String name = theme.paint(_fit(instance, _serverNameColumn), nameTone);
  final String bullet = live
      ? theme.paint(glyphs.bulletOn, theme.statusTone(state))
      : theme.paint(glyphs.bulletOff, theme.faint);

  return '$selector $name $bullet';
}

/// The selected-server panel's meter row: memory against the largest reading
/// in this instance's window, and CPU against one whole core.
String _metersRow({
  required MetricSample? latest,
  required List<MetricSample> history,
  required int inner,
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
  final String memText = formatBytes(rss);
  final String cpuText = formatCpuPercent(cpu);
  final int cells = _clampInt(
    (inner - _panelMetersFixed - memText.length - cpuText.length) ~/ 2,
    0,
    _panelMeterCells,
  );

  return 'MEM ${renderMeter(fraction: memFraction, cells: cells, theme: theme)} '
      '${theme.paint(memText, rss == null ? theme.faint : theme.text)}'
      '  CPU ${renderMeter(fraction: cpuFraction, cells: cells, theme: theme)} '
      '${theme.paint(cpuText, cpu == null ? theme.faint : theme.text)}';
}

/// The selected-server panel's facts row. A fact leaves whole when the row
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
  final List<String> facts = <String>[
    'UP ${uptime == null ? 'n/a' : formatCompactDuration(Duration(seconds: uptime))}',
    '${monitorPlayersText(latest, theme)} PLAYERS',
    'PING ${latency == null ? 'n/a' : '${latency}ms'}',
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
/// The KPI strip trades the decimal place for the columns it costs.
String _wholePercent(double? percent) =>
    percent == null ? 'n/a' : '${percent.round()}%';

/// Clips or pads the already-plain [text] to exactly [width] columns.
String _fit(String text, int width) =>
    text.length > width ? text.substring(0, width) : text.padRight(width);

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
