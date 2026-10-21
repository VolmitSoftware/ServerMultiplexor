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
  String _packaging = 'local';
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
      const MenuEntry<String>('Back', value: 'back'),
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
          'Every registered project and target',
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
        const MenuEntry<String>('Back', value: 'back'),
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
        ] else if (scope == 'all')
          '--all'
        else
          selection.project!,
        if (_reuse) '--changed',
        '--packaging',
        _packaging,
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

  Future<List<String>?> _locations(ProjectDashboardSelection selection) async {
    while (true) {
      int chosen = await menuSelect<int>('Locations', <MenuEntry<int>>[
        for (int index = 0; index < selection.destinations.length; index++)
          MenuEntry<int>(
            projectText(selection.destinations[index]['name']),
            value: index,
            detail: _destinationDetail(selection.destinations[index]),
          ),
        const MenuEntry<int>('Add destination', value: -1, shortcut: 'a'),
        const MenuEntry<int>('Back', value: -2),
      ]);
      if (chosen == -2) return null;
      try {
        List<String>? command = chosen == -1
            ? await _destination(selection)
            : await _locationActions(selection, selection.destinations[chosen]);
        if (command != null) return command;
      } on PromptBackNavigation {
        continue;
      }
    }
  }

  Future<List<String>?> _locationActions(
    ProjectDashboardSelection selection,
    Map<String, Object?> destination,
  ) async {
    String name = projectText(destination['name']);
    while (true) {
      String action;
      try {
        action = await menuSelect<String>(name, <MenuEntry<String>>[
          const MenuEntry<String>('Edit destination', value: 'edit'),
          if (selection.run != null)
            const MenuEntry<String>(
              'Preview delivery from current run',
              value: 'deploy',
            ),
          MenuEntry<String>(
            'Remove configuration',
            value: 'remove',
            labelColor: Ui.theme.danger,
          ),
          const MenuEntry<String>('Back', value: 'back'),
        ], footer: _destinationDetail(destination));
      } on PromptBackNavigation {
        return null;
      }
      if (action == 'back') return null;
      try {
        if (action == 'edit') {
          return await _destination(selection, existing: destination);
        }
        if (action == 'deploy') {
          List<String>? command = await _deploy(
            selection,
            destination: destination,
          );
          if (command != null) return command;
        }
        if (action == 'remove' &&
            await Ui.confirm(
              'Remove destination $name? Files at the destination stay unchanged.',
              defaultValue: false,
            )) {
          return <String>['destination', name, '--remove'];
        }
      } on PromptBackNavigation {
        continue;
      }
    }
  }

  Future<List<String>> _destination(
    ProjectDashboardSelection selection, {
    Map<String, Object?>? existing,
  }) async {
    String name = existing == null
        ? await Ui.input(
            'Destination name',
            validator: (String value) =>
                RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value) &&
                !selection.destinations.any(
                  (Map<String, Object?> item) => item['name'] == value,
                ),
            validationMessage:
                'Use a unique lowercase name with letters, digits, dots, underscores, or hyphens.',
          )
        : projectText(existing['name']);
    List<String> kinds = <String>[
      'Export directory',
      'Multiplexor instance',
      'Shared dropins',
    ];
    int kindIndex = switch (existing?['kind']) {
      'instance' => 1,
      'dropins' => 2,
      _ => 0,
    };
    String kind = await Ui.pick(
      'Destination kind',
      kinds,
      initialIndex: kindIndex,
    );
    String? path = kind == 'Export directory'
        ? await Ui.input(
            'Export directory',
            defaultValue: existing?['kind'] == 'directory'
                ? projectText(existing?['path'])
                : null,
            validator: (String value) => value.isNotEmpty,
          )
        : null;
    String? instance = kind == 'Multiplexor instance'
        ? await Ui.input(
            'Instance name',
            defaultValue: projectText(existing?['instance']),
            validator: (String value) => value.isNotEmpty,
          )
        : null;
    List<String> platforms = <String>[
      if (path != null) 'any',
      'plugin',
      'fabric',
      'forge',
      'neoforge',
      if (kind != 'Shared dropins') ...<String>['velocity', 'bungee'],
    ];
    int platformIndex = platforms.indexOf(
      projectText(existing?['platform'] ?? 'any'),
    );
    String platform = await Ui.pick(
      'Accept artifacts for',
      platforms,
      initialIndex: platformIndex < 0 ? 0 : platformIndex,
    );
    bool exactVersion = kind == 'Shared dropins';
    if (!exactVersion) {
      exactVersion =
          await Ui.choose('Minecraft compatibility', <String>[
            instance == null
                ? 'Any Minecraft version'
                : 'Read instance metadata',
            'Exact Minecraft version',
          ], initialIndex: existing?['minecraft'] == null ? 0 : 1) ==
          1;
    }
    String minecraft = exactVersion
        ? await Ui.input(
            'Exact Minecraft version',
            defaultValue: projectText(existing?['minecraft']),
            validator: (String value) =>
                RegExp(r'^\d+(?:\.\d+)*$').hasMatch(value),
            validationMessage:
                'Enter an exact Minecraft version, such as 26.3.',
          )
        : '';
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
          const MenuEntry<int>('Back', value: -2),
        ]);
        if (chosen == -2) return null;
        try {
          return chosen == -1
              ? await _destination(selection)
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
