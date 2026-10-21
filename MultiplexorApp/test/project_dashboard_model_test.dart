import 'package:multiplexor/services/projects/project_dashboard_model.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
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
        rows: projectDashboardRows(catalog, run),
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
        expect(frame.lines.join('\n'), contains('running'));
        expect(frame.targetRows.length, 2);
        expect(
          frame.lines[frame.targetRows.entries.first.key],
          contains('bukkit'),
        );
      }
    }
  });

  test('stale state retains targets and gives a recovery message', () {
    ProjectDashboardFrame frame = renderProjectDashboard(
      columns: 100,
      lines: 24,
      rows: projectDashboardRows(catalog, run),
      selected: 0,
      run: run,
      logs: <String>[],
      notice: 'Project state unavailable. Retrying.',
      stale: true,
      theme: MonitorTheme.plainAscii(),
      now: DateTime.utc(2026),
    );
    expect(frame.lines.join('\n'), contains('Iris / bukkit'));
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
