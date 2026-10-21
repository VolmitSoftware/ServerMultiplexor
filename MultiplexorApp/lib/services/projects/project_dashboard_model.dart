import 'dart:math' as math;

import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';

List<Map<String, Object?>> projectMaps(Object? value) => value is List
    ? value.whereType<Map<String, Object?>>().toList(growable: false)
    : const <Map<String, Object?>>[];

String projectText(Object? value) => (value?.toString() ?? '')
    .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');

String projectOutputText(String value) =>
    value.split('\n').map(projectText).join('\n');

class ProjectDashboardRow {
  const ProjectDashboardRow({
    required this.project,
    required this.target,
    required this.name,
    required this.job,
  });

  final String project;
  final String target;
  final String name;
  final Map<String, Object?> job;

  String get key => '$project:$target';
  String get status => projectText(job['status'] ?? 'ready');
  String get task => projectText(job['currentTask']);
  String get error => projectText(job['error']);
  String get logPath => projectText(job['logPath']);

  String elapsed(DateTime now) {
    DateTime? started = DateTime.tryParse(projectText(job['startedAt']));
    if (started == null) return '-';
    DateTime ended = DateTime.tryParse(projectText(job['finishedAt'])) ?? now;
    return formatCompactDuration(ended.difference(started));
  }
}

List<ProjectDashboardRow> projectDashboardRows(
  List<Map<String, Object?>> catalog,
  Map<String, Object?>? run,
) {
  Map<String, Map<String, Object?>> jobs = <String, Map<String, Object?>>{
    for (Map<String, Object?> job in projectMaps(run?['jobs']))
      projectText(job['key'] ?? '${job['project']}:${job['target']}'): job,
  };
  List<ProjectDashboardRow> rows = <ProjectDashboardRow>[];
  Set<String> keys = <String>{};
  for (Map<String, Object?> project in catalog) {
    String id = projectText(project['id']);
    for (Map<String, Object?> target in projectMaps(project['targets'])) {
      String targetId = projectText(target['id']);
      String key = '$id:$targetId';
      if (!keys.add(key)) continue;
      rows.add(
        ProjectDashboardRow(
          project: id,
          target: targetId,
          name: projectText(project['name'] ?? id),
          job: jobs[key] ?? const <String, Object?>{},
        ),
      );
    }
  }
  for (MapEntry<String, Map<String, Object?>> entry in jobs.entries) {
    if (!keys.add(entry.key)) continue;
    String project = projectText(entry.value['project']);
    rows.add(
      ProjectDashboardRow(
        project: project,
        target: projectText(entry.value['target']),
        name: project,
        job: entry.value,
      ),
    );
  }
  return rows;
}

class ProjectDashboardFrame {
  const ProjectDashboardFrame({
    required this.lines,
    required this.targetRows,
    required this.targetColumns,
  });

  final List<String> lines;
  final Map<int, int> targetRows;
  final int targetColumns;
}

ProjectDashboardFrame renderProjectDashboard({
  required int columns,
  required int lines,
  required List<ProjectDashboardRow> rows,
  required int selected,
  required Map<String, Object?>? run,
  required List<String> logs,
  required String notice,
  required bool stale,
  required MonitorTheme theme,
  required DateTime now,
}) {
  int width = math.max(1, columns);
  int height = math.max(1, lines);
  String fit(String text, int size) => Ansi.padVisible(
    Ansi.clipVisible(text, math.max(0, size)),
    math.max(0, size),
  );
  List<String> frame = <String>[
    theme.paint('MULTIPLEXOR / PROJECTS', '${theme.bold}${theme.textStrong}'),
  ];
  Map<int, int> hitRows = <int, int>{};
  int targetColumns = 0;
  if (width < 48 || height < 14) {
    frame.addAll(<String>[
      'Use a terminal at least 48 columns by 14 rows.',
      'Builds continue while this view is closed.',
      'q / Esc: detach',
    ]);
  } else {
    String runLabel = run == null
        ? 'No build runs. Press b to build or s to scan sources.'
        : '${projectText(run['id'])}  ${projectText(run['status']).toUpperCase()}';
    frame.add(runLabel);
    frame.add(
      run == null
          ? '${rows.length} targets in the saved catalog'
          : '${rows.length} targets  |  budget: jobs ${run['jobsLimit'] ?? '-'}'
                '  memory ${run['memoryMiB'] ?? '-'} MiB'
                '  workers ${run['workers'] ?? '-'}',
    );
    int bodyHeight = height - 6;
    bool lateral = width >= 120;
    int tableWidth = lateral ? (width * 0.58).floor() : width;
    targetColumns = tableWidth;
    int tableHeight = lateral ? bodyHeight : math.max(5, bodyHeight ~/ 2);
    int capacity = tableHeight - 3;
    int start = rows.isEmpty ? 0 : (selected ~/ capacity) * capacity;
    int identityWidth = math.max(15, (tableWidth - 4) ~/ 2);
    List<String> table = <String>[
      '${fit('PROJECT / TARGET', identityWidth)} ${fit('STATE', 10)}'
          ' ${fit('AGE', 7)} TASK',
    ];
    for (
      int index = start;
      index < math.min(rows.length, start + capacity);
      index++
    ) {
      ProjectDashboardRow row = rows[index];
      String identity =
          '${index == selected ? '>' : ' '} ${row.name} / ${row.target}';
      String stateTone = switch (row.status) {
        'succeeded' => theme.ok,
        'failed' || 'blocked' || 'interrupted' => theme.danger,
        'running' || 'preparing' => theme.accent,
        'queued' => theme.warn,
        _ => theme.muted,
      };
      String content =
          '${fit(identity, identityWidth)} '
          '${theme.paint(fit(row.status, 10), stateTone)} '
          '${fit(row.elapsed(now), 7)} ${row.task}';
      table.add(index == selected ? theme.paint(content, theme.bold) : content);
      hitRows[4 + table.length - 1] = index;
    }
    if (rows.isEmpty) {
      table.add('No projects registered. Press s to scan a source folder.');
    }
    while (table.length < tableHeight - 2) {
      table.add('');
    }
    List<String> tablePanel = renderPanel(
      title: 'TARGETS',
      badge: rows.isEmpty ? '0' : '${selected + 1}/${rows.length}',
      content: table,
      width: tableWidth,
      theme: theme,
      emphasis: PanelEmphasis.active,
    );
    int logHeight = lateral ? bodyHeight : bodyHeight - tableHeight;
    int logWidth = lateral ? width - tableWidth - 1 : width;
    int logCapacity = math.max(0, logHeight - 2);
    List<String> logLines = logs.isEmpty
        ? <String>['Select a target to inspect its build output.']
        : logs;
    List<String> logContent = <String>[
      ...logLines
          .skip(math.max(0, logLines.length - logCapacity))
          .map(projectText),
    ];
    while (logContent.length < logCapacity) {
      logContent.add('');
    }
    List<String> logPanel = renderPanel(
      title: rows.isEmpty ? 'OUTPUT' : 'OUTPUT / ${rows[selected].target}',
      badge: 'l full log',
      content: logContent,
      width: logWidth,
      theme: theme,
    );
    if (lateral) {
      for (int index = 0; index < bodyHeight; index++) {
        frame.add('${tablePanel[index]} ${logPanel[index]}');
      }
    } else {
      frame.addAll(tablePanel);
      frame.addAll(logPanel);
    }
    frame.add(
      theme.paint(
        '${stale ? 'STALE: ' : ''}$notice',
        stale ? theme.warn : theme.muted,
      ),
    );
    frame.add(
      'Enter actions  b build  s scan  h runs  r retry  c cancel  d deploy',
    );
    frame.add('Arrows / wheel select  PgUp/PgDn logs  q / Esc detach');
  }
  while (frame.length < height) {
    frame.add('');
  }
  return ProjectDashboardFrame(
    lines: frame
        .take(height)
        .map((String line) => fit(line, width))
        .toList(growable: false),
    targetRows: hitRows,
    targetColumns: targetColumns,
  );
}
