import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_dashboard_model.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/button.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

ProjectDashboardFrame _renderTree(
  List<ProjectDashboardNode> nodes, {
  int columns = 80,
  int lines = 24,
  int selected = 0,
  Set<String> checked = const <String>{},
  MonitorTheme? theme,
  bool showOutput = false,
  List<String> logs = const <String>['compiler output marker'],
}) => renderProjectDashboard(
  columns: columns,
  lines: lines,
  nodes: nodes,
  checked: checked,
  limits: ProjectBuildLimits(jobs: 3, memoryMiB: 12288, workers: 6),
  selected: selected,
  run: null,
  logs: logs,
  notice: '',
  stale: false,
  theme: theme ?? MonitorTheme.plainAscii(),
  now: DateTime.utc(2026),
  showOutput: showOutput,
);

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
  List<Map<String, Object?>> groupedCatalog = <Map<String, Object?>>[
    <String, Object?>{
      'id': 'iris',
      'name': 'Iris',
      'targets': <Object?>[
        for (String target in <String>[
          'bukkit',
          'fabric-26.1',
          'fabric-26.2',
          'forge-26.1',
          'forge-26.2',
          'neoforge-26.1',
          'neoforge-26.2',
        ])
          <String, Object?>{'id': target},
      ],
    },
    <String, Object?>{
      'id': 'gloss',
      'name': 'Gloss',
      'targets': <Object?>[
        <String, Object?>{'id': 'bukkit'},
      ],
    },
  ];

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

  test('run timer measures wall time including queue and preparation', () {
    for (String status in <String>['queued', 'preparing', 'running']) {
      Map<String, Object?> active = <String, Object?>{
        'status': status,
        'createdAt': '2026-01-01T00:00:00Z',
        'startedAt': '2026-01-01T00:00:10Z',
        'jobs': <Object?>[
          for (int index = 0; index < 4; index++)
            <String, Object?>{'startedAt': '2026-01-01T00:00:20Z'},
        ],
      };
      expect(
        projectRunTiming(active, DateTime.utc(2026, 1, 1, 0, 2, 3)),
        'Elapsed 2m 3s',
      );
      expect(
        projectRunTiming(active, DateTime.utc(2026, 1, 1, 0, 2, 4)),
        'Elapsed 2m 4s',
      );
    }
  });

  test('finished and interrupted run timers stop advancing', () {
    for (String status in <String>['succeeded', 'failed', 'cancelled']) {
      Map<String, Object?> completed = <String, Object?>{
        'status': status,
        'createdAt': '2026-01-01T00:00:00Z',
        'finishedAt': '2026-01-01T00:05:21Z',
      };
      expect(
        projectRunTiming(completed, DateTime.utc(2026, 1, 2)),
        'Total 5m 21s',
      );
    }
    expect(
      projectRunTiming(<String, Object?>{
        'status': 'interrupted',
        'createdAt': '2026-01-01T00:00:00Z',
        'heartbeatAt': '2026-01-01T00:01:45Z',
      }, DateTime.utc(2026, 1, 2)),
      'Total 1m 45s',
    );
    expect(
      projectRunTiming(<String, Object?>{
        'status': 'running',
        'startedAt': '2026-01-01T00:01:00Z',
      }, DateTime.utc(2026, 1, 1)),
      'Elapsed 0s',
    );
    expect(
      projectRunTiming(<String, Object?>{
        'status': 'failed',
        'createdAt': 'invalid',
      }, DateTime.utc(2026)),
      'Total -',
    );
  });

  test('run timer stays visible at narrow and wide widths', () {
    for (int columns in <int>[48, 80, 120]) {
      for (bool completed in <bool>[false, true]) {
        ProjectDashboardFrame frame = renderProjectDashboard(
          columns: columns,
          lines: 24,
          nodes: <ProjectDashboardNode>[],
          checked: <String>{},
          limits: ProjectBuildLimits.defaults(),
          selected: 0,
          run: <String, Object?>{
            'id': 'run-${'1234567890' * 8}',
            'status': completed ? 'succeeded' : 'running',
            'createdAt': '2026-01-01T00:00:00Z',
            if (completed) 'finishedAt': '2026-01-01T00:10:03Z',
          },
          logs: <String>[],
          notice: '',
          stale: false,
          theme: MonitorTheme.plainAscii(),
          now: DateTime.utc(2026, 1, 1, 0, 10, 3),
        );
        String header = Ansi.strip(frame.lines[1]);
        expect(header, startsWith(completed ? 'SUCCEEDED' : 'RUNNING'));
        expect(header, endsWith('${completed ? 'Total' : 'Elapsed'} 10m 3s'));
        expect(header.length, columns);
      }
    }
  });

  test(
    'build choices omit only projects with exclusively library artifacts',
    () {
      Map<String, Object?> target(String id, List<String?> roles) =>
          <String, Object?>{
            'id': id,
            'artifacts': <Object?>[
              for (String? role in roles) <String, Object?>{'role': ?role},
            ],
          };
      List<Map<String, Object?>> projects = <Map<String, Object?>>[
        <String, Object?>{
          'id': 'library',
          'targets': <Object?>[
            target('shared', <String?>['library']),
            target('native', <String?>['library']),
          ],
        },
        <String, Object?>{
          'id': 'mixed',
          'targets': <Object?>[
            target('api', <String?>['library']),
            target('bukkit', <String?>['runtime']),
          ],
        },
        <String, Object?>{
          'id': 'api',
          'targets': <Object?>[
            target('api', <String?>['api']),
          ],
        },
        <String, Object?>{
          'id': 'implicit-runtime',
          'targets': <Object?>[
            target('bukkit', <String?>[null]),
          ],
        },
        <String, Object?>{
          'id': 'utility',
          'targets': <Object?>[target('check', <String?>[])],
        },
        <String, Object?>{'id': 'empty', 'targets': <Object?>[]},
      ];
      expect(
        projectDashboardCatalog(
          projects,
        ).map((Map<String, Object?> p) => p['id']),
        <String>['mixed', 'api', 'implicit-runtime', 'utility', 'empty'],
      );
      expect(
        projectDashboardRows(
          projects,
          null,
        ).map((ProjectDashboardRow row) => row.key),
        <String>[
          'mixed:api',
          'mixed:bukkit',
          'api:api',
          'implicit-runtime:bukkit',
          'utility:check',
        ],
      );
    },
  );

  test('library build history remains named and cannot be selected', () {
    List<ProjectDashboardRow> rows = projectDashboardRows(
      <Map<String, Object?>>[
        <String, Object?>{
          'id': 'shared',
          'name': 'Shared Library',
          'targets': <Object?>[
            <String, Object?>{
              'id': 'library',
              'artifacts': <Object?>[
                <String, Object?>{'role': 'library'},
              ],
            },
          ],
        },
      ],
      <String, Object?>{
        'jobs': <Object?>[
          <String, Object?>{
            'key': 'shared:library',
            'project': 'shared',
            'target': 'library',
            'status': 'blocked',
            'error': 'Definition changed; scan sources.',
          },
        ],
      },
    );
    expect(rows.single.name, 'Shared Library');
    expect(rows.single.registered, isFalse);
    expect(rows.single.error, 'Definition changed; scan sources.');
    expect(projectDashboardTree(rows, <String>{}).single.buildKeys, isEmpty);
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
      'iris:',
    }).single;
    expect(collapsed.expanded, isFalse);
    expect(collapsed.buildKeys, expanded.first.buildKeys);
  });

  test('repeated loaders form nested branches with stable target keys', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(groupedCatalog, null),
      <String>{},
    );
    expect(nodes.map((ProjectDashboardNode node) => node.key), <String>[
      'iris:',
      'iris:bukkit',
      'iris:@fabric',
      'iris:fabric-26.1',
      'iris:fabric-26.2',
      'iris:@forge',
      'iris:forge-26.1',
      'iris:forge-26.2',
      'iris:@neoforge',
      'iris:neoforge-26.1',
      'iris:neoforge-26.2',
      'gloss:bukkit',
    ]);
    expect(nodes.first.isProject, isTrue);
    expect(nodes.first.isBranch, isTrue);
    expect(nodes.first.depth, 0);
    expect(nodes.first.ancestors, isEmpty);
    for (String loader in <String>['fabric', 'forge', 'neoforge']) {
      ProjectDashboardNode branch = nodes.singleWhere(
        (ProjectDashboardNode node) => node.key == 'iris:@$loader',
      );
      expect(branch.isBranch, isTrue);
      expect(branch.isProject, isFalse);
      expect(branch.parentKey, 'iris:');
      expect(branch.depth, 1);
      expect(branch.ancestors, <String>['iris:']);
      expect(branch.displayLabel, switch (loader) {
        'fabric' => 'Fabric',
        'forge' => 'Forge',
        _ => 'NeoForge',
      });
      expect(branch.buildKeys, <String>[
        'iris:$loader-26.1',
        'iris:$loader-26.2',
      ]);
      ProjectDashboardNode leaf = nodes.singleWhere(
        (ProjectDashboardNode node) => node.key == 'iris:$loader-26.2',
      );
      expect(leaf.isBranch, isFalse);
      expect(leaf.isProject, isFalse);
      expect(leaf.depth, 2);
      expect(leaf.parentKey, branch.key);
      expect(leaf.ancestors, <String>['iris:', branch.key]);
      expect(leaf.ancestorLastChildren, <bool>[loader == 'neoforge']);
      expect(leaf.displayLabel, '26.2');
      expect(leaf.lastChild, isTrue);
    }
  });

  test('singleton projects and loader targets have no redundant branch', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[
        ...catalog,
        groupedCatalog.last,
      ], null),
      <String>{'gloss:'},
    );
    expect(nodes.map((ProjectDashboardNode node) => node.key), <String>[
      'iris:',
      'iris:bukkit',
      'iris:fabric-26.1',
      'gloss:bukkit',
    ]);
    ProjectDashboardNode single = nodes.last;
    expect(single.depth, 0);
    expect(single.isProject, isFalse);
    expect(single.isBranch, isFalse);
    expect(single.parentKey, isNull);
    expect(single.ancestors, isEmpty);
    expect(single.displayLabel, 'Gloss / bukkit');
    expect(single.buildKeys, <String>['gloss:bukkit']);
    expect(nodes[2].displayLabel, 'fabric-26.1');
    expect(nodes[2].depth, 1);

    ProjectDashboardFrame frame = _renderTree(nodes);
    expect(frame.disclosures.values.map((ButtonSpan span) => span.id), <String>[
      'iris:',
    ]);
    expect(
      frame.checkboxes.values.map((ButtonSpan span) => span.id),
      contains('gloss:bukkit'),
    );
    expect(frame.lines.join('\n'), contains('3 TARGETS'));
  });

  test('loader checkbox states aggregate only registered descendants', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(groupedCatalog, <String, Object?>{
        'jobs': <Object?>[
          <String, Object?>{
            'project': 'iris',
            'target': 'forge-previous',
            'status': 'failed',
          },
        ],
      }),
      <String>{},
    );
    ProjectDashboardNode forge = nodes.singleWhere(
      (ProjectDashboardNode node) => node.key == 'iris:@forge',
    );
    expect(forge.targets.length, 3);
    expect(forge.status, 'failed');
    expect(forge.checkbox(<String>{}), '[ ]');
    expect(forge.checkbox(<String>{'iris:forge-26.1'}), '[-]');
    expect(
      forge.checkbox(<String>{'iris:forge-26.1', 'iris:forge-26.2'}),
      '[X]',
    );
    expect(forge.checkbox(<String>{'iris:fabric-26.1'}), '[ ]');
    expect(nodes.first.checkbox(forge.buildKeys.toSet()), '[-]');
    expect(nodes.first.checkbox(nodes.first.buildKeys.toSet()), '[X]');
    ProjectDashboardNode historical = nodes.singleWhere(
      (ProjectDashboardNode node) => node.key == 'iris:forge-previous',
    );
    expect(historical.checkbox(<String>{historical.key}), ' - ');
    ProjectDashboardFrame frame = _renderTree(nodes, lines: 32);
    expect(
      frame.checkboxes.values.map((ButtonSpan span) => span.id),
      isNot(contains(historical.key)),
    );
  });

  test('nested collapse preserves branch selections and sibling groups', () {
    List<ProjectDashboardRow> rows = projectDashboardRows(groupedCatalog, null);
    Set<String> collapsed = <String>{'iris:@forge'};
    List<ProjectDashboardNode> nodes = projectDashboardTree(rows, collapsed);
    ProjectDashboardNode forge = nodes.singleWhere(
      (ProjectDashboardNode node) => node.key == 'iris:@forge',
    );
    expect(forge.expanded, isFalse);
    expect(forge.buildKeys, <String>['iris:forge-26.1', 'iris:forge-26.2']);
    expect(forge.checkbox(<String>{'iris:forge-26.1'}), '[-]');
    expect(
      nodes.map((ProjectDashboardNode node) => node.key),
      isNot(contains('iris:forge-26.1')),
    );
    expect(
      nodes.map((ProjectDashboardNode node) => node.key),
      containsAll(<String>['iris:fabric-26.1', 'iris:neoforge-26.1']),
    );
    collapsed.add('iris:');
    expect(
      projectDashboardTree(
        rows,
        collapsed,
      ).map((ProjectDashboardNode node) => node.key),
      <String>['iris:', 'gloss:bukkit'],
    );
    collapsed.remove('iris:');
    expect(
      projectDashboardTree(
        rows,
        collapsed,
      ).map((ProjectDashboardNode node) => node.key),
      nodes.map((ProjectDashboardNode node) => node.key),
    );
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
        '[X]',
      );
      expect(nodes[1].checkbox(<String>{'iris:bukkit'}), '[X]');
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
      expect(nodes.first.checkbox(<String>{'iris:bukkit'}), '[X]');
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
    expect(frame.lines[4], contains('[-] ALL'));
    expect(frame.lines[5], contains('> v [-] Iris'));
    expect(frame.lines[6], contains('|-   [X] bukkit'));
    expect(frame.lines[7], contains('`-   [ ] fabric-26.1'));
    expect(frame.selectAllRow, 4);
    expect(frame.targetRows.values, <int>[0, 1, 2]);
    ProjectDashboardFrame collapsed = renderProjectDashboard(
      columns: 80,
      lines: 24,
      nodes: projectDashboardTree(projectDashboardRows(catalog, run), <String>{
        'iris:',
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
    expect(collapsed.lines[4], contains('[X] ALL'));
    expect(collapsed.lines[5], contains('> > [X] Iris'));
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
          expect(frame.lines[hit.key], matches(RegExp(r'>.*\[X\]')));
        }
      }
    }
  });

  test('deep paging keeps both ancestors and the focused leaf visible', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[
        groupedCatalog.last,
        <String, Object?>{
          'id': 'matrix',
          'name': 'Matrix',
          'targets': <Object?>[
            <String, Object?>{'id': 'bukkit'},
            for (int index = 1; index <= 60; index++)
              <String, Object?>{'id': 'forge-$index'},
            <String, Object?>{'id': 'api'},
          ],
        },
      ], null),
      <String>{},
    );
    for ((int, int) size in <(int, int)>[(48, 14), (80, 24), (120, 32)]) {
      for (String focused in <String>[
        'matrix:forge-1',
        'matrix:forge-30',
        'matrix:forge-60',
      ]) {
        int selected = nodes.indexWhere(
          (ProjectDashboardNode node) => node.key == focused,
        );
        ProjectDashboardFrame frame = _renderTree(
          nodes,
          columns: size.$1,
          lines: size.$2,
          selected: selected,
          checked: <String>{focused},
        );
        List<String> visible = frame.targetRows.values
            .map((int index) => nodes[index].key)
            .toList(growable: false);
        expect(
          visible,
          containsAllInOrder(<String>['matrix:', 'matrix:@forge', focused]),
        );
        expect(visible.toSet().length, visible.length);
        expect(frame.lines.length, size.$2);
        expect(frame.lines.map(Ansi.visibleLength), everyElement(size.$1));
        int focusedRow = frame.targetRows.entries
            .singleWhere((MapEntry<int, int> hit) => hit.value == selected)
            .key;
        ButtonSpan checkbox = frame.checkboxes[focusedRow]!;
        expect(checkbox.id, focused);
        expect(
          Ansi.strip(
            frame.lines[focusedRow],
          ).substring(checkbox.colStart, checkbox.colEnd),
          '[X]',
        );
        expect(
          Ansi.strip(frame.lines[focusedRow]).substring(0, checkbox.colStart),
          contains('>'),
        );
      }
    }
  });

  test('checkbox and disclosure spans match text at every tree depth', () {
    for (bool ascii in <bool>[true, false]) {
      for (int columns in <int>[48, 80, 120]) {
        for (Set<String> checked in <Set<String>>[
          <String>{},
          <String>{'iris:fabric-26.1'},
          <String>{
            for (ProjectDashboardRow row in projectDashboardRows(
              groupedCatalog,
              null,
            ))
              row.key,
          },
        ]) {
          List<ProjectDashboardNode> nodes = projectDashboardTree(
            projectDashboardRows(groupedCatalog, null),
            <String>{'iris:@forge'},
          );
          ProjectDashboardFrame frame = _renderTree(
            nodes,
            columns: columns,
            lines: 32,
            selected: 3,
            checked: checked,
            theme: ascii ? MonitorTheme.plainAscii() : MonitorTheme.plain(),
          );
          expect(frame.lines.map(Ansi.visibleLength), everyElement(columns));
          expect(frame.checkboxes.length, frame.targetRows.length + 1);
          expect(frame.checkboxes[frame.selectAllRow]!.id, 'all');
          Map<int, int> checkboxColumns = <int, int>{};
          for (MapEntry<int, ButtonSpan> hit in frame.checkboxes.entries) {
            ButtonSpan span = hit.value;
            String row = Ansi.strip(frame.lines[hit.key]);
            expect(span.colStart, greaterThanOrEqualTo(0));
            expect(span.colEnd, lessThanOrEqualTo(columns));
            expect(span.colEnd - span.colStart, 3);
            String mark = row.substring(span.colStart, span.colEnd);
            if (span.id == 'all') {
              expect(
                mark,
                checked.isEmpty
                    ? '[ ]'
                    : checked.length == 8
                    ? '[X]'
                    : '[-]',
              );
            } else {
              ProjectDashboardNode node = nodes[frame.targetRows[hit.key]!];
              expect(span.id, node.key);
              expect(mark, node.checkbox(checked));
              checkboxColumns[node.depth] = span.colStart;
              expect(row.indexOf(mark), span.colStart);
              expect(frame.disclosures.containsKey(hit.key), node.isBranch);
            }
          }
          expect(checkboxColumns.keys.toSet(), <int>{0, 1, 2});
          expect(checkboxColumns[1]! - checkboxColumns[0]!, 3);
          expect(checkboxColumns[2]! - checkboxColumns[1]!, 3);
          for (MapEntry<int, ButtonSpan> hit in frame.disclosures.entries) {
            ProjectDashboardNode node = nodes[frame.targetRows[hit.key]!];
            String row = Ansi.strip(frame.lines[hit.key]);
            ButtonSpan span = hit.value;
            expect(span.id, node.key);
            expect(span.colEnd - span.colStart, 1);
            expect(span.colEnd, lessThan(frame.checkboxes[hit.key]!.colStart));
            String glyph = row.substring(span.colStart, span.colEnd);
            expect(
              glyph,
              ascii ? (node.expanded ? 'v' : '>') : (node.expanded ? '▾' : '▸'),
            );
          }
        }
      }
    }
  });

  test('tree occupies full body until the output pane is requested', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'matrix',
          'name': 'Matrix',
          'targets': <Object?>[
            for (int index = 1; index <= 50; index++)
              <String, Object?>{'id': 'target-$index'},
          ],
        },
      ], null),
      <String>{},
    );
    for (int columns in <int>[48, 80, 120]) {
      ProjectDashboardFrame full = _renderTree(
        nodes,
        columns: columns,
        lines: 24,
      );
      ProjectDashboardFrame output = _renderTree(
        nodes,
        columns: columns,
        lines: 24,
        showOutput: true,
      );
      expect(full.targetColumns, columns);
      expect(full.lines.join('\n'), isNot(contains('compiler output marker')));
      expect(output.lines.join('\n'), contains('compiler output marker'));
      expect(full.lines.length, 24);
      expect(output.lines.length, 24);
      expect(full.lines.map(Ansi.visibleLength), everyElement(columns));
      expect(output.lines.map(Ansi.visibleLength), everyElement(columns));
      if (columns < 120) {
        expect(full.targetRows.length, greaterThan(output.targetRows.length));
      } else {
        expect(output.targetColumns, lessThan(columns));
      }
    }
  });

  test('single-target catalogs retain totals and all-selection controls', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[groupedCatalog.last], null),
      <String>{},
    );
    ProjectDashboardFrame frame = _renderTree(
      nodes,
      checked: <String>{'gloss:bukkit'},
    );
    expect(nodes.single.isBranch, isFalse);
    expect(frame.targetRows.values, <int>[0]);
    expect(frame.disclosures, isEmpty);
    expect(frame.lines.join('\n'), contains('1 TARGETS'));
    expect(frame.checkboxes.values.map((ButtonSpan span) => span.id), <String>[
      'all',
      'gloss:bukkit',
    ]);
    for (MapEntry<int, ButtonSpan> hit in frame.checkboxes.entries) {
      expect(
        Ansi.strip(
          frame.lines[hit.key],
        ).substring(hit.value.colStart, hit.value.colEnd),
        '[X]',
      );
    }
    expect(
      frame.buttons.values.single.map((ButtonSpan span) => span.id),
      contains('build'),
    );
  });

  test('short stacked trees give spare rows to output', () {
    for (List<Map<String, Object?>> projects in <List<Map<String, Object?>>>[
      <Map<String, Object?>>[groupedCatalog.last],
      groupedCatalog,
    ]) {
      List<ProjectDashboardNode> nodes = projectDashboardTree(
        projectDashboardRows(projects, null),
        <String>{'iris:'},
      );
      int outputCapacity = 18 - (nodes.length + 3) - 2;
      ProjectDashboardFrame frame = _renderTree(
        nodes,
        showOutput: true,
        logs: <String>[
          for (int index = 1; index <= outputCapacity; index++) 'line $index',
        ],
      );
      expect(frame.lines.length, 24);
      expect(frame.targetRows.length, nodes.length);
      expect(frame.lines.map(Ansi.visibleLength), everyElement(80));
      expect(frame.lines[nodes.length + 6], contains('OUTPUT'));
      expect(frame.lines.join('\n'), contains('line 1 '));
      expect(frame.lines.join('\n'), contains('line $outputCapacity '));
    }
  });

  test('lateral trees fit labels and leave the remaining width for logs', () {
    for (int columns in <int>[120, 180, 240]) {
      List<ProjectDashboardNode> nodes = projectDashboardTree(
        projectDashboardRows(groupedCatalog, null),
        <String>{'iris:'},
      );
      ProjectDashboardFrame frame = _renderTree(
        nodes,
        columns: columns,
        showOutput: true,
      );
      expect(frame.targetColumns, 48);
      expect(frame.lines[4], contains('AGE'));
      expect(frame.lines[4], isNot(contains('TASK')));
      for (MapEntry<int, int> hit in frame.targetRows.entries) {
        expect(frame.lines[hit.key], contains(nodes[hit.value].displayLabel));
      }
      expect(frame.lines.map(Ansi.visibleLength), everyElement(columns));
    }
    List<ProjectDashboardNode> longNames = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'extended',
          'name': 'Extended project with a long display name',
          'targets': <Object?>[
            <String, Object?>{'id': 'bukkit'},
          ],
        },
      ], null),
      <String>{},
    );
    ProjectDashboardFrame bounded = _renderTree(
      longNames,
      columns: 120,
      showOutput: true,
    );
    expect(bounded.targetColumns, 71);
    expect(120 - bounded.targetColumns - 1, 48);
    ButtonSpan checkbox = bounded.checkboxes[5]!;
    expect(
      bounded.lines[5].substring(checkbox.colStart, checkbox.colEnd),
      '[ ]',
    );
  });

  test('output wraps long failures and paths without dropping their ends', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[groupedCatalog.last], null),
      <String>{},
    );
    String failure =
        'Could not resolve a required artifact because the remote repository '
        'rejected the request while resolving the selected build target.';
    String path = '/builds/${'long-directory/' * 12}missing-artifact.jar';
    for (int columns in <int>[48, 80, 120, 180]) {
      ProjectDashboardFrame frame = _renderTree(
        nodes,
        columns: columns,
        lines: 32,
        showOutput: true,
        logs: <String>['\x1b[2J$failure\x07', '', path],
      );
      int left = columns >= 120 ? frame.targetColumns + 3 : 2;
      int outputStart = columns >= 120 ? 4 : 8;
      List<String> content = frame.lines
          .sublist(outputStart, 28)
          .map((String line) => line.substring(left, columns - 2).trimRight())
          .toList(growable: false);
      expect(content.join(' '), contains(failure));
      expect(content.join(), contains(path));
      expect(content, contains(''));
      expect(frame.lines.join('\n'), isNot(contains('\x1b')));
      expect(frame.lines.map(Ansi.visibleLength), everyElement(columns));
    }
  });

  test('wrapped output follows the latest lines when the pane fills', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(<Map<String, Object?>>[groupedCatalog.last], null),
      <String>{},
    );
    ProjectDashboardFrame frame = _renderTree(
      nodes,
      columns: 48,
      lines: 14,
      showOutput: true,
      logs: <String>['old output', '${'x' * 150} final failure'],
    );
    expect(frame.lines.join('\n'), contains('final failure'));
    expect(frame.lines.join('\n'), isNot(contains('old output')));
    expect(frame.lines.map(Ansi.visibleLength), everyElement(48));
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
      <String>{'iris:'},
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
    expect(projectLine, contains('> [ ] Iris (2)'));
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
    expect(frame.lines[6], contains('├─   [ ] bukkit'));
    expect(frame.lines[7], contains('└─   [ ] fabric-26.1'));
    expect(frame.lines.map(Ansi.visibleLength), everyElement(120));
  });

  test('nested connectors continue only through remaining sibling groups', () {
    List<ProjectDashboardNode> nodes = projectDashboardTree(
      projectDashboardRows(groupedCatalog, null),
      <String>{},
    );
    for (bool ascii in <bool>[true, false]) {
      ProjectDashboardFrame frame = _renderTree(
        nodes,
        lines: 32,
        theme: ascii ? MonitorTheme.plainAscii() : MonitorTheme.plain(),
      );
      for ((String, String, String) example in <(String, String, String)>[
        ('iris:fabric-26.1', '|  |- ', '│  ├─ '),
        ('iris:fabric-26.2', '|  `- ', '│  └─ '),
        ('iris:neoforge-26.1', '   |- ', '   ├─ '),
        ('iris:neoforge-26.2', '   `- ', '   └─ '),
      ]) {
        int row = frame.targetRows.entries
            .singleWhere(
              (MapEntry<int, int> hit) => nodes[hit.value].key == example.$1,
            )
            .key;
        expect(
          Ansi.strip(frame.lines[row]),
          contains(ascii ? example.$2 : example.$3),
        );
      }
    }
  });

  test(
    'select-all state ignores checked targets outside the current catalog',
    () {
      List<ProjectDashboardNode> nodes = projectDashboardTree(
        projectDashboardRows(<Map<String, Object?>>[groupedCatalog.last], null),
        <String>{},
      );
      for ((Set<String>, String) selection in <(Set<String>, String)>[
        (<String>{'removed:bukkit'}, '[ ]'),
        (<String>{'gloss:bukkit', 'removed:bukkit'}, '[X]'),
      ]) {
        ProjectDashboardFrame frame = _renderTree(nodes, checked: selection.$1);
        ButtonSpan all = frame.checkboxes[frame.selectAllRow]!;
        String row = Ansi.strip(frame.lines[frame.selectAllRow!]);
        expect(row.substring(all.colStart, all.colEnd), selection.$2);
      }
    },
  );

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
          if (size.$1 >= 80) ...<String>['setup', 'actions'],
        ]);
        String row = frame.lines[frame.buttons.keys.single];
        for (ButtonSpan button in buttons) {
          expect(button.colStart, greaterThanOrEqualTo(0));
          expect(button.colEnd, lessThanOrEqualTo(size.$1));
          String label = switch (button.id) {
            'actions' => 'MORE',
            'setup' => 'CONVERT',
            _ => button.id.toUpperCase(),
          };
          expect(
            row.substring(button.colStart, button.colEnd),
            contains(label),
          );
        }
        expect(frame.lines.last, contains('e/z tree'));
        expect(frame.lines.last, contains('i convert'));
        if (size.$1 >= 80) {
          expect(frame.lines.last, contains('Enter open'));
          expect(frame.lines.last, contains('t output'));
        } else {
          expect(frame.lines.last, contains('t log'));
        }
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
