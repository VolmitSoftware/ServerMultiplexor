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
import '../instance_bulk.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_groups.dart';
import 'monitor_hitbox.dart';
import 'monitor_landing.dart';
import 'monitor_selection.dart';

/// The frame's fixed row budget, top-down: the header panel (a title border,
/// one facts row and a bottom border), the KPI strip, one row per action bar,
/// and the footer hint. Everything left over is the body — at the 24-line
/// floor that is 15 rows.
const int _headerRows = 3;
const int _kpiRows = 3;
const int _barRows = 1;
const int _footerRows = 1;

/// The narrowest frame the KPI strip still reads at; below it the strip
/// gives its rows to the body.
const int _kpiMinColumns = 80;

/// How the body splits between the fleet table and the selected-server card.
///
/// The card is sized to the selection's own state, and the table keeps the
/// rows its fleet needs: an idle selection has nothing to plot, so its card
/// is one quiet line ([_idleCardRows]); a live one expands into charts,
/// growing from [_minLiveCardRows] with whatever rows the fleet does not
/// need, up to [monitorLiveCardMaxRows] without a log tail and without limit
/// with one, and never pushing the table below [_minListRows] (its borders,
/// the column header and one instance row). Rows the card cannot use go
/// back to the table.
const int _minListRows = 4;
const int _idleCardRows = 3;
const int _minLiveCardRows = 8;

/// Separator between footer hints.
const String _hintSeparator = ' · ';

/// Local footer key hints in display order — the row exactly as it renders on
/// a terminal wide enough for all of it.
const String _localFooterHints =
    '[tab] local/remote · [enter] open · Space check · a all · x clear · d detail · Shift+R repaint · S stop · X kill · ⌫ delete · O console · '
    'g consoles · n new · b build · w workspace · r range · '
    'q quit';

/// Remote replaces Local build and consumer shortcuts with its fleet bulk
/// menu and connection card. The workspace shortcut remains visible because
/// that card also owns files and create-many.
const String _remoteFooterHints =
    '[tab] local/remote · [enter] open · Space check · a all · x clear · d detail · Shift+R repaint · S stop · X kill · ⌫ delete · '
    'O live console · n new · b bulk · w workspace · c connection · r range · '
    'q quit';

/// The order hints are given up in when the terminal is too narrow for all
/// of them (comma-separated). A hint always leaves whole — a footer clipped
/// mid-word hides a binding without admitting to it. The ordinary footer keeps
/// open, detail, repaint, and quit; checked rows prioritize selection controls.
///
/// `b build` goes first even though `w workspace` was added after it: the
/// workspace card `w` raises carries Build & tuning itself, so giving up the
/// shortcut costs a keystroke, while giving up `w` would leave the card
/// reachable by mouse alone.
const String _localFooterDropOrder =
    'b build,n new,g consoles,O console,X kill,⌫ delete,S stop,'
    'r range,w workspace,[tab] local/remote,x clear,a all,Space check';

const String _remoteFooterDropOrder =
    'n new,c connection,X kill,⌫ delete,S stop,O live console,r range,b bulk,w workspace,'
    '[tab] local/remote,x clear,a all,Space check';

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
  ButtonSpec(id: wsProjectsHitId, label: 'PROJECTS'),
  ButtonSpec(id: wsBuildsHitId, label: 'BUILDS'),
  ButtonSpec(id: wsTuningHitId, label: 'TUNING'),
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
/// Pure: no clock reads and no IO. [now] and [clockNow] must be UTC. Sample
/// timestamps are UTC and chart windows are `[now - range, now]`; the header
/// clock is rendered in local time from [clockNow]. Keeping the two clocks
/// separate lets an unchanged chart stay byte-for-byte stable between data
/// samples while the visible clock remains current.
///
/// [hoveredId] and [pressedId] select the interaction state of whatever they
/// name: a button chip renders hovered or pressed, and a hovered server row
/// shows its selector. Both null (the `--once` snapshot) renders every
/// region in its resting state.
///
/// [notice] is the outcome a finished flow left behind; while it is set it
/// takes the footer's place, so a result is read without a key press.
/// [logLines] are the selected server's log tail; a live card with spare
/// rows shows them under its charts.
MonitorFrame buildMonitorFrame({
  required MonitorSnapshot snapshot,
  required int selectedIndex,
  required int frame,
  required int columns,
  required int lines,
  required MonitorTheme theme,
  required Duration range,
  required DateTime now,
  required DateTime clockNow,
  Set<String> checkedInstances = const <String>{},
  String? hoveredId,
  String? pressedId,
  String? updateLabel,
  bool updateChecking = false,
  String? focusedGroup,
  String? notice,
  List<String>? logLines,
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
  final Set<String> checked = snapshot.instances
      .where(checkedInstances.contains)
      .toSet();
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

  final String? selectedInstance = hasInstances
      ? snapshot.instances[selected]
      : null;
  final MetricSample? selectedLatest = selectedInstance == null
      ? null
      : snapshot.latestFor(selectedInstance);
  final bool selectedLive =
      selectedLatest != null && selectedLatest.state != RuntimeState.stopped;
  final int metadataRows = selectedInstance == null
      ? 0
      : selectedMetadataRowCount(
          snapshot: snapshot,
          instance: selectedInstance,
          inner: columns - 4,
        );
  final int cardNeed =
      selectedInstance == null || snapshot.groupedLocal && focusedGroup != null
      ? 0
      : metadataRows + (selectedLive ? _minLiveCardRows : _idleCardRows);
  final _FrameBudget layout = _planFrameBudget(
    lines: lines,
    columns: columns,
    // Chrome is shed for the card and a list that can still scroll, never
    // just to show more rows of a long fleet.
    need:
        (!hasInstances
            ? _minListRows
            : snapshot.groupedLocal
            ? localMonitorMinimumRows(snapshot)
            : _minInt(total, 3) + 3) +
        cardNeed,
    bars: hasInstances ? _barRows * 2 : _barRows,
  );
  final int bodyTop = layout.headerRows + layout.kpiRows;
  final int budget = lines - bodyTop - layout.bars - _footerRows;
  final int bodyRows = budget < 0 ? 0 : budget;

  final List<String> fullHeader = _headerPanel(
    snapshot: snapshot,
    instances: total,
    frame: frame,
    columns: columns,
    theme: theme,
    range: range,
    now: clockNow,
    hoveredId: hoveredId,
    pressedId: pressedId,
  );
  final List<String> header = layout.headerRows == _headerRows
      ? fullHeader
      : <String>[fullHeader.first];
  final List<String> rows = <String>[
    ...header,
    if (layout.kpiRows > 0)
      ...renderKpiStrip(rollup: rollup, columns: columns, theme: theme),
  ];
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    ..._headerActionHitboxes(header, snapshot.view),
  ];

  if (selectedInstance != null) {
    final String? operationBlockReason = snapshot.operationBlockReasonFor(
      selectedInstance,
    );

    // The card's rows: sized to the selection's state, fed by the rows the
    // whole fleet does not need, and never starving the table below its own
    // floor. A body too short for even the idle card (unreachable above the
    // frame floor) gives everything to the table.
    final bool hasLog = logLines != null && logLines.isNotEmpty;
    final int liveCeiling = hasLog
        ? bodyRows
        : monitorLiveCardMaxRows + metadataRows;
    int cardRows;
    if (selectedLive) {
      cardRows = bodyRows - (total + 3);
      if (cardRows < _minLiveCardRows) {
        cardRows = _minLiveCardRows;
      }
      if (cardRows > liveCeiling) {
        cardRows = liveCeiling;
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
    if (snapshot.groupedLocal) {
      // Groups keep their natural height when there is room; otherwise they
      // scroll down to their minimum so the selected card still shows.
      final int spare = bodyRows - localMonitorNaturalRows(snapshot);
      final int room = bodyRows - localMonitorMinimumRows(snapshot);
      final int cardFloor = informationFloor;
      final int summaryFloor = metadataRows + _idleCardRows;
      cardRows = focusedGroup != null
          ? 0
          : spare >= cardFloor
          ? (selectedLive ? _minInt(spare, liveCeiling) : cardFloor)
          : room >= cardFloor
          ? cardFloor
          : room >= summaryFloor
          ? summaryFloor
          : 0;
    }
    final int listRows = bodyRows - cardRows;

    final MonitorPanelRender list = snapshot.groupedLocal
        ? renderGroupedServerList(
            snapshot: snapshot,
            selectedIndex: selected,
            rows: listRows,
            width: columns,
            topRow: bodyTop,
            theme: theme,
            windowStart: now.subtract(range),
            windowEnd: now,
            checkedInstances: checked,
            hoveredId: hoveredId,
            focusedGroup: focusedGroup,
          )
        : renderServerList(
            snapshot: snapshot,
            rollup: rollup,
            selectedIndex: selected,
            rows: listRows,
            width: columns,
            topRow: bodyTop,
            theme: theme,
            windowStart: now.subtract(range),
            windowEnd: now,
            checkedInstances: checked,
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
        logLines: logLines,
      );
      rows.addAll(panel.rows);
      hitboxes.addAll(panel.hitboxes);
    }

    final String selectionLabel = checked.isEmpty
        ? ''
        : ' ${checked.length} SELECTED  ';
    final ButtonRowRender bar = layoutButtonRow(
      buttons: _keepLastChip(
        snapshot.groupedLocal && focusedGroup != null && checked.isEmpty
            ? <ButtonSpec>[
                ButtonSpec(
                  id: '$groupNewHitPrefix$focusedGroup',
                  label: '+ NEW',
                ),
              ]
            : checked.isEmpty
            ? _selectionButtons(
                selectedLatest,
                operationBlockReason: operationBlockReason,
                remote: snapshot.view == MonitorView.remote,
              )
            : _bulkButtons(snapshot, checked),
        columns - selectionLabel.length,
        indent: checked.isEmpty ? 1 : 0,
      ),
      width: columns - selectionLabel.length,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
      indent: checked.isEmpty ? 1 : 0,
    );
    rows.add(
      selectionLabel.isEmpty
          ? bar.row
          : '${theme.paint(selectionLabel, '${theme.bold}${theme.accent}')}${bar.row}',
    );
    hitboxes.addAll(
      _buttonHits(bar.spans, rows.length - 1, colOffset: selectionLabel.length),
    );
  } else if (snapshot.groupedLocal) {
    MonitorPanelRender body = renderGroupedServerList(
      snapshot: snapshot,
      selectedIndex: -1,
      rows: bodyRows,
      width: columns,
      topRow: bodyTop,
      theme: theme,
      windowStart: now.subtract(range),
      windowEnd: now,
      focusedGroup: focusedGroup,
      hoveredId: hoveredId,
    );
    rows.addAll(body.rows);
    hitboxes.addAll(body.hitboxes);
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

  if (layout.bars == _barRows * 2 || !hasInstances) {
    final ButtonRowRender workspace = layoutButtonRow(
      buttons: _keepLastChip(
        snapshot.view == MonitorView.remote
            ? (remoteDisconnected
                  ? _remoteEmptyWorkspaceButtons
                  : _remoteWorkspaceButtons)
            : _workspaceButtons,
        columns,
      ),
      width: columns,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );
    rows.add(workspace.row);
    hitboxes.addAll(_buttonHits(workspace.spans, rows.length - 1));
  }

  final String? buttonLabel = updateLabel == null
      ? null
      : Ansi.clipVisible(updateLabel, columns ~/ 2 - 4);
  final int updateWidth = buttonLabel == null ? 0 : buttonLabel.length + 4;
  final int hintsWidth = columns - updateWidth - (updateWidth > 0 ? 1 : 0);
  String footer = notice == null
      ? theme.paint(
          Ansi.clipVisible(
            _footerHints(
              hintsWidth,
              snapshot.view,
              hasChecked: checked.isNotEmpty,
              groupedLocal: snapshot.groupedLocal,
            ),
            hintsWidth,
          ),
          theme.faint,
        )
      : theme.paint(
          Ansi.clipVisible('✔ $notice', hintsWidth),
          '${theme.bold}${theme.ok}',
        );
  if (buttonLabel != null) {
    final ButtonRowRender update = layoutButtonRow(
      buttons: <ButtonSpec>[
        ButtonSpec(
          id: updateHitId,
          label: buttonLabel,
          enabled: !updateChecking,
        ),
      ],
      width: updateWidth,
      indent: 0,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );
    final int leftWidth = columns - updateWidth;
    footer = '${Ansi.padVisible(footer, leftWidth)}${update.row}';
    hitboxes.addAll(
      _buttonHits(update.spans, rows.length, colOffset: leftWidth),
    );
  }
  rows.add(footer);

  return padFrame(
    MonitorFrame(rows: rows, hitboxes: hitboxes),
    columns: columns,
    lines: lines,
  );
}

/// How a frame of [lines] rows spends them: a three-row header panel or its
/// one-row title, the KPI strip or nothing, and one or two action bars.
typedef _FrameBudget = ({int headerRows, int kpiRows, int bars});

/// Gives the body the [need] rows its list and selected card want by
/// shedding chrome in order: the KPI strip, then the header's facts and
/// borders, then the workspace bar (whose card stays one `w` away). A
/// frame narrower than [_kpiMinColumns] never draws the strip.
_FrameBudget _planFrameBudget({
  required int lines,
  required int columns,
  required int need,
  required int bars,
}) {
  int headerRows = _headerRows;
  int kpiRows = columns >= _kpiMinColumns ? _kpiRows : 0;
  int barRows = bars;
  int body() => lines - headerRows - kpiRows - barRows - _footerRows;
  if (body() < need) kpiRows = 0;
  if (body() < need) headerRows = 1;
  if (body() < need && barRows > _barRows) barRows = _barRows;
  return (headerRows: headerRows, kpiRows: kpiRows, bars: barRows);
}

/// [buttons] trimmed to fit [width] while keeping the last chip, the MORE
/// card that reaches everything the bar had to leave out. Chips go from the
/// end of the row, just before it.
List<ButtonSpec> _keepLastChip(
  List<ButtonSpec> buttons,
  int width, {
  int indent = 1,
}) {
  int needed(List<ButtonSpec> row) {
    int total = indent;
    for (int index = 0; index < row.length; index++) {
      total +=
          row[index].labelFor(showShortcut: true).length +
          4 +
          (index == 0 ? 0 : 1);
    }
    return total;
  }

  final List<ButtonSpec> kept = List<ButtonSpec>.of(buttons);
  while (kept.length > 1 && needed(kept) > width) {
    kept.removeAt(kept.length - 2);
  }
  return kept;
}

List<ButtonSpec> _bulkButtons(MonitorSnapshot snapshot, Set<String> checked) {
  bool eligible(InstanceBulkAction action) => checked.any(
    (String instance) => monitorBulkEligible(snapshot, instance, action),
  );
  return <ButtonSpec>[
    ButtonSpec(
      id: bulkStartHitId,
      label: 'START',
      enabled: eligible(InstanceBulkAction.start),
    ),
    ButtonSpec(
      id: bulkStopHitId,
      label: 'STOP',
      enabled: eligible(InstanceBulkAction.stop),
    ),
    ButtonSpec(
      id: bulkRestartHitId,
      label: 'RESTART',
      enabled: eligible(InstanceBulkAction.restart),
    ),
    ButtonSpec(
      id: bulkDeleteHitId,
      label: 'DELETE',
      danger: true,
      enabled: eligible(InstanceBulkAction.delete),
    ),
    const ButtonSpec(id: clearSelectionHitId, label: 'CLEAR'),
  ];
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
List<MonitorHitbox> _buttonHits(
  List<ButtonSpan> spans,
  int row, {
  int colOffset = 0,
}) => <MonitorHitbox>[
  for (final ButtonSpan span in spans)
    MonitorHitbox(
      id: span.id,
      kind: MonitorHitKind.button,
      row: row,
      colStart: span.colStart + colOffset,
      colEnd: span.colEnd + colOffset,
    ),
];

/// The footer hint row for a [columns]-wide frame: as many of
/// the provider's hints as fit, dropped whole and highest rank first, so
/// the row never ends mid-hint and never hides `q quit`.
String _footerHints(
  int columns,
  MonitorView view, {
  bool hasChecked = false,
  bool groupedLocal = false,
}) {
  final bool remote = view == MonitorView.remote;
  String hints = remote ? _remoteFooterHints : _localFooterHints;
  String dropOrder = remote ? _remoteFooterDropOrder : _localFooterDropOrder;
  if (groupedLocal) {
    hints = hints.replaceFirst('Space check', 'Space primary · v check');
    dropOrder = dropOrder.replaceFirst(',Space check', '');
    dropOrder = '$dropOrder,d detail,Shift+R repaint';
  }
  if (hasChecked) {
    hints = hints.replaceFirst(
      remote ? 'b bulk' : 'b build',
      'b selected actions',
    );
    dropOrder = dropOrder
        .split(',')
        .where(
          (String hint) =>
              !<String>['Space check', 'a all', 'x clear'].contains(hint),
        )
        .join(',');
    dropOrder = '$dropOrder,d detail,Shift+R repaint';
  }
  final List<String> shown = hints.split(_hintSeparator);
  for (final String hint in dropOrder.split(',')) {
    if (shown.join(_hintSeparator).length <= columns) {
      break;
    }
    shown.remove(hint);
  }
  while (shown.length > 1 && shown.join(_hintSeparator).length > columns) {
    shown.removeAt(0);
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

  final String facts = snapshot.captureError != null
      ? 'METRICS ${snapshot.lastSuccessfulCapture == null ? 'UNAVAILABLE' : 'STALE'} · retrying automatically · ${snapshot.captureError}'
      : 'VIEW ${snapshot.view.name.toUpperCase()} · '
            '${snapshot.groupedLocal ? 'ALL PROFILES' : 'ACTIVE ${snapshot.activeInstance == null ? 'none' : snapshot.displayNameFor(snapshot.activeInstance!)}'} · '
            'RANGE ${rangeLabel(range)} · '
            '$instances SERVERS';

  final String switchLabel =
      'TAB ${snapshot.view == MonitorView.local ? 'REMOTE' : 'LOCAL'}';
  final String switchTone = pressedId == viewSwitchHitId
      ? '${theme.bold}${theme.textStrong}'
      : hoveredId == viewSwitchHitId
      ? '${theme.bold}${theme.accent}'
      : theme.faint;
  const String workspaceLabel = 'W WORKSPACES';
  final String workspaceTone = pressedId == workspaceHeaderHitId
      ? '${theme.bold}${theme.textStrong}'
      : hoveredId == workspaceHeaderHitId
      ? '${theme.bold}${theme.accent}'
      : theme.faint;
  final String spinner = monitorSpinner(theme, frame);
  final int badgeBudget = columns - 8 - 'MULTIPLEXOR'.length;
  final int fixedBadgeWidth = Ansi.visibleLength(
    '$spinner  · $workspaceLabel · $switchLabel · $clock',
  );
  final int providerBudget = badgeBudget - fixedBadgeWidth;
  final String provider = Ansi.clipVisible(
    snapshot.groupedLocal ? 'Local' : snapshot.consumerName,
    providerBudget < 0 ? 0 : providerBudget,
  );
  final String badgePrefix =
      '$spinner '
      '$provider · ';
  final String badgeSuffix = ' · $clock';
  final String badge = '$badgePrefix$workspaceLabel · $switchLabel$badgeSuffix';

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
        '${theme.paint(workspaceLabel, workspaceTone)}'
        '${theme.paint(' · ', theme.faint)}'
        '${theme.paint(switchLabel, switchTone)}'
        '${theme.paint(badgeSuffix, theme.faint)}',
    content: <String>[
      theme.paint(
        facts,
        snapshot.captureError == null ? theme.faint : theme.accent,
      ),
    ],
    width: columns,
    theme: theme,
  );
}

/// Provider text gives up space before either action. Locate the final label
/// so a provider name containing the same words cannot steal its hitbox.
List<MonitorHitbox> _headerActionHitboxes(
  List<String> header,
  MonitorView view,
) {
  if (header.isEmpty) {
    return const <MonitorHitbox>[];
  }
  final String row = Ansi.strip(header.first);
  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[];
  for (final (String id, String label) in <(String, String)>[
    (workspaceHeaderHitId, 'W WORKSPACES'),
    (viewSwitchHitId, 'TAB ${view == MonitorView.local ? 'REMOTE' : 'LOCAL'}'),
  ]) {
    final int start = row.lastIndexOf(label);
    if (start < 0) continue;
    hitboxes.add(
      MonitorHitbox(
        id: id,
        kind: MonitorHitKind.button,
        row: 0,
        colStart: start,
        colEnd: start + label.length,
      ),
    );
  }
  return hitboxes;
}

int _minInt(int left, int right) => left < right ? left : right;
