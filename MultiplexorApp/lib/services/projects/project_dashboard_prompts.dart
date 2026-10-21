import 'dart:io';

import '../../utils/user_prompt.dart';
import 'project_build_limits.dart';
import 'project_dashboard_model.dart';

enum ProjectDashboardAction {
  actions,
  build,
  scan,
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
  });

  final ProjectDashboardRow? row;
  final Map<String, Object?>? run;
  final List<Map<String, Object?>> runs;
  final List<Map<String, Object?>> catalog;
  final ProjectBuildLimits limits;
  final ProjectDashboardNode? node;
  final List<String> checkedTargets;

  String? get project => node?.project ?? row?.project;
  String? get projectName => node?.name ?? row?.name;
  bool get registered =>
      node == null ? row?.registered ?? false : node!.buildKeys.isNotEmpty;
}

class ProjectDashboardPrompts {
  ProjectDashboardPrompts(this.command);

  final ProjectDashboardCommand command;

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
        return _destination();
      case ProjectDashboardAction.scan:
        return _scan(selection);
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
      MenuEntry<String>(
        'Build limits',
        value: 'limits',
        detail:
            '${selection.limits.jobs} jobs / ${selection.limits.memoryMiB} MiB / ${selection.limits.workers} workers',
        shortcut: 'p',
      ),
      const MenuEntry<String>(
        'Configure destination',
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
      const MenuEntry<String>('Back', value: 'back'),
    ];
    String selected = await menuSelect<String>('Projects', entries);
    if (selected == 'back') return null;
    return request(ProjectDashboardAction.values.byName(selected), selection);
  }

  Future<List<String>?> _build(ProjectDashboardSelection selection) async {
    if (selection.catalog.isEmpty) return _scan(selection);
    ProjectDashboardRow? row = selection.row;
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
        'Every registered project and target',
        value: 'all',
      ),
      const MenuEntry<String>('Changed projects and targets', value: 'changed'),
      MenuEntry<String>(
        'Change build limits',
        value: 'limits',
        detail:
            '${selection.limits.jobs} jobs / ${selection.limits.memoryMiB} MiB / ${selection.limits.workers} workers',
      ),
      const MenuEntry<String>('Back', value: 'back'),
    ]);
    if (scope == 'back') return null;
    if (scope == 'limits') {
      return _limits(selection.limits);
    }
    if (scope == 'checked' && selection.checkedTargets.isEmpty) {
      throw StateError('No targets are checked');
    }
    return <String>[
      'build',
      if (scope == 'checked') ...<String>[
        '--targets',
        selection.checkedTargets.join(','),
      ] else if (scope == 'all' || scope == 'changed')
        '--all'
      else
        selection.project!,
      if (scope == 'changed') '--changed',
      if (scope == 'target') ...<String>[
        '--target',
        row!.target,
      ] else if (scope != 'checked')
        '--all-targets',
      '--jobs',
      '${selection.limits.jobs}',
      '--memory',
      '${selection.limits.memoryMiB}',
      '--workers',
      '${selection.limits.workers}',
    ];
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
        const MenuEntry<String>('Back', value: 'back'),
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
      values[setting] = int.parse(
        await Ui.input(
          labels[setting]!,
          defaultValue: '${values[setting]}',
          validator: (String value) => (int.tryParse(value) ?? 0) > 0,
          validationMessage: 'Enter a positive integer.',
        ),
      );
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

  Future<List<String>?> _history(ProjectDashboardSelection selection) async {
    if (selection.runs.isEmpty) return null;
    String id = await menuSelect<String>('Build runs', <MenuEntry<String>>[
      for (Map<String, Object?> run in selection.runs)
        MenuEntry<String>(
          projectText(run['id']),
          value: projectText(run['id']),
          detail:
              '${projectText(run['status'])} / ${projectText(run['createdAt'])}',
        ),
      const MenuEntry<String>('Back', value: ''),
    ]);
    return id.isEmpty ? null : <String>['view', id];
  }

  Future<List<String>> _destination() async {
    String name = await Ui.input(
      'Destination name',
      validator: (String value) => value.isNotEmpty,
    );
    String kind = await Ui.pick('Destination kind', <String>[
      'Export directory',
      'Multiplexor instance',
      'Shared dropins',
    ]);
    String? path = kind == 'Export directory'
        ? await Ui.input(
            'Export directory',
            validator: (String value) => value.isNotEmpty,
          )
        : null;
    String? instance = kind == 'Multiplexor instance'
        ? await Ui.input(
            'Instance name',
            validator: (String value) => value.isNotEmpty,
          )
        : null;
    String platform = await Ui.pick('Accept artifacts for', <String>[
      if (path != null) 'any',
      'plugin',
      'fabric',
      'forge',
      'neoforge',
      'velocity',
      'bungee',
    ]);
    String minecraft = await Ui.input(
      'Minecraft version (blank for any)',
      defaultValue: '',
    );
    return <String>[
      'destination',
      name,
      if (path != null) ...<String>['--path', path],
      if (instance != null) ...<String>['--instance', instance],
      if (kind == 'Shared dropins') '--dropins',
      if (platform != 'any') ...<String>['--platform', platform],
      if (minecraft.isNotEmpty) ...<String>['--mc', minecraft],
    ];
  }

  Future<List<String>?> _deploy(ProjectDashboardSelection selection) async {
    String? run = selection.run?['id'] as String?;
    if (run == null) return null;
    String destination = await Ui.input(
      'Destination name',
      validator: (String value) => value.isNotEmpty,
    );
    bool onlySelected =
        selection.row != null &&
        await Ui.confirm('Deliver only ${selection.row!.key}?');
    List<String> arguments = <String>[
      'deploy',
      run,
      '--to',
      destination,
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
