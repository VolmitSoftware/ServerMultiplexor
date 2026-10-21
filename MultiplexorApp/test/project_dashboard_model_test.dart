import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_dashboard_model.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/button.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  List<Map<String, Object?>> catalog = <Map<String, Object?>>[
    <String, Object?>{
      'id': 'iris',
      'name': 'Iris',
      'targets': <Object?>[
        <String, Object?>{'id': 'bukkit'},
        <String, Object?>{'id': 'fabric-26.1'},
      ],
    },
  ];
  Map<String, Object?> run = <String, Object?>{
    'id': 'run-1',
    'status': 'running',
    'jobsLimit': 2,
    'memoryMiB': 8192,
    'workers': 2,
    'jobs': <Object?>[
      <String, Object?>{
        'key': 'iris:fabric-26.1',
        'project': 'iris',
        'target': 'fabric-26.1',
        'status': 'running',
        'currentTask': ':compileJava',
        'startedAt': '2026-01-01T00:00:00Z',
      },
    ],
  };

  test('catalog keeps every target mounted while selected jobs run', () {
    List<ProjectDashboardRow> rows = projectDashboardRows(catalog, run);
    expect(rows.map((ProjectDashboardRow row) => row.key), <String>[
      'iris:bukkit',
      'iris:fabric-26.1',
    ]);
    expect(rows.first.status, 'ready');
    expect(rows.last.status, 'running');
    expect(rows.last.task, ':compileJava');
    expect(rows.last.elapsed(DateTime.utc(2026, 1, 1, 0, 1, 5)), '1m 5s');
  });

  test('run targets remain inspectable after catalog removal', () {
    List<ProjectDashboardRow> rows = projectDashboardRows(
      <Map<String, Object?>>[],
      run,
    );
    expect(rows.single.key, 'iris:fabric-26.1');
    expect(rows.single.status, 'running');
  });

  test('project groups retain children when collapsed', () {
    List<ProjectDashboardRow> rows = projectDashboardRows(catalog, run);
    List<ProjectDashboardNode> expanded = projectDashboardTree(
      rows,
      <String>{},
    );
    expect(expanded.map((ProjectDashboardNode node) => node.key), <String>[
      'iris:',
      'iris:bukkit',
      'iris:fabric-26.1',
    ]);
    expect(expanded.first.isProject, isTrue);
    expect(expanded.first.expanded, isTrue);
    expect(expanded.first.buildKeys, <String>[
      'iris:bukkit',
      'iris:fabric-26.1',
    ]);
    expect(expanded[1].lastChild, isFalse);
    expect(expanded.last.lastChild, isTrue);

    ProjectDashboardNode collapsed = projectDashboardTree(rows, <String>{
      'iris',
    }).single;
    expect(collapsed.expanded, isFalse);
    expect(collapsed.buildKeys, expanded.first.buildKeys);
  });

  test(
    'project checkboxes distinguish none, some, and all registered targets',
    () {
      List<ProjectDashboardNode> nodes = projectDashboardTree(
        projectDashboardRows(catalog, run),
        <String>{},
      );
      expect(nodes.first.checkbox(<String>{}), '[ ]');
      expect(nodes.first.checkbox(<String>{'iris:bukkit'}), '[-]');
      expect(
        nodes.first.checkbox(<String>{'iris:bukkit', 'iris:fabric-26.1'}),
        '[x]',
      );
      expect(nodes[1].checkbox(<String>{'iris:bukkit'}), '[x]');
      expect(nodes.last.checkbox(<String>{'iris:bukkit'}), '[ ]');
    },
  );

  test(
    'run history children remain visible without becoming build choices',
    () {
      List<ProjectDashboardNode> nodes = projectDashboardTree(
        projectDashboardRows(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'iris',
            'name': 'Iris',
            'targets': <Object?>[
              <String, Object?>{'id': 'bukkit'},
            ],
          },
        ], run),
        <String>{},
      );
      expect(nodes.first.targets.length, 2);
      expect(nodes.first.buildKeys, <String>['iris:bukkit']);
      expect(nodes.first.checkbox(<String>{'iris:bukkit'}), '[x]');
      expect(nodes.last.target!.registered, isFalse);
      expect(nodes.last.buildKeys, isEmpty);
      expect(nodes.last.checkbox(<String>{'iris:fabric-26.1'}), ' - ');
      List<ProjectDashboardNode> historyOnly = projectDashboardTree(
        projectDashboardRows(<Map<String, Object?>>[], run),
        <String>{},
      );
      expect(
        historyOnly.map((ProjectDashboardNode node) => node.buildKeys),
        everyElement(isEmpty),
      );
      expect(
        historyOnly.map(
          (ProjectDashboardNode node) => node.checkbox(<String>{}),
        ),
        everyElement(' - '),
      );
    },
  );

  test('tree rendering exposes selection, disclosure, and branch markers', () {
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 120,
      lines: 32,
      nodes: projectDashboardTree(
        projectDashboardRows(catalog, run),
        <String>{},
      ),
      checked: <String>{'iris:bukkit'},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: run,
      logs: <String>[],
      notice: '',
      stale: false,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(frame.lines[4], contains('[-]   PROJECT / TARGET'));
    expect(frame.lines[5], contains('[-] > [-] Iris'));
    expect(frame.lines[6], contains('[x]   |-  bukkit'));
    expect(frame.lines[7], contains('[ ]   `-  fabric-26.1'));
    expect(frame.selectAllRow, 4);
    expect(frame.targetRows.values, <int>[0, 1, 2]);
    ProjectDashboardFrame collapsed = renderProjectDashboard(
      columns: 80,
      lines: 24,
      nodes: projectDashboardTree(projectDashboardRows(catalog, run), <String>{
        'iris',
      }),
      checked: <String>{'iris:bukkit', 'iris:fabric-26.1'},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: run,
      logs: <String>[],
      notice: '',
      stale: false,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(collapsed.lines[4], contains('[x]   PROJECT / TARGET'));
    expect(collapsed.lines[5], contains('[x] > [+] Iris'));
    expect(collapsed.targetRows.values, <int>[0]);
  });

  test('paged target lists keep the project and focused child visible', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'matrix',
          'name': 'Matrix',
          'targets': <Object?>[
            for (int index = 1; index <= 60; index++)
              <String, Object?>{'id': 'target-$index'},
          ],
        },
      ], null),
      <String>{},
    );
    for ((int, int, int) size in <(int, int, int)>[
      (48, 14, 9),
      (80, 24, 11),
      (120, 32, 45),
    ]) {
      ProjectDashboardFrame frame = renderProjectDashboard(
        columns: size.$1,
        lines: size.$2,
        nodes: nodes,
        checked: <String>{'matrix:target-${size.$3}'},
        limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
        selected: size.$3,
        run: null,
        logs: <String>[],
        notice: '',
        stale: false,
        theme: MonitorTheme.plainAscii(),
        now: DateTime.utc(2026),
      );
      expect(frame.lines.length, size.$2);
      expect(frame.lines.map(Ansi.visibleLength), everyElement(size.$1));
      expect(frame.targetRows.values.first, 0);
      expect(frame.targetRows.values, contains(size.$3));
      expect(frame.targetRows.values.toSet().length, frame.targetRows.length);
      for (MapEntry<int, int> hit in frame.targetRows.entries) {
        ProjectDashboardNode node = nodes[hit.value];
        expect(
          frame.lines[hit.key],
          contains(node.isProject ? 'Matrix (60)' : node.target!.target),
        );
        if (hit.value == size.$3) {
          expect(frame.lines[hit.key], contains('[x] >'));
        }
      }
    }
  });

  test('collapsed projects expose failed child status and target count', () {
    Map<String, Object?> failedRun = <String, Object?>{
      ...run,
      'jobs': <Object?>[
        <String, Object?>{
          'key': 'iris:bukkit',
          'project': 'iris',
          'target': 'bukkit',
          'status': 'failed',
        },
        ...projectMaps(run['jobs']),
      ],
    };
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(catalog, failedRun),
      <String>{'iris'},
    );
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 80,
      lines: 24,
      nodes: nodes,
      checked: <String>{},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: failedRun,
      logs: <String>[],
      notice: '',
      stale: false,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(nodes.single.status, 'failed');
    expect(frame.targetRows.values, <int>[0]);
    String projectLine = frame.lines[frame.targetRows.keys.single];
    expect(projectLine, contains('[+] Iris (2)'));
    expect(projectLine, contains('failed'));
  });

  test('Unicode terminals render connected child branches', () {
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 120,
      lines: 32,
      nodes: projectDashboardTree(
        projectDashboardRows(catalog, run),
        <String>{},
      ),
      checked: <String>{},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: run,
      logs: <String>[],
      notice: '',
      stale: false,
      theme: MonitorTheme.plain(),
      now: DateTime.utc(2026),
    );
    expect(frame.lines[6], contains('├─  bukkit'));
    expect(frame.lines[7], contains('└─  fabric-26.1'));
    expect(frame.lines.map(Ansi.visibleLength), everyElement(120));
  });

  test('frames fit narrow, stacked, and lateral terminals', () {
    for ((int, int) size in <(int, int)>[
      (1, 1),
      (40, 10),
      (48, 14),
      (80, 24),
      (120, 32),
      (180, 50),
    ]) {
      ProjectDashboardFrame frame = renderProjectDashboard(
        columns: size.$1,
        lines: size.$2,
        nodes: projectDashboardTree(
          projectDashboardRows(catalog, run),
          <String>{},
        ),
        checked: <String>{},
        limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
        selected: 1,
        run: run,
        logs: <String>['compile started', 'x' * 300],
        notice: 'State refreshed',
        stale: false,
        theme: MonitorTheme.plainAscii(),
        now: DateTime.utc(2026, 1, 1, 0, 1, 5),
      );
      expect(frame.lines.length, size.$2);
      expect(frame.lines.map(Ansi.visibleLength), everyElement(size.$1));
      if (size.$1 >= 48 && size.$2 >= 14) {
        expect(frame.lines.join('\n'), contains('3 jobs  12288 MiB'));
        expect(frame.targetRows.values, contains(1));
        expect(
          frame.lines[frame.targetRows.entries
              .firstWhere((MapEntry<int, int> entry) => entry.value == 1)
              .key],
          contains('bukkit'),
        );
      }
    }
  });

  test(
    'action bar keeps Back and primary controls visible at narrow widths',
    () {
      for ((int, int) size in <(int, int)>[(48, 14), (80, 24)]) {
        ProjectDashboardFrame frame = renderProjectDashboard(
          columns: size.$1,
          lines: size.$2,
          nodes: projectDashboardTree(
            projectDashboardRows(catalog, run),
            <String>{},
          ),
          checked: <String>{},
          limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
          selected: 0,
          run: run,
          logs: <String>[],
          notice: '',
          stale: false,
          theme: MonitorTheme.plainAscii(),
          now: DateTime.utc(2026),
        );
        expect(frame.buttons.keys.single, size.$2 - 2);
        List<ButtonSpan> buttons = frame.buttons.values.single;
        expect(buttons.map((ButtonSpan button) => button.id), <String>[
          'back',
          'build',
          'limits',
          'locations',
          if (size.$1 >= 80) 'actions',
        ]);
        String row = frame.lines[frame.buttons.keys.single];
        for (ButtonSpan button in buttons) {
          expect(button.colStart, greaterThanOrEqualTo(0));
          expect(button.colEnd, lessThanOrEqualTo(size.$1));
          String label = button.id == 'actions'
              ? 'MORE'
              : button.id.toUpperCase();
          expect(
            row.substring(button.colStart, button.colEnd),
            contains(label),
          );
        }
        expect(frame.lines.last, contains('Enter menu'));
      }
    },
  );

  test('empty catalogs render Build disabled without a clickable span', () {
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 80,
      lines: 24,
      nodes: <ProjectDashboardNode>[],
      checked: <String>{},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: null,
      logs: <String>[],
      notice: '',
      stale: false,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(frame.lines[frame.buttons.keys.single], contains('BUILD'));
    expect(
      frame.buttons.values.single.map((ButtonSpan button) => button.id),
      isNot(contains('build')),
    );
  });

  test('stale state retains targets and gives a recovery message', () {
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 100,
      lines: 24,
      nodes: projectDashboardTree(
        projectDashboardRows(catalog, run),
        <String>{},
      ),
      checked: <String>{},
      limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
      selected: 0,
      run: run,
      logs: <String>[],
      notice: 'Project state unavailable. Retrying.',
      stale: true,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(frame.lines.join('\n'), contains('Iris'));
    expect(
      frame.lines.join('\n'),
      contains('STALE: Project state unavailable. Retrying.'),
    );
  });

  test('log and identity text cannot inject terminal controls', () {
    expect(projectText('\x1b[2Jhidden\r\n\x07'), 'hidden');
    expect(projectOutputText('\x1b[2Jfirst\r\nsecond\x07'), 'first\nsecond');
  });
}
