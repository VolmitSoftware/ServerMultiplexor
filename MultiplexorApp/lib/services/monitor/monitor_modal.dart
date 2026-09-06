/// Modal cards for the interactive monitor dashboard: the two daily-driver
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
  pullToLocal,
  pushToRemote,
  addons,
  backups,
  settings,
  history,
  reinstall,
  setPort,
  makeActive,
  motd,
  lock,
  unlock,
  isolated,
  shared,
  copyDropins,
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
  connect,
  files,
  bulkActions,
  diagnostics,
  templates,
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

/// The id of the card's own [MonitorHitKind.modalScrim] hitboxes, laid over
/// the card rectangle above [modalScrimHitId] and below the button boxes.
/// A click that lands on it hit the card's border, title, badge or row
/// padding — inside the modal but not on a control — and is a no-op. It
/// exists so those clicks stop at the card instead of falling through to the
/// scrim and dismissing the modal the user was aiming at.
const String modalCardHitId = 'card';

/// The hitbox id for [action] on the instance card.
String instanceModalHitId(InstanceModalAction action) =>
    '$instanceModalHitPrefix${action.name}';

/// The hitbox id for [action] on the workspace card.
String workspaceModalHitId(WorkspaceModalAction action) =>
    '$workspaceModalHitPrefix${action.name}';

/// The instance action [id] names, or null when [id] is not an instance-card
/// button id — the exact inverse of [instanceModalHitId]. A dispatcher can
/// therefore hand it every id it hit-tests and act only on the ones that come
/// back non-null.
InstanceModalAction? instanceModalActionForId(String id) {
  if (!id.startsWith(instanceModalHitPrefix)) {
    return null;
  }
  final String name = id.substring(instanceModalHitPrefix.length);
  for (final InstanceModalAction action in InstanceModalAction.values) {
    if (action.name == name) {
      return action;
    }
  }
  return null;
}

/// The workspace action [id] names, or null when [id] is not a
/// workspace-card button id — the exact inverse of [workspaceModalHitId].
WorkspaceModalAction? workspaceModalActionForId(String id) {
  if (!id.startsWith(workspaceModalHitPrefix)) {
    return null;
  }
  final String name = id.substring(workspaceModalHitPrefix.length);
  for (final WorkspaceModalAction action in WorkspaceModalAction.values) {
    if (action.name == name) {
      return action;
    }
  }
  return null;
}

/// Single-key bindings for instance-card actions. Complementary actions use
/// the same key because they are never available on the card together.
String instanceModalActionHotkey(InstanceModalAction action) =>
    switch (action) {
      InstanceModalAction.start || InstanceModalAction.stop => 's',
      InstanceModalAction.restart => 'r',
      InstanceModalAction.console => 'c',
      InstanceModalAction.pullToLocal ||
      InstanceModalAction.pushToRemote => 'p',
      InstanceModalAction.addons => 'o',
      InstanceModalAction.backups => 'b',
      InstanceModalAction.settings => 'e',
      InstanceModalAction.history => 'h',
      InstanceModalAction.reinstall => 'n',
      InstanceModalAction.setPort => 't',
      InstanceModalAction.makeActive => 'a',
      InstanceModalAction.motd => 'm',
      InstanceModalAction.lock || InstanceModalAction.unlock => 'l',
      InstanceModalAction.isolated || InstanceModalAction.shared => 'i',
      InstanceModalAction.copyDropins => 'y',
      InstanceModalAction.folder => 'f',
      InstanceModalAction.update => 'u',
      InstanceModalAction.factoryReset => 'x',
      InstanceModalAction.delete => 'd',
    };

/// Single-key bindings for workspace-card actions.
String workspaceModalActionHotkey(WorkspaceModalAction action) =>
    switch (action) {
      WorkspaceModalAction.buildTuning ||
      WorkspaceModalAction.bulkActions => 'b',
      WorkspaceModalAction.pullBuilds => 'p',
      WorkspaceModalAction.createMany => 'm',
      WorkspaceModalAction.startAll => 'a',
      WorkspaceModalAction.stopAll => 's',
      WorkspaceModalAction.wipe => 'x',
      WorkspaceModalAction.newInstance => 'n',
      WorkspaceModalAction.connect => 'c',
      WorkspaceModalAction.files => 'f',
      WorkspaceModalAction.diagnostics => 'd',
      WorkspaceModalAction.templates => 't',
    };

/// The hotkey carried by a modal button id, or null for a non-button id.
String? modalHotkeyForId(String id) {
  final InstanceModalAction? instance = instanceModalActionForId(id);
  if (instance != null) {
    return instanceModalActionHotkey(instance);
  }
  final WorkspaceModalAction? workspace = workspaceModalActionForId(id);
  return workspace == null ? null : workspaceModalActionHotkey(workspace);
}

/// Resolves [char] against the enabled, visible modal buttons in [hitboxes].
/// Case is ignored; disabled and height-clipped buttons have no hitbox and
/// therefore cannot be triggered from the keyboard.
String? modalActionIdForHotkey(List<MonitorHitbox> hitboxes, String char) {
  if (char.length != 1) {
    return null;
  }
  final String key = char.toLowerCase();
  for (final MonitorHitbox hitbox in hitboxes) {
    if (hitbox.kind == MonitorHitKind.button &&
        modalHotkeyForId(hitbox.id) == key) {
      return hitbox.id;
    }
  }
  return null;
}

/// Direction of keyboard focus movement inside a modal card.
enum ModalMove { up, down, left, right }

/// Moves keyboard focus spatially through the enabled modal [hitboxes].
/// Horizontal movement stays on the current row; vertical movement selects
/// the closest button center on the nearest row above or below. Boundaries
/// clamp, and a missing selection begins at the first enabled button.
String? moveModalSelection(
  List<MonitorHitbox> hitboxes,
  String? selectedId,
  ModalMove move,
) {
  final List<MonitorHitbox> buttons = hitboxes
      .where((MonitorHitbox hitbox) => hitbox.kind == MonitorHitKind.button)
      .toList(growable: false);
  if (buttons.isEmpty) {
    return null;
  }
  final int currentIndex = buttons.indexWhere(
    (MonitorHitbox hitbox) => hitbox.id == selectedId,
  );
  final MonitorHitbox current = currentIndex < 0
      ? buttons.first
      : buttons[currentIndex];
  final double currentCenter = (current.colStart + current.colEnd) / 2;

  Iterable<MonitorHitbox> candidates;
  switch (move) {
    case ModalMove.left:
      candidates = buttons.where(
        (MonitorHitbox hitbox) =>
            hitbox.row == current.row && hitbox.colEnd <= current.colStart,
      );
      if (candidates.isEmpty) {
        return current.id;
      }
      return candidates
          .reduce(
            (MonitorHitbox left, MonitorHitbox right) =>
                left.colEnd > right.colEnd ? left : right,
          )
          .id;
    case ModalMove.right:
      candidates = buttons.where(
        (MonitorHitbox hitbox) =>
            hitbox.row == current.row && hitbox.colStart >= current.colEnd,
      );
      if (candidates.isEmpty) {
        return current.id;
      }
      return candidates
          .reduce(
            (MonitorHitbox left, MonitorHitbox right) =>
                left.colStart < right.colStart ? left : right,
          )
          .id;
    case ModalMove.up:
    case ModalMove.down:
      final bool up = move == ModalMove.up;
      candidates = buttons.where(
        (MonitorHitbox hitbox) =>
            up ? hitbox.row < current.row : hitbox.row > current.row,
      );
      if (candidates.isEmpty) {
        return current.id;
      }
      final int targetRow = candidates
          .map((MonitorHitbox hitbox) => hitbox.row)
          .reduce(
            up
                ? (int a, int b) => a > b ? a : b
                : (int a, int b) => a < b ? a : b,
          );
      final List<MonitorHitbox> rowButtons = candidates
          .where((MonitorHitbox hitbox) => hitbox.row == targetRow)
          .toList(growable: false);
      rowButtons.sort((MonitorHitbox left, MonitorHitbox right) {
        final double leftDistance =
            ((left.colStart + left.colEnd) / 2 - currentCenter).abs();
        final double rightDistance =
            ((right.colStart + right.colEnd) / 2 - currentCenter).abs();
        final int distanceOrder = leftDistance.compareTo(rightDistance);
        return distanceOrder != 0
            ? distanceOrder
            : left.colStart.compareTo(right.colStart);
      });
      return rowButtons.first.id;
  }
}

ButtonSpec _instanceButton(
  InstanceModalAction action,
  String label, {
  bool danger = false,
  bool enabled = true,
}) => ButtonSpec(
  id: instanceModalHitId(action),
  label: label,
  shortcut: instanceModalActionHotkey(action),
  danger: danger,
  enabled: enabled,
);

ButtonSpec _workspaceButton(
  WorkspaceModalAction action,
  String label, {
  bool danger = false,
}) => ButtonSpec(
  id: workspaceModalHitId(action),
  label: label,
  shortcut: workspaceModalActionHotkey(action),
  danger: danger,
);

/// The card's preferred width.
const int _cardMaxWidth = 46;

/// Columns left showing on either side of the card at full width.
const int _cardInset = 8;

/// Leading spaces before the first chip of a card row, and the spaces between
/// the two chips of a row.
const int _rowIndent = 2;
const int _rowGap = 2;

/// The columns a chip spends on its brackets and their padding — the `[ ` and
/// ` ]` [renderButton] wraps every label in. Mirrors that renderer's own
/// `label.length + 4` sizing, and is what lets this library predict a row's
/// width before laying it out.
const int _chipPadding = 4;

/// The columns a card spends on its own frame: the two border rules plus the
/// one space of padding [renderPanel] adds on each side.
const int _cardChrome = 4;

/// The dismiss hint on the last content row of the card.
const String _modalHint = 'arrows move · enter runs · esc closes';

/// The columns a card row's content is offset by within the card: the left
/// border rule plus the one space of padding [renderPanel] adds.
const int _contentOffset = 2;

/// The visible columns one card row needs to render every one of [buttons]
/// whole: the row indent, each chip, and a gap between consecutive chips.
int _rowWidth(List<ButtonSpec> buttons, {bool showShortcuts = true}) {
  int width = _rowIndent;
  for (int index = 0; index < buttons.length; index++) {
    if (index > 0) {
      width += _rowGap;
    }
    width +=
        buttons[index].labelFor(showShortcut: showShortcuts).length +
        _chipPadding;
  }
  return width;
}

/// The narrowest card that still renders every chip of every row in [rows].
///
/// [layoutButtonRow] drops a chip that would not fit *whole*, and it drops it
/// silently — so a card narrower than this loses buttons with no visual cue
/// that anything is missing. Deriving the floor from the rows themselves means
/// relabelling a chip can never quietly reintroduce that.
int _contentFloor(List<List<ButtonSpec>> rows) {
  int floor = 0;
  for (final List<ButtonSpec> row in rows) {
    final int needed = _rowWidth(row) + _cardChrome;
    if (needed > floor) {
      floor = needed;
    }
  }
  return floor;
}

/// The card width for a [columns]-wide frame drawing [rows]: [_cardMaxWidth]
/// at most, and [_cardInset] columns narrower than the frame so the dashboard
/// stays visible around it — but never narrower than [_contentFloor], since a
/// card that silently drops DELETE is worse than one that touches both edges.
///
/// When the frame cannot seat the floor even at full width, the card spends
/// the whole frame and [layoutButtonRow] does the dropping; there is no width
/// left to give it.
int _cardWidth(int columns, List<List<ButtonSpec>> rows) {
  final int inset = columns - _cardInset;
  final int capped = inset > _cardMaxWidth ? _cardMaxWidth : inset;
  if (capped >= _contentFloor(rows)) {
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
/// - ADDONS requires a stopped Local instance.
/// - An instance with no reading yet is treated as stopped, the same way the
///   selection bar treats it — an unsampled instance is not a running one.
/// - FACTORY RESET and DELETE need the instance stopped *and* unlocked; that
///   pair is the entire reach of the lock, which is what the old menu's
///   "block delete and factory reset" lock copy promised.
/// - PUSH TO REMOTE needs a stopped Local source. Remote cards apply the same
///   stopped-source rule to PULL TO LOCAL so neither flow advertises an
///   operation the transfer engine will refuse.
/// - SET PORT, MAKE ACTIVE, MOTD, FOLDER, the lock pair and the isolation
///   pair are always live.
/// - Isolated instances offer a one-time COPY DROP-INS action. Shared
///   instances continue to receive their consumer's drop-ins through sync.
List<List<ButtonSpec>> _instanceRows({
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
  required int columns,
}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  final bool destructive = stopped && !locked;
  final List<ButtonSpec> transferAddons = <ButtonSpec>[
    _instanceButton(
      InstanceModalAction.pushToRemote,
      'PUSH TO REMOTE',
      enabled: stopped,
    ),
    _instanceButton(InstanceModalAction.addons, 'ADDONS', enabled: stopped),
  ];
  final bool splitTransferAddons =
      _rowWidth(transferAddons, showShortcuts: false) + _cardChrome > columns;

  return <List<ButtonSpec>>[
    <ButtonSpec>[
      stopped
          ? _instanceButton(InstanceModalAction.start, 'START')
          : _instanceButton(InstanceModalAction.stop, 'STOP'),
      _instanceButton(
        InstanceModalAction.restart,
        'RESTART',
        enabled: !stopped,
      ),
    ],
    <ButtonSpec>[
      _instanceButton(
        InstanceModalAction.console,
        'CONSOLE',
        enabled: !stopped,
      ),
      _instanceButton(InstanceModalAction.setPort, 'SET PORT'),
    ],
    if (splitTransferAddons)
      for (final ButtonSpec button in transferAddons) <ButtonSpec>[button]
    else
      transferAddons,
    <ButtonSpec>[
      _instanceButton(InstanceModalAction.makeActive, 'MAKE ACTIVE'),
      _instanceButton(InstanceModalAction.motd, 'MOTD'),
    ],
    <ButtonSpec>[
      locked
          ? _instanceButton(InstanceModalAction.unlock, 'UNLOCK')
          : _instanceButton(InstanceModalAction.lock, 'LOCK'),
      isolated
          ? _instanceButton(InstanceModalAction.shared, 'SHARE')
          : _instanceButton(InstanceModalAction.isolated, 'ISOLATE'),
    ],
    if (isolated)
      <ButtonSpec>[
        _instanceButton(InstanceModalAction.copyDropins, 'COPY DROP-INS'),
      ],
    <ButtonSpec>[
      _instanceButton(InstanceModalAction.folder, 'FOLDER'),
      _instanceButton(InstanceModalAction.update, 'UPDATE', enabled: stopped),
    ],
    <ButtonSpec>[
      _instanceButton(InstanceModalAction.backups, 'BACKUPS'),
      _instanceButton(InstanceModalAction.settings, 'RUNTIME'),
    ],
    <ButtonSpec>[
      _instanceButton(
        InstanceModalAction.factoryReset,
        'FACTORY RESET',
        danger: true,
        enabled: destructive,
      ),
      _instanceButton(
        InstanceModalAction.delete,
        'DELETE',
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
    _workspaceButton(WorkspaceModalAction.diagnostics, 'DIAGNOSTICS'),
    _workspaceButton(WorkspaceModalAction.templates, 'TEMPLATES'),
  ],
  <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.buildTuning, 'BUILD & TUNING'),
    _workspaceButton(WorkspaceModalAction.pullBuilds, 'PULL BUILDS'),
  ],
  <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.createMany, 'CREATE MANY'),
    _workspaceButton(WorkspaceModalAction.startAll, 'START ALL'),
  ],
  <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.stopAll, 'STOP ALL'),
    _workspaceButton(WorkspaceModalAction.wipe, 'WIPE', danger: true),
  ],
];

List<List<ButtonSpec>> _remoteInstanceRows({
  required MetricSample? latest,
  required bool operationsBlocked,
}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  return <List<ButtonSpec>>[
    <ButtonSpec>[
      stopped
          ? _instanceButton(
              InstanceModalAction.start,
              'START',
              enabled: !operationsBlocked,
            )
          : _instanceButton(
              InstanceModalAction.stop,
              'STOP',
              enabled: !operationsBlocked,
            ),
      _instanceButton(
        InstanceModalAction.restart,
        'RESTART',
        enabled: !stopped && !operationsBlocked,
      ),
    ],
    <ButtonSpec>[
      _instanceButton(
        InstanceModalAction.console,
        'CONSOLE',
        enabled: !stopped && !operationsBlocked,
      ),
      _instanceButton(InstanceModalAction.history, 'HISTORY'),
    ],
    <ButtonSpec>[
      _instanceButton(
        InstanceModalAction.pullToLocal,
        'PULL TO LOCAL',
        enabled: stopped && !operationsBlocked,
      ),
    ],
    <ButtonSpec>[
      _instanceButton(InstanceModalAction.settings, 'SETTINGS'),
      _instanceButton(InstanceModalAction.folder, 'OPEN FOLDER'),
    ],
    <ButtonSpec>[
      _instanceButton(InstanceModalAction.reinstall, 'REINSTALL', danger: true),
      _instanceButton(InstanceModalAction.delete, 'DELETE', danger: true),
    ],
  ];
}

List<List<ButtonSpec>> _remoteWorkspaceRows() => <List<ButtonSpec>>[
  <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.connect, 'CONNECTION'),
    _workspaceButton(WorkspaceModalAction.files, 'FILES'),
  ],
  <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.createMany, 'CREATE MANY'),
    _workspaceButton(WorkspaceModalAction.bulkActions, 'BULK ACTIONS'),
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
///   clickable. In their place come three layers, emitted in painter's order
///   so [hitTest]'s last-wins search resolves them top down: one full-width
///   [modalScrimHitId] box per frame row, then one [modalCardHitId] box per
///   card row spanning the card's columns, then the card's button boxes. A
///   click therefore reads as the button under it, else as [modalCardHitId]
///   (inside the card but not on a control — a no-op), else as
///   [modalScrimHitId] (outside the card — dismisses).
///
/// - The card is never narrower than the widest chip row needs, so no button
///   is ever silently dropped while there are columns left to give it.
///
/// [latest] is the instance's most recent reading (it badges the card and
/// gates the runtime actions), [locked] and [isolated] are its flags. Both
/// are ignored by the workspace card. [selectedId] is keyboard focus;
/// [hoveredId] temporarily takes visual precedence when the pointer is over a
/// button, and [pressedId] remains the active mouse press.
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
  bool remote = false,
  String? operationBlockReason,
  required MonitorTheme theme,
  String? selectedId,
  String? hoveredId,
  String? pressedId,
  required int columns,
  required int lines,
}) {
  final String title = switch (modal) {
    InstanceModal(instance: final String name) => name,
    WorkspaceModal() => 'WORKSPACE',
  };
  final bool instanceBlocked =
      modal is InstanceModal && remote && operationBlockReason != null;
  final String? badge = switch (modal) {
    InstanceModal() => instanceBlocked ? 'BLOCKED' : monitorStateText(latest),
    WorkspaceModal() => null,
  };
  final List<List<ButtonSpec>> allRows = switch (modal) {
    InstanceModal() =>
      remote
          ? _remoteInstanceRows(
              latest: latest,
              operationsBlocked: instanceBlocked,
            )
          : _instanceRows(
              latest: latest,
              locked: locked,
              isolated: isolated,
              columns: columns,
            ),
    WorkspaceModal() => remote ? _remoteWorkspaceRows() : _workspaceRows(),
  };

  // Width is derived from the full row set, not the height-truncated one, so
  // a short frame narrows the card's contents but never its columns.
  final int width = _cardWidth(columns, allRows);
  final int innerWidth = width - _cardChrome < 0 ? 0 : width - _cardChrome;

  // Two borders and the hint row are the card's fixed overhead; whatever is
  // left over is the chip-row budget, and at least one chip row is always
  // drawn even when that overflows a very short frame.
  final int reasonRows = instanceBlocked ? 1 : 0;
  final int budget = lines - 3 - reasonRows;
  final int maxRows = budget < 1 ? 1 : budget;
  final List<List<ButtonSpec>> buttonRows = allRows.length > maxRows
      ? allRows.sublist(0, maxRows)
      : allRows;
  final bool showReason =
      instanceBlocked && lines >= buttonRows.length + reasonRows + 2;
  final bool showHint =
      lines >= buttonRows.length + (showReason ? reasonRows : 0) + 3;

  final List<String> enabledIds = buttonRows
      .expand((List<ButtonSpec> row) => row)
      .where((ButtonSpec button) => button.enabled)
      .map((ButtonSpec button) => button.id)
      .toList(growable: false);
  final String? keyboardFocusId = enabledIds.contains(selectedId)
      ? selectedId
      : enabledIds.isEmpty
      ? null
      : enabledIds.first;
  final String? effectiveHoveredId = hoveredId ?? keyboardFocusId;

  final List<String> content = <String>[];
  final List<List<ButtonSpan>> rowSpans = <List<ButtonSpan>>[];
  for (final List<ButtonSpec> buttons in buttonRows) {
    final bool showShortcuts = _rowWidth(buttons) + _cardChrome <= width;
    final ButtonRowRender render = layoutButtonRow(
      buttons: buttons,
      width: innerWidth,
      theme: theme,
      hoveredId: effectiveHoveredId,
      pressedId: pressedId,
      showShortcuts: showShortcuts,
      gap: _rowGap,
      indent: _rowIndent,
    );
    content.add(render.row);
    rowSpans.add(render.spans);
  }
  if (showReason) {
    content.add(theme.paint('BLOCKED: $operationBlockReason', theme.danger));
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
  for (int index = 0; index < card.length; index++) {
    hitboxes.add(
      MonitorHitbox(
        id: modalCardHitId,
        row: top + index,
        colStart: left,
        colEnd: left + width,
        kind: MonitorHitKind.modalScrim,
      ),
    );
  }
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
