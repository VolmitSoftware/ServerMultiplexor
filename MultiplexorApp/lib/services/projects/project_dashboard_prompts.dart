import 'dart:io';
import 'dart:math' as math;

import '../../utils/user_prompt.dart';
import 'project_build_service.dart' show projectDefaultMemory;
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
  });

  final ProjectDashboardRow? row;
  final Map<String, Object?>? run;
  final List<Map<String, Object?>> runs;
  final List<Map<String, Object?>> catalog;
}

class ProjectDashboardPrompts {
  ProjectDashboardPrompts(this.command);

  final ProjectDashboardCommand command;
  int jobs = math.min(4, Platform.numberOfProcessors);
  int memoryMiB = projectDefaultMemory();
  int workers = math.max(1, Platform.numberOfProcessors);

  Future<List<String>?> request(
    ProjectDashboardAction action,
    ProjectDashboardSelection selection,
  ) async {
    switch (action) {
      case ProjectDashboardAction.actions:
        return _actions(selection);
      case ProjectDashboardAction.build:
        return _build(selection);
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
      if (selection.row != null)
        MenuEntry<String>(
          'Build ${selection.row!.name}',
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
        detail: '$jobs jobs / $memoryMiB MiB / $workers workers',
      ),
      const MenuEntry<String>('Configure destination', value: 'destination'),
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
    if (selected == 'limits') {
      await _limits();
      return null;
    }
    if (selected == 'destination') return _destination();
    return request(ProjectDashboardAction.values.byName(selected), selection);
  }

  Future<List<String>?> _build(ProjectDashboardSelection selection) async {
    if (selection.catalog.isEmpty) return _scan(selection);
    ProjectDashboardRow? row = selection.row;
    String scope = await menuSelect<String>(
      'Build targets',
      <MenuEntry<String>>[
        if (row != null) ...<MenuEntry<String>>[
          MenuEntry<String>('${row.name} / ${row.target}', value: 'target'),
          MenuEntry<String>('Every target in ${row.name}', value: 'project'),
        ],
        const MenuEntry<String>(
          'Every registered project and target',
          value: 'all',
        ),
        const MenuEntry<String>(
          'Changed projects and targets',
          value: 'changed',
        ),
        MenuEntry<String>(
          'Change build limits',
          value: 'limits',
          detail: '$jobs jobs / $memoryMiB MiB / $workers workers',
        ),
        const MenuEntry<String>('Back', value: 'back'),
      ],
    );
    if (scope == 'back') return null;
    if (scope == 'limits') {
      await _limits();
      return _build(selection);
    }
    return <String>[
      'build',
      if (scope == 'all' || scope == 'changed') '--all' else row!.project,
      if (scope == 'changed') '--changed',
      if (scope == 'target') ...<String>['--target', row!.target] else
        '--all-targets',
      '--jobs',
      '$jobs',
      '--memory',
      '$memoryMiB',
      '--workers',
      '$workers',
    ];
  }

  Future<void> _limits() async {
    String value = await Ui.input(
      'Jobs, total memory MiB, total Gradle workers',
      defaultValue: '$jobs $memoryMiB $workers',
      validator: (String value) {
        List<String> parts = value.trim().split(RegExp(r'\s+'));
        return parts.length == 3 &&
            parts.every((String part) => (int.tryParse(part) ?? 0) > 0);
      },
      validationMessage: 'Enter three positive integers, for example 2 8192 2.',
    );
    List<int> values = value
        .trim()
        .split(RegExp(r'\s+'))
        .map(int.parse)
        .toList();
    jobs = values[0];
    memoryMiB = values[1];
    workers = values[2];
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
