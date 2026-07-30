/// Modal cards for the mouse-first monitor dashboard: the two daily-driver
/// menus — the per-instance action card and the workspace action card —
/// drawn as a centered panel over an already-rendered base frame.
///
/// This library is a pure compositor. It never builds the base frame, never
/// decides when a modal opens or closes, and never runs an action: it takes
/// a rendered [MonitorFrame] plus the modal's state and returns a new frame
/// with the card painted over it and the card's clickable regions layered on
/// top of a full-frame scrim.
///
/// Everything here is pure: no clock reads, no IO, no mutation.
library;

import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import '../runtime_state.dart';
import 'metric_sample.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';

/// Which modal card is open. There are exactly two, so the type is sealed and
/// callers switch exhaustively rather than testing a nullable name.
sealed class MonitorModalState {
  const MonitorModalState();
}

/// The action card for a single instance.
class InstanceModal extends MonitorModalState {
  const InstanceModal(this.instance);

  /// The instance the card acts on.
  final String instance;
}

/// The action card for the workspace as a whole.
class WorkspaceModal extends MonitorModalState {
  const WorkspaceModal();
}

/// Every action the instance card can dispatch.
///
/// [lock]/[unlock] and [isolated]/[shared] are complementary pairs: the card
/// only ever offers the one that applies to the instance's current flags.
/// [start]/[stop] pair the same way off the instance's runtime state.
enum InstanceModalAction {
  start,
  stop,
  restart,
  console,
  setPort,
  makeActive,
  motd,
  lock,
  unlock,
  isolated,
  shared,
  folder,
  update,
  factoryReset,
  delete,
}

/// Every action the workspace card can dispatch.
///
/// [newInstance] is deliberately *not* a card row: creating an instance is a
/// bar button and a keyboard shortcut, so the workspace card stays a list of
/// things you do *to* an existing workspace. It lives in this enum so the
/// dispatcher has one vocabulary for both entry points.
enum WorkspaceModalAction {
  buildTuning,
  pullBuilds,
  createMany,
  startAll,
  stopAll,
  wipe,
  newInstance,
}

/// The id prefix every instance-card button hitbox carries: the id is
/// `im:<action name>`. Emitter and dispatcher both name it from here.
const String instanceModalHitPrefix = 'im:';

/// The id prefix every workspace-card button hitbox carries: the id is
/// `wm:<action name>`.
const String workspaceModalHitPrefix = 'wm:';

/// The id of the full-frame [MonitorHitKind.modalScrim] hitbox. A click that
/// lands on it fell outside the card, and closes the modal.
const String modalScrimHitId = 'scrim';

/// The hitbox id for [action] on the instance card.
String instanceModalHitId(InstanceModalAction action) =>
    '$instanceModalHitPrefix${action.name}';

/// The hitbox id for [action] on the workspace card.
String workspaceModalHitId(WorkspaceModalAction action) =>
    '$workspaceModalHitPrefix${action.name}';

/// The card's preferred width, and the narrowest it stays readable at.
const int _cardMaxWidth = 46;
const int _cardMinWidth = 24;

/// Columns left showing on either side of the card at full width.
const int _cardInset = 8;

/// Leading spaces before the first chip of a card row, and the spaces between
/// the two chips of a row.
const int _rowIndent = 2;
const int _rowGap = 2;

/// The dismiss hint on the last content row of the card.
const String _modalHint = 'esc closes';

/// The columns a card row's content is offset by within the card: the left
/// border rule plus the one space of padding [renderPanel] adds.
const int _contentOffset = 2;

/// The card width for a [columns]-wide frame: [_cardMaxWidth] at most, and
/// [_cardInset] columns narrower than the frame so the dashboard stays
/// visible around it. Below [_cardMinWidth] the inset is what is starving the
/// card, not the cap, so the card spends the whole frame width instead.
int _cardWidth(int columns) {
  final int inset = columns - _cardInset;
  final int capped = inset > _cardMaxWidth ? _cardMaxWidth : inset;
  if (capped >= _cardMinWidth) {
    return capped;
  }
  return columns < 2 ? 2 : columns;
}

/// The chip rows of the instance card, top to bottom, for an instance whose
/// most recent reading is [latest].
///
/// Availability mirrors the deleted `_instanceMenu` exactly:
/// - Not stopped (running, or mid-flight starting/stopping/restarting): STOP,
///   RESTART and CONSOLE are live; START is not offered at all.
/// - Stopped: START and UPDATE are live; RESTART and CONSOLE render faint.
/// - An instance with no reading yet is treated as stopped, the same way the
///   selection bar treats it — an unsampled instance is not a running one.
/// - FACTORY RESET and DELETE need the instance stopped *and* unlocked; that
///   pair is the entire reach of the lock, which is what the old menu's
///   "block delete and factory reset" lock copy promised.
/// - SET PORT, MAKE ACTIVE, MOTD, FOLDER, the lock pair and the isolation
///   pair are always live.
List<List<ButtonSpec>> _instanceRows({
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  final bool destructive = stopped && !locked;

  return <List<ButtonSpec>>[
    <ButtonSpec>[
      stopped
          ? ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.start),
              label: 'START',
            )
          : ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.stop),
              label: 'STOP',
            ),
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.restart),
        label: 'RESTART',
        enabled: !stopped,
      ),
    ],
    <ButtonSpec>[
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.console),
        label: 'CONSOLE',
        enabled: !stopped,
      ),
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.setPort),
        label: 'SET PORT',
      ),
    ],
    <ButtonSpec>[
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.makeActive),
        label: 'MAKE ACTIVE',
      ),
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.motd),
        label: 'MOTD',
      ),
    ],
    <ButtonSpec>[
      locked
          ? ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.unlock),
              label: 'UNLOCK',
            )
          : ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.lock),
              label: 'LOCK',
            ),
      isolated
          ? ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.shared),
              label: 'SHARE',
            )
          : ButtonSpec(
              id: instanceModalHitId(InstanceModalAction.isolated),
              label: 'ISOLATE',
            ),
    ],
    <ButtonSpec>[
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.folder),
        label: 'FOLDER',
      ),
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.update),
        label: 'UPDATE',
        enabled: stopped,
      ),
    ],
    <ButtonSpec>[
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.factoryReset),
        label: 'FACTORY RESET',
        danger: true,
        enabled: destructive,
      ),
      ButtonSpec(
        id: instanceModalHitId(InstanceModalAction.delete),
        label: 'DELETE',
        danger: true,
        enabled: destructive,
      ),
    ],
  ];
}

/// The chip rows of the workspace card, top to bottom. Every workspace action
/// is always available; only WIPE carries the danger tone.
List<List<ButtonSpec>> _workspaceRows() => <List<ButtonSpec>>[
  <ButtonSpec>[
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.buildTuning),
      label: 'BUILD & TUNING',
    ),
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.pullBuilds),
      label: 'PULL BUILDS',
    ),
  ],
  <ButtonSpec>[
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.createMany),
      label: 'CREATE MANY',
    ),
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.startAll),
      label: 'START ALL',
    ),
  ],
  <ButtonSpec>[
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.stopAll),
      label: 'STOP ALL',
    ),
    ButtonSpec(
      id: workspaceModalHitId(WorkspaceModalAction.wipe),
      label: 'WIPE',
      danger: true,
    ),
  ],
];

/// The dismiss-hint content row: [_modalHint] centered across [innerWidth],
/// faint.
String _hintRow(int innerWidth, MonitorTheme theme) {
  final int slack = innerWidth - _modalHint.length;
  final int pad = slack <= 0 ? 0 : slack ~/ 2;
  return theme.paint('${' ' * pad}$_modalHint', theme.faint);
}

/// Draws [modal]'s card centered over [base] and returns the composed frame:
/// exactly [lines] rows of exactly [columns] visible columns.
///
/// Composition rules:
/// - Rows the card does not cover are passed through from [base] byte for
///   byte.
/// - On a row the card *does* cover, the base row is kept up to the card's
///   left edge and everything to the right of the card is blanked to spaces.
///   Splicing a styled run back in on the right would require reconstructing
///   the escape state the clip cut through; blanking is the honest, cheap
///   answer, and a modal row reads as a modal row either way.
/// - [base]'s hitboxes are discarded outright — nothing behind a modal is
///   clickable. In their place comes one full-width
///   [MonitorHitKind.modalScrim] box per row (id [modalScrimHitId]), emitted
///   *before* the card's button boxes so [hitTest]'s last-wins ordering lets
///   a button beat the scrim underneath it.
///
/// [latest] is the instance's most recent reading (it badges the card and
/// gates the runtime actions), [locked] and [isolated] are its flags. Both
/// are ignored by the workspace card. [hoveredId] and [pressedId] thread
/// straight through to the chips.
///
/// The card never outgrows the frame: its width follows [_cardWidth], and
/// when [lines] cannot hold every chip row the rows are dropped from the
/// bottom (the first is always kept), then the dismiss hint, before the final
/// clip to the frame rectangle.
MonitorFrame overlayModal({
  required MonitorFrame base,
  required MonitorModalState modal,
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
  required MonitorTheme theme,
  String? hoveredId,
  String? pressedId,
  required int columns,
  required int lines,
}) {
  final int width = _cardWidth(columns);
  final int innerWidth = width - 4 < 0 ? 0 : width - 4;

  final String title = switch (modal) {
    InstanceModal(instance: final String name) => name,
    WorkspaceModal() => 'WORKSPACE',
  };
  final String? badge = switch (modal) {
    InstanceModal() => monitorStateText(latest),
    WorkspaceModal() => null,
  };
  final List<List<ButtonSpec>> allRows = switch (modal) {
    InstanceModal() => _instanceRows(
      latest: latest,
      locked: locked,
      isolated: isolated,
    ),
    WorkspaceModal() => _workspaceRows(),
  };

  // Two borders and the hint row are the card's fixed overhead; whatever is
  // left over is the chip-row budget, and at least one chip row is always
  // drawn even when that overflows a very short frame.
  final int budget = lines - 3;
  final int maxRows = budget < 1 ? 1 : budget;
  final List<List<ButtonSpec>> buttonRows = allRows.length > maxRows
      ? allRows.sublist(0, maxRows)
      : allRows;
  final bool showHint = lines >= buttonRows.length + 3;

  final List<String> content = <String>[];
  final List<List<ButtonSpan>> rowSpans = <List<ButtonSpan>>[];
  for (final List<ButtonSpec> buttons in buttonRows) {
    final ButtonRowRender render = layoutButtonRow(
      buttons: buttons,
      width: innerWidth,
      theme: theme,
      hoveredId: hoveredId,
      pressedId: pressedId,
      gap: _rowGap,
      indent: _rowIndent,
    );
    content.add(render.row);
    rowSpans.add(render.spans);
  }
  if (showHint) {
    content.add(_hintRow(innerWidth, theme));
  }

  final List<String> card = renderPanel(
    title: title,
    badge: badge,
    content: content,
    width: width,
    theme: theme,
  );

  final int centeredLeft = (columns - width) ~/ 2;
  final int left = centeredLeft < 0 ? 0 : centeredLeft;
  final int centeredTop = (lines - card.length) ~/ 2;
  final int top = centeredTop < 0 ? 0 : centeredTop;
  final int rightWidth = columns - left - width;
  final String rightBlank = ' ' * (rightWidth < 0 ? 0 : rightWidth);

  final List<String> rows = <String>[];
  for (int index = 0; index < lines; index++) {
    final String baseRow = index < base.rows.length ? base.rows[index] : '';
    final int cardIndex = index - top;
    if (cardIndex < 0 || cardIndex >= card.length) {
      rows.add(baseRow);
      continue;
    }
    final String kept = Ansi.padVisible(Ansi.clipVisible(baseRow, left), left);
    rows.add('$kept${card[cardIndex]}$rightBlank');
  }

  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    for (int index = 0; index < lines; index++)
      MonitorHitbox(
        id: modalScrimHitId,
        row: index,
        colStart: 0,
        colEnd: columns < 0 ? 0 : columns,
        kind: MonitorHitKind.modalScrim,
      ),
  ];
  for (int index = 0; index < rowSpans.length; index++) {
    final int row = top + 1 + index;
    final int offset = left + _contentOffset;
    for (final ButtonSpan span in rowSpans[index]) {
      hitboxes.add(
        MonitorHitbox(
          id: span.id,
          row: row,
          colStart: offset + span.colStart,
          colEnd: offset + span.colEnd,
          kind: MonitorHitKind.button,
        ),
      );
    }
  }

  return padFrame(
    MonitorFrame(rows: rows, hitboxes: hitboxes),
    columns: columns,
    lines: lines,
  );
}
