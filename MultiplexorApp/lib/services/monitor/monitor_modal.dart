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

import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/key_grid.dart';
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
  profile,
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
  projects,
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
  networks,
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
      InstanceModalAction.profile => 'j',
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
      WorkspaceModalAction.projects => 'j',
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
      WorkspaceModalAction.networks => 'v',
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

/// The card's width bounds. The card is as wide as its grid and title ask
/// for within these — the readings and note wrap, the hint shortens — and
/// [_cardInset] columns narrower than the frame so the dashboard stays
/// visible around it.
const int _cardMinWidth = 46;
const int _cardMaxWidth = 84;
const int _cardInset = 8;

/// Most columns an action grid is laid out in.
const int _maxGridColumns = 4;

/// Spaces between consecutive grid columns.
const int _gridGap = 2;

/// Most rows the readings line and the note may each wrap onto.
const int _maxTextRows = 2;

/// The columns a card spends on its own frame: the two border rules plus the
/// one space of padding [renderPanel] adds on each side.
const int _cardChrome = 4;

/// The columns a bottom border spends around its inlaid hint: `└─ `, the
/// space after the hint, a two-column tail and the corner.
const int _hintChrome = 7;

/// The dismiss hint inlaid in the card's bottom border, longest first; the
/// card shows the longest that fits.
const List<String> _modalHints = <String>[
  'arrows move · enter runs · letter shortcut · esc closes',
  'enter runs · letter key · esc closes',
  'esc closes',
];

/// The columns a card row's content is offset by within the card: the left
/// border rule plus the one space of padding [renderPanel] adds.
const int _contentOffset = 2;

/// One labeled group of card actions.
class _ModalSection {
  const _ModalSection(this.title, this.buttons);

  final String title;
  final List<ButtonSpec> buttons;
}

/// The tidiest grid, at most [_maxGridColumns] columns, whose rows fit
/// [inner] columns, or null when not even a single column does. Tidiest is
/// the lowest [_gridScore]; a tie goes to more columns.
List<int>? _gridFor(List<List<ButtonSpec>> groups, int inner) {
  List<int>? best;
  int bestScore = 0;
  for (int columns = _maxGridColumns; columns >= 1; columns--) {
    final List<int> widths = keyGridColumnWidths(groups, columns);
    if (keyGridWidth(widths, gap: _gridGap) > inner) continue;
    final int score = _gridScore(groups, widths.length);
    if (best == null || score < bestScore) {
      best = widths;
      bestScore = score;
    }
  }
  return best;
}

/// How ragged [groups] look laid out [columns] cells wide: each row counts
/// twice and each empty cell once, so a narrower grid wins only when the
/// extra rows buy back orphaned cells.
int _gridScore(List<List<ButtonSpec>> groups, int columns) {
  int score = 0;
  for (final List<ButtonSpec> group in groups) {
    final int rows = (group.length + columns - 1) ~/ columns;
    score += 2 * rows + rows * columns - group.length;
  }
  return score;
}

/// [widths] grown evenly so the grid spans [inner] columns; earlier columns
/// take any remainder.
List<int> _stretch(List<int> widths, int inner) {
  final int extra = inner - keyGridWidth(widths, gap: _gridGap);
  if (extra <= 0 || widths.isEmpty) return widths;
  return <int>[
    for (int index = 0; index < widths.length; index++)
      widths[index] +
          extra ~/ widths.length +
          (index < extra % widths.length ? 1 : 0),
  ];
}

/// [buttons] split into rows of at most [columns] cells, in order.
List<List<ButtonSpec>> _gridRows(List<ButtonSpec> buttons, int columns) =>
    <List<ButtonSpec>>[
      for (int start = 0; start < buttons.length; start += columns)
        buttons.sublist(
          start,
          start + columns > buttons.length ? buttons.length : start + columns,
        ),
    ];

/// [parts] joined by [separator] and wrapped into at most [_maxTextRows]
/// rows no wider than [width]; a part that still does not fit is clipped.
List<String> _wrapParts(List<String> parts, String separator, int width) {
  final List<String> rows = <String>[];
  String current = '';
  for (final String part in parts) {
    final String joined = current.isEmpty ? part : '$current$separator$part';
    if (current.isEmpty || joined.length <= width) {
      current = joined;
      continue;
    }
    rows.add(current);
    current = part;
  }
  if (current.isNotEmpty) rows.add(current);
  return <String>[
    for (final String row in rows.take(_maxTextRows))
      Ansi.clipVisible(row, width),
  ];
}

/// A section heading as an inlaid rule, `── RUN ─────`, the way prompt
/// menus separate their groups.
String _sectionRule(String title, int inner, MonitorTheme theme) {
  final String dash = theme.glyphs.frameH;
  final int fill = inner - title.length - 4;
  if (fill < 2) {
    return theme.paint(Ansi.clipVisible(title, inner), theme.faint);
  }
  return '${theme.paint('$dash$dash ', theme.frame)}'
      '${theme.paint(title, '${theme.bold}${theme.faint}')}'
      '${theme.paint(' ${dash * fill}', theme.frame)}';
}

/// The sections of the Local instance card, for an instance whose most
/// recent reading is [latest].
///
/// Availability:
/// - Not stopped (running, or mid-flight starting/stopping/restarting): STOP,
///   RESTART and CONSOLE are live; START is not offered at all.
/// - Stopped: START and UPDATE are live; RESTART and CONSOLE render faint.
/// - ADDONS requires a stopped Local instance.
/// - An instance with no reading yet is treated as stopped, the same way the
///   selection bar treats it — an unsampled instance is not a running one.
/// - FACTORY RESET and DELETE need the instance stopped *and* unlocked; that
///   pair is the entire reach of the lock.
/// - PUSH TO REMOTE needs a stopped Local source, so it never advertises an
///   operation the transfer engine will refuse.
/// - SET PORT, MAKE ACTIVE, MOTD, FOLDER, the lock pair and the isolation
///   pair are always live.
/// - Isolated instances offer a one-time COPY DROP-INS action. Shared
///   instances continue to receive their consumer's drop-ins through sync.
List<_ModalSection> _instanceSections({
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  final bool destructive = stopped && !locked;
  return <_ModalSection>[
    _ModalSection('RUN', <ButtonSpec>[
      stopped
          ? _instanceButton(InstanceModalAction.start, 'Start')
          : _instanceButton(InstanceModalAction.stop, 'Stop'),
      _instanceButton(
        InstanceModalAction.restart,
        'Restart',
        enabled: !stopped,
      ),
      _instanceButton(
        InstanceModalAction.console,
        'Console',
        enabled: !stopped,
      ),
      _instanceButton(InstanceModalAction.makeActive, 'Make active'),
    ]),
    _ModalSection('CONFIGURE', <ButtonSpec>[
      _instanceButton(InstanceModalAction.addons, 'Addons', enabled: stopped),
      _instanceButton(InstanceModalAction.settings, 'Runtime'),
      _instanceButton(InstanceModalAction.setPort, 'Set port'),
      _instanceButton(InstanceModalAction.motd, 'MOTD'),
      isolated
          ? _instanceButton(InstanceModalAction.shared, 'Share')
          : _instanceButton(InstanceModalAction.isolated, 'Isolate'),
      if (isolated)
        _instanceButton(InstanceModalAction.copyDropins, 'Copy drop-ins'),
      locked
          ? _instanceButton(InstanceModalAction.unlock, 'Unlock')
          : _instanceButton(InstanceModalAction.lock, 'Lock'),
    ]),
    _ModalSection('FILES', <ButtonSpec>[
      _instanceButton(InstanceModalAction.backups, 'Backups'),
      _instanceButton(InstanceModalAction.update, 'Update', enabled: stopped),
      _instanceButton(InstanceModalAction.folder, 'Folder'),
      _instanceButton(
        InstanceModalAction.pushToRemote,
        'Push to remote',
        enabled: stopped,
      ),
    ]),
    _ModalSection('DANGER', <ButtonSpec>[
      _instanceButton(
        InstanceModalAction.factoryReset,
        'Factory reset',
        danger: true,
        enabled: destructive,
      ),
      _instanceButton(
        InstanceModalAction.delete,
        'Delete',
        danger: true,
        enabled: destructive,
      ),
    ]),
  ];
}

/// Why some Local actions are dimmed, or null when none are.
String? _instanceNote({required MetricSample? latest, required bool locked}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  if (!stopped) {
    return 'Stop the server to add addons, update, push, reset, or delete.';
  }
  return locked ? 'Unlock the server to factory reset or delete.' : null;
}

/// The sections of the workspace card. Every workspace action is always
/// available; only WIPE carries the danger tone.
List<_ModalSection> _workspaceSections({
  required bool networks,
}) => <_ModalSection>[
  _ModalSection('BUILD', <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.projects, 'Projects'),
    _workspaceButton(WorkspaceModalAction.buildTuning, 'Build & tuning'),
    _workspaceButton(WorkspaceModalAction.pullBuilds, 'Pull builds'),
  ]),
  _ModalSection('SERVERS', <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.createMany, 'Create many'),
    _workspaceButton(WorkspaceModalAction.startAll, 'Start all'),
    _workspaceButton(WorkspaceModalAction.stopAll, 'Stop all'),
    if (networks) _workspaceButton(WorkspaceModalAction.networks, 'Networks'),
    _workspaceButton(WorkspaceModalAction.diagnostics, 'Diagnostics'),
  ]),
  _ModalSection('DANGER', <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.wipe, 'Wipe', danger: true),
  ]),
];

List<_ModalSection> _remoteInstanceSections({
  required MetricSample? latest,
  required bool operationsBlocked,
}) {
  final RuntimeState? state = latest?.state;
  final bool stopped = state == null || state == RuntimeState.stopped;
  return <_ModalSection>[
    _ModalSection('RUN', <ButtonSpec>[
      stopped
          ? _instanceButton(
              InstanceModalAction.start,
              'Start',
              enabled: !operationsBlocked,
            )
          : _instanceButton(
              InstanceModalAction.stop,
              'Stop',
              enabled: !operationsBlocked,
            ),
      _instanceButton(
        InstanceModalAction.restart,
        'Restart',
        enabled: !stopped && !operationsBlocked,
      ),
      _instanceButton(
        InstanceModalAction.console,
        'Console',
        enabled: !stopped && !operationsBlocked,
      ),
    ]),
    _ModalSection('MANAGE', <ButtonSpec>[
      _instanceButton(InstanceModalAction.settings, 'Settings'),
      _instanceButton(InstanceModalAction.history, 'History'),
      _instanceButton(InstanceModalAction.profile, 'Profile'),
      _instanceButton(InstanceModalAction.folder, 'Open folder'),
      _instanceButton(
        InstanceModalAction.pullToLocal,
        'Pull to local',
        enabled: stopped && !operationsBlocked,
      ),
    ]),
    _ModalSection('DANGER', <ButtonSpec>[
      _instanceButton(InstanceModalAction.reinstall, 'Reinstall', danger: true),
      _instanceButton(InstanceModalAction.delete, 'Delete', danger: true),
    ]),
  ];
}

List<_ModalSection> _remoteWorkspaceSections() => <_ModalSection>[
  _ModalSection('FLEET', <ButtonSpec>[
    _workspaceButton(WorkspaceModalAction.connect, 'Connection'),
    _workspaceButton(WorkspaceModalAction.files, 'Files'),
    _workspaceButton(WorkspaceModalAction.createMany, 'Create many'),
    _workspaceButton(WorkspaceModalAction.bulkActions, 'Bulk actions'),
  ]),
];

/// The instance's latest readings and flags, each one a short phrase; empty
/// when there is nothing to say.
List<String> _instanceFacts({
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
}) {
  final int? players = latest?.players;
  final int? maxPlayers = latest?.maxPlayers;
  final int? uptime = latest?.uptimeSeconds;
  return <String>[
    if (latest?.port != null) 'port ${latest!.port}',
    if (players != null)
      'players $players${maxPlayers == null ? '' : '/$maxPlayers'}',
    if (latest?.tps != null) 'TPS ${latest!.tps!.toStringAsFixed(1)}',
    if (latest?.rssBytes != null) 'mem ${formatBytes(latest!.rssBytes)}',
    if (uptime != null)
      'up ${formatCompactDuration(Duration(seconds: uptime))}',
    if (locked) 'locked',
    if (isolated) 'isolated',
  ];
}

/// The longest of [_modalHints] that fits a [width]-wide bottom border, or
/// null when none does.
String? _hintFor(int width) {
  for (final String hint in _modalHints) {
    if (hint.length + _hintChrome <= width) return hint;
  }
  return null;
}

/// The badge inlaid at the right of the card's top border: the state behind
/// a status dot in its tone, or BLOCKED.
String _badgeFor(
  String text,
  RuntimeState? state,
  bool blocked,
  MonitorTheme theme,
) {
  if (blocked) return theme.paint(text, '${theme.bold}${theme.danger}');
  if (state == null) return theme.paint(text, theme.faint);
  final String tone = theme.statusTone(state);
  return theme.paint('${theme.glyphs.bulletOn} $text', tone);
}

/// Draws [modal]'s card centered over [base] and returns the composed frame:
/// exactly [lines] rows of exactly [columns] visible columns.
///
/// Composition rules:
/// - The whole base frame is dimmed: every row is reduced to its text and
///   painted faint, so the dashboard stays readable around the card without
///   competing with it. A one-cell clear margin rings the card so the
///   dimmed dashboard never touches its border; on rows the card covers, the
///   base text continues on both sides past that margin.
/// - [base]'s hitboxes are discarded outright — nothing behind a modal is
///   clickable. In their place come three layers, emitted in painter's order
///   so [hitTest]'s last-wins search resolves them top down: one full-width
///   [modalScrimHitId] box per frame row, then one [modalCardHitId] box per
///   card row spanning the card's columns, then the card's button boxes. A
///   click therefore reads as the button under it, else as [modalCardHitId]
///   (inside the card but not on a control — a no-op), else as
///   [modalScrimHitId] (outside the card — dismisses).
///
/// The card lays its actions out as a grid of `[k] Label` cells whose
/// columns line up across every section, each section under an inlaid
/// heading rule, with the dismiss hint inlaid in the bottom border. An
/// instance card leads with the server's latest readings and ends with a
/// note naming why any actions are dimmed. The card is as wide as its grid
/// and title ask for, between [_cardMinWidth] and [_cardMaxWidth]; a frame
/// too narrow for even one grid column at that size gives the card its full
/// width. When [lines] cannot hold everything, the readings and note go
/// first, then the headings, then grid rows from the bottom (the first is
/// always kept), before the final clip to the frame rectangle.
///
/// [latest] is the instance's most recent reading (it badges the card and
/// gates the runtime actions), [locked] and [isolated] are its flags. Both
/// are ignored by the workspace card. [selectedId] is keyboard focus;
/// [hoveredId] temporarily takes visual precedence when the pointer is over a
/// button, and [pressedId] remains the active mouse press.
MonitorFrame overlayModal({
  required MonitorFrame base,
  required MonitorModalState modal,
  required MetricSample? latest,
  required bool locked,
  required bool isolated,
  bool remote = false,
  bool networks = false,
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
  final List<_ModalSection> sections = switch (modal) {
    InstanceModal() =>
      remote
          ? _remoteInstanceSections(
              latest: latest,
              operationsBlocked: instanceBlocked,
            )
          : _instanceSections(
              latest: latest,
              locked: locked,
              isolated: isolated,
            ),
    WorkspaceModal() =>
      remote
          ? _remoteWorkspaceSections()
          : _workspaceSections(networks: networks),
  };
  final List<String> factParts = modal is InstanceModal
      ? _instanceFacts(latest: latest, locked: locked, isolated: isolated)
      : const <String>[];
  final String? note = modal is InstanceModal && !remote
      ? _instanceNote(latest: latest, locked: locked)
      : null;
  final String? reason = instanceBlocked
      ? 'BLOCKED: $operationBlockReason'
      : null;

  final List<List<ButtonSpec>> groups = <List<ButtonSpec>>[
    for (final _ModalSection section in sections) section.buttons,
  ];
  final int safeColumns = columns < 0 ? 0 : columns;
  final int insetWidth = safeColumns - _cardInset;
  final int roomy = insetWidth < _cardMaxWidth ? insetWidth : _cardMaxWidth;
  final int limit = _gridFor(groups, roomy - _cardChrome) != null
      ? roomy
      : safeColumns;
  final List<int> natural =
      _gridFor(groups, limit - _cardChrome) ?? keyGridColumnWidths(groups, 1);
  final int gridWanted = keyGridWidth(natural, gap: _gridGap) + _cardChrome;
  final int titleWanted =
      title.length + (badge == null ? 0 : badge.length + 2) + 8;
  final int wanted = gridWanted > titleWanted ? gridWanted : titleWanted;
  final int floor = limit < _cardMinWidth ? limit : _cardMinWidth;
  final int width = wanted < floor ? floor : (wanted > limit ? limit : wanted);
  final int innerWidth = width - _cardChrome < 0 ? 0 : width - _cardChrome;
  final List<int> grid = _stretch(natural, innerWidth);
  final List<List<List<ButtonSpec>>> sectionRows = <List<List<ButtonSpec>>>[
    for (final _ModalSection section in sections)
      _gridRows(section.buttons, grid.length),
  ];
  final List<String> factRows = factParts.isEmpty
      ? const <String>[]
      : _wrapParts(factParts, ' · ', innerWidth);
  final List<String> noteRows = note == null
      ? const <String>[]
      : _wrapParts(note.split(' '), ' ', innerWidth);
  final int gridRows = sectionRows.fold(
    0,
    (int total, List<List<ButtonSpec>> rows) => total + rows.length,
  );
  final int reasonRows = reason == null ? 0 : 1;
  final int ruled = 2 + sections.length + gridRows + reasonRows;
  final int fullHeight =
      ruled + factRows.length + (noteRows.isEmpty ? 0 : 1 + noteRows.length);
  final bool full = fullHeight <= lines;
  final bool withRules = full || ruled <= lines;

  final List<List<ButtonSpec>> allRows = <List<ButtonSpec>>[
    for (final List<List<ButtonSpec>> rows in sectionRows) ...rows,
  ];
  final int budget = lines - 2 - reasonRows;
  final List<List<ButtonSpec>> shownRows = withRules
      ? allRows
      : allRows.sublist(
          0,
          allRows.length > (budget < 1 ? 1 : budget)
              ? (budget < 1 ? 1 : budget)
              : allRows.length,
        );
  final List<String> enabledIds = <String>[
    for (final List<ButtonSpec> row in shownRows)
      for (final ButtonSpec button in row)
        if (button.enabled) button.id,
  ];
  final String? keyboardFocusId = enabledIds.contains(selectedId)
      ? selectedId
      : enabledIds.isEmpty
      ? null
      : enabledIds.first;
  final String? effectiveHoveredId = hoveredId ?? keyboardFocusId;

  final List<String> content = <String>[];
  final Map<int, List<ButtonSpan>> spansByRow = <int, List<ButtonSpan>>{};
  void addGridRow(List<ButtonSpec> buttons) {
    final ButtonRowRender render = layoutKeyGridRow(
      buttons: buttons,
      columnWidths: grid,
      width: innerWidth,
      theme: theme,
      hoveredId: effectiveHoveredId,
      pressedId: pressedId,
      gap: _gridGap,
    );
    spansByRow[content.length] = render.spans;
    content.add(render.row);
  }

  if (full) {
    for (final String row in factRows) {
      content.add(theme.paint(row, theme.muted));
    }
  }
  if (withRules) {
    for (int index = 0; index < sections.length; index++) {
      content.add(_sectionRule(sections[index].title, innerWidth, theme));
      sectionRows[index].forEach(addGridRow);
    }
  } else {
    shownRows.forEach(addGridRow);
  }
  if (reason != null && lines >= content.length + 3) {
    content.add(
      theme.paint(Ansi.clipVisible(reason, innerWidth), theme.danger),
    );
  }
  if (full && noteRows.isNotEmpty) {
    content.add('');
    for (final String row in noteRows) {
      content.add(theme.paint(row, theme.faint));
    }
  }

  final List<String> card = renderPanel(
    title: title,
    badge: badge,
    styledBadge: badge == null
        ? null
        : _badgeFor(badge, latest?.state, instanceBlocked, theme),
    footer: _hintFor(width),
    content: content,
    width: width,
    theme: theme,
    emphasis: PanelEmphasis.active,
  );

  final int centeredLeft = (safeColumns - width) ~/ 2;
  final int left = centeredLeft < 0 ? 0 : centeredLeft;
  final int centeredTop = (lines - card.length) ~/ 2;
  final int top = centeredTop < 0 ? 0 : centeredTop;
  final int clearLeft = left > 0 ? left - 1 : 0;
  final int clearRight = left + width < safeColumns
      ? left + width + 1
      : safeColumns;

  final List<String> rows = <String>[];
  for (int index = 0; index < lines; index++) {
    final String baseRow = Ansi.padVisible(
      Ansi.strip(index < base.rows.length ? base.rows[index] : ''),
      safeColumns,
    );
    final int cardIndex = index - top;
    final bool margin = cardIndex == -1 || cardIndex == card.length;
    if (!margin && (cardIndex < 0 || cardIndex >= card.length)) {
      rows.add(theme.paint(baseRow, theme.faint));
      continue;
    }
    final String middle = margin
        ? ' ' * (clearRight - clearLeft)
        : '${' ' * (left - clearLeft)}${card[cardIndex]}'
              '${' ' * (clearRight - left - width)}';
    rows.add(
      '${theme.paint(baseRow.substring(0, clearLeft), theme.faint)}'
      '$middle'
      '${theme.paint(baseRow.substring(clearRight), theme.faint)}',
    );
  }

  final List<MonitorHitbox> hitboxes = <MonitorHitbox>[
    for (int index = 0; index < lines; index++)
      MonitorHitbox(
        id: modalScrimHitId,
        row: index,
        colStart: 0,
        colEnd: safeColumns,
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
  for (final MapEntry<int, List<ButtonSpan>> entry in spansByRow.entries) {
    final int row = top + 1 + entry.key;
    final int offset = left + _contentOffset;
    for (final ButtonSpan span in entry.value) {
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
