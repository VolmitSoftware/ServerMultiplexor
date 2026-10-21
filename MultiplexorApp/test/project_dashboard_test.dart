import 'dart:async';
import 'dart:collection';

import 'package:multiplexor/services/projects/project_dashboard.dart';
import 'package:multiplexor/services/projects/project_dashboard_prompts.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  test(
    'navigation and detach work while a command is being submitted',
    () async {
      _Terminal terminal = _Terminal();
      Completer<int> command = Completer<int>();
      List<List<String>> calls = <List<String>>[];
      List<String> reads = <String>[];
      Future<void> running = _screen(
        terminal,
        command:
            (
              List<String> args, {
              required void Function(String) output,
              required void Function(String) error,
            }) {
              calls.add(args);
              return command.future;
            },
        prompt:
            (
              ProjectDashboardAction action,
              ProjectDashboardSelection selection,
            ) async => <String>[
              'build',
              selection.row!.project,
              '--target',
              selection.row!.target,
            ],
        logReader: (String path, int count) async {
          reads.add(path);
          return <String>['Output $path'];
        },
      ).run();
      await _until(() => terminal.output.contains('Iris / bukkit'));
      terminal.input.add(const TermEvent(TermEventKind.char, char: 'b'));
      await _until(() => calls.isNotEmpty);
      terminal.input.add(const TermEvent(TermEventKind.arrowDown));
      await _until(() => reads.contains('/fabric.log'));
      terminal.input.add(const TermEvent(TermEventKind.char, char: 'q'));
      await running;
      expect(calls, <List<String>>[
        <String>['build', 'iris', '--target', 'bukkit'],
      ]);
      expect(terminal.output, contains('Output /fabric.log'));
      expect(terminal.output, contains('\r\n'));
      expect(RegExp(r'(?<!\r)\n').hasMatch(terminal.output), isFalse);
      expect(command.isCompleted, isFalse);
      command.complete(0);
      expect(terminal.restores, greaterThan(0));
    },
  );

  test('state capture failures preserve rows and recover in place', () async {
    _Terminal terminal = _Terminal();
    bool fail = false;
    Future<void> running = _screen(
      terminal,
      loadStatus: () {
        if (fail) throw StateError('manifest temporarily unavailable');
        return _status;
      },
    ).run();
    await _until(() => terminal.output.contains('Iris / bukkit'));
    fail = true;
    await _until(() => terminal.output.contains('STALE:'));
    fail = false;
    await _until(() => terminal.output.contains('Project state refreshed.'));
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
    expect(terminal.restores, 1);
  });

  test('cancel is dispatched only when the prompt confirms it', () async {
    _Terminal terminal = _Terminal();
    List<List<String>> calls = <List<String>>[];
    int prompts = 0;
    Future<void> running = _screen(
      terminal,
      command:
          (
            List<String> args, {
            required void Function(String) output,
            required void Function(String) error,
          }) async {
            calls.add(args);
            return 0;
          },
      prompt:
          (
            ProjectDashboardAction action,
            ProjectDashboardSelection selection,
          ) async {
            expect(action, ProjectDashboardAction.cancel);
            prompts++;
            return prompts == 1
                ? null
                : <String>['cancel', selection.run!['id']! as String];
          },
    ).run();
    terminal.input.add(const TermEvent(TermEventKind.char, char: 'c'));
    await _until(() => prompts == 1);
    expect(calls, isEmpty);
    terminal.input.add(const TermEvent(TermEventKind.char, char: 'c'));
    await _until(() => calls.length == 1);
    terminal.input.add(const TermEvent(TermEventKind.ctrlC));
    await running;
    expect(calls.single, <String>['cancel', 'run-1']);
  });

  test('mouse selects targets without activating the log pane', () async {
    _Terminal terminal = _Terminal()..columns = 140;
    List<String> selections = <String>[];
    Future<void> running = _screen(
      terminal,
      prompt:
          (
            ProjectDashboardAction action,
            ProjectDashboardSelection selection,
          ) async {
            selections.add(selection.row!.key);
            return null;
          },
    ).run();
    terminal.input.add(
      const TermEvent(TermEventKind.mouseDown, row: 7, col: 110),
    );
    terminal.input.add(
      const TermEvent(TermEventKind.mouseDown, row: 7, col: 15),
    );
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _until(() => selections.isNotEmpty);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
    expect(selections, <String>['iris:fabric']);
  });
}

ProjectDashboard _screen(
  _Terminal terminal, {
  ProjectDashboardCommand? command,
  ProjectDashboardPrompt? prompt,
  Map<String, Object?> Function()? loadStatus,
  Future<List<String>> Function(String, int)? logReader,
}) => ProjectDashboard.withCallbacks(
  loadCatalog: () => _catalog,
  loadStatus: loadStatus ?? () => _status,
  command:
      command ??
      (
        List<String> args, {
        required void Function(String) output,
        required void Function(String) error,
      }) async => 0,
  prompt:
      prompt ??
      (
        ProjectDashboardAction action,
        ProjectDashboardSelection selection,
      ) async => null,
  terminal: terminal,
  theme: MonitorTheme.plainAscii(),
  logReader:
      logReader ?? (String path, int count) async => <String>['Build output'],
  refreshInterval: const Duration(milliseconds: 2),
  yieldInterval: const Duration(milliseconds: 1),
);

final List<Map<String, Object?>> _catalog = <Map<String, Object?>>[
  <String, Object?>{
    'id': 'iris',
    'name': 'Iris',
    'targets': <Object?>[
      <String, Object?>{'id': 'bukkit'},
      <String, Object?>{'id': 'fabric'},
    ],
  },
];

final Map<String, Object?> _status = <String, Object?>{
  'runs': <Object?>[
    <String, Object?>{
      'id': 'run-1',
      'status': 'running',
      'jobs': <Object?>[
        for (String target in <String>['bukkit', 'fabric'])
          <String, Object?>{
            'key': 'iris:$target',
            'project': 'iris',
            'target': target,
            'status': 'running',
            'logPath': '/$target.log',
          },
      ],
    },
  ],
};

class _Terminal implements ProjectDashboardTerminal {
  final Queue<TermEvent> input = Queue<TermEvent>();
  final StringBuffer _output = StringBuffer();
  int restores = 0;
  String get output => _output.toString();

  @override
  bool get hasTerminal => true;
  @override
  int columns = 100;
  @override
  int lines = 24;
  @override
  void activate() {}
  @override
  TermEvent? readEventTimeout(Duration timeout) =>
      input.isEmpty ? null : input.removeFirst();
  @override
  void write(String text) => _output.write(text);
  @override
  void restore() => restores++;
}

Future<void> _until(bool Function() condition) async {
  DateTime end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Dashboard did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
