/// The full-screen monitoring dashboard's event loop.
///
/// Everything that can be pure lives elsewhere — key bindings in
/// `monitor_keymap.dart`, frame layout in `monitor_model.dart`,
/// `monitor_detail_model.dart` and their shared `monitor_frame_util.dart`,
/// sampling in `metrics_sampler.dart`. What is
/// left here is the part that cannot be: owning the terminal (alternate
/// screen, raw mode, mouse reporting), driving a 250 ms heartbeat, and
/// handing the terminal back to legacy flows and reclaiming it afterwards.
library;

import 'dart:async';
import 'dart:io';

import '../../utils/terminal/frame_patch.dart';
import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import '../../utils/terminal/theme.dart';
import 'metric_sample.dart';
import 'metrics_sampler.dart';
import 'monitor_detail_model.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';
import 'monitor_keymap.dart';
import 'monitor_modal.dart';
import 'monitor_model.dart';

/// How long each iteration waits for input. Together with [_yieldWindow] this
/// is the heartbeat: no [Timer] drives this screen, the blocking read's own
/// deadline does.
const Duration _readTimeout = Duration(milliseconds: 240);

/// The slice of each iteration handed back to the VM's event loop. It has to
/// be non-zero: a zero-duration delay resumes this loop at the head of the
/// event queue, which advances a pending async chain by only one step per
/// tick, so a sweep of N instances would need N-plus ticks to finish. A 10 ms
/// window lets those chains run to completion while keeping the tick at the
/// intended ~250 ms.
const Duration _yieldWindow = Duration(milliseconds: 10);

/// How often metrics are swept, measured on the wall clock rather than in
/// iterations: held keys and trackpad scrolling produce iterations, and
/// neither should turn into a sweep storm.
const Duration _localSweepInterval = Duration(seconds: 2);

/// How long each spinner glyph is shown. The spinner index comes from
/// elapsed time for the same reason the sweep does — so it animates at a
/// steady rate no matter how much input arrives.
const Duration _spinnerPeriod = Duration(milliseconds: 250);

/// The detail view re-reads its log tail no more than once per second,
/// however fast frames are drawn.
const Duration _logTailInterval = Duration(seconds: 1);

/// How many trailing log lines the detail view asks for. The log panel is
/// row-capped by the detail model and shows the tail of what it is given,
/// so reading more than this would be wasted IO.
const int _logTailLines = 12;

/// Enter the alternate screen buffer and hide the cursor.
const String _enterAltScreen = '\x1B[?1049h\x1B[?25l';

/// Leave the alternate screen buffer and show the cursor.
const String _leaveAltScreen = '\x1B[?1049l\x1B[?25h';

/// The prefix [renderTerminalPatch] puts on a full-frame repaint. A patch
/// that starts with it carries `\n`-separated rows and needs carriage
/// returns added before it can be written in raw mode.
const String _fullFramePrefix = '\x1B[H\x1B[2J';

/// Why the monitor screen stopped: either the user left it, or it is
/// handing off to a flow the dashboard itself does not implement.
///
/// There is exactly one of the latter left. Every other hand-off the
/// dashboard used to report — opening an instance, creating one, the build
/// menu — is now a modal card and an injected callback run on a suspended
/// terminal, so the session is never torn down for it. A consumer switch
/// stays a result because it invalidates the sampler and its trend store:
/// the caller has to build a new session, not resume this one.
sealed class MonitorResult {
  const MonitorResult();
}

/// The user quit the dashboard.
class MonitorQuit extends MonitorResult {
  const MonitorQuit();
}

/// The user asked to switch consumer profiles.
class MonitorSwitchConsumer extends MonitorResult {
  const MonitorSwitchConsumer();
}

/// The user moved between the Local and Remote tabs.
class MonitorSwitchView extends MonitorResult {
  const MonitorSwitchView();
}

/// Runs the command-center dashboard until the user leaves it.
///
/// Every collaborator is injected: [sampler] supplies metric history,
/// [loadSnapshot] rebuilds the workspace view after each sweep,
/// [quickAction] performs a per-instance command bound to a key,
/// [instanceAction] and [workspaceAction] run the flows behind the two modal
/// cards and the action bars, [readLogTail] reads a log tail for the detail
/// view, and [suspend] runs any of them while this screen is out of the way.
///
/// [suspend] receives a flow to run and is only responsible for running it:
/// the screen brackets the call with its own terminal transitions (leaving
/// the alternate screen and raw mode before, reclaiming both after), so no
/// injected callback can leave the terminal in a half-owned state. Every
/// [instanceAction] and [workspaceAction] call goes through that bracket, so
/// those callbacks are free to prompt.
class MonitorScreen {
  MonitorScreen({
    required this.sampler,
    required this.theme,
    required this.loadSnapshot,
    required this.suspend,
    required this.quickAction,
    required this.instanceAction,
    required this.workspaceAction,
    required this.readLogTail,
    Duration sweepInterval = _localSweepInterval,
    this.sweepIntervalProvider,
    this.refreshImmediately = true,
    this.sessionInvalidated,
  }) : _sweepInterval = sweepInterval;

  final MetricsSampler sampler;
  final MonitorTheme theme;
  final Future<MonitorSnapshot> Function() loadSnapshot;
  final Future<void> Function(Future<void> Function() flow) suspend;
  final Future<void> Function(String instance, MonitorAction action)
  quickAction;
  final Future<void> Function(String instance, InstanceModalAction action)
  instanceAction;
  final Future<void> Function(WorkspaceModalAction action) workspaceAction;
  final Future<List<String>> Function(String logPath, int maxLines) readLogTail;

  final Duration _sweepInterval;

  /// Optional live cadence source. It is evaluated on every heartbeat so a
  /// provider can adapt after its fleet size changes without rebuilding the
  /// screen. When absent, [sweepInterval] remains the constructor's static
  /// value (two seconds by default).
  final Duration Function()? sweepIntervalProvider;

  /// The refresh cadence currently in force.
  Duration get sweepInterval => sweepIntervalProvider?.call() ?? _sweepInterval;

  /// Whether entering the loop should immediately sweep. Callers that
  /// preload metrics can disable this and begin the normal cadence now.
  final bool refreshImmediately;

  /// Reports that a suspended flow changed the backing provider session and
  /// this screen must be rebuilt with a new sampler/store.
  final bool Function()? sessionInvalidated;

  MonitorSnapshot _snapshot = const MonitorSnapshot(
    instances: <String>[],
    history: <String, List<MetricSample>>{},
    consumerName: '',
  );

  /// The frame text last written, i.e. what the terminal is showing. Null
  /// means "nothing trustworthy on screen": the next render is a full one.
  String? _last;

  /// The hitboxes from the most recently built frame — the mouse-click map.
  /// Rebuilt every [_render], including in detail mode, where it is always
  /// empty (the detail view has no clickable regions yet), and while a modal
  /// is open, where it is the modal's own three layers and nothing else.
  List<MonitorHitbox> _hitboxes = const <MonitorHitbox>[];

  /// The id of the region the pointer is currently over, and the id the
  /// pointer went down on and has not been released over yet. Both name a
  /// hitbox from the frame on screen; either is cleared the moment the id it
  /// names stops being part of that frame (see [_liveId]).
  String? _hoveredId;
  String? _pressedId;

  /// The modal card on screen, or null when there is none. While it is
  /// non-null it owns the pointer and Escape outright: nothing behind it is
  /// clickable, and no key but Escape and quit does anything.
  MonitorModalState? _modal;

  int _selectedIndex = 0;
  int _frame = 0;
  Duration _range = monitorRanges.first;
  bool _forceFull = true;
  int _lastColumns = -1;
  int _lastLines = -1;

  /// When this run started, the origin the spinner's phase is measured from.
  DateTime _startedAt = DateTime.now();

  /// When a sweep was last asked for — the wall clock the sweep cadence is
  /// paced against.
  DateTime _lastSweepKick = DateTime.fromMillisecondsSinceEpoch(0);

  bool _detailMode = false;
  String _detailInstance = '';
  List<String> _logLines = const <String>[];
  DateTime? _logReadAt;
  bool _readingLog = false;

  /// True while a sweep-and-reload is in flight, so overlapping refreshes
  /// cannot interleave and publish an older snapshot over a newer one.
  bool _refreshing = false;

  /// Takes over the terminal, runs the dashboard, and gives the terminal
  /// back — on every path out, including a thrown flow.
  ///
  /// Throws a [StateError] when there is no terminal to take over; callers
  /// are expected to check [TermIo.hasTerminal] and pick a non-interactive
  /// path instead.
  Future<MonitorResult> run() async {
    final TermIo io = TermIo.instance;
    if (!io.hasTerminal) {
      throw StateError(
        'The monitor dashboard requires an interactive terminal.',
      );
    }

    // Loaded before the alternate screen opens: the first frame the user
    // sees is a real one, not an empty dashboard that fills in a tick later.
    _snapshot = await loadSnapshot();
    _resetViewState();

    try {
      // Inside the try: taking the terminal is itself a sequence of writes
      // and mode changes, and one of them throwing must still leave the
      // restore path to run.
      _enterScreen(io);
      return await _loop(io);
    } finally {
      // restoreTerminal() is the backstop for the whole session (echo, line
      // mode, SGR, the signal watch), so a failure while stepping off the
      // alternate screen must not be allowed to skip it.
      try {
        _leaveScreen(io);
      } finally {
        io.restoreTerminal();
      }
    }
  }

  /// Clears per-run view state so a screen re-entered after a suspended
  /// flow (new instance, build menu, consumer switch) comes back on the
  /// main view with nothing stale on it. The chart range and selection
  /// survive on purpose — they are the user's place in the dashboard.
  void _resetViewState() {
    _last = null;
    _forceFull = true;
    _lastColumns = -1;
    _lastLines = -1;
    _detailMode = false;
    _detailInstance = '';
    _logLines = const <String>[];
    _logReadAt = null;
    _modal = null;
    _clearPointer();
    _startedAt = DateTime.now();
    _clampSelection();
  }

  /// Forgets where the pointer was. Called whenever what is on screen stops
  /// being what the pointer was last measured against — a modal opening or
  /// closing, a suspension, a resize — so no chip is left lit under a
  /// pointer that is no longer over it.
  void _clearPointer() {
    _hoveredId = null;
    _pressedId = null;
  }

  void _enterScreen(TermIo io) {
    // Re-armed on every entry, not once per run: the legacy flows a
    // suspension hands the terminal to call restoreTerminal() in their own
    // cleanup, which cancels this watch. Without re-arming, the dashboard
    // would come back from its first suspension with no way to step off the
    // alternate screen on a signal. The install is `??=`-guarded, so
    // repeating it costs nothing.
    io.installSignalRestore();
    io.setRawMode(true);
    stdout.write(_enterAltScreen);
    io.altScreenActive = true;
    io.enableMouse();
    io.drainInput();
  }

  void _leaveScreen(TermIo io) {
    io.disableMouse();
    stdout.write(_leaveAltScreen);
    io.altScreenActive = false;
    io.setRawMode(false);
  }

  Future<MonitorResult> _loop(TermIo io) async {
    if (refreshImmediately) {
      _kickRefresh();
    } else {
      _lastSweepKick = DateTime.now();
    }
    _render(io);

    while (true) {
      TermEvent? event;
      try {
        event = io.readEventTimeout(_readTimeout);
      } on TermInputUnavailable {
        // stdin died under us (terminal closed, session detached): there is
        // no dashboard left to drive.
        return const MonitorQuit();
      }

      if (DateTime.now().difference(_lastSweepKick) >= sweepInterval) {
        _kickRefresh();
      }

      if (event != null) {
        final MonitorResult? result = await _handleEvent(event);
        if (result != null) {
          return result;
        }
      }

      _refreshLogTail();
      _render(io);

      // The read and the render are both synchronous, so an idle dashboard
      // would spin here without ever handing control back to the VM: no
      // sweep would ever complete, no snapshot would ever land, and the
      // SIGINT watcher would never fire. This window is what lets all of
      // them run — see [_yieldWindow] for why it is not zero.
      await Future<void>.delayed(_yieldWindow);
    }
  }

  // --- rendering ----------------------------------------------------------

  void _render(TermIo io) {
    final int columns = io.terminalColumns;
    final int lines = io.terminalLines;
    if (columns != _lastColumns || lines != _lastLines) {
      // A resized terminal has already scrambled what is on screen; a
      // line-by-line patch against the old geometry would only add to it.
      // The pointer's last position was measured against the old geometry
      // too, so it goes with it.
      _lastColumns = columns;
      _lastLines = lines;
      _forceFull = true;
      _clearPointer();
    }

    _clampSelection();
    final DateTime wallClock = DateTime.now();
    // Phase from elapsed time, not from an iteration count: a held key or a
    // trackpad flick produces iterations far faster than 250 ms and would
    // otherwise spin the spinner at input rate.
    _frame =
        wallClock.difference(_startedAt).inMilliseconds ~/
        _spinnerPeriod.inMilliseconds;
    final DateTime now = wallClock.toUtc();
    final MonitorModalState? modal = _modal;
    // Nothing behind a modal is clickable, so nothing behind one is drawn as
    // if it were: the base frame is built with no pointer at all and the
    // pointer is spent on the card instead.
    final String? baseHovered = modal == null ? _hoveredId : null;
    final String? basePressed = modal == null ? _pressedId : null;
    final MonitorFrame base = _detailMode
        ? buildDetailFrame(
            instance: _detailInstance,
            history: _historyFor(_detailInstance),
            logLines: _logLines,
            frame: _frame,
            columns: columns,
            lines: lines,
            theme: theme,
            range: _range,
            now: now,
            hoveredId: baseHovered,
            pressedId: basePressed,
          )
        : buildMonitorFrame(
            snapshot: _snapshot,
            selectedIndex: _selectedIndex,
            frame: _frame,
            columns: columns,
            lines: lines,
            theme: theme,
            range: _range,
            now: now,
            hoveredId: baseHovered,
            pressedId: basePressed,
          );
    final MonitorFrame frame = modal == null
        ? base
        : _overlay(modal, base, columns, lines);
    _hitboxes = frame.hitboxes;
    // A hovered or pressed id that this frame does not carry names a region
    // that is no longer on screen — a chip the selection's state swapped out,
    // a row a sweep dropped. Holding on to it would light whatever chip
    // inherits the id next.
    _hoveredId = _liveId(_hoveredId);
    _pressedId = _liveId(_pressedId);

    final String text = frame.rows.join('\n');
    final String patch = renderTerminalPatch(
      previous: _last,
      next: text,
      forceFull: _forceFull,
    );
    _last = text;
    _forceFull = false;
    if (patch.isEmpty) {
      return;
    }
    // Raw mode turns OPOST off, so a bare '\n' drops a line without
    // returning the carriage and stair-steps the frame. Only the full-frame
    // path contains newlines at all — a patch addresses each line by cursor
    // position — so that is the only one that needs them expanded.
    stdout.write(
      patch.startsWith(_fullFramePrefix)
          ? patch.replaceAll('\n', '\r\n')
          : patch,
    );
  }

  /// Composes [modal]'s card over [base], carrying the instance's latest
  /// reading and its flags so the card can gate the actions that depend on
  /// them. The workspace card ignores both.
  MonitorFrame _overlay(
    MonitorModalState modal,
    MonitorFrame base,
    int columns,
    int lines,
  ) {
    final String instance = switch (modal) {
      InstanceModal(instance: final String name) => name,
      WorkspaceModal() => '',
    };
    final InstanceFlags flags = _snapshot.flagsFor(instance);
    return overlayModal(
      base: base,
      modal: modal,
      latest: instance.isEmpty ? null : _latestFor(instance),
      locked: flags.locked,
      isolated: flags.isolated,
      remote: _snapshot.view == MonitorView.remote,
      operationBlockReason: instance.isEmpty
          ? null
          : _snapshot.operationBlockReasonFor(instance),
      theme: theme,
      hoveredId: _hoveredId,
      pressedId: _pressedId,
      columns: columns,
      lines: lines,
    );
  }

  /// [id] when the frame on screen still carries a hitbox with it, null
  /// otherwise.
  String? _liveId(String? id) {
    if (id == null) {
      return null;
    }
    for (final MonitorHitbox hitbox in _hitboxes) {
      if (hitbox.id == id) {
        return id;
      }
    }
    return null;
  }

  // --- state --------------------------------------------------------------

  /// The server-row hitboxes from the most recently rendered frame — the
  /// only kind the main view has to hit-test against today.
  List<MonitorHitbox> _hits() => _hitboxes
      .where((MonitorHitbox hitbox) => hitbox.kind == MonitorHitKind.serverRow)
      .toList(growable: false);

  String? get _selectedInstance {
    final List<String> instances = _snapshot.instances;
    if (instances.isEmpty ||
        _selectedIndex < 0 ||
        _selectedIndex >= instances.length) {
      return null;
    }
    return instances[_selectedIndex];
  }

  void _clampSelection() {
    final int count = _snapshot.instances.length;
    if (count == 0) {
      _selectedIndex = 0;
      return;
    }
    if (_selectedIndex < 0) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= count) {
      _selectedIndex = count - 1;
    }
  }

  void _moveSelection(int delta) {
    final int count = _snapshot.instances.length;
    if (count == 0) {
      return;
    }
    // Clamped, not wrapped: a wheel roll past the last server should stop
    // there rather than jump the selection to the top of the list.
    final int next = _selectedIndex + delta;
    _selectedIndex = next < 0
        ? 0
        : next >= count
        ? count - 1
        : next;
  }

  /// Live history for [instance], preferring the sampler (updated by every
  /// sweep) over the snapshot (only as fresh as the last reload).
  List<MetricSample> _historyFor(String instance) {
    final List<MetricSample> sampled = sampler.history(instance);
    return sampled.isEmpty ? _snapshot.historyFor(instance) : sampled;
  }

  MetricSample? _latestFor(String instance) =>
      sampler.latest(instance) ?? _snapshot.latestFor(instance);

  /// Fires a sweep and a snapshot reload without waiting for either: a slow
  /// capture must not stall the heartbeat. Both are dropped if a refresh is
  /// already running.
  ///
  /// The cadence timestamp moves even on a dropped kick, so a capture that
  /// runs longer than [sweepInterval] is followed by a gap rather than
  /// being re-fired on the very next tick.
  void _kickRefresh() {
    _lastSweepKick = DateTime.now();
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    unawaited(_sweepAndReload());
  }

  Future<void> _sweepAndReload() async {
    try {
      await sampler.sweep();
      final MonitorSnapshot next = await loadSnapshot();
      _snapshot = next;
      _clampSelection();
    } catch (_) {
      // A failed refresh leaves the last good snapshot on screen; the next
      // sweep tries again. A broken reload must never end the session.
    } finally {
      _refreshing = false;
    }
  }

  /// Refreshes the detail view's log tail at most once per [_logTailInterval],
  /// off the render path so a slow read cannot stall the heartbeat.
  void _refreshLogTail() {
    if (!_detailMode || _readingLog) {
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? readAt = _logReadAt;
    if (readAt != null && now.difference(readAt) < _logTailInterval) {
      return;
    }
    _logReadAt = now;

    final String instance = _detailInstance;
    final String? logPath = _latestFor(instance)?.logPath;
    if (logPath == null || logPath.isEmpty) {
      _logLines = const <String>['no log yet'];
      return;
    }
    _readingLog = true;
    unawaited(_readLogTailInto(instance, logPath));
  }

  Future<void> _readLogTailInto(String instance, String logPath) async {
    try {
      final List<String> lines = await readLogTail(logPath, _logTailLines);
      if (!_detailMode || _detailInstance != instance) {
        // The view moved on while the read was in flight. Publishing now
        // would put one server's log under another server's header.
        return;
      }
      _logLines = lines;
    } catch (_) {
      // Unreadable right now (rotated, permissions): keep showing the last
      // tail we got rather than blanking the panel.
    } finally {
      _readingLog = false;
    }
  }

  // --- input --------------------------------------------------------------

  Future<MonitorResult?> _handleEvent(TermEvent event) async {
    _clampSelection();
    if (event.kind == TermEventKind.mouseMove) {
      _hoveredId = _hitAt(event);
      return null;
    }
    if (event.kind == TermEventKind.mouseDown) {
      _handleMouseDown(event);
      return null;
    }
    if (event.kind == TermEventKind.mouseUp) {
      return _handleMouseUp(event);
    }
    final MonitorAction action = monitorActionForEvent(event);
    if (event.kind == TermEventKind.wheelUp ||
        event.kind == TermEventKind.wheelDown) {
      return _handleWheel(event, action);
    }
    return _handleAction(action);
  }

  /// The id of the region under [event]'s pointer, or null when it is over
  /// nothing clickable. Terminal coordinates are 1-based and hitboxes are
  /// 0-based, which is the whole of the conversion.
  String? _hitAt(TermEvent event) =>
      hitTest(_hitboxes, row: event.row - 1, col: event.col - 1);

  /// Arms the region under the pointer. Nothing runs on the way down: an
  /// action fires only when the button comes back up over the same region,
  /// so a press that slides off is a press the user took back.
  ///
  /// The hover moves too, for the terminals that report presses but not
  /// motion — without it the chip being pressed would never light.
  void _handleMouseDown(TermEvent event) {
    if (event.button != 0) {
      return;
    }
    final String? id = _hitAt(event);
    _hoveredId = id;
    _pressedId = id;
  }

  /// Releases the armed region, and activates it when the pointer came back
  /// up over the same one.
  Future<MonitorResult?> _handleMouseUp(TermEvent event) async {
    final String? pressed = _pressedId;
    _pressedId = null;
    final String? id = _hitAt(event);
    _hoveredId = id;
    if (pressed == null || id != pressed) {
      return null;
    }
    return _activate(pressed);
  }

  /// The wheel means "scroll the list" over the server list and "change the
  /// window" anywhere else, because everywhere else is charts. In the detail
  /// view the whole screen is charts, so it always changes the window. With
  /// a modal open it means nothing at all: the dashboard behind the card is
  /// not being read, and silently re-windowing its charts is not an answer
  /// to a scroll aimed at the card.
  ///
  /// The list is no longer the full width of the frame: it is a slim panel
  /// with the selected server's chart beside it, sharing its rows. So the
  /// pointer has to be inside the list's columns as well as its rows —
  /// testing rows alone would turn a wheel over the chart into a selection
  /// change. Both bounds come from the server-row hitboxes themselves rather
  /// than from a constant here, so they cannot drift from what was drawn.
  /// The row band is one row wider at each end than the hitboxes: a clipped
  /// list spends that row on a `+N more` marker, which is part of the list
  /// even though it is deliberately not a click target.
  MonitorResult? _handleWheel(TermEvent event, MonitorAction action) {
    if (_modal != null) {
      return null;
    }
    if (!_detailMode) {
      final List<MonitorHitbox> hits = _hits();
      if (hits.isNotEmpty) {
        final MonitorHitbox first = hits.first;
        final int row = event.row - 1;
        final int col = event.col - 1;
        if (col >= first.colStart &&
            col < first.colEnd &&
            row >= first.row - 1 &&
            row <= hits.last.row + 1) {
          _moveSelection(action == MonitorAction.up ? -1 : 1);
          return null;
        }
      }
    }
    _range = nextRange(_range);
    return null;
  }

  // --- activation ----------------------------------------------------------

  /// Runs whatever [id] names. The modal owns every id while it is open, so
  /// the two routes never overlap.
  Future<MonitorResult?> _activate(String id) async {
    final MonitorModalState? modal = _modal;
    return modal == null ? _activateBase(id) : _activateModal(modal, id);
  }

  /// Activation on the dashboard itself: server rows, the selection bar, the
  /// workspace bar, and the range chip.
  ///
  /// Every case is one of [monitorBarHitIds] (or [rangeHitId], or a
  /// [serverHitPrefix] row), named from `monitor_hitbox.dart` — the same
  /// constants the builders draw their chips from, so this switch and the
  /// bars cannot drift apart on an id.
  Future<MonitorResult?> _activateBase(String id) async {
    if (id.startsWith(serverHitPrefix)) {
      _activateServerRow(id.substring(serverHitPrefix.length));
      return null;
    }
    switch (id) {
      case actStartHitId:
        return _runInstanceAction(InstanceModalAction.start);
      case actStopHitId:
        return _runInstanceAction(InstanceModalAction.stop);
      case actRestartHitId:
        return _runInstanceAction(InstanceModalAction.restart);
      case actConsoleHitId:
        return _runInstanceAction(InstanceModalAction.console);
      case actDetailHitId:
        _enterDetail();
      case actMoreHitId:
        _openInstanceModal(_actionTarget());
      case wsNewHitId:
        return _runWorkspaceAction(WorkspaceModalAction.newInstance);
      case wsBuildsHitId:
        return _runWorkspaceAction(WorkspaceModalAction.pullBuilds);
      case wsTuningHitId:
        return _runWorkspaceAction(WorkspaceModalAction.buildTuning);
      case wsConsumerHitId:
        // The one hand-off that still ends the session: a new profile means
        // a new sampler and a new trend store.
        return const MonitorSwitchConsumer();
      case wsConsolesHitId:
        return _runQuickAction(MonitorAction.consolesGrid);
      case wsConnectHitId:
        return _runWorkspaceAction(WorkspaceModalAction.connect);
      case wsMoreHitId:
        _modal = const WorkspaceModal();
        _clearPointer();
      case rangeHitId:
        _range = nextRange(_range);
    }
    return null;
  }

  /// A click on a server row selects it; a click on the row that is already
  /// selected opens its card. A row naming an instance the snapshot no
  /// longer has does nothing.
  void _activateServerRow(String instance) {
    final int index = _snapshot.instances.indexOf(instance);
    if (index < 0) {
      return;
    }
    if (index == _selectedIndex) {
      _openInstanceModal(instance);
      return;
    }
    _selectedIndex = index;
  }

  /// Activation inside a modal card: a button runs its action, the card
  /// itself swallows the click, and anything outside the card dismisses.
  ///
  /// The card is always closed *before* the flow runs. The flow takes the
  /// terminal, so leaving the card up would only mean redrawing it on the
  /// way back — and the reading it was drawn from is the one the action is
  /// about to invalidate.
  Future<MonitorResult?> _activateModal(
    MonitorModalState modal,
    String id,
  ) async {
    if (id == modalScrimHitId) {
      _closeModal();
      return null;
    }
    if (id == modalCardHitId) {
      return null;
    }
    switch (modal) {
      case InstanceModal(instance: final String instance):
        final InstanceModalAction? action = instanceModalActionForId(id);
        if (action == null) {
          return null;
        }
        if (_instanceOperationBlocked(instance, action)) {
          return null;
        }
        _closeModal();
        final bool invalidated = await _suspended(
          () => instanceAction(instance, action),
        );
        return invalidated ? const MonitorSwitchConsumer() : null;
      case WorkspaceModal():
        final WorkspaceModalAction? action = workspaceModalActionForId(id);
        if (action == null) {
          return null;
        }
        _closeModal();
        final bool invalidated = await _suspended(
          () => workspaceAction(action),
        );
        return invalidated ? const MonitorSwitchConsumer() : null;
    }
  }

  /// Runs [action] against whichever instance the view is pointed at, on a
  /// suspended terminal. Without a target there is nothing to act on.
  Future<MonitorResult?> _runInstanceAction(InstanceModalAction action) async {
    final String? target = _actionTarget();
    if (target == null || _instanceOperationBlocked(target, action)) {
      return null;
    }
    final bool invalidated = await _suspended(
      () => instanceAction(target, action),
    );
    return invalidated ? const MonitorSwitchConsumer() : null;
  }

  Future<MonitorResult?> _runWorkspaceAction(
    WorkspaceModalAction action,
  ) async {
    final bool invalidated = await _suspended(() => workspaceAction(action));
    return invalidated ? const MonitorSwitchConsumer() : null;
  }

  void _openInstanceModal(String? instance) {
    if (instance == null || instance.isEmpty) {
      return;
    }
    _modal = InstanceModal(instance);
    _clearPointer();
  }

  void _closeModal() {
    _modal = null;
    _clearPointer();
  }

  void _enterDetail() {
    if (_detailMode) {
      return;
    }
    final String? instance = _selectedInstance;
    if (instance == null) {
      return;
    }
    _detailMode = true;
    _detailInstance = instance;
    _logLines = const <String>[];
    _logReadAt = null;
  }

  Future<MonitorResult?> _handleAction(MonitorAction action) async {
    if (_modal != null) {
      // A modal is mouse-first: its buttons have no keys of their own yet
      // (keyboard navigation of the card is future work). Escape takes the
      // card down, quit still quits, and everything else is inert rather
      // than reaching the dashboard underneath it.
      if (action == MonitorAction.back) {
        _closeModal();
        return null;
      }
      return action == MonitorAction.quit ? const MonitorQuit() : null;
    }
    switch (action) {
      case MonitorAction.up:
        _moveSelection(-1);
        return null;
      case MonitorAction.down:
        _moveSelection(1);
        return null;
      case MonitorAction.open:
        // What `enter` used to hand back to the caller is now a card drawn
        // over this frame: same actions, without leaving the dashboard.
        _openInstanceModal(_actionTarget());
        return null;
      case MonitorAction.detail:
        _enterDetail();
        return null;
      case MonitorAction.back:
        if (!_detailMode) {
          return const MonitorQuit();
        }
        _detailMode = false;
        _detailInstance = '';
        _logLines = const <String>[];
        _logReadAt = null;
        return null;
      case MonitorAction.restart:
      case MonitorAction.stop:
      case MonitorAction.kill:
      case MonitorAction.console:
      case MonitorAction.consolesGrid:
        return _runQuickAction(action);
      case MonitorAction.newInstance:
        return _runWorkspaceAction(WorkspaceModalAction.newInstance);
      case MonitorAction.buildMenu:
        return _runWorkspaceAction(WorkspaceModalAction.buildTuning);
      case MonitorAction.workspaceCard:
        // The keyboard twin of `[ MORE ]` on the workspace bar — and, like
        // that chip, a landing-view affordance. The detail view draws no
        // workspace bar, so `w` there would raise a card over a frame that
        // offers no way to reach it by mouse.
        if (!_detailMode) {
          _modal = const WorkspaceModal();
          _clearPointer();
        }
        return null;
      case MonitorAction.switchView:
        return const MonitorSwitchView();
      case MonitorAction.switchConsumer:
        return const MonitorSwitchConsumer();
      case MonitorAction.cycleRange:
        _range = nextRange(_range);
        return null;
      case MonitorAction.refresh:
        _kickRefresh();
        return null;
      case MonitorAction.quit:
        return const MonitorQuit();
      case MonitorAction.none:
        return null;
    }
  }

  /// The instance a per-instance action applies to: the one being detailed,
  /// or the selected row on the main view. Null when there is nothing to
  /// act on.
  String? _actionTarget() {
    if (_detailMode) {
      return _detailInstance.isEmpty ? null : _detailInstance;
    }
    return _selectedInstance;
  }

  Future<MonitorResult?> _runQuickAction(MonitorAction action) async {
    final String? target = _actionTarget();
    // The consoles grid is a workspace-level view, not a per-instance
    // command: it opens with or without a selection, and the name is only a
    // hint about which pane to focus. Every other quick action needs a
    // target and does nothing without one.
    if (target == null && action != MonitorAction.consolesGrid) {
      return null;
    }
    if (target != null && _quickOperationBlocked(target, action)) {
      return null;
    }
    final bool invalidated = await _suspended(
      () => quickAction(target ?? '', action),
    );
    return invalidated ? const MonitorSwitchConsumer() : null;
  }

  bool _instanceOperationBlocked(String instance, InstanceModalAction action) {
    if (_snapshot.view != MonitorView.remote ||
        _snapshot.operationBlockReasonFor(instance) == null) {
      return false;
    }
    return switch (action) {
      InstanceModalAction.start ||
      InstanceModalAction.stop ||
      InstanceModalAction.restart ||
      InstanceModalAction.console => true,
      _ => false,
    };
  }

  bool _quickOperationBlocked(String instance, MonitorAction action) {
    if (_snapshot.view != MonitorView.remote ||
        _snapshot.operationBlockReasonFor(instance) == null) {
      return false;
    }
    return switch (action) {
      MonitorAction.restart ||
      MonitorAction.stop ||
      MonitorAction.kill ||
      MonitorAction.console => true,
      _ => false,
    };
  }

  /// Hands the terminal back for [flow] and takes it again afterwards.
  ///
  /// The restore half runs in a `finally`, so a flow that throws still
  /// leaves the screen owned and repainted rather than half-suspended.
  Future<bool> _suspended(Future<void> Function() flow) async {
    final TermIo io = TermIo.instance;
    bool invalidated = false;
    _leaveScreen(io);
    try {
      await suspend(flow);
    } finally {
      _enterScreen(io);
      // Whatever the flow drew is gone with the alternate screen swap, and
      // anything typed at it must not reach the dashboard as commands. The
      // pointer went with it too: mouse reporting was off for the whole
      // flow, so where it is now is not known until it next moves.
      _last = null;
      _forceFull = true;
      _clearPointer();
      // Picks up whatever the flow changed — state, ports, lock and
      // isolation flags — on the next sweep's capture.
      invalidated = sessionInvalidated?.call() ?? false;
      if (!invalidated) {
        _kickRefresh();
      }
    }
    return invalidated;
  }
}
