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

import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';
import 'monitor_landing.dart';

/// The frame's fixed row budget, top-down: the header panel (a title border,
/// one facts row and a bottom border), the KPI strip, one row per action bar,
/// and the footer hint. Everything left over is the body — at the 24-line
/// floor that is 15 rows.
const int _headerRows = 3;
const int _kpiRows = 3;
const int _barRows = 1;
const int _footerRows = 1;

/// How the body splits between the fleet table and the selected-server card.
///
/// The card is sized to the selection's own state, and the table absorbs the
/// rest: an idle selection has nothing to plot, so its card is one quiet
/// line ([_idleCardRows]); a live one expands into charts, growing from
/// [_minLiveCardRows] toward [_maxLiveCardRows] with whatever rows the whole
/// fleet does not need, and never pushing the table below [_minListRows]
/// (its borders, the column header and one instance row).
const int _minListRows = 4;
const int _idleCardRows = 3;
const int _minLiveCardRows = 9;
const int _maxLiveCardRows = 15;

/// Separator between footer hints.
const String _hintSeparator = ' · ';

/// Local footer key hints in display order — the row exactly as it renders on
/// a terminal wide enough for all of it.
const String _localFooterHints =
    '[tab] local/remote · [enter] open · d detail · R restart · S stop · X kill · O console · '
    'g consoles · n new · b build · w workspace · c consumer · r range · '
    'q quit';

/// Remote replaces Local build and consumer shortcuts with its fleet bulk
/// menu and connection card. The workspace shortcut remains visible because
/// that card also owns files and create-many.
const String _remoteFooterHints =
    '[tab] local/remote · [enter] open · d detail · R restart · S stop · X kill · '
    'O live console · n new · b bulk · w workspace · c connection · r range · '
    'q quit';

/// The order hints are given up in when the terminal is too narrow for all
/// of them (comma-separated). A hint always leaves whole — a footer clipped
/// mid-word hides a binding without admitting to it — and the three absent
/// here (`[enter] open`, `d detail`, `q quit`) are never dropped at all.
///
/// `b build` goes first even though `w workspace` was added after it: the
/// workspace card `w` raises carries Build & tuning itself, so giving up the
/// shortcut costs a keystroke, while giving up `w` would leave the card
/// reachable by mouse alone.
const String _localFooterDropOrder =
    'b build,c consumer,n new,g consoles,O console,X kill,S stop,R restart,'
    'r range,w workspace';

const String _remoteFooterDropOrder =
    'n new,c connection,X kill,S stop,R restart,O live console,r range';

/// The selection action bar's chips. Which set is drawn follows the
/// selection's own state: you cannot stop what is not running, and starting
/// what already runs is not an action anyone means.
const ButtonSpec _detailButton = ButtonSpec(
  id: actDetailHitId,
  label: 'DETAIL',
);
const ButtonSpec _moreButton = ButtonSpec(id: actMoreHitId, label: 'MORE');

const List<ButtonSpec> _stoppedButtons = <ButtonSpec>[
  ButtonSpec(id: actStartHitId, label: 'START'),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _liveButtons = <ButtonSpec>[
  ButtonSpec(id: actStopHitId, label: 'STOP'),
  ButtonSpec(id: actRestartHitId, label: 'RESTART'),
  ButtonSpec(id: actConsoleHitId, label: 'CONSOLE'),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _remoteLiveButtons = <ButtonSpec>[
  ButtonSpec(id: actStopHitId, label: 'STOP'),
  ButtonSpec(id: actRestartHitId, label: 'RESTART'),
  ButtonSpec(id: actConsoleHitId, label: 'CONSOLE'),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _blockedStoppedButtons = <ButtonSpec>[
  ButtonSpec(id: actStartHitId, label: 'START', enabled: false),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _blockedLiveButtons = <ButtonSpec>[
  ButtonSpec(id: actStopHitId, label: 'STOP', enabled: false),
  ButtonSpec(id: actRestartHitId, label: 'RESTART', enabled: false),
  ButtonSpec(id: actConsoleHitId, label: 'CONSOLE', enabled: false),
  _detailButton,
  _moreButton,
];

const List<ButtonSpec> _blockedRemoteLiveButtons = <ButtonSpec>[
  ButtonSpec(id: actStopHitId, label: 'STOP', enabled: false),
  ButtonSpec(id: actRestartHitId, label: 'RESTART', enabled: false),
  ButtonSpec(id: actConsoleHitId, label: 'CONSOLE', enabled: false),
  _detailButton,
  _moreButton,
];

/// The workspace action bar's chips — the things that act on the workspace
/// rather than on whichever server happens to be selected.
const List<ButtonSpec> _workspaceButtons = <ButtonSpec>[
  newInstanceButton,
  ButtonSpec(id: wsBuildsHitId, label: 'BUILDS'),
  ButtonSpec(id: wsTuningHitId, label: 'TUNING'),
  ButtonSpec(id: wsConsumerHitId, label: 'CONSUMER'),
  ButtonSpec(id: wsConsolesHitId, label: 'CONSOLES'),
  ButtonSpec(id: wsMoreHitId, label: 'MORE'),
];

const List<ButtonSpec> _remoteWorkspaceButtons = <ButtonSpec>[
  newInstanceButton,
  ButtonSpec(id: wsConnectHitId, label: 'CONNECTION'),
  ButtonSpec(id: wsMoreHitId, label: 'MORE'),
];

const List<ButtonSpec> _remoteEmptyWorkspaceButtons = <ButtonSpec>[
  ButtonSpec(id: wsConnectHitId, label: 'CONNECTION'),
  ButtonSpec(id: wsMoreHitId, label: 'MORE'),
];

/// Builds the full-screen dashboard frame: exactly [lines] rows of exactly
/// [columns] visible columns, ready to be painted as-is.
///
/// Below the [monitorMinColumns] x [monitorMinLines] floor the frame
/// degrades to [buildResizeRequiredFrame]. Above it the layout is a header
/// panel, a three-card KPI strip, a body (the full-width fleet table over
/// the selected server's card, split state-dependently — see
/// [_minLiveCardRows]), a state-aware selection action bar, the workspace
/// action bar, and a one-row footer hint. An empty workspace drops the
/// selection bar and spends its body on a prompt instead.
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
  final bool remoteDisconnected =
      snapshot.view == MonitorView.remote &&
      snapshot.consumerName == 'remote:not connected';
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

  final List<String> header = _headerPanel(
    snapshot: snapshot,
    instances: total,
    frame: frame,
    columns: columns,
    theme: theme,
    range: range,
    now: now,
    hoveredId: hoveredId,
    pressedId: pressedId,
  );
  final List<String> rows = <String>[
    ...header,
    ...renderKpiStrip(rollup: rollup, columns: columns, theme: theme),
  ];
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    if (_headerViewSwitchHitbox(header) case final MonitorHitbox hitbox) hitbox,
  ];

  if (hasInstances) {
    final MetricSample? selectedLatest = snapshot.latestFor(
      snapshot.instances[selected],
    );
    final String? operationBlockReason = snapshot.operationBlockReasonFor(
      snapshot.instances[selected],
    );
    final bool selectedLive =
        selectedLatest != null && selectedLatest.state != RuntimeState.stopped;
    final String selectedInstance = snapshot.instances[selected];
    final int metadataRows = selectedMetadataRowCount(
      snapshot: snapshot,
      instance: selectedInstance,
      inner: columns - 4,
    );

    // The card's rows: sized to the selection's state, fed by the rows the
    // whole fleet does not need, and never starving the table below its own
    // floor. A body too short for even the idle card (unreachable above the
    // frame floor) gives everything to the table.
    int cardRows;
    if (selectedLive) {
      cardRows = bodyRows - (total + 3);
      if (cardRows < _minLiveCardRows) {
        cardRows = _minLiveCardRows;
      }
      if (cardRows > _maxLiveCardRows) {
        cardRows = _maxLiveCardRows;
      }
    } else {
      cardRows = _idleCardRows;
    }
    final int informationFloor =
        metadataRows + (selectedLive ? _minLiveCardRows : _idleCardRows);
    if (cardRows < informationFloor) {
      cardRows = informationFloor;
    }
    final int cardCeiling = bodyRows - _minListRows;
    if (cardRows > cardCeiling) {
      cardRows = cardCeiling;
    }
    if (cardRows < _idleCardRows) {
      cardRows = 0;
    }
    final int listRows = bodyRows - cardRows;

    final MonitorPanelRender list = renderServerList(
      snapshot: snapshot,
      rollup: rollup,
      selectedIndex: selected,
      rows: listRows,
      width: columns,
      topRow: bodyTop,
      theme: theme,
      windowStart: now.subtract(range),
      windowEnd: now,
      hoveredId: hoveredId,
    );
    rows.addAll(list.rows);
    hitboxes.addAll(list.hitboxes);

    if (cardRows > 0) {
      final MonitorPanelRender panel = renderSelectedPanel(
        snapshot: snapshot,
        selectedIndex: selected,
        rows: cardRows,
        width: columns,
        topRow: bodyTop + listRows,
        colOffset: 0,
        theme: theme,
        range: range,
        now: now,
        hoveredId: hoveredId,
      );
      rows.addAll(panel.rows);
      hitboxes.addAll(panel.hitboxes);
    }

    final ButtonRowRender bar = layoutButtonRow(
      buttons: _selectionButtons(
        selectedLatest,
        operationBlockReason: operationBlockReason,
        remote: snapshot.view == MonitorView.remote,
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
      remoteDisconnected: remoteDisconnected,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );
    rows.addAll(body.rows);
    hitboxes.addAll(body.hitboxes);
  }

  final ButtonRowRender workspace = layoutButtonRow(
    buttons: snapshot.view == MonitorView.remote
        ? (remoteDisconnected
              ? _remoteEmptyWorkspaceButtons
              : _remoteWorkspaceButtons)
        : _workspaceButtons,
    width: columns,
    theme: theme,
    hoveredId: hoveredId,
    pressedId: pressedId,
  );
  rows.add(workspace.row);
  hitboxes.addAll(_buttonHits(workspace.spans, rows.length - 1));

  rows.add(theme.paint(_footerHints(columns, snapshot.view), theme.faint));

  return padFrame(
    MonitorFrame(rows: rows, hitboxes: hitboxes),
    columns: columns,
    lines: lines,
  );
}

/// The chips the selection bar draws for a selection whose latest reading is
/// [latest]. Anything that is not demonstrably running — stopped, or never
/// sampled at all — gets the start set.
List<ButtonSpec> _selectionButtons(
  MetricSample? latest, {
  required String? operationBlockReason,
  required bool remote,
}) {
  final RuntimeState? state = latest?.state;
  final bool live = state != null && state != RuntimeState.stopped;
  if (operationBlockReason != null) {
    return live
        ? (remote ? _blockedRemoteLiveButtons : _blockedLiveButtons)
        : _blockedStoppedButtons;
  }
  return live ? (remote ? _remoteLiveButtons : _liveButtons) : _stoppedButtons;
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
/// the provider's hints as fit, dropped whole and highest rank first, so
/// the row never ends mid-hint and never hides `q quit`.
String _footerHints(int columns, MonitorView view) {
  final bool remote = view == MonitorView.remote;
  final String hints = remote ? _remoteFooterHints : _localFooterHints;
  final String dropOrder = remote
      ? _remoteFooterDropOrder
      : _localFooterDropOrder;
  final List<String> shown = hints.split(_hintSeparator);
  for (final String hint in dropOrder.split(',')) {
    if (shown.join(_hintSeparator).length <= columns) {
      break;
    }
    shown.remove(hint);
  }
  return shown.join(_hintSeparator);
}

/// The header panel: brand wordmark, spinner/consumer/clock badge, and one
/// faint workspace-facts row.
///
/// The fleet roll-up that used to sit here — up/down, players, average TPS —
/// is the KPI strip's job now. Saying it twice, one row apart, spent a row
/// of the body on a repetition.
List<String> _headerPanel({
  required MonitorSnapshot snapshot,
  required int instances,
  required int frame,
  required int columns,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
  String? hoveredId,
  String? pressedId,
}) {
  final DateTime local = now.toLocal();
  final String clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  final String facts =
      'VIEW ${snapshot.view.name.toUpperCase()} · '
      'ACTIVE ${snapshot.activeInstance == null ? 'none' : snapshot.displayNameFor(snapshot.activeInstance!)} · '
      'RANGE ${rangeLabel(range)} · '
      '$instances SERVERS';

  final String switchLabel =
      'TAB ${snapshot.view == MonitorView.local ? 'REMOTE' : 'LOCAL'}';
  final String switchTone = pressedId == viewSwitchHitId
      ? '${theme.bold}${theme.textStrong}'
      : hoveredId == viewSwitchHitId
      ? '${theme.bold}${theme.accent}'
      : theme.faint;
  final String spinner = monitorSpinner(theme, frame);
  final int badgeBudget = columns - 8 - 'MULTIPLEXOR'.length;
  final int fixedBadgeWidth = Ansi.visibleLength(
    '$spinner  · $switchLabel · $clock',
  );
  final int providerBudget = badgeBudget - fixedBadgeWidth;
  final String provider = Ansi.clipVisible(
    snapshot.consumerName,
    providerBudget < 0 ? 0 : providerBudget,
  );
  final String badgePrefix =
      '$spinner '
      '$provider · ';
  final String badgeSuffix = ' · $clock';
  final String badge = '$badgePrefix$switchLabel$badgeSuffix';

  return renderPanel(
    // The wordmark is the one title the panel does not style itself: the
    // gradient is a caller-owned run, inlaid verbatim. At ColorDepth.none
    // gradientTitle returns the plain text, so a plain frame stays free of
    // escape bytes.
    title: 'MULTIPLEXOR',
    styledTitle: theme.gradientTitle('MULTIPLEXOR'),
    badge: badge,
    styledBadge:
        '${theme.paint(badgePrefix, theme.faint)}'
        '${theme.paint(switchLabel, switchTone)}'
        '${theme.paint(badgeSuffix, theme.faint)}',
    content: <String>[theme.paint(facts, theme.faint)],
    width: columns,
    theme: theme,
  );
}

/// Locates the view-switch label after the panel has laid out its right-hand
/// badge. The provider name is clipped above to reserve this space, but the
/// lookup still refuses to create an invisible hitbox if layout ever changes.
MonitorHitbox? _headerViewSwitchHitbox(List<String> header) {
  if (header.isEmpty) {
    return null;
  }
  final String row = Ansi.strip(header.first);
  final Match? match = RegExp(r'TAB (?:REMOTE|LOCAL)').firstMatch(row);
  if (match == null) {
    return null;
  }
  return MonitorHitbox(
    id: viewSwitchHitId,
    kind: MonitorHitKind.button,
    row: 0,
    colStart: match.start,
    colEnd: match.end,
  );
}
