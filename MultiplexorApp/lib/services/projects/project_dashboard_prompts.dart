import 'dart:convert';
import 'dart:io';

import '../../utils/user_prompt.dart';
import 'project_build_limits.dart';
import 'project_dashboard_model.dart';
import 'project_destination_editor.dart';

enum ProjectDashboardAction {
  actions,
  build,
  scan,
  setup,
  history,
  retry,
  cancel,
  deploy,
  logs,
  limits,
  locations,
}

typedef ProjectDashboardCommand =
    Future<int> Function(
      List<String> arguments, {
      required void Function(String) output,
      required void Function(String) error,
    });

class ProjectDashboardSelection {
  const ProjectDashboardSelection({
    required this.row,
    required this.run,
    required this.runs,
    required this.catalog,
    required this.limits,
    this.node,
    this.checkedTargets = const <String>[],
    this.destinations = const <Map<String, Object?>>[],
  });

  final ProjectDashboardRow? row;
  final Map<String, Object?>? run;
  final List<Map<String, Object?>> runs;
  final List<Map<String, Object?>> catalog;
  final ProjectBuildLimits limits;
  final ProjectDashboardNode? node;
  final List<String> checkedTargets;
  final List<Map<String, Object?>> destinations;

  String? get project => node?.project ?? row?.project;
  String? get projectName => node?.name ?? row?.name;
  bool get registered =>
      node == null ? row?.registered ?? false : node!.buildKeys.isNotEmpty;
}

class ProjectDashboardPrompts {
  ProjectDashboardPrompts(this.command);

  final ProjectDashboardCommand command;
  String _packaging = 'compact';
  bool _reuse = true;

  Future<List<String>?> request(
    ProjectDashboardAction action,
    ProjectDashboardSelection selection,
  ) async {
    switch (action) {
      case ProjectDashboardAction.actions:
        return _actions(selection);
      case ProjectDashboardAction.build:
        return _build(selection);
      case ProjectDashboardAction.limits:
        return _limits(selection.limits);
      case ProjectDashboardAction.locations:
        return _locations(selection);
      case ProjectDashboardAction.scan:
        return _scan(selection);
      case ProjectDashboardAction.setup:
        return _setup();
      case ProjectDashboardAction.history:
        return _history(selection);
      case ProjectDashboardAction.retry:
        String? run = selection.run?['id'] as String?;
        return run == null ? null : <String>['retry', run];
      case ProjectDashboardAction.cancel:
        String? run = selection.run?['id'] as String?;
        if (run == null) return null;
        stdout.writeln(
          Ui.theme.paint('Cancel build run $run', Ui.theme.danger),
        );
        if (!await Ui.confirm(
          'Stop its active and queued targets?',
          defaultValue: false,
        )) {
          return null;
        }
        return <String>['cancel', run];
      case ProjectDashboardAction.deploy:
        return _deploy(selection);
      case ProjectDashboardAction.logs:
        if (selection.run == null || selection.row == null) return null;
        await command(
          <String>[
            'logs',
            projectText(selection.run!['id']),
            '--target',
            selection.row!.key,
          ],
          output: (String line) => stdout.writeln(projectOutputText(line)),
          error: (String line) => stdout.writeln(
            Ui.theme.paint(projectText(line), Ui.theme.danger),
          ),
        );
        await Ui.pause();
        return null;
    }
  }

  Future<List<String>?> _actions(ProjectDashboardSelection selection) async {
    List<MenuEntry<String>> entries = <MenuEntry<String>>[
      if (selection.catalog.isNotEmpty)
        MenuEntry<String>(
          selection.checkedTargets.isNotEmpty
              ? 'Build ${selection.checkedTargets.length} checked targets'
              : 'Build targets',
          value: 'build',
          shortcut: 'b',
        ),
      const MenuEntry<String>(
        'Scan source folder',
        value: 'scan',
        shortcut: 's',
      ),
      const MenuEntry<String>(
        'Convert Gradle project',
        value: 'setup',
        shortcut: 'i',
        detail: 'Add Multiplexor build targets to an existing Gradle project',
      ),
      MenuEntry<String>(
        'Build limits',
        value: 'limits',
        detail:
            '${selection.limits.jobs} jobs / ${selection.limits.memoryMiB} MiB / ${selection.limits.workers} workers',
        shortcut: 'p',
      ),
      const MenuEntry<String>(
        'Manage locations',
        value: 'locations',
        shortcut: 'o',
      ),
      if (selection.runs.isNotEmpty)
        const MenuEntry<String>('Run history', value: 'history', shortcut: 'h'),
      if (selection.row?.logPath.isNotEmpty ?? false)
        const MenuEntry<String>(
          'Show complete target log',
          value: 'logs',
          shortcut: 'l',
        ),
      if (selection.run != null) ...<MenuEntry<String>>[
        const MenuEntry<String>(
          'Retry unsuccessful targets',
          value: 'retry',
          shortcut: 'r',
        ),
        const MenuEntry<String>(
          'Preview artifact delivery',
          value: 'deploy',
          shortcut: 'd',
        ),
        if (<String>{
          'queued',
          'preparing',
          'running',
        }.contains(selection.run!['status']))
          MenuEntry<String>(
            'Cancel run',
            value: 'cancel',
            shortcut: 'c',
            labelColor: Ui.theme.danger,
          ),
      ],
      const MenuEntry<String>('Back', value: 'back', shortcut: 'q'),
    ];
    while (true) {
      String selected = await menuSelect<String>('Projects', entries);
      if (selected == 'back') return null;
      try {
        List<String>? result = await request(
          ProjectDashboardAction.values.byName(selected),
          selection,
        );
        if (result != null) return result;
      } on PromptBackNavigation {
        continue;
      }
    }
  }

  Future<List<String>?> _build(ProjectDashboardSelection selection) async {
    if (selection.catalog.isEmpty) return _scan(selection);
    ProjectDashboardRow? row = selection.row;
    while (true) {
      String
      scope = await menuSelect<String>('Build targets', <MenuEntry<String>>[
        if (selection.checkedTargets.isNotEmpty)
          MenuEntry<String>(
            'Build ${selection.checkedTargets.length} checked targets',
            value: 'checked',
            detail: selection.checkedTargets.join(', '),
          ),
        if (row != null && row.registered)
          MenuEntry<String>('${row.name} / ${row.target}', value: 'target'),
        if (selection.registered)
          MenuEntry<String>(
            'Every target in ${selection.projectName}',
            value: 'project',
          ),
        const MenuEntry<String>(
          'Every listed project and target',
          value: 'all',
        ),
        MenuEntry<String>(
          'Reuse verified artifacts',
          value: 'reuse',
          detail: _reuse
              ? 'On: rebuild changed targets'
              : 'Off: run Gradle for every target',
        ),
        MenuEntry<String>(
          'Packaging',
          value: 'packaging',
          detail: _packaging == 'local'
              ? 'Local: full checks, fast compression'
              : 'Compact: full checks, maximum compression',
        ),
        MenuEntry<String>(
          'Change build limits',
          value: 'limits',
          detail:
              '${selection.limits.jobs} jobs / ${selection.limits.memoryMiB} MiB / ${selection.limits.workers} workers',
        ),
        const MenuEntry<String>('Back', value: 'back', shortcut: 'q'),
      ]);
      if (scope == 'back') return null;
      if (scope == 'reuse') {
        _reuse = !_reuse;
        continue;
      }
      if (scope == 'packaging') {
        _packaging = _packaging == 'local' ? 'compact' : 'local';
        continue;
      }
      if (scope == 'limits') {
        try {
          List<String>? result = await _limits(selection.limits);
          if (result != null) return result;
        } on PromptBackNavigation {
          continue;
        }
        continue;
      }
      if (scope == 'checked' && selection.checkedTargets.isEmpty) {
        throw StateError('No targets are checked');
      }
      return <String>[
        'build',
        if (scope == 'checked') ...<String>[
          '--targets',
          selection.checkedTargets.join(','),
        ] else if (scope == 'all') ...<String>[
          '--targets',
          projectDashboardRows(
            selection.catalog,
            null,
          ).map((ProjectDashboardRow target) => target.key).join(','),
        ] else
          selection.project!,
        if (_reuse) '--changed',
        '--packaging',
        _packaging,
        if (scope == 'target') ...<String>[
          '--target',
          row!.target,
        ] else if (scope == 'project')
          '--all-targets',
        '--jobs',
        '${selection.limits.jobs}',
        '--memory',
        '${selection.limits.memoryMiB}',
        '--workers',
        '${selection.limits.workers}',
      ];
    }
  }

  Future<List<String>?> _limits(ProjectBuildLimits limits) async {
    Map<String, int> values = <String, int>{
      'jobs': limits.jobs,
      'memory': limits.memoryMiB,
      'workers': limits.workers,
    };
    Map<String, String> labels = <String, String>{
      'jobs': 'Parallel builds',
      'memory': 'Total memory budget (MiB)',
      'workers': 'Total Gradle workers',
    };
    while (true) {
      String
      setting = await menuSelect<String>('Build limits', <MenuEntry<String>>[
        for (String key in values.keys)
          MenuEntry<String>(labels[key]!, value: key, detail: '${values[key]}'),
        const MenuEntry<String>('Save limits', value: 'save'),
        const MenuEntry<String>('Back', value: 'back', shortcut: 'q'),
      ], footer: 'Limits apply to new builds. Memory is a scheduling budget.');
      if (setting == 'back') return null;
      if (setting == 'save') {
        return <String>[
          'limits',
          for (MapEntry<String, int> value in values.entries) ...<String>[
            '--${value.key}',
            '${value.value}',
          ],
        ];
      }
      try {
        values[setting] = int.parse(
          await Ui.input(
            labels[setting]!,
            defaultValue: '${values[setting]}',
            validator: (String value) => (int.tryParse(value) ?? 0) > 0,
            validationMessage: 'Enter a positive integer.',
          ),
        );
      } on PromptBackNavigation {
        continue;
      }
    }
  }

  Future<List<String>> _scan(ProjectDashboardSelection selection) async =>
      <String>[
        'scan',
        await Ui.input(
          'Source folder',
          defaultValue: selection.catalog.isEmpty
              ? Directory.current.path
              : projectText(selection.catalog.first['sourceRoot']),
          validator: (String value) => value.isNotEmpty,
        ),
      ];

  Future<List<String>?> _setup() async {
    stdout.writeln(Ui.theme.paint('CONVERT GRADLE PROJECT', Ui.theme.bold));
    stdout.writeln(
      'Choose the project root containing gradlew and build.gradle or build.gradle.kts.',
    );
    stdout.writeln(
      'Review detected targets and file changes, then confirm to write them and scan the project.',
    );
    String path = await Ui.input(
      'Project root folder',
      validator: (String value) => value.trim().isNotEmpty,
    );
    List<String> output = <String>[];
    List<String> errors = <String>[];
    List<String> arguments = <String>['init', path, '--json'];
    int code = await command(arguments, output: output.add, error: errors.add);
    if (code != 0) {
      for (String error in errors) {
        stdout.writeln(Ui.theme.paint(projectText(error), Ui.theme.danger));
      }
      await Ui.pause();
      return null;
    }
    Object? decoded = jsonDecode(output.join('\n'));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid project setup preview');
    }
    stdout.writeln(Ui.theme.paint('CONVERSION PREVIEW', Ui.theme.bold));
    stdout.writeln(projectText(decoded['path']));
    for (Map<String, Object?> target in projectMaps(decoded['targets'])) {
      stdout.writeln(
        '${projectText(target['id'])}: '
        '${projectText(target['platform'] ?? 'library')} '
        '(${projectText(target['projectDirectory'])})',
      );
    }
    for (Map<String, Object?> file in projectMaps(decoded['files'])) {
      stdout.writeln(
        '\n${projectText(file['action'])}: ${projectText(file['path'])}',
      );
      stdout.writeln(projectOutputText(file['content']?.toString() ?? ''));
    }
    for (Object? warning
        in decoded['warnings'] as List<Object?>? ?? <Object?>[]) {
      stdout.writeln(Ui.theme.paint(projectText(warning), Ui.theme.warn));
    }
    if (!await Ui.confirm(
      'Write this configuration and scan the project?',
      defaultValue: false,
    )) {
      return null;
    }
    output.clear();
    errors.clear();
    code = await command(
      <String>[...arguments, '--apply'],
      output: output.add,
      error: errors.add,
    );
    if (code != 0) {
      for (String error in errors) {
        stdout.writeln(Ui.theme.paint(projectText(error), Ui.theme.danger));
      }
      await Ui.pause();
      return null;
    }
    return <String>['scan', path];
  }

  Future<List<String>?> _history(ProjectDashboardSelection selection) async {
    if (selection.runs.isEmpty) return null;
    DateTime now = DateTime.now();
    String id = await menuSelect<String>('Build runs', <MenuEntry<String>>[
      for (Map<String, Object?> run in selection.runs)
        MenuEntry<String>(
          projectText(run['id']),
          value: projectText(run['id']),
          detail:
              '${projectText(run['status'])} / ${projectRunTiming(run, now)}'
              ' / ${projectText(run['createdAt'])}',
        ),
      const MenuEntry<String>('Back', value: '', shortcut: 'q'),
    ]);
    return id.isEmpty ? null : <String>['view', id];
  }

  String _destinationDetail(Map<String, Object?> destination) {
    String kind = switch (destination['kind']) {
      'directory' => 'Export directory',
      'instance' => 'Instance ${projectText(destination['instance'])}',
      'dropins' => 'Shared dropins',
      _ => projectText(destination['kind']),
    };
    return '$kind / ${projectText(destination['path'])}'
        ' / ${projectText(destination['platform'] ?? 'any platform')}'
        ' / Minecraft ${projectText(destination['minecraft'] ?? 'any')}';
  }

  Future<List<String>?> _locations(
    ProjectDashboardSelection selection, {
    bool newDestination = false,
  }) async {
    ProjectDestinationEditor editor = ProjectDestinationEditor(
      destinations: selection.destinations,
      canPreview: selection.run != null,
      newDestination: newDestination,
      theme: Ui.theme,
    );
    while (true) {
      ProjectDestinationEdit? edit = await editor.run();
      if (edit == null) return null;
      if (edit.action != ProjectDestinationEditAction.preview) {
        return edit.arguments;
      }
      try {
        List<String>? result = await _deploy(
          selection,
          destination: edit.destination,
        );
        if (result != null) return result;
      } on PromptBackNavigation {
        continue;
      }
    }
  }

  Future<List<String>?> _deploy(
    ProjectDashboardSelection selection, {
    Map<String, Object?>? destination,
  }) async {
    String? run = selection.run?['id'] as String?;
    if (run == null) return null;
    if (destination == null) {
      while (true) {
        int chosen = await menuSelect<int>('Deliver to', <MenuEntry<int>>[
          for (int index = 0; index < selection.destinations.length; index++)
            MenuEntry<int>(
              projectText(selection.destinations[index]['name']),
              value: index,
              detail: _destinationDetail(selection.destinations[index]),
            ),
          const MenuEntry<int>('Add destination', value: -1, shortcut: 'a'),
          const MenuEntry<int>('Back', value: -2, shortcut: 'q'),
        ]);
        if (chosen == -2) return null;
        try {
          return chosen == -1
              ? await _locations(selection, newDestination: true)
              : await _deploy(
                  selection,
                  destination: selection.destinations[chosen],
                );
        } on PromptBackNavigation {
          continue;
        }
      }
    }
    bool onlySelected =
        selection.row != null &&
        await Ui.confirm('Deliver only ${selection.row!.key}?');
    List<String> arguments = <String>[
      'deploy',
      run,
      '--to',
      projectText(destination['name']),
      if (onlySelected) ...<String>['--target', selection.row!.key],
    ];
    int code = await command(
      <String>[...arguments, '--preview'],
      output: (String line) => stdout.writeln(projectOutputText(line)),
      error: (String line) =>
          stdout.writeln(Ui.theme.paint(projectText(line), Ui.theme.danger)),
    );
    if (code != 0) {
      await Ui.pause();
      return null;
    }
    return await Ui.confirm('Deliver these artifacts?', defaultValue: false)
        ? arguments
        : null;
  }
}
