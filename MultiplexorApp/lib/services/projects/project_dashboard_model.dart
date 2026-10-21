import 'dart:math' as math;

import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import 'project_build_limits.dart';

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
    required this.registered,
  });

  final String project;
  final String target;
  final String name;
  final Map<String, Object?> job;
  final bool registered;

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
          registered: true,
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
        registered: false,
      ),
    );
  }
  return rows;
}

class ProjectDashboardNode {
  const ProjectDashboardNode({
    required this.project,
    required this.name,
    required this.targets,
    this.target,
    this.expanded = false,
    this.lastChild = false,
  });

  final String project;
  final String name;
  final List<ProjectDashboardRow> targets;
  final ProjectDashboardRow? target;
  final bool expanded;
  final bool lastChild;

  bool get isProject => target == null;
  String get key => target?.key ?? '$project:';
  String get status {
    if (target != null) return target!.status;
    Set<String> states = targets
        .map((ProjectDashboardRow row) => row.status)
        .toSet();
    for (String state in <String>[
      'failed',
      'interrupted',
      'running',
      'preparing',
      'queued',
      'blocked',
      'cancelled',
    ]) {
      if (states.contains(state)) return state;
    }
    return states.length == 1 ? states.single : 'partial';
  }

  List<String> get buildKeys => targets
      .where((ProjectDashboardRow row) => row.registered)
      .map((ProjectDashboardRow row) => row.key)
      .toList(growable: false);

  String checkbox(Set<String> checked) {
    List<String> keys = buildKeys;
    if (keys.isEmpty) return ' - ';
    int count = keys.where(checked.contains).length;
    return count == 0
        ? '[ ]'
        : count == keys.length
        ? '[x]'
        : '[-]';
  }
}

List<ProjectDashboardNode> projectDashboardTree(
  List<ProjectDashboardRow> rows,
  Set<String> collapsed,
) {
  Map<String, List<ProjectDashboardRow>> projects =
      <String, List<ProjectDashboardRow>>{};
  for (ProjectDashboardRow row in rows) {
    projects.putIfAbsent(row.project, () => <ProjectDashboardRow>[]).add(row);
  }
  return <ProjectDashboardNode>[
    for (MapEntry<String, List<ProjectDashboardRow>> entry
        in projects.entries) ...<ProjectDashboardNode>[
      ProjectDashboardNode(
        project: entry.key,
        name: entry.value.first.name,
        targets: entry.value,
        expanded: !collapsed.contains(entry.key),
      ),
      if (!collapsed.contains(entry.key))
        for (ProjectDashboardRow row in entry.value)
          ProjectDashboardNode(
            project: entry.key,
            name: row.name,
            targets: <ProjectDashboardRow>[row],
            target: row,
            lastChild: identical(row, entry.value.last),
          ),
    ],
  ];
}

class ProjectDashboardFrame {
  const ProjectDashboardFrame({
    required this.lines,
    required this.targetRows,
    required this.targetColumns,
    this.selectAllRow,
    this.buttons = const <int, List<ButtonSpan>>{},
  });

  final List<String> lines;
  final Map<int, int> targetRows;
  final int targetColumns;
  final int? selectAllRow;
  final Map<int, List<ButtonSpan>> buttons;
}

ProjectDashboardFrame renderProjectDashboard({
  required int columns,
  required int lines,
  required List<ProjectDashboardNode> nodes,
  required Set<String> checked,
  required ProjectBuildLimits limits,
  required int selected,
  required Map<String, Object?>? run,
  required List<String> logs,
  required String notice,
  required bool stale,
  required MonitorTheme theme,
  required DateTime now,
  String? pressedButton,
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
  int? selectAllRow;
  Map<int, List<ButtonSpan>> buttons = <int, List<ButtonSpan>>{};
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
      'p Limits: ${limits.jobs} jobs  ${limits.memoryMiB} MiB'
      '  ${limits.workers} workers',
    );
    int bodyHeight = height - 6;
    bool lateral = width >= 120;
    int tableWidth = lateral ? (width * 0.58).floor() : width;
    targetColumns = tableWidth;
    int tableHeight = lateral ? bodyHeight : math.max(5, bodyHeight ~/ 2);
    int capacity = tableHeight - 3;
    int start = nodes.isEmpty ? 0 : (selected ~/ capacity) * capacity;
    int? parent;
    if (nodes.isNotEmpty && !nodes[start].isProject) {
      parent = nodes.lastIndexWhere(
        (ProjectDashboardNode node) =>
            node.isProject && node.project == nodes[start].project,
        start,
      );
      if (selected - parent < capacity) {
        start = parent;
        parent = null;
      } else {
        start = math.max(start, selected - capacity + 2);
      }
    }
    List<int> visible = <int>[
      ?parent,
      for (
        int index = start;
        index <
            math.min(nodes.length, start + capacity - (parent == null ? 0 : 1));
        index++
      )
        index,
    ];
    int identityWidth = math.max(24, (tableWidth - 4) ~/ 2);
    List<ProjectDashboardRow> targets = nodes
        .where((ProjectDashboardNode node) => node.isProject)
        .expand((ProjectDashboardNode node) => node.targets)
        .toList(growable: false);
    int buildable = targets
        .where((ProjectDashboardRow row) => row.registered)
        .length;
    String allCheckbox = buildable == 0
        ? ' - '
        : checked.isEmpty
        ? '[ ]'
        : checked.length == buildable
        ? '[x]'
        : '[-]';
    selectAllRow = buildable == 0 ? null : 4;
    List<String> table = <String>[
      '${fit('$allCheckbox   PROJECT / TARGET', identityWidth)} ${fit('STATE', 10)}'
          ' ${fit('AGE', 7)} TASK',
    ];
    for (int index in visible) {
      ProjectDashboardNode node = nodes[index];
      ProjectDashboardRow? row = node.target;
      String branch = node.isProject
          ? node.expanded
                ? '[-]'
                : '[+]'
          : node.lastChild
          ? theme.glyphs.isAscii
                ? '`- '
                : '└─ '
          : theme.glyphs.isAscii
          ? '|- '
          : '├─ ';
      String identity =
          '${node.checkbox(checked)} ${index == selected ? '>' : ' '}'
          ' $branch ${node.isProject ? '${node.name} (${node.targets.length})' : row!.target}';
      String state = node.status;
      String stateTone = switch (state) {
        'succeeded' => theme.ok,
        'failed' || 'blocked' || 'interrupted' => theme.danger,
        'running' || 'preparing' => theme.accent,
        'queued' => theme.warn,
        _ => theme.muted,
      };
      String content =
          '${fit(identity, identityWidth)} '
          '${theme.paint(fit(state, 10), stateTone)} '
          '${fit(row?.elapsed(now) ?? '-', 7)} ${row?.task ?? ''}';
      table.add(
        index == selected || node.isProject
            ? theme.paint(content, theme.bold)
            : content,
      );
      hitRows[4 + table.length - 1] = index;
    }
    if (nodes.isEmpty) {
      table.add('No projects registered. Press s to scan a source folder.');
    }
    while (table.length < tableHeight - 2) {
      table.add('');
    }
    List<String> tablePanel = renderPanel(
      title: 'PROJECTS / ${targets.length} TARGETS',
      badge: '${checked.length} checked',
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
      title: nodes.isEmpty
          ? 'OUTPUT'
          : nodes[selected].isProject
          ? 'PROJECT / ${nodes[selected].name}'
          : 'OUTPUT / ${nodes[selected].name} / ${nodes[selected].target!.target}',
      badge: nodes.isNotEmpty && !nodes[selected].isProject
          ? 'l full log'
          : null,
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
    ButtonRowRender actions = layoutButtonRow(
      buttons: <ButtonSpec>[
        const ButtonSpec(id: 'back', label: 'BACK', shortcut: 'q'),
        ButtonSpec(
          id: 'build',
          label: 'BUILD',
          shortcut: 'b',
          enabled: buildable > 0,
        ),
        const ButtonSpec(id: 'limits', label: 'LIMITS', shortcut: 'p'),
        const ButtonSpec(id: 'locations', label: 'LOCATIONS', shortcut: 'o'),
        const ButtonSpec(id: 'actions', label: 'MORE'),
      ],
      width: width,
      theme: theme,
      showShortcuts: width >= 80,
      pressedId: pressedButton,
      indent: 0,
    );
    buttons[frame.length] = actions.spans;
    frame.add(actions.row);
    frame.add(
      width < 80
          ? 'Space check  a all  x clear  Enter menu  s scan'
          : 'Space check  a all  x clear  Left/Right tree  Enter menu  s scan  h runs  d deploy',
    );
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
    selectAllRow: selectAllRow,
    buttons: buttons,
  );
}
