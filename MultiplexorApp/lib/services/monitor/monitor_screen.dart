/// The full-screen monitoring dashboard's event loop.
///
/// Everything that can be pure lives elsewhere — key bindings in
/// `monitor_keymap.dart`, frame layout in `monitor_model.dart` and
/// `monitor_detail_model.dart`, sampling in `metrics_sampler.dart`. What is
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
import 'monitor_keymap.dart';
import 'monitor_model.dart';

/// The event-loop heartbeat. Also the input poll timeout: no [Timer] drives
/// this screen, the blocking read's own deadline does.
const Duration _tick = Duration(milliseconds: 250);

/// Metrics are swept every eighth heartbeat, i.e. about every two seconds.
const int _sweepEveryTicks = 8;

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
sealed class MonitorResult {
  const MonitorResult();
}

/// The user quit the dashboard.
class MonitorQuit extends MonitorResult {
  const MonitorQuit();
}

/// The user opened [instance] — the caller runs the per-instance flow.
class MonitorOpenInstance extends MonitorResult {
  const MonitorOpenInstance(this.instance);

  final String instance;
}

/// The user asked to create a new instance.
class MonitorNewInstance extends MonitorResult {
  const MonitorNewInstance();
}

/// The user asked for the build menu.
class MonitorBuildMenu extends MonitorResult {
  const MonitorBuildMenu();
}

/// The user asked to switch consumer profiles.
class MonitorSwitchConsumer extends MonitorResult {
  const MonitorSwitchConsumer();
}

/// Runs the command-center dashboard until the user leaves it.
///
/// Every collaborator is injected: [sampler] supplies metric history,
/// [loadSnapshot] rebuilds the workspace view after each sweep,
/// [quickAction] performs a per-instance command, [readLogTail] reads a log
/// tail for the detail view, and [suspend] runs a legacy flow while this
/// screen is out of the way.
///
/// [suspend] receives a flow to run and is only responsible for running it:
/// the screen brackets the call with its own terminal transitions (leaving
/// the alternate screen and raw mode before, reclaiming both after), so no
/// injected callback can leave the terminal in a half-owned state.
class MonitorScreen {
  MonitorScreen({
    required this.sampler,
    required this.theme,
    required this.loadSnapshot,
    required this.suspend,
    required this.quickAction,
    required this.readLogTail,
  });

  final MetricsSampler sampler;
  final MonitorTheme theme;
  final Future<MonitorSnapshot> Function() loadSnapshot;
  final Future<void> Function(Future<void> Function() flow) suspend;
  final Future<void> Function(String instance, MonitorAction action)
  quickAction;
  final Future<List<String>> Function(String logPath, int maxLines) readLogTail;

  MonitorSnapshot _snapshot = const MonitorSnapshot(
    instances: <String>[],
    history: <String, List<MetricSample>>{},
    consumerName: '',
  );

  /// The frame text last written, i.e. what the terminal is showing. Null
  /// means "nothing trustworthy on screen": the next render is a full one.
  String? _last;

  int _selectedIndex = 0;
  int _frame = 0;
  Duration _range = monitorRanges.first;
  bool _forceFull = true;
  int _lastColumns = -1;
  int _lastLines = -1;

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

    io.installSignalRestore();
    _enterScreen(io);
    try {
      return await _loop(io);
    } finally {
      _leaveScreen(io);
      io.restoreTerminal();
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
    _clampSelection();
  }

  void _enterScreen(TermIo io) {
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
    _kickRefresh();
    _render(io);

    while (true) {
      TermEvent? event;
      try {
        event = io.readEventTimeout(_tick);
      } on TermInputUnavailable {
        // stdin died under us (terminal closed, session detached): there is
        // no dashboard left to drive.
        return const MonitorQuit();
      }

      _frame += 1;
      if (_frame % _sweepEveryTicks == 0) {
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
      // SIGINT watcher would never fire. One zero-duration delay per tick
      // drains everything the event loop has queued up.
      await Future<void>.delayed(Duration.zero);
    }
  }

  // --- rendering ----------------------------------------------------------

  void _render(TermIo io) {
    final int columns = io.terminalColumns;
    final int lines = io.terminalLines;
    if (columns != _lastColumns || lines != _lastLines) {
      // A resized terminal has already scrambled what is on screen; a
      // line-by-line patch against the old geometry would only add to it.
      _lastColumns = columns;
      _lastLines = lines;
      _forceFull = true;
    }

    _clampSelection();
    final DateTime now = DateTime.now().toUtc();
    final List<String> rows = _detailMode
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
          );

    final String text = rows.join('\n');
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

  // --- state --------------------------------------------------------------

  List<MonitorHitRow> _hits() => monitorServerRowHits(
    snapshot: _snapshot,
    columns: _lastColumns,
    lines: _lastLines,
  );

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
  void _kickRefresh() {
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

    final String? logPath = _latestFor(_detailInstance)?.logPath;
    if (logPath == null || logPath.isEmpty) {
      _logLines = const <String>['no log yet'];
      return;
    }
    _readingLog = true;
    unawaited(_readLogTailInto(logPath));
  }

  Future<void> _readLogTailInto(String logPath) async {
    try {
      _logLines = await readLogTail(logPath, _logTailLines);
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
    if (event.kind == TermEventKind.mouseDown) {
      return _handleMouseDown(event);
    }
    final MonitorAction action = monitorActionForEvent(event);
    if (event.kind == TermEventKind.wheelUp ||
        event.kind == TermEventKind.wheelDown) {
      return _handleWheel(event, action);
    }
    return _handleAction(action);
  }

  /// A left click on a server row selects it; a second click on the row
  /// that is already selected opens it. Clicks anywhere else are ignored.
  MonitorResult? _handleMouseDown(TermEvent event) {
    if (_detailMode || event.button != 0) {
      return null;
    }
    final int row = event.row - 1;
    for (final MonitorHitRow hit in _hits()) {
      if (hit.row != row) {
        continue;
      }
      if (hit.instanceIndex == _selectedIndex) {
        final String? instance = _selectedInstance;
        return instance == null ? null : MonitorOpenInstance(instance);
      }
      _selectedIndex = hit.instanceIndex;
      return null;
    }
    return null;
  }

  /// The wheel means "scroll the list" over the servers panel and "change
  /// the window" anywhere else, because everywhere else is charts. In the
  /// detail view the whole screen is charts, so it always changes the
  /// window.
  MonitorResult? _handleWheel(TermEvent event, MonitorAction action) {
    if (!_detailMode) {
      final List<MonitorHitRow> hits = _hits();
      if (hits.isNotEmpty) {
        final int row = event.row - 1;
        if (row >= hits.first.row && row <= hits.last.row) {
          _moveSelection(action == MonitorAction.up ? -1 : 1);
          return null;
        }
      }
    }
    _range = nextRange(_range);
    return null;
  }

  Future<MonitorResult?> _handleAction(MonitorAction action) async {
    switch (action) {
      case MonitorAction.up:
        _moveSelection(-1);
        return null;
      case MonitorAction.down:
        _moveSelection(1);
        return null;
      case MonitorAction.open:
        final String? target = _actionTarget();
        return target == null ? null : MonitorOpenInstance(target);
      case MonitorAction.detail:
        if (_detailMode) {
          return null;
        }
        final String? instance = _selectedInstance;
        if (instance == null) {
          return null;
        }
        _detailMode = true;
        _detailInstance = instance;
        _logLines = const <String>[];
        _logReadAt = null;
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
        await _runQuickAction(action);
        return null;
      case MonitorAction.newInstance:
        return const MonitorNewInstance();
      case MonitorAction.buildMenu:
        return const MonitorBuildMenu();
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

  Future<void> _runQuickAction(MonitorAction action) async {
    final String? target = _actionTarget();
    if (target == null) {
      return;
    }
    await _suspended(() => quickAction(target, action));
  }

  /// Hands the terminal back for [flow] and takes it again afterwards.
  ///
  /// The restore half runs in a `finally`, so a flow that throws still
  /// leaves the screen owned and repainted rather than half-suspended.
  Future<void> _suspended(Future<void> Function() flow) async {
    final TermIo io = TermIo.instance;
    _leaveScreen(io);
    try {
      await suspend(flow);
    } finally {
      _enterScreen(io);
      // Whatever the flow drew is gone with the alternate screen swap, and
      // anything typed at it must not reach the dashboard as commands.
      _last = null;
      _forceFull = true;
      _kickRefresh();
    }
  }
}
