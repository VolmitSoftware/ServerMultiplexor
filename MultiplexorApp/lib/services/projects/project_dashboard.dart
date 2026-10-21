import 'dart:async';
import 'dart:math' as math;

import '../../utils/terminal/frame_patch.dart';
import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/theme.dart';
import '../../utils/user_prompt.dart' show PromptBackNavigation;
import '../monitor/log_tail.dart';
import 'project_build_service.dart';
import 'project_build_limits.dart';
import 'project_dashboard_model.dart';
import 'project_dashboard_prompts.dart';
import 'project_terminal.dart';

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
        loadLimits: service.limits,
        loadDestinations: service.destinations,
        command: service.command,
      );

  ProjectDashboard.withCallbacks({
    required List<Map<String, Object?>> Function() loadCatalog,
    required Map<String, Object?> Function() loadStatus,
    required ProjectDashboardCommand command,
    ProjectBuildLimits Function()? loadLimits,
    List<Map<String, Object?>> Function()? loadDestinations,
    ProjectDashboardPrompt? prompt,
    ProjectTerminal? terminal,
    MonitorTheme? theme,
    Future<List<String>> Function(String, int)? logReader,
    Duration refreshInterval = const Duration(seconds: 1),
    Duration yieldInterval = const Duration(milliseconds: 10),
  }) : _loadCatalog = loadCatalog,
       _loadStatus = loadStatus,
       _loadLimits = loadLimits ?? ProjectBuildLimits.defaults,
       _loadDestinations = loadDestinations ?? (() => <Map<String, Object?>>[]),
       _command = command,
       _prompt = prompt ?? ProjectDashboardPrompts(command).request,
       _terminal = terminal ?? const DartProjectTerminal(),
       _theme = theme ?? MonitorTheme.cached,
       _logReader = logReader ?? readLogTail,
       _refreshInterval = refreshInterval,
       _yieldInterval = yieldInterval;

  final List<Map<String, Object?>> Function() _loadCatalog;
  final Map<String, Object?> Function() _loadStatus;
  final ProjectBuildLimits Function() _loadLimits;
  final List<Map<String, Object?>> Function() _loadDestinations;
  final ProjectDashboardCommand _command;
  final ProjectDashboardPrompt _prompt;
  final ProjectTerminal _terminal;
  final MonitorTheme _theme;
  final Future<List<String>> Function(String, int) _logReader;
  final Duration _refreshInterval;
  final Duration _yieldInterval;
  List<Map<String, Object?>> _catalog = <Map<String, Object?>>[];
  List<Map<String, Object?>> _runs = <Map<String, Object?>>[];
  List<ProjectDashboardRow> _rows = <ProjectDashboardRow>[];
  List<ProjectDashboardNode> _nodes = <ProjectDashboardNode>[];
  final Set<String> _checked = <String>{};
  final Set<String> _collapsed = <String>{};
  final Set<String> _knownBranches = <String>{};
  ProjectBuildLimits _limits = ProjectBuildLimits.defaults();
  List<Map<String, Object?>> _destinations = <Map<String, Object?>>[];
  String? _pressedCheckbox;
  String? _pressedDisclosure;
  String? _pressedButton;
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
  bool _showOutput = true;
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
      ProjectBuildLimits limits = _loadLimits();
      List<Map<String, Object?>> destinations = _loadDestinations();
      _catalog = projectDashboardCatalog(catalog);
      _limits = limits;
      _destinations = destinations;
      _runs = runs;
      _run = _runId == null
          ? runs.firstOrNull
          : runs
                .where((Map<String, Object?> run) => run['id'] == _runId)
                .firstOrNull;
      _rows = projectDashboardRows(catalog, _run);
      _checked.retainAll(
        _rows
            .where((ProjectDashboardRow row) => row.registered)
            .map((ProjectDashboardRow row) => row.key),
      );
      Set<String> branches = projectDashboardTree(_rows, <String>{})
          .where((ProjectDashboardNode node) => node.isBranch)
          .map((ProjectDashboardNode node) => node.key)
          .toSet();
      _collapsed.addAll(branches.difference(_knownBranches));
      _collapsed.retainAll(branches);
      _knownBranches
        ..clear()
        ..addAll(branches);
      _rebuildTree();
      if (_stale) _notice = 'Project state refreshed.';
      _stale = false;
    } catch (error) {
      _stale = true;
      _notice = 'Project state unavailable: ${projectText(error)}. Retrying.';
    }
  }

  void _rebuildTree() {
    ProjectDashboardNode? previous = _nodes
        .where((ProjectDashboardNode node) => node.key == _selectedKey)
        .firstOrNull;
    _nodes = projectDashboardTree(_rows, _collapsed);
    int matched = _nodes.indexWhere(
      (ProjectDashboardNode node) => node.key == _selectedKey,
    );
    if (matched < 0 && _selectedKey != null) {
      ProjectDashboardNode? current = projectDashboardTree(_rows, <String>{})
          .where((ProjectDashboardNode node) => node.key == _selectedKey)
          .firstOrNull;
      for (String parent
          in (current?.ancestors ?? previous?.ancestors ?? <String>[])
              .reversed) {
        matched = _nodes.indexWhere(
          (ProjectDashboardNode node) => node.key == parent,
        );
        if (matched >= 0) break;
      }
      if (matched < 0) {
        matched = _nodes.indexWhere(
          (ProjectDashboardNode node) =>
              node.project == _selectedKey!.split(':').first,
        );
      }
    }
    _selected = matched >= 0
        ? matched
        : math.min(_selected, math.max(0, _nodes.length - 1));
    String? nextKey = _nodes.isEmpty ? null : _nodes[_selected].key;
    if (nextKey != _selectedKey) {
      _logs = <String>[];
      _lastLogRead = null;
      _logOffset = 0;
    }
    _selectedKey = nextKey;
  }

  void _readLogs() {
    if (!_showOutput || _readingLogs || _nodes.isEmpty) return;
    DateTime now = DateTime.now();
    if (_lastLogRead != null &&
        now.difference(_lastLogRead!) < _refreshInterval) {
      return;
    }
    _lastLogRead = now;
    ProjectDashboardNode node = _nodes[_selected];
    if (node.isBranch) {
      _logs = <String>[
        '${node.displayLabel}: ${node.buildKeys.where(_checked.contains).length}'
            ' / ${node.buildKeys.length} targets checked',
        for (ProjectDashboardRow row in node.targets)
          '${row.target}: ${row.status}${row.task.isEmpty ? '' : ' / ${row.task}'}',
      ];
      return;
    }
    ProjectDashboardRow row = node.target!;
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
          _nodes[_selected].target?.logPath == row.logPath) {
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
    if (_nodes.isEmpty) return;
    int selected = index.clamp(0, _nodes.length - 1);
    if (selected == _selected) return;
    _selected = selected;
    _selectedKey = _nodes[_selected].key;
    _logs = <String>[];
    _logOffset = 0;
    _lastLogRead = null;
  }

  void _toggleChecked(ProjectDashboardNode node) {
    List<String> keys = node.buildKeys;
    if (keys.isEmpty) {
      _notice =
          'This row is build history and is available for log inspection.';
      return;
    }
    if (keys.every(_checked.contains)) {
      _checked.removeAll(keys);
    } else {
      _checked.addAll(keys);
    }
    _lastLogRead = null;
  }

  void _selectAll({bool toggle = false}) {
    List<String> keys = _rows
        .where((ProjectDashboardRow row) => row.registered)
        .map((ProjectDashboardRow row) => row.key)
        .toList(growable: false);
    if (toggle && keys.every(_checked.contains)) {
      _checked.clear();
    } else {
      _checked.addAll(keys);
    }
    _lastLogRead = null;
  }

  void _expand(bool expanded) {
    if (_nodes.isEmpty) return;
    ProjectDashboardNode node = _nodes[_selected];
    if (!expanded && (!node.isBranch || !node.expanded)) {
      if (node.parentKey != null) {
        _select(
          _nodes.indexWhere(
            (ProjectDashboardNode item) => item.key == node.parentKey,
          ),
        );
      }
      return;
    }
    if (!node.isBranch) return;
    if (expanded && node.expanded) {
      if (node.targets.isNotEmpty) _select(_selected + 1);
      return;
    }
    expanded ? _collapsed.remove(node.key) : _collapsed.add(node.key);
    _rebuildTree();
  }

  String? _checkboxAt(TermEvent event) {
    return _spanAt(event, _frame?.checkboxes);
  }

  String? _spanAt(TermEvent event, Map<int, ButtonSpan>? spans) {
    ButtonSpan? span = spans?[event.row - 1];
    return span != null &&
            event.col - 1 >= span.colStart &&
            event.col - 1 < span.colEnd
        ? span.id
        : null;
  }

  String? _buttonAt(TermEvent event) {
    for (ButtonSpan button
        in _frame?.buttons[event.row - 1] ?? const <ButtonSpan>[]) {
      if (event.col - 1 >= button.colStart && event.col - 1 < button.colEnd) {
        return button.id;
      }
    }
    return null;
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
        _select(_nodes.length - 1);
      case TermEventKind.arrowLeft:
        _expand(false);
      case TermEventKind.arrowRight:
        _expand(true);
      case TermEventKind.pageUp:
        if (_showOutput) {
          _logOffset = math.min(math.max(0, _logs.length - 1), _logOffset + 10);
        }
      case TermEventKind.pageDown:
        if (_showOutput) _logOffset = math.max(0, _logOffset - 10);
      case TermEventKind.enter:
        if (_nodes.isNotEmpty && _nodes[_selected].isBranch) {
          _expand(!_nodes[_selected].expanded);
        } else {
          await _action(ProjectDashboardAction.actions);
        }
      case TermEventKind.mouseDown:
        _pressedCheckbox = null;
        _pressedDisclosure = null;
        _pressedButton = event.button == 0 ? _buttonAt(event) : null;
        if (_pressedButton != null) break;
        _pressedCheckbox = event.button == 0 ? _checkboxAt(event) : null;
        if (_pressedCheckbox != null) {
          int? row = _frame?.targetRows[event.row - 1];
          if (row != null) _select(row);
          break;
        }
        _pressedDisclosure = event.button == 0
            ? _spanAt(event, _frame?.disclosures)
            : null;
        if (_pressedDisclosure != null) {
          _select(_frame!.targetRows[event.row - 1]!);
          break;
        }
        if (event.button == 0 &&
            event.col > 0 &&
            event.col <= (_frame?.targetColumns ?? 0)) {
          int? row = _frame?.targetRows[event.row - 1];
          if (row != null) {
            _select(row);
          }
        }
      case TermEventKind.mouseUp:
        String? disclosure = _pressedDisclosure;
        _pressedDisclosure = null;
        if (event.button == 0 &&
            disclosure != null &&
            disclosure == _spanAt(event, _frame?.disclosures)) {
          _select(
            _nodes.indexWhere(
              (ProjectDashboardNode node) => node.key == disclosure,
            ),
          );
          _expand(!_nodes[_selected].expanded);
        }
        String? button = _pressedButton;
        _pressedButton = null;
        if (event.button == 0 && button != null && button == _buttonAt(event)) {
          if (button == 'back') {
            _active = false;
          } else {
            await _action(ProjectDashboardAction.values.byName(button));
          }
        }
        String? pressed = _pressedCheckbox;
        _pressedCheckbox = null;
        if (event.button == 0 &&
            pressed != null &&
            pressed == _checkboxAt(event)) {
          if (pressed == 'all') {
            _selectAll(toggle: true);
          } else {
            _toggleChecked(
              _nodes.firstWhere(
                (ProjectDashboardNode node) => node.key == pressed,
              ),
            );
          }
        }
      case TermEventKind.char:
        ProjectDashboardAction? action = switch (event.char) {
          'm' => ProjectDashboardAction.actions,
          'b' => ProjectDashboardAction.build,
          's' => ProjectDashboardAction.scan,
          'i' => ProjectDashboardAction.setup,
          'h' => ProjectDashboardAction.history,
          'r' => ProjectDashboardAction.retry,
          'c' => ProjectDashboardAction.cancel,
          'd' => ProjectDashboardAction.deploy,
          'l' => ProjectDashboardAction.logs,
          'p' => ProjectDashboardAction.limits,
          'o' => ProjectDashboardAction.locations,
          _ => null,
        };
        if (event.char == 'q') _active = false;
        if ((event.char == ' ' || event.char == 'v') && _nodes.isNotEmpty) {
          _toggleChecked(_nodes[_selected]);
        }
        if (event.char == 'a') _selectAll();
        if (event.char == 'e' || event.char == 'z') {
          _collapsed.clear();
          if (event.char == 'z') _collapsed.addAll(_knownBranches);
          _rebuildTree();
        }
        if (event.char == 't') {
          _showOutput = !_showOutput;
          _lastLogRead = null;
        }
        if (event.char == 'x') {
          _checked.clear();
          _lastLogRead = null;
        }
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
          row: _nodes.isEmpty ? null : _nodes[_selected].target,
          node: _nodes.isEmpty ? null : _nodes[_selected],
          checkedTargets: List<String>.unmodifiable(
            _rows
                .where((ProjectDashboardRow row) => _checked.contains(row.key))
                .map((ProjectDashboardRow row) => row.key),
          ),
          limits: _limits,
          destinations: _destinations,
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
      nodes: _nodes,
      checked: _checked,
      limits: _limits,
      selected: _selected,
      run: _run,
      logs: _logs
          .take(math.max(0, _logs.length - _logOffset))
          .toList(growable: false),
      notice: _notice,
      stale: _stale,
      theme: _theme,
      now: now,
      pressedButton: _pressedButton,
      showOutput: _showOutput,
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
