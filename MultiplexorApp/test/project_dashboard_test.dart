import 'dart:async';
import 'dart:collection';

import 'package:multiplexor/services/projects/project_build_limits.dart';
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
      await _until(() => terminal.output.contains('Iris'));
      terminal.input.add(const TermEvent(TermEventKind.arrowDown));
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
    await _until(() => terminal.output.contains('Iris'));
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
      const TermEvent(TermEventKind.mouseDown, row: 8, col: 110),
    );
    terminal.input.add(
      const TermEvent(TermEventKind.mouseDown, row: 8, col: 15),
    );
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _until(() => selections.isNotEmpty);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
    expect(selections, <String>['iris:fabric']);
  });

  test(
    'Back button exits on release and restores narrow and wide terminals',
    () async {
      for (int width in <int>[48, 80]) {
        _Terminal terminal = _Terminal()..columns = width;
        Future<void> running = _start(_screen(terminal), terminal);
        await _until(() => terminal.output.contains('BACK'));
        terminal.input.add(
          TermEvent(TermEventKind.mouseDown, row: terminal.lines - 1, col: 3),
        );
        await _until(() => terminal.input.isEmpty);
        expect(terminal.restores, 0);
        terminal.input.add(
          TermEvent(TermEventKind.mouseUp, row: terminal.lines - 1, col: 3),
        );
        await running.timeout(const Duration(seconds: 3));
        expect(terminal.restores, 1);
      }
    },
  );

  test(
    'action buttons open their prompts after matching left release',
    () async {
      _Terminal terminal = _Terminal()..columns = 80;
      List<ProjectDashboardAction> actions = <ProjectDashboardAction>[];
      Future<void> running = _start(
        _screen(
          terminal,
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                actions.add(action);
                return null;
              },
        ),
        terminal,
      );
      await _until(() => terminal.output.contains('LOCATIONS'));
      for ((int, ProjectDashboardAction) button
          in <(int, ProjectDashboardAction)>[
            (15, ProjectDashboardAction.build),
            (27, ProjectDashboardAction.limits),
            (40, ProjectDashboardAction.locations),
            (55, ProjectDashboardAction.actions),
          ]) {
        int count = actions.length;
        terminal.input.add(
          TermEvent(
            TermEventKind.mouseDown,
            row: terminal.lines - 1,
            col: button.$1,
          ),
        );
        await _until(() => terminal.input.isEmpty);
        expect(actions.length, count);
        terminal.input.add(
          TermEvent(
            TermEventKind.mouseUp,
            row: terminal.lines - 1,
            col: button.$1,
          ),
        );
        await _until(() => actions.length == count + 1);
        expect(actions.last, button.$2);
      }
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'dragging away and unmatched releases do not activate action buttons',
    () async {
      _Terminal terminal = _Terminal()..columns = 80;
      List<ProjectDashboardAction> actions = <ProjectDashboardAction>[];
      Future<void> running = _start(
        _screen(
          terminal,
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                actions.add(action);
                return null;
              },
        ),
        terminal,
      );
      await _until(() => terminal.output.contains('LOCATIONS'));
      int row = terminal.lines - 1;
      for (List<TermEvent> gesture in <List<TermEvent>>[
        <TermEvent>[TermEvent(TermEventKind.mouseUp, row: row, col: 15)],
        <TermEvent>[
          TermEvent(TermEventKind.mouseDown, row: row, col: 15),
          TermEvent(TermEventKind.mouseUp, row: row - 1, col: 15),
        ],
        <TermEvent>[
          TermEvent(TermEventKind.mouseDown, row: row, col: 15),
          TermEvent(TermEventKind.mouseUp, row: row, col: 27),
        ],
        <TermEvent>[
          TermEvent(TermEventKind.mouseDown, row: row, col: 15, button: 2),
          TermEvent(TermEventKind.mouseUp, row: row, col: 15, button: 2),
        ],
        <TermEvent>[
          TermEvent(TermEventKind.mouseDown, row: row, col: 3),
          TermEvent(TermEventKind.mouseUp, row: row, col: 80),
        ],
      ]) {
        terminal.input.addAll(gesture);
        terminal.input.add(const TermEvent(TermEventKind.enter));
        int count = actions.length;
        await _until(() => actions.length > count);
        expect(actions.length, count + 1);
        expect(actions.last, ProjectDashboardAction.actions);
      }
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'project and target checkboxes support partial and mixed-project builds',
    () async {
      _Terminal terminal = _Terminal();
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadCatalog: () => <Map<String, Object?>>[..._catalog, _wormholes],
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                selections.add(selection);
                return null;
              },
        ),
        terminal,
      );
      ProjectDashboardSelection wholeProject = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.char, char: ' ')],
      );
      expect(wholeProject.node!.key, 'iris:');
      expect(wholeProject.row, isNull);
      expect(wholeProject.checkedTargets, <String>[
        'iris:bukkit',
        'iris:fabric',
      ]);

      ProjectDashboardSelection partial =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.arrowDown),
            const TermEvent(TermEventKind.char, char: 'v'),
          ]);
      expect(partial.node!.key, 'iris:bukkit');
      expect(partial.checkedTargets, <String>['iris:fabric']);

      terminal.input.addAll(<TermEvent>[
        const TermEvent(TermEventKind.end),
        const TermEvent(TermEventKind.arrowLeft),
        const TermEvent(TermEventKind.char, char: ' '),
        const TermEvent(TermEventKind.char, char: 'b'),
      ]);
      await _until(() => selections.length == 3);
      expect(selections.last.node!.key, 'wormholes:');
      expect(selections.last.checkedTargets, <String>[
        'iris:fabric',
        'wormholes:bukkit',
        'wormholes:forge',
      ]);
      expect(selections.last.limits.toJson(), <String, Object?>{
        'schema': 1,
        'jobs': 3,
        'memoryMiB': 12288,
        'workers': 6,
      });
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'arrows traverse parents and collapse without losing checked children',
    () async {
      _Terminal terminal = _Terminal();
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadCatalog: () => <Map<String, Object?>>[..._catalog, _wormholes],
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                selections.add(selection);
                return null;
              },
        ),
        terminal,
      );
      ProjectDashboardSelection collapsed =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.char, char: ' '),
            const TermEvent(TermEventKind.arrowLeft),
          ]);
      expect(collapsed.node!.key, 'iris:');
      expect(collapsed.node!.expanded, isFalse);
      expect(collapsed.checkedTargets, <String>['iris:bukkit', 'iris:fabric']);
      ProjectDashboardSelection nextProject = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.arrowDown)],
      );
      expect(nextProject.node!.key, 'wormholes:');
      ProjectDashboardSelection expanded =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.home),
            const TermEvent(TermEventKind.arrowRight),
          ]);
      expect(expanded.node!.key, 'iris:');
      expect(expanded.node!.expanded, isTrue);
      ProjectDashboardSelection child = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.arrowRight)],
      );
      expect(child.row!.key, 'iris:bukkit');
      ProjectDashboardSelection parent = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.arrowLeft)],
      );
      expect(parent.node!.key, 'iris:');
      expect(parent.node!.expanded, isTrue);
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'all includes collapsed and offscreen targets and clear removes them',
    () async {
      _Terminal terminal = _Terminal()
        ..columns = 48
        ..lines = 14;
      List<Map<String, Object?>> catalog = <Map<String, Object?>>[
        ..._catalog,
        _wormholes,
        for (int index = 0; index < 12; index++)
          <String, Object?>{
            'id': 'project-$index',
            'name': 'Project $index',
            'targets': <Object?>[
              <String, Object?>{'id': 'jar'},
            ],
          },
      ];
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadCatalog: () => catalog,
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                selections.add(selection);
                return null;
              },
        ),
        terminal,
      );
      ProjectDashboardSelection all =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.arrowLeft),
            const TermEvent(TermEventKind.char, char: 'a'),
          ]);
      expect(all.checkedTargets, <String>[
        'iris:bukkit',
        'iris:fabric',
        'wormholes:bukkit',
        'wormholes:forge',
        for (int index = 0; index < 12; index++) 'project-$index:jar',
      ]);
      ProjectDashboardSelection repeated = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.char, char: 'a')],
      );
      expect(repeated.checkedTargets, all.checkedTargets);
      ProjectDashboardSelection cleared = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.char, char: 'x')],
      );
      expect(cleared.checkedTargets, isEmpty);
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'checks follow target identities across reorder and prune removed targets',
    () async {
      _Terminal terminal = _Terminal();
      List<Map<String, Object?>> catalog = <Map<String, Object?>>[
        ..._catalog,
        _wormholes,
      ];
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadCatalog: () => catalog,
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                selections.add(selection);
                return null;
              },
        ),
        terminal,
      );
      await _capture(terminal, selections, <TermEvent>[
        const TermEvent(TermEventKind.char, char: 'a'),
        const TermEvent(TermEventKind.arrowDown),
      ]);
      catalog = <Map<String, Object?>>[
        _wormholes,
        <String, Object?>{
          'id': 'iris',
          'name': 'Iris',
          'targets': <Object?>[
            <String, Object?>{'id': 'fabric'},
            <String, Object?>{'id': 'bukkit'},
            <String, Object?>{'id': 'neoforge'},
          ],
        },
      ];
      ProjectDashboardSelection reordered = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.char, char: 'R')],
      );
      expect(reordered.row!.key, 'iris:bukkit');
      expect(reordered.checkedTargets, <String>[
        'wormholes:bukkit',
        'wormholes:forge',
        'iris:fabric',
        'iris:bukkit',
      ]);
      catalog = <Map<String, Object?>>[
        _wormholes,
        <String, Object?>{
          'id': 'iris',
          'name': 'Iris',
          'targets': <Object?>[
            <String, Object?>{'id': 'bukkit'},
          ],
        },
      ];
      ProjectDashboardSelection removed = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.char, char: 'R')],
      );
      expect(removed.checkedTargets, <String>[
        'wormholes:bukkit',
        'wormholes:forge',
        'iris:bukkit',
      ]);
      expect(removed.node!.key, 'iris:bukkit');
      catalog = <Map<String, Object?>>[];
      ProjectDashboardSelection history =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.char, char: 'R'),
            const TermEvent(TermEventKind.char, char: 'a'),
            const TermEvent(TermEventKind.char, char: ' '),
          ]);
      expect(history.checkedTargets, isEmpty);
      expect(history.row!.registered, isFalse);
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test('checks survive stale status and switching run history', () async {
    _Terminal terminal = _Terminal();
    bool failStatus = false;
    List<ProjectDashboardSelection> selections = <ProjectDashboardSelection>[];
    Future<void> running = _start(
      _screen(
        terminal,
        loadStatus: () {
          if (failStatus) throw StateError('Temporarily unreadable');
          return <String, Object?>{
            'runs': <Object?>[
              ..._status['runs']! as List<Object?>,
              <String, Object?>{
                'id': 'run-old',
                'status': 'succeeded',
                'jobs': <Object?>[],
              },
            ],
          };
        },
        prompt:
            (
              ProjectDashboardAction action,
              ProjectDashboardSelection selection,
            ) async {
              selections.add(selection);
              return action == ProjectDashboardAction.history
                  ? <String>['view', 'run-old']
                  : null;
            },
      ),
      terminal,
    );
    await _capture(terminal, selections, <TermEvent>[
      const TermEvent(TermEventKind.char, char: ' '),
    ]);
    failStatus = true;
    ProjectDashboardSelection stale = await _capture(
      terminal,
      selections,
      <TermEvent>[const TermEvent(TermEventKind.char, char: 'R')],
    );
    expect(terminal.output, contains('STALE:'));
    expect(stale.checkedTargets, <String>['iris:bukkit', 'iris:fabric']);
    failStatus = false;
    ProjectDashboardSelection older = await _capture(
      terminal,
      selections,
      <TermEvent>[const TermEvent(TermEventKind.char, char: 'h')],
    );
    expect(older.run!['id'], 'run-old');
    expect(older.checkedTargets, <String>['iris:bukkit', 'iris:fabric']);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test(
    'empty catalogs and history targets do not create checked builds',
    () async {
      for (Map<String, Object?> status in <Map<String, Object?>>[
        <String, Object?>{'runs': <Object?>[]},
        _status,
      ]) {
        _Terminal terminal = _Terminal();
        List<ProjectDashboardSelection> selections =
            <ProjectDashboardSelection>[];
        Future<void> running = _start(
          _screen(
            terminal,
            loadCatalog: () => <Map<String, Object?>>[],
            loadStatus: () => status,
            prompt:
                (
                  ProjectDashboardAction action,
                  ProjectDashboardSelection selection,
                ) async {
                  selections.add(selection);
                  return null;
                },
          ),
          terminal,
        );
        ProjectDashboardSelection selection =
            await _capture(terminal, selections, <TermEvent>[
              const TermEvent(TermEventKind.char, char: 'a'),
              const TermEvent(TermEventKind.char, char: ' '),
              const TermEvent(TermEventKind.char, char: 'v'),
            ]);
        expect(selection.checkedTargets, isEmpty);
        expect(selection.registered, isFalse);
        terminal.input.add(const TermEvent(TermEventKind.escape));
        await running;
      }
    },
  );

  test('checkbox mouse clicks require matching left-button release', () async {
    _Terminal terminal = _Terminal()..columns = 140;
    List<ProjectDashboardSelection> selections = <ProjectDashboardSelection>[];
    Future<void> running = _start(
      _screen(
        terminal,
        prompt:
            (
              ProjectDashboardAction action,
              ProjectDashboardSelection selection,
            ) async {
              selections.add(selection);
              return null;
            },
      ),
      terminal,
    );
    for (List<TermEvent> gesture in <List<TermEvent>>[
      <TermEvent>[const TermEvent(TermEventKind.mouseUp, row: 7, col: 4)],
      <TermEvent>[
        const TermEvent(TermEventKind.mouseDown, row: 7, col: 4),
        const TermEvent(TermEventKind.mouseUp, row: 8, col: 4),
      ],
      <TermEvent>[
        const TermEvent(TermEventKind.mouseDown, row: 7, col: 4),
        const TermEvent(TermEventKind.mouseUp, row: 7, col: 12),
      ],
      <TermEvent>[
        const TermEvent(TermEventKind.mouseDown, row: 7, col: 4, button: 2),
        const TermEvent(TermEventKind.mouseUp, row: 7, col: 4, button: 2),
      ],
    ]) {
      ProjectDashboardSelection selection = await _capture(
        terminal,
        selections,
        gesture,
      );
      expect(selection.checkedTargets, isEmpty);
    }
    ProjectDashboardSelection target =
        await _capture(terminal, selections, <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 7, col: 4),
          const TermEvent(TermEventKind.mouseUp, row: 7, col: 4),
        ]);
    expect(target.checkedTargets, <String>['iris:bukkit']);
    expect(target.row!.key, 'iris:bukkit');
    ProjectDashboardSelection parent =
        await _capture(terminal, selections, <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 6, col: 4),
          const TermEvent(TermEventKind.mouseUp, row: 6, col: 4),
        ]);
    expect(parent.checkedTargets, <String>['iris:bukkit', 'iris:fabric']);
    ProjectDashboardSelection cleared =
        await _capture(terminal, selections, <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 5, col: 4),
          const TermEvent(TermEventKind.mouseUp, row: 5, col: 4),
        ]);
    expect(cleared.checkedTargets, isEmpty);
    ProjectDashboardSelection all =
        await _capture(terminal, selections, <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 5, col: 4),
          const TermEvent(TermEventKind.mouseUp, row: 5, col: 4),
        ]);
    expect(all.checkedTargets, <String>['iris:bukkit', 'iris:fabric']);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test(
    'clicking a disclosure changes the tree without checking targets',
    () async {
      _Terminal terminal = _Terminal()..columns = 140;
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadCatalog: () => <Map<String, Object?>>[..._catalog, _wormholes],
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                selections.add(selection);
                return null;
              },
        ),
        terminal,
      );
      ProjectDashboardSelection collapsed =
          await _capture(terminal, selections, <TermEvent>[
            const TermEvent(TermEventKind.mouseDown, row: 6, col: 10),
            const TermEvent(TermEventKind.mouseUp, row: 6, col: 10),
          ]);
      expect(collapsed.node!.expanded, isFalse);
      expect(collapsed.checkedTargets, isEmpty);
      ProjectDashboardSelection next = await _capture(
        terminal,
        selections,
        <TermEvent>[const TermEvent(TermEventKind.arrowDown)],
      );
      expect(next.node!.key, 'wormholes:');
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );

  test(
    'limits shortcut refreshes saved limits and preserves checked targets',
    () async {
      _Terminal terminal = _Terminal();
      ProjectBuildLimits limits = ProjectBuildLimits(
        jobs: 2,
        memoryMiB: 8192,
        workers: 4,
      );
      List<ProjectDashboardSelection> selections =
          <ProjectDashboardSelection>[];
      List<ProjectDashboardAction> actions = <ProjectDashboardAction>[];
      List<List<String>> calls = <List<String>>[];
      Future<void> running = _start(
        _screen(
          terminal,
          loadLimits: () => limits,
          prompt:
              (
                ProjectDashboardAction action,
                ProjectDashboardSelection selection,
              ) async {
                actions.add(action);
                selections.add(selection);
                return action == ProjectDashboardAction.limits
                    ? <String>[
                        'limits',
                        '--jobs',
                        '5',
                        '--memory',
                        '24576',
                        '--workers',
                        '10',
                      ]
                    : null;
              },
          command:
              (
                List<String> args, {
                required void Function(String) output,
                required void Function(String) error,
              }) async {
                calls.add(args);
                limits = ProjectBuildLimits(
                  jobs: 5,
                  memoryMiB: 24576,
                  workers: 10,
                );
                return 0;
              },
        ),
        terminal,
      );
      terminal.input.addAll(<TermEvent>[
        const TermEvent(TermEventKind.char, char: ' '),
        const TermEvent(TermEventKind.char, char: 'p'),
      ]);
      await _until(() => calls.isNotEmpty);
      expect(actions.single, ProjectDashboardAction.limits);
      expect(selections.single.limits.jobs, 2);
      await _until(
        () => terminal.output.contains('5 jobs  24576 MiB  10 workers'),
      );
      terminal.input.add(const TermEvent(TermEventKind.char, char: 'b'));
      await _until(() => selections.length == 2);
      expect(actions.last, ProjectDashboardAction.build);
      expect(selections.last.checkedTargets, <String>[
        'iris:bukkit',
        'iris:fabric',
      ]);
      expect(selections.last.limits.toJson(), limits.toJson());
      expect(calls.single, <String>[
        'limits',
        '--jobs',
        '5',
        '--memory',
        '24576',
        '--workers',
        '10',
      ]);
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;
    },
  );
}

ProjectDashboard _screen(
  _Terminal terminal, {
  ProjectDashboardCommand? command,
  ProjectDashboardPrompt? prompt,
  Map<String, Object?> Function()? loadStatus,
  List<Map<String, Object?>> Function()? loadCatalog,
  ProjectBuildLimits Function()? loadLimits,
  Future<List<String>> Function(String, int)? logReader,
}) => ProjectDashboard.withCallbacks(
  loadCatalog: loadCatalog ?? () => _catalog,
  loadLimits:
      loadLimits ??
      () => ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
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

final Map<String, Object?> _wormholes = <String, Object?>{
  'id': 'wormholes',
  'name': 'Wormholes',
  'targets': <Object?>[
    <String, Object?>{'id': 'bukkit'},
    <String, Object?>{'id': 'forge'},
  ],
};

Future<void> _start(ProjectDashboard screen, _Terminal terminal) {
  Future<void> running = screen.run();
  addTearDown(() async {
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });
  return running;
}

Future<ProjectDashboardSelection> _capture(
  _Terminal terminal,
  List<ProjectDashboardSelection> selections,
  List<TermEvent> events,
) async {
  int previous = selections.length;
  terminal.input.addAll(<TermEvent>[
    ...events,
    const TermEvent(TermEventKind.enter),
  ]);
  await _until(() => selections.length > previous && terminal.input.isEmpty);
  return selections.last;
}
