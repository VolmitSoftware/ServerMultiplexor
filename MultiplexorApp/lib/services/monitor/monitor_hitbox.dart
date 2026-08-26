/// Hitbox model for the interactive monitor dashboard: a rendered frame
/// (rows of text) paired with the clickable regions layered over it.
///
/// Everything in this library is pure: no clock reads, no IO, no mutation.
library;

/// The kind of interactive region a [MonitorHitbox] represents.
enum MonitorHitKind { serverRow, button, chart, rangeChip, modalScrim }

/// The id prefix every [MonitorHitKind.serverRow] hitbox carries: the id is
/// `server:<instance>`. Both the builder that emits the hitbox and the
/// screen that reads it back name the prefix from here, so the two can never
/// drift apart on the spelling.
const String serverHitPrefix = 'server:';

/// The id of the [MonitorHitKind.rangeChip] hitbox over the selected-server
/// panel's badge — clicking it cycles the chart window, exactly as `r` does.
const String rangeHitId = 'range';

/// The clickable `TAB REMOTE` / `TAB LOCAL` label in the header. It switches
/// providers through the same route as the Tab key.
const String viewSwitchHitId = 'view:switch';

/// The selection action bar's button ids: what the chips over the selected
/// server do. `monitor_model.dart` builds the chips from these and
/// `monitor_screen.dart` dispatches on them, so — like [serverHitPrefix] —
/// emitter and dispatcher name every one of them from here and cannot drift
/// apart on a spelling.
const String actStartHitId = 'act:start';
const String actStopHitId = 'act:stop';
const String actRestartHitId = 'act:restart';
const String actConsoleHitId = 'act:console';
const String actDetailHitId = 'act:detail';
const String actMoreHitId = 'act:more';

/// The workspace action bar's button ids: what the chips act on the
/// workspace as a whole do. [wsNewHitId] is also the id of the `+ NEW` chip
/// the empty-workspace body draws, so both routes dispatch the same way.
const String wsNewHitId = 'ws:new';
const String wsBuildsHitId = 'ws:builds';
const String wsTuningHitId = 'ws:tuning';
const String wsConsumerHitId = 'ws:consumer';
const String wsConsolesHitId = 'ws:consoles';
const String wsConnectHitId = 'ws:connect';
const String wsMoreHitId = 'ws:more';

/// Every non-row dashboard control id, header switch first and then both
/// action bars. Both halves of the contract are pinned to this list: the
/// builders emit exactly these ids (across the states that select between
/// them) and the screen dispatches on exactly these ids, so a control can
/// never be drawn with an id nothing acts on, nor acted on under an id nothing
/// draws.
const List<String> monitorBarHitIds = <String>[
  viewSwitchHitId,
  actStartHitId,
  actStopHitId,
  actRestartHitId,
  actConsoleHitId,
  actDetailHitId,
  actMoreHitId,
  wsNewHitId,
  wsBuildsHitId,
  wsTuningHitId,
  wsConsumerHitId,
  wsConsolesHitId,
  wsConnectHitId,
  wsMoreHitId,
];

/// A single clickable region within a rendered frame: terminal row [row],
/// half-open column range `[colStart, colEnd)` (both 0-based), identified by
/// [id] and typed by [kind] so a caller can dispatch on what was clicked
/// without string-matching the id.
class MonitorHitbox {
  const MonitorHitbox({
    required this.id,
    required this.row,
    required this.colStart,
    required this.colEnd,
    required this.kind,
  });

  final String id;
  final int row;
  final int colStart;
  final int colEnd;
  final MonitorHitKind kind;
}

/// A rendered frame: [rows] of visible terminal text plus every clickable
/// [hitboxes] region layered over it.
class MonitorFrame {
  const MonitorFrame({required this.rows, required this.hitboxes});

  final List<String> rows;
  final List<MonitorHitbox> hitboxes;
}

/// The id of the topmost hitbox in [hitboxes] whose [MonitorHitbox.row]
/// equals [row] and whose column range `[colStart, colEnd)` contains [col].
///
/// [hitboxes] is searched last-to-first, so when two hitboxes overlap the
/// one added later — the one drawn on top — wins, mirroring how overlapping
/// UI is actually painted. Returns null when nothing matches.
String? hitTest(
  List<MonitorHitbox> hitboxes, {
  required int row,
  required int col,
}) {
  for (int index = hitboxes.length - 1; index >= 0; index--) {
    final MonitorHitbox box = hitboxes[index];
    if (box.row == row && col >= box.colStart && col < box.colEnd) {
      return box.id;
    }
  }
  return null;
}

/// Resolves a left-button release into an activation target.
///
/// A region activates only when the pointer was pressed and released over
/// the same hitbox. Keeping this rule pure makes the mouse contract explicit
/// for every target, including the header view switch: dragging off cancels
/// the click, and releasing over a different control never activates either.
String? monitorReleaseTarget({
  required String? pressedId,
  required String? releasedId,
  required bool primaryButton,
}) => primaryButton && pressedId != null && releasedId == pressedId
    ? pressedId
    : null;
