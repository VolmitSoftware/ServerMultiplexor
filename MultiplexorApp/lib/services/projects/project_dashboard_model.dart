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

String projectRunTiming(Map<String, Object?> run, DateTime now) {
  DateTime? started =
      DateTime.tryParse(projectText(run['createdAt'])) ??
      DateTime.tryParse(projectText(run['startedAt']));
  DateTime? finished = DateTime.tryParse(projectText(run['finishedAt']));
  String status = projectText(run['status']);
  bool active =
      finished == null &&
      <String>{'queued', 'preparing', 'running'}.contains(status);
  DateTime? ended =
      finished ??
      (active
          ? now
          : status == 'interrupted'
          ? DateTime.tryParse(projectText(run['heartbeatAt']))
          : null);
  String duration = started == null || ended == null
      ? '-'
      : formatCompactDuration(ended.difference(started));
  return '${active ? 'Elapsed' : 'Total'} $duration';
}

List<Map<String, Object?>> projectDashboardCatalog(
  List<Map<String, Object?>> catalog,
) => catalog
    .where((Map<String, Object?> project) {
      List<Map<String, Object?>> targets = projectMaps(project['targets']);
      return targets.isEmpty ||
          !targets.every((Map<String, Object?> target) {
            List<Map<String, Object?>> artifacts = projectMaps(
              target['artifacts'],
            );
            return artifacts.isNotEmpty &&
                artifacts.every(
                  (Map<String, Object?> artifact) =>
                      artifact['role'] == 'library',
                );
          });
    })
    .toList(growable: false);

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
  for (Map<String, Object?> project in projectDashboardCatalog(catalog)) {
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
    Map<String, Object?>? definition = catalog
        .where((Map<String, Object?> item) => item['id'] == project)
        .firstOrNull;
    rows.add(
      ProjectDashboardRow(
        project: project,
        target: projectText(entry.value['target']),
        name: projectText(definition?['name'] ?? project),
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
    this.group,
    this.ancestors = const <String>[],
    this.ancestorLastChildren = const <bool>[],
    this.expanded = false,
    this.lastChild = false,
  });

  final String project;
  final String name;
  final List<ProjectDashboardRow> targets;
  final ProjectDashboardRow? target;
  final String? group;
  final List<String> ancestors;
  final List<bool> ancestorLastChildren;
  final bool expanded;
  final bool lastChild;

  bool get isBranch => target == null;
  bool get isProject => isBranch && group == null;
  int get depth => ancestors.length;
  String? get parentKey => ancestors.lastOrNull;
  String get key => target?.key ?? '$project:${group == null ? '' : '@$group'}';
  String get displayLabel {
    if (isProject) return name;
    if (isBranch) {
      return switch (group) {
        'fabric' => 'Fabric',
        'forge' => 'Forge',
        'neoforge' => 'NeoForge',
        _ => group!,
      };
    }
    if (depth == 0) return '$name / ${target!.target}';
    return group == null
        ? target!.target
        : target!.target.substring(group!.length + 1);
  }

  String treePrefix({required bool ascii}) {
    if (depth == 0) return '';
    return '${ancestorLastChildren.map((bool last) => last
            ? '   '
            : ascii
            ? '|  '
            : '│  ').join()}'
        '${lastChild
            ? ascii
                  ? '`- '
                  : '└─ '
            : ascii
            ? '|- '
            : '├─ '}';
  }

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
        ? '[X]'
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
  List<ProjectDashboardNode> nodes = <ProjectDashboardNode>[];
  for (MapEntry<String, List<ProjectDashboardRow>> entry in projects.entries) {
    if (entry.value.length == 1) {
      nodes.add(
        ProjectDashboardNode(
          project: entry.key,
          name: entry.value.single.name,
          targets: entry.value,
          target: entry.value.single,
        ),
      );
      continue;
    }
    String projectKey = '${entry.key}:';
    nodes.add(
      ProjectDashboardNode(
        project: entry.key,
        name: entry.value.first.name,
        targets: entry.value,
        expanded: !collapsed.contains(projectKey),
      ),
    );
    if (collapsed.contains(projectKey)) continue;
    Map<String, List<ProjectDashboardRow>> platforms =
        <String, List<ProjectDashboardRow>>{};
    for (ProjectDashboardRow row in entry.value) {
      String platform = row.target.split('-').first;
      if (<String>{'fabric', 'forge', 'neoforge'}.contains(platform) &&
          row.target.startsWith('$platform-')) {
        platforms.putIfAbsent(platform, () => <ProjectDashboardRow>[]).add(row);
      }
    }
    Set<String> emitted = <String>{};
    List<(String?, List<ProjectDashboardRow>)> children =
        <(String?, List<ProjectDashboardRow>)>[];
    for (ProjectDashboardRow row in entry.value) {
      String platform = row.target.split('-').first;
      List<ProjectDashboardRow>? siblings = platforms[platform];
      if (siblings != null && siblings.length > 1) {
        if (emitted.add(platform)) children.add((platform, siblings));
      } else {
        children.add((null, <ProjectDashboardRow>[row]));
      }
    }
    for (int index = 0; index < children.length; index++) {
      (String?, List<ProjectDashboardRow>) child = children[index];
      String? group = child.$1;
      bool last = index == children.length - 1;
      if (group == null) {
        nodes.add(
          ProjectDashboardNode(
            project: entry.key,
            name: child.$2.single.name,
            targets: child.$2,
            target: child.$2.single,
            ancestors: <String>[projectKey],
            lastChild: last,
          ),
        );
        continue;
      }
      String groupKey = '${entry.key}:@$group';
      nodes.add(
        ProjectDashboardNode(
          project: entry.key,
          name: entry.value.first.name,
          targets: child.$2,
          group: group,
          ancestors: <String>[projectKey],
          expanded: !collapsed.contains(groupKey),
          lastChild: last,
        ),
      );
      if (collapsed.contains(groupKey)) continue;
      for (ProjectDashboardRow row in child.$2) {
        nodes.add(
          ProjectDashboardNode(
            project: entry.key,
            name: row.name,
            targets: <ProjectDashboardRow>[row],
            target: row,
            group: group,
            ancestors: <String>[projectKey, groupKey],
            ancestorLastChildren: <bool>[last],
            lastChild: identical(row, child.$2.last),
          ),
        );
      }
    }
  }
  return nodes;
}

List<int> projectTreeViewport(
  List<ProjectDashboardNode> nodes,
  int selected,
  int capacity,
) {
  if (nodes.isEmpty || capacity <= 0) return <int>[];
  int start = math.max(0, selected - capacity + 1);
  List<int> parents = nodes[selected].ancestors
      .map(
        (String key) =>
            nodes.indexWhere((ProjectDashboardNode node) => node.key == key),
      )
      .where((int index) => index >= 0)
      .toList(growable: false);
  List<int> pinned = <int>[];
  while (true) {
    pinned = parents
        .where((int index) => index < start)
        .toList(growable: false);
    if (pinned.length >= capacity) {
      pinned = pinned.sublist(pinned.length - capacity + 1);
    }
    if (selected < start + capacity - pinned.length) break;
    start++;
  }
  return <int>[
    ...pinned,
    for (
      int index = start;
      index < math.min(nodes.length, start + capacity - pinned.length);
      index++
    )
      index,
  ];
}

class ProjectDashboardFrame {
  const ProjectDashboardFrame({
    required this.lines,
    required this.targetRows,
    required this.targetColumns,
    this.selectAllRow,
    this.checkboxes = const <int, ButtonSpan>{},
    this.disclosures = const <int, ButtonSpan>{},
    this.buttons = const <int, List<ButtonSpan>>{},
  });

  final List<String> lines;
  final Map<int, int> targetRows;
  final int targetColumns;
  final int? selectAllRow;
  final Map<int, ButtonSpan> checkboxes;
  final Map<int, ButtonSpan> disclosures;
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
  bool showOutput = true,
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
  Map<int, ButtonSpan> checkboxes = <int, ButtonSpan>{};
  Map<int, ButtonSpan> disclosures = <int, ButtonSpan>{};
  if (width < 48 || height < 14) {
    frame.addAll(<String>[
      'Use a terminal at least 48 columns by 14 rows.',
      'Builds continue while this view is closed.',
      'q / Esc: detach',
    ]);
  } else {
    String runLabel = 'No build runs. Press b to build or s to scan sources.';
    if (run != null) {
      String timing = projectRunTiming(run, now);
      String identity =
          '${projectText(run['status']).toUpperCase()}  ${projectText(run['id'])}';
      runLabel = '${fit(identity, width - timing.length - 2)}  $timing';
    }
    frame.add(runLabel);
    frame.add(
      'p Limits: ${limits.jobs} jobs  ${limits.memoryMiB} MiB'
      '  ${limits.workers} workers',
    );
    int bodyHeight = height - 6;
    bool lateral = showOutput && width >= 120;
    int tableHeight = !showOutput || lateral
        ? bodyHeight
        : math.min(
            math.max(4, nodes.length + 3),
            math.max(5, (bodyHeight * 0.65).floor()),
          );
    int capacity = tableHeight - 3;
    List<int> visible = projectTreeViewport(nodes, selected, capacity);
    int naturalIdentityWidth = 11;
    for (int index in visible) {
      ProjectDashboardNode node = nodes[index];
      String label = node.isBranch
          ? '${node.displayLabel} (${node.targets.length})'
          : node.displayLabel;
      naturalIdentityWidth = math.max(
        naturalIdentityWidth,
        8 + node.depth * 3 + Ansi.visibleLength(label),
      );
    }
    int tableWidth = lateral
        ? (naturalIdentityWidth + 23).clamp(48, width - 49)
        : width;
    targetColumns = tableWidth;
    bool showAge = lateral || tableWidth >= 68;
    bool showTask = !lateral && tableWidth >= 100;
    int identityWidth = showTask
        ? ((tableWidth - 4) * 0.6).floor()
        : tableWidth - 4 - (showAge ? 19 : 11);
    List<ProjectDashboardRow> targets = nodes
        .where((ProjectDashboardNode node) => node.depth == 0)
        .expand((ProjectDashboardNode node) => node.targets)
        .toList(growable: false);
    Set<String> buildableKeys = targets
        .where((ProjectDashboardRow row) => row.registered)
        .map((ProjectDashboardRow row) => row.key)
        .toSet();
    int buildable = buildableKeys.length;
    int checkedCount = buildableKeys.where(checked.contains).length;
    String allCheckbox = buildable == 0
        ? ' - '
        : checkedCount == 0
        ? '[ ]'
        : checkedCount == buildable
        ? '[X]'
        : '[-]';
    selectAllRow = buildable == 0 ? null : 4;
    if (buildable > 0) {
      checkboxes[4] = const ButtonSpan(id: 'all', colStart: 6, colEnd: 9);
    }
    List<String> table = <String>[
      '${fit('    $allCheckbox ALL', identityWidth)} ${fit('STATE', 10)}'
          '${showAge ? ' ${fit('AGE', 7)}' : ''}${showTask ? ' TASK' : ''}',
    ];
    for (int index in visible) {
      ProjectDashboardNode node = nodes[index];
      ProjectDashboardRow? row = node.target;
      String branch = node.treePrefix(ascii: theme.glyphs.isAscii);
      String disclosure = !node.isBranch
          ? ' '
          : node.expanded
          ? theme.glyphs.isAscii
                ? 'v'
                : '▾'
          : theme.glyphs.isAscii
          ? '>'
          : '▸';
      String prefix = '${index == selected ? '>' : ' '} $branch';
      String label = node.isBranch
          ? '${node.displayLabel} (${node.targets.length})'
          : node.displayLabel;
      String identity = '$prefix$disclosure ${node.checkbox(checked)} $label';
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
          '${theme.paint(fit(state, 10), stateTone)}'
          '${showAge ? ' ${fit(row?.elapsed(now) ?? '-', 7)}' : ''}'
          '${showTask ? ' ${row?.task ?? ''}' : ''}';
      table.add(
        index == selected
            ? theme.paint(content, '${theme.bold}${theme.textStrong}')
            : node.isBranch
            ? theme.paint(content, theme.bold)
            : content,
      );
      int screenRow = 4 + table.length - 1;
      int disclosureColumn = 2 + Ansi.visibleLength(prefix);
      hitRows[screenRow] = index;
      if (node.buildKeys.isNotEmpty) {
        checkboxes[screenRow] = ButtonSpan(
          id: node.key,
          colStart: disclosureColumn + 2,
          colEnd: disclosureColumn + 5,
        );
      }
      if (node.isBranch) {
        disclosures[screenRow] = ButtonSpan(
          id: node.key,
          colStart: disclosureColumn,
          colEnd: disclosureColumn + 1,
        );
      }
    }
    if (nodes.isEmpty) {
      table.add('No projects. Press i to convert or s to scan.');
    }
    while (table.length < tableHeight - 2) {
      table.add('');
    }
    List<String> tablePanel = renderPanel(
      title: 'PROJECTS / ${targets.length} TARGETS',
      badge: '$checkedCount checked',
      content: table,
      width: tableWidth,
      theme: theme,
      emphasis: PanelEmphasis.active,
    );
    if (showOutput) {
      int logHeight = lateral ? bodyHeight : bodyHeight - tableHeight;
      int logWidth = lateral ? width - tableWidth - 1 : width;
      int logCapacity = math.max(0, logHeight - 2);
      List<String> logLines = logs.isEmpty
          ? <String>['Select a target to inspect its build output.']
          : logs;
      List<String> logContent = _projectOutputTail(
        logLines,
        logWidth - 4,
        logCapacity,
      );
      while (logContent.length < logCapacity) {
        logContent.add('');
      }
      ProjectDashboardNode? focused = nodes.isEmpty ? null : nodes[selected];
      List<String> logPanel = renderPanel(
        title: focused == null
            ? 'OUTPUT'
            : 'OUTPUT / ${focused.name}'
                  '${focused.isProject ? '' : ' / ${focused.target?.target ?? focused.displayLabel}'}',
        badge: 't hide',
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
    } else {
      frame.addAll(tablePanel);
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
        const ButtonSpec(id: 'setup', label: 'CONVERT', shortcut: 'i'),
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
          ? 'Space mark a/x all/none e/z tree t log i convert'
          : 'Space check a all x clear e/z tree t output Enter open m menu s scan i convert',
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
    checkboxes: checkboxes,
    disclosures: disclosures,
    buttons: buttons,
  );
}

List<String> _projectOutputTail(List<String> logs, int width, int capacity) {
  List<String> result = <String>[];
  if (width <= 0 || capacity <= 0) return result;
  for (String raw in logs.reversed) {
    String line = projectText(raw);
    List<String> wrapped = <String>[];
    if (line.isEmpty) wrapped.add('');
    int start = 0;
    while (start < line.length) {
      int end = math.min(line.length, start + width);
      if (end < line.length) {
        int boundary = line.lastIndexOf(' ', end);
        if (boundary > start + width ~/ 2) end = boundary;
      }
      wrapped.add(line.substring(start, end));
      start = end;
      if (start < line.length && line[start] == ' ') start++;
    }
    for (String row in wrapped.reversed) {
      result.add(row);
      if (result.length == capacity) return result.reversed.toList();
    }
  }
  return result.reversed.toList();
}
