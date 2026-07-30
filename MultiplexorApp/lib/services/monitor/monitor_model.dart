/// The landing frame of the command centre: the whole dashboard, composed
/// top-down from a fixed row budget.
///
/// The blocks themselves live in `monitor_landing.dart`; what is here is the
/// budget that decides how many rows each one gets, the header and footer
/// that bracket them, the two action bars, and the hitbox map the screen
/// clicks against.
///
/// Everything in this library is pure: no clock reads and no IO.
library;

import '../../utils/terminal/button.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';
import 'monitor_landing.dart';

/// The frame's fixed row budget, top-down: the header panel, the KPI strip,
/// one row per action bar, and the footer hint. Everything left over is the
/// body — at the 24-line floor that is 14 rows.
const int _headerRows = 4;
const int _kpiRows = 3;
const int _barRows = 1;
const int _footerRows = 1;

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

/// The selection action bar's chips. Which set is drawn follows the
/// selection's own state: you cannot stop what is not running, and starting
/// what already runs is not an action anyone means.
const ButtonSpec _detailButton = ButtonSpec(id: 'act:detail', label: 'DETAIL');
const ButtonSpec _moreButton = ButtonSpec(id: 'act:more', label: 'MORE');

const List<ButtonSpec> _stoppedButtons = <ButtonSpec>[
  ButtonSpec(id: 'act:start', label: 'START'),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _liveButtons = <ButtonSpec>[
  ButtonSpec(id: 'act:stop', label: 'STOP'),
  ButtonSpec(id: 'act:restart', label: 'RESTART'),
  ButtonSpec(id: 'act:console', label: 'CONSOLE'),
  _detailButton,
  _moreButton,
];

/// The workspace action bar's chips — the things that act on the workspace
/// rather than on whichever server happens to be selected.
const List<ButtonSpec> _workspaceButtons = <ButtonSpec>[
  newInstanceButton,
  ButtonSpec(id: 'ws:builds', label: 'BUILDS'),
  ButtonSpec(id: 'ws:tuning', label: 'TUNING'),
  ButtonSpec(id: 'ws:consumer', label: 'CONSUMER'),
  ButtonSpec(id: 'ws:consoles', label: 'CONSOLES'),
  ButtonSpec(id: 'ws:more', label: 'MORE'),
];

/// Builds the full-screen dashboard frame: exactly [lines] rows of exactly
/// [columns] visible columns, ready to be painted as-is.
///
/// Below the [monitorMinColumns] x [monitorMinLines] floor the frame
/// degrades to [buildResizeRequiredFrame]. Above it the layout is a header
/// panel, a three-card KPI strip, a body (the slim server list beside the
/// selected server's panel), a state-aware selection action bar, the
/// workspace action bar, and a one-row footer hint. An empty workspace drops
/// the selection bar and spends its body on a prompt instead.
///
/// Pure: no clock reads and no IO. [now] must be UTC — sample timestamps
/// are UTC and chart windows are `[now - range, now]` — and is the only
/// notion of "current" the frame has. The header clock is rendered in local
/// time from it.
///
/// [hoveredId] and [pressedId] select the interaction state of whatever they
/// name: a button chip renders hovered or pressed, and a hovered server row
/// shows its selector. Both null (the `--once` snapshot) renders every
/// region in its resting state.
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

  final int total = snapshot.instances.length;
  final bool hasInstances = total > 0;
  final int selected = selectedIndex < 0
      ? 0
      : (selectedIndex >= total ? total - 1 : selectedIndex);

  final MonitorRollup rollup = MonitorRollup.of(
    snapshot,
    windowStart: now.subtract(range),
    windowEnd: now,
  );

  final int bodyTop = _headerRows + _kpiRows;
  final int bars = hasInstances ? _barRows * 2 : _barRows;
  final int budget = lines - bodyTop - bars - _footerRows;
  final int bodyRows = budget < 0 ? 0 : budget;

  final List<String> rows = <String>[
    ..._headerPanel(
      snapshot: snapshot,
      rollup: rollup,
      frame: frame,
      columns: columns,
      theme: theme,
      range: range,
      now: now,
    ),
    ...renderKpiStrip(rollup: rollup, columns: columns, theme: theme),
  ];
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[];

  if (hasInstances) {
    final MonitorPanelRender list = renderServerList(
      snapshot: snapshot,
      rollup: rollup,
      selectedIndex: selected,
      rows: bodyRows,
      topRow: bodyTop,
      theme: theme,
      hoveredId: hoveredId,
    );
    final MonitorPanelRender panel = renderSelectedPanel(
      snapshot: snapshot,
      selectedIndex: selected,
      rows: bodyRows,
      width: columns - serverListWidth - 1,
      topRow: bodyTop,
      colOffset: serverListWidth + 1,
      theme: theme,
      range: range,
      now: now,
    );
    rows.addAll(joinBlocks(<List<String>>[list.rows, panel.rows]));
    hitboxes
      ..addAll(list.hitboxes)
      ..addAll(panel.hitboxes);

    final ButtonRowRender bar = layoutButtonRow(
      buttons: _selectionButtons(
        snapshot.latestFor(snapshot.instances[selected]),
      ),
      width: columns,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );
    rows.add(bar.row);
    hitboxes.addAll(_buttonHits(bar.spans, rows.length - 1));
  } else {
    final MonitorPanelRender body = renderEmptyBody(
      rows: bodyRows,
      columns: columns,
      topRow: bodyTop,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );
    rows.addAll(body.rows);
    hitboxes.addAll(body.hitboxes);
  }

  final ButtonRowRender workspace = layoutButtonRow(
    buttons: _workspaceButtons,
    width: columns,
    theme: theme,
    hoveredId: hoveredId,
    pressedId: pressedId,
  );
  rows.add(workspace.row);
  hitboxes.addAll(_buttonHits(workspace.spans, rows.length - 1));

  rows.add(theme.paint(_footerHints(columns), theme.faint));

  return padFrame(
    MonitorFrame(rows: rows, hitboxes: hitboxes),
    columns: columns,
    lines: lines,
  );
}

/// The chips the selection bar draws for a selection whose latest reading is
/// [latest]. Anything that is not demonstrably running — stopped, or never
/// sampled at all — gets the start set.
List<ButtonSpec> _selectionButtons(MetricSample? latest) {
  final RuntimeState? state = latest?.state;
  final bool live = state != null && state != RuntimeState.stopped;
  return live ? _liveButtons : _stoppedButtons;
}

/// The hitboxes for one laid-out button row, drawn on frame row [row].
List<MonitorHitbox> _buttonHits(List<ButtonSpan> spans, int row) =>
    <MonitorHitbox>[
      for (final ButtonSpan span in spans)
        MonitorHitbox(
          id: span.id,
          kind: MonitorHitKind.button,
          row: row,
          colStart: span.colStart,
          colEnd: span.colEnd,
        ),
    ];

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
  required MonitorRollup rollup,
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

  final double? meanTps = rollup.meanTps;
  final String upTone = rollup.up > 0 ? theme.ok : theme.faint;
  final String summary =
      '${theme.paint(glyphs.bulletOn, upTone)} '
      '${theme.paint('${rollup.up} UP', upTone)} · '
      '${theme.paint('${rollup.down} DOWN', theme.faint)}'
      '   PLAYERS ${theme.paint(rollup.anyPlayers ? '${rollup.players}' : 'n/a', rollup.anyPlayers && rollup.players > 0 ? theme.accent : theme.faint)}'
      '   AVG TPS ${theme.paint(meanTps == null ? 'n/a' : meanTps.toStringAsFixed(1), theme.tpsTone(meanTps))}';

  final String facts =
      'ACTIVE ${snapshot.activeInstance ?? 'none'} · '
      'RANGE ${rangeLabel(range)} · '
      '${rollup.total} SERVERS';

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
