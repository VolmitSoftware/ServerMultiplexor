import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../../utils/terminal/frame_patch.dart';
import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import '../../utils/terminal/theme.dart';
import '../../utils/user_prompt.dart' show PromptBackNavigation;
import '../monitor/log_tail.dart';
import 'project_build_service.dart';
import 'project_dashboard_model.dart';
import 'project_dashboard_prompts.dart';

abstract interface class ProjectDashboardTerminal {
  bool get hasTerminal;
  int get columns;
  int get lines;
  void activate();
  TermEvent? readEventTimeout(Duration timeout);
  void write(String text);
  void restore();
}

class DartProjectDashboardTerminal implements ProjectDashboardTerminal {
  const DartProjectDashboardTerminal();

  TermIo get _io => TermIo.instance;

  @override
  bool get hasTerminal => _io.hasTerminal;
  @override
  int get columns => _io.terminalColumns;
  @override
  int get lines => _io.terminalLines;

  @override
  void activate() {
    _io.installSignalRestore();
    _io.setRawMode(true);
    stdout.write('\x1B[?1049h');
    _io.altScreenActive = true;
    _io.enableMouse();
    _io.drainInput();
    _io.hideCursor();
  }

  @override
  TermEvent? readEventTimeout(Duration timeout) =>
      _io.readEventTimeout(timeout);
  @override
  void write(String text) => stdout.write(text);
  @override
  void restore() => _io.restoreTerminal();
}

typedef ProjectDashboardPrompt =
    Future<List<String>?> Function(
      ProjectDashboardAction action,
      ProjectDashboardSelection selection,
    );

class ProjectDashboard {
  ProjectDashboard({required ProjectBuildService service})
    : this.withCallbacks(
        loadCatalog: service.catalog,
        loadStatus: service.status,
        command: service.command,
      );

  ProjectDashboard.withCallbacks({
    required List<Map<String, Object?>> Function() loadCatalog,
    required Map<String, Object?> Function() loadStatus,
    required ProjectDashboardCommand command,
    ProjectDashboardPrompt? prompt,
    ProjectDashboardTerminal? terminal,
    MonitorTheme? theme,
    Future<List<String>> Function(String, int)? logReader,
    Duration refreshInterval = const Duration(seconds: 1),
    Duration yieldInterval = const Duration(milliseconds: 10),
  }) : _loadCatalog = loadCatalog,
       _loadStatus = loadStatus,
       _command = command,
       _prompt = prompt ?? ProjectDashboardPrompts(command).request,
       _terminal = terminal ?? const DartProjectDashboardTerminal(),
       _theme = theme ?? MonitorTheme.cached,
       _logReader = logReader ?? readLogTail,
       _refreshInterval = refreshInterval,
       _yieldInterval = yieldInterval;

  final List<Map<String, Object?>> Function() _loadCatalog;
  final Map<String, Object?> Function() _loadStatus;
  final ProjectDashboardCommand _command;
  final ProjectDashboardPrompt _prompt;
  final ProjectDashboardTerminal _terminal;
  final MonitorTheme _theme;
  final Future<List<String>> Function(String, int) _logReader;
  final Duration _refreshInterval;
  final Duration _yieldInterval;
  List<Map<String, Object?>> _catalog = <Map<String, Object?>>[];
  List<Map<String, Object?>> _runs = <Map<String, Object?>>[];
  List<ProjectDashboardRow> _rows = <ProjectDashboardRow>[];
  List<String> _logs = <String>[];
  Map<String, Object?>? _run;
  ProjectDashboardFrame? _frame;
  String? _selectedKey;
  String? _runId;
  String? _previousFrame;
  String _notice =
      'Builds run independently. Closing this view leaves them running.';
  DateTime? _lastRefresh;
  DateTime? _lastFullFrame;
  DateTime? _lastLogRead;
  bool _stale = false;
  bool _active = false;
  bool _dispatching = false;
  bool _readingLogs = false;
  int _selected = 0;
  int _logOffset = 0;
  int _patchCharacters = 0;
  int _lastColumns = 0;
  int _lastLines = 0;

  Future<void> run() async {
    if (!_terminal.hasTerminal) {
      throw StateError(
        'Projects dashboard requires a terminal. Use projects list or projects status --json.',
      );
    }
    _active = true;
    try {
      _terminal.activate();
      while (_active) {
        _refresh();
        _readLogs();
        _render();
        TermEvent? event = _terminal.readEventTimeout(
          const Duration(milliseconds: 40),
        );
        if (event != null) await _handleEvent(event);
        await Future<void>.delayed(_yieldInterval);
      }
    } on TermInputUnavailable {
      _active = false;
    } finally {
      _active = false;
      _terminal.restore();
    }
  }

  void _refresh() {
    DateTime now = DateTime.now();
    if (_lastRefresh != null &&
        now.difference(_lastRefresh!) < _refreshInterval) {
      return;
    }
    _lastRefresh = now;
    try {
      List<Map<String, Object?>> catalog = _loadCatalog();
      List<Map<String, Object?>> runs = projectMaps(_loadStatus()['runs']);
      _catalog = catalog;
      _runs = runs;
      _run = _runId == null
          ? runs.firstOrNull
          : runs
                .where((Map<String, Object?> run) => run['id'] == _runId)
                .firstOrNull;
      _rows = projectDashboardRows(_catalog, _run);
      int matched = _rows.indexWhere(
        (ProjectDashboardRow row) => row.key == _selectedKey,
      );
      _selected = matched >= 0
          ? matched
          : math.min(_selected, math.max(0, _rows.length - 1));
      _selectedKey = _rows.isEmpty ? null : _rows[_selected].key;
      if (_stale) _notice = 'Project state refreshed.';
      _stale = false;
    } catch (error) {
      _stale = true;
      _notice = 'Project state unavailable: ${projectText(error)}. Retrying.';
    }
  }

  void _readLogs() {
    if (_readingLogs || _rows.isEmpty) return;
    DateTime now = DateTime.now();
    if (_lastLogRead != null &&
        now.difference(_lastLogRead!) < _refreshInterval) {
      return;
    }
    _lastLogRead = now;
    ProjectDashboardRow row = _rows[_selected];
    if (row.logPath.isEmpty) {
      _logs = <String>[
        row.error.isEmpty ? 'No output recorded for ${row.key}.' : row.error,
      ];
      return;
    }
    _readingLogs = true;
    unawaited(_loadLogs(row));
  }

  Future<void> _loadLogs(ProjectDashboardRow row) async {
    try {
      List<String> logs = await _logReader(row.logPath, 500);
      if (_active &&
          row.key == _selectedKey &&
          _rows[_selected].logPath == row.logPath) {
        _logs = logs.map(projectText).toList(growable: false);
      }
    } catch (error) {
      if (_active && row.key == _selectedKey) {
        _logs = <String>['Log unavailable: ${projectText(error)}'];
      }
    } finally {
      _readingLogs = false;
    }
  }

  void _select(int index) {
    if (_rows.isEmpty) return;
    int selected = index.clamp(0, _rows.length - 1);
    if (selected == _selected) return;
    _selected = selected;
    _selectedKey = _rows[_selected].key;
    _logs = <String>[];
    _logOffset = 0;
    _lastLogRead = null;
  }

  Future<void> _handleEvent(TermEvent event) async {
    switch (event.kind) {
      case TermEventKind.escape:
      case TermEventKind.ctrlC:
        _active = false;
      case TermEventKind.arrowUp:
      case TermEventKind.wheelUp:
        _select(_selected - 1);
      case TermEventKind.arrowDown:
      case TermEventKind.wheelDown:
        _select(_selected + 1);
      case TermEventKind.home:
        _select(0);
      case TermEventKind.end:
        _select(_rows.length - 1);
      case TermEventKind.pageUp:
        _logOffset = math.min(math.max(0, _logs.length - 1), _logOffset + 10);
      case TermEventKind.pageDown:
        _logOffset = math.max(0, _logOffset - 10);
      case TermEventKind.enter:
        await _action(ProjectDashboardAction.actions);
      case TermEventKind.mouseDown:
        if (event.button == 0 &&
            event.col > 0 &&
            event.col <= (_frame?.targetColumns ?? 0)) {
          int? row = _frame?.targetRows[event.row - 1];
          if (row != null) {
            if (row == _selected) {
              await _action(ProjectDashboardAction.actions);
            } else {
              _select(row);
            }
          }
        }
      case TermEventKind.char:
        ProjectDashboardAction? action = switch (event.char) {
          'b' => ProjectDashboardAction.build,
          's' => ProjectDashboardAction.scan,
          'h' => ProjectDashboardAction.history,
          'r' => ProjectDashboardAction.retry,
          'c' => ProjectDashboardAction.cancel,
          'd' => ProjectDashboardAction.deploy,
          'l' => ProjectDashboardAction.logs,
          _ => null,
        };
        if (event.char == 'q') _active = false;
        if (event.char == 'R') {
          _lastRefresh = null;
          _previousFrame = null;
        }
        if (action != null) await _action(action);
      default:
        break;
    }
  }

  Future<void> _action(ProjectDashboardAction action) async {
    if (_dispatching) {
      _notice =
          'A command is being submitted. Navigation and log inspection remain available.';
      return;
    }
    List<String>? command;
    _terminal.restore();
    try {
      command = await _prompt(
        action,
        ProjectDashboardSelection(
          row: _rows.isEmpty ? null : _rows[_selected],
          run: _run,
          runs: _runs,
          catalog: _catalog,
        ),
      );
    } on PromptBackNavigation {
      return;
    } catch (error) {
      _notice = 'Action failed: ${projectText(error)}';
      return;
    } finally {
      _terminal.activate();
      _previousFrame = null;
    }
    if (command == null || command.isEmpty) return;
    if (command.first == 'view') {
      _runId = command[1];
      _lastRefresh = null;
      _lastLogRead = null;
      _logs = <String>[];
      return;
    }
    _dispatching = true;
    _notice = 'Submitting ${command.first}...';
    unawaited(_execute(command));
  }

  Future<void> _execute(List<String> arguments) async {
    List<String> output = <String>[];
    List<String> errors = <String>[];
    try {
      int code = await _command(
        arguments,
        output: (String line) {
          output.add(line);
          _notice = projectText(line);
        },
        error: (String line) {
          errors.add(line);
          _notice = projectText(line);
        },
      );
      _notice = projectText(
        code == 0
            ? output.lastOrNull ?? '${arguments.first} completed.'
            : errors.lastOrNull ?? '${arguments.first} failed (exit $code).',
      );
      if (code == 0 && <String>{'build', 'retry'}.contains(arguments.first)) {
        _runId = null;
      }
    } catch (error) {
      _notice = '${arguments.first} failed: ${projectText(error)}';
    } finally {
      _dispatching = false;
      _lastRefresh = null;
      _lastLogRead = null;
    }
  }

  void _render() {
    DateTime now = DateTime.now();
    _frame = renderProjectDashboard(
      columns: _terminal.columns,
      lines: _terminal.lines,
      rows: _rows,
      selected: _selected,
      run: _run,
      logs: _logs
          .take(math.max(0, _logs.length - _logOffset))
          .toList(growable: false),
      notice: _notice,
      stale: _stale,
      theme: _theme,
      now: now,
    );
    String next = _frame!.lines.join('\n');
    String patch = renderTerminalPatch(previous: _previousFrame, next: next);
    bool full =
        _previousFrame == null ||
        _lastColumns != _terminal.columns ||
        _lastLines != _terminal.lines ||
        terminalFullFrameCheckpointDue(
          charactersSinceFullFrame: _patchCharacters,
          nextPatchCharacters: patch.length,
          elapsedSinceFullFrame: _lastFullFrame == null
              ? Duration.zero
              : now.difference(_lastFullFrame!),
        );
    if (full) {
      patch = renderTerminalPatch(previous: null, next: next);
      _patchCharacters = 0;
      _lastFullFrame = now;
    } else {
      _patchCharacters += patch.length;
    }
    _terminal.write(synchronizeTerminalPatch(patch.replaceAll('\n', '\r\n')));
    _previousFrame = next;
    _lastColumns = _terminal.columns;
    _lastLines = _terminal.lines;
  }
}
