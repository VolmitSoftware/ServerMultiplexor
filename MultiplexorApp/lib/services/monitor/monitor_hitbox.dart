/// Hitbox model for the mouse-first monitor dashboard: a rendered frame
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
