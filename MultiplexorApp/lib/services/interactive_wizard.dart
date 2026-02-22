import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/consumer_profile.dart';
import '../utils/user_prompt.dart';
import 'app_context.dart';
import 'consumer_service.dart';
import 'passthrough_service.dart';

class InteractiveWizard {
  InteractiveWizard({
    required this.consumerService,
    required this.passthrough,
    this.requestedConsumer,
  });

  final ConsumerService consumerService;
  final PassthroughService passthrough;
  final ConsumerProfile? requestedConsumer;

  Future<void> run() async {
    if (!stdin.hasTerminal || !stdout.hasTerminal) {
      await _runTextFallback();
      return;
    }

    try {
      while (true) {
        await _showHeader();
        final options = <String>['Run', 'Instances', 'Build/JVM', 'Exit'];
        late final int choice;
        try {
          choice = await UserPrompt.menu('Main Menu', options);
        } on PromptBackNavigation {
          return;
        }
        final selected = options[choice];

        switch (selected) {
          case 'Run':
            await _runEscapableStep(_serverControlMenu);
            break;
          case 'Instances':
            await _runEscapableStep(_instancesMenu);
            break;
          case 'Build/JVM':
            await _runEscapableStep(_buildAndJvmMenu);
            break;
          case 'Exit':
            return;
        }
      }
    } on PromptInputUnavailable catch (e) {
      UserPrompt.error('Input stream lost: $e');
      stdout.writeln('Wizard closed to avoid a menu redraw loop.');
    }
  }

  Future<void> _runTextFallback() async {
    await _showHeader();
    stdout.writeln('Interactive mode requires a TTY.');
    stdout.writeln('Run commands directly, for example:');
    stdout.writeln('  ./start.sh consumer show');
    stdout.writeln('  ./start.sh instance list');
    stdout.writeln('  ./start.sh runtime console <instance>');
  }

  Future<void> _showHeader() async {
    UserPrompt.clearScreen();

    final activeConsumer = requestedConsumer ?? consumerService.readActive();
    final activeInstance = await _activeInstanceWithPort();
    final dropins = await _dropinsSource();
    final running = await _runningServersWithPorts();

    UserPrompt.banner('Minecraft Dev Wizard', subtitle: 'Backend: native-dart');

    UserPrompt.row('Consumer:', activeConsumer.shortName);
    UserPrompt.row('Active instance:', activeInstance ?? 'none');
    UserPrompt.row(
      activeConsumer == ConsumerProfile.plugin ? 'Plugin jars:' : 'Mod jars:',
      dropins ?? 'unknown',
    );
    if (running.isNotEmpty) {
      UserPrompt.row('Running:', running.join(', '));
    }
    stdout.writeln('');
  }

  Future<void> _runEscapableStep(Future<void> Function() step) async {
    try {
      await step();
    } on PromptBackNavigation {
      // ESC always cancels the current step and returns to the previous page.
    }
  }

  Future<void> _serverControlMenu() async {
    while (true) {
      await _showHeader();
      final running = await _runningServers();
      final all = await _instanceNames();
      final stopped = all
          .where((name) => !running.contains(name))
          .toList(growable: false);
      final stoppedCount = stopped.length;
      UserPrompt.info('Running: ${running.length}  Stopped: $stoppedCount');
      UserPrompt.info(
        'Start servers, open live consoles, and stop running servers.',
      );
      UserPrompt.info(
        'Single start auto-opens console. Start-all opens all consoles.',
      );

      final options = <String>[];
      if (stopped.isNotEmpty) {
        options.add('Start one stopped instance');
      }
      if (stopped.length > 1) {
        options.add('Start all stopped instances');
      }
      if (running.isNotEmpty) {
        options.add('Open console for running server');
        if (running.length > 1) {
          options.add('Open all running consoles (grid)');
          options.add('Open all running consoles (lateral)');
        }
        options.add('Stop one running server');
      }
      if (running.length > 1) {
        options.add('Stop all running servers');
      }
      if (options.isEmpty) {
        UserPrompt.warn('No instances available. Create one first.');
        await UserPrompt.pressEnter();
        return;
      }
      late final int choice;
      try {
        choice = await UserPrompt.menu('Run', options);
      } on PromptBackNavigation {
        return;
      }

      final selected = options[choice];
      switch (selected) {
        case 'Start one stopped instance':
          await _runEscapableStep(_startInstanceFromStopped);
          break;
        case 'Start all stopped instances':
          await _runEscapableStep(_startAllStoppedInstances);
          break;
        case 'Open console for running server':
          await _runEscapableStep(_openConsoleForRunningServer);
          break;
        case 'Open all running consoles (grid)':
          await _runEscapableStep(() => _openAllRunningConsoles('grid'));
          break;
        case 'Open all running consoles (lateral)':
          await _runEscapableStep(() => _openAllRunningConsoles('lateral'));
          break;
        case 'Stop one running server':
          await _runEscapableStep(_stopOneRunningServer);
          break;
        case 'Stop all running servers':
          for (final server in running) {
            await passthrough.run(<String>['runtime', 'stop', server]);
          }
          await UserPrompt.pressEnter();
          break;
      }
    }
  }

  Future<void> _startInstanceFromStopped() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final running = (await _runningServers()).toSet();
    final active = await _activeInstance();
    final candidates = instances
        .where((name) => !running.contains(name))
        .toList(growable: false);

    if (candidates.isEmpty) {
      UserPrompt.warn('No stopped instances available to start.');
      await UserPrompt.pressEnter();
      return;
    }

    final options = candidates
        .map((name) => name == active ? '$name (active)' : name)
        .toList(growable: false);
    final picked = await UserPrompt.pick('Start which instance?', options);
    final selected = _instanceNameFromMenuLine(picked);

    await _syncDropinsAllTargets();
    final code = await passthrough.run(<String>['runtime', 'start', selected]);
    if (code != 0) {
      await UserPrompt.pressEnter();
    }
  }

  Future<void> _startAllStoppedInstances() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final running = (await _runningServers()).toSet();
    final candidates = instances
        .where((name) => !running.contains(name))
        .toList(growable: false);

    if (candidates.isEmpty) {
      UserPrompt.warn('No stopped instances available to start.');
      await UserPrompt.pressEnter();
      return;
    }

    final confirm = await UserPrompt.confirm(
      'Start all ${candidates.length} stopped instance(s)?',
      defaultValue: true,
    );
    if (!confirm) {
      return;
    }

    var started = 0;
    var failed = 0;
    final startedNames = <String>[];
    await _syncDropinsAllTargets();
    for (final instance in candidates) {
      final code = await passthrough.run(<String>[
        'runtime',
        'start',
        instance,
        '--no-console',
      ]);
      if (code == 0) {
        started++;
        startedNames.add(instance);
      } else {
        failed++;
      }
    }

    if (failed == 0) {
      UserPrompt.success('Started $started instance(s).');
    } else {
      UserPrompt.warn('Started $started instance(s), failed $failed.');
    }

    if (started == 0) {
      await UserPrompt.pressEnter();
      return;
    }

    if (started == 1) {
      await passthrough.run(<String>['runtime', 'console', startedNames.first]);
      return;
    }

    await _openAllRunningConsoles('grid');
  }

  Future<void> _instancesMenu() async {
    while (true) {
      await _showHeader();
      final instances = await _instanceNames();
      UserPrompt.info(
        'Manage instances, active profile, ports, resets, and cleanup.',
      );
      final options = <String>[
        'Switch Consumer Profile',
        'Switch Existing Instance',
        'Create From Type (cached build)',
      ];
      if (instances.isNotEmpty) {
        options.add('Set Instance Port');
        options.add('Apply Styled MOTD');
        options.add('Reset One Instance (factory)');
        if (instances.length > 1) {
          options.add('Apply Styled MOTD to All');
        }
        options.add('Delete One Instance');
        if (instances.length > 1) {
          options.add('Delete All Instances');
        }
      }
      late final int choice;
      try {
        choice = await UserPrompt.menu('Instances', options);
      } on PromptBackNavigation {
        return;
      }
      final selected = options[choice];

      switch (selected) {
        case 'Switch Consumer Profile':
          await _runEscapableStep(_switchConsumer);
          break;
        case 'Switch Existing Instance':
          await _runEscapableStep(_switchExistingInstance);
          break;
        case 'Create From Type (cached build)':
          await _runEscapableStep(_createFromType);
          break;
        case 'Set Instance Port':
          await _runEscapableStep(_setInstancePort);
          break;
        case 'Apply Styled MOTD':
          await _runEscapableStep(_applyStyledMotdForOne);
          break;
        case 'Reset One Instance (factory)':
          await _runEscapableStep(_resetOneInstance);
          break;
        case 'Apply Styled MOTD to All':
          await _runEscapableStep(_applyStyledMotdForAll);
          break;
        case 'Delete One Instance':
          await _runEscapableStep(_deleteOneInstance);
          break;
        case 'Delete All Instances':
          await _runEscapableStep(_deleteAllInstances);
          break;
      }
    }
  }

  Future<void> _switchExistingInstance() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final selected = await UserPrompt.pick('Select instance', instances);
    final code = await passthrough.run(<String>[
      'instance',
      'activate',
      selected,
    ]);
    if (code == 0) {
      UserPrompt.success('Active instance: $selected');
    }
    await UserPrompt.pressEnter();
  }

  Future<void> _createFromType() async {
    final type = await UserPrompt.pick('Target type', const <String>[
      'paper',
      'purpur',
      'folia',
      'canvas',
      'spigot',
      'forge',
      'fabric',
      'neoforge',
    ]);

    final latest = await _resolveLatestVersion(type);
    final version = await UserPrompt.input(
      'Minecraft version',
      defaultValue: latest,
      validator: (raw) => raw.trim().isNotEmpty,
      validationMessage: 'Version is required',
    );

    final suggestedName = '$type-${version.trim()}';
    final name = await UserPrompt.input(
      'Instance name',
      defaultValue: suggestedName,
      validator: _isValidInstanceName,
      validationMessage: 'Use letters, numbers, ., _, or - with no spaces.',
    );

    final code = await passthrough.run(<String>[
      'server',
      'create',
      name,
      '--type',
      type,
      '--mc',
      version.trim(),
    ]);

    if (code == 0) {
      await _syncDropinsAllTargets();
      if (await _autoLaunchFirstInstance(name)) {
        return;
      }

      final activate = await UserPrompt.confirm(
        'Activate $name now?',
        defaultValue: true,
      );
      if (activate) {
        await passthrough.run(<String>['instance', 'activate', name]);
      }
    }

    await UserPrompt.pressEnter();
  }

  Future<void> _syncDropinsAllTargets() async {
    if (_isPluginConsumerSelected()) {
      await passthrough.run(<String>['plugins', 'sync', '--all']);
    } else {
      await passthrough.run(<String>['mods', 'sync', '--all']);
    }
  }

  Future<void> _setInstancePort() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final active = await _activeInstance();
    final instanceOptions = instances
        .map((name) => name == active ? '$name (active)' : name)
        .toList(growable: false);
    final picked = await UserPrompt.pick(
      'Set port for which instance?',
      instanceOptions,
    );
    final target = _instanceNameFromMenuLine(picked);

    final currentPortRaw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'port',
      target,
    ]);
    final currentPort = int.tryParse((currentPortRaw ?? '').trim());

    final portPool = <int>{
      for (var p = 25565; p <= 25575; p++) p,
      ?currentPort,
    }.toList(growable: false)..sort();

    final portOptions = portPool
        .map((p) => currentPort == p ? '$p (current)' : '$p')
        .toList(growable: false);

    var initialIndex = 0;
    if (currentPort != null) {
      final idx = portPool.indexOf(currentPort);
      if (idx >= 0) {
        initialIndex = idx;
      }
    }

    final selectedPortLine = await UserPrompt.pick(
      'Select server port',
      portOptions,
      initialIndex: initialIndex,
    );
    final selectedPort = selectedPortLine.split(' ').first.trim();
    await passthrough.run(<String>['instance', 'port', target, selectedPort]);
    await UserPrompt.pressEnter();
  }

  Future<void> _applyStyledMotdForOne() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final active = await _activeInstance();
    final options = instances
        .map((name) => name == active ? '$name (active)' : name)
        .toList(growable: false);
    final picked = await UserPrompt.pick('Apply styled MOTD to', options);
    final target = _instanceNameFromMenuLine(picked);
    await passthrough.run(<String>['instance', 'motd-style', target]);
    await UserPrompt.pressEnter();
  }

  Future<void> _applyStyledMotdForAll() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found. Create one first.');
      await UserPrompt.pressEnter();
      return;
    }

    final confirmed = await UserPrompt.confirm(
      'Apply platform-styled MOTD to all ${instances.length} instances?',
      defaultValue: true,
    );
    if (!confirmed) {
      return;
    }

    await passthrough.run(<String>['instance', 'motd-style', '--all']);
    await UserPrompt.pressEnter();
  }

  Future<void> _deleteOneInstance() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found.');
      await UserPrompt.pressEnter();
      return;
    }

    final active = await _activeInstance();
    final running = (await _runningServers()).toSet();
    final options = instances
        .map((name) {
          final tags = <String>[];
          if (name == active) {
            tags.add('active');
          }
          if (running.contains(name)) {
            tags.add('running');
          }
          if (tags.isEmpty) {
            return name;
          }
          return '$name (${tags.join(', ')})';
        })
        .toList(growable: false);

    final picked = await UserPrompt.pick('Delete which instance?', options);
    final target = _instanceNameFromMenuLine(picked);
    final confirmed = await UserPrompt.confirm(
      'Delete instance $target?',
      defaultValue: false,
    );
    if (!confirmed) {
      return;
    }

    await passthrough.run(<String>['instance', 'delete', target]);
    await UserPrompt.pressEnter();
  }

  Future<void> _resetOneInstance() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found.');
      await UserPrompt.pressEnter();
      return;
    }

    final active = await _activeInstance();
    final running = (await _runningServers()).toSet();
    final options = instances
        .map((name) {
          final tags = <String>[];
          if (name == active) {
            tags.add('active');
          }
          if (running.contains(name)) {
            tags.add('running');
          }
          if (tags.isEmpty) {
            return name;
          }
          return '$name (${tags.join(', ')})';
        })
        .toList(growable: false);

    final picked = await UserPrompt.pick('Reset which instance?', options);
    final target = _instanceNameFromMenuLine(picked);
    final confirmed = await UserPrompt.confirm(
      'Factory reset $target? Launch artifacts are kept; worlds/config/plugins/mods are wiped.',
      defaultValue: false,
    );
    if (!confirmed) {
      return;
    }

    await passthrough.run(<String>['instance', 'reset', target]);
    await UserPrompt.pressEnter();
  }

  Future<void> _deleteAllInstances() async {
    final instances = await _instanceNames();
    if (instances.isEmpty) {
      UserPrompt.warn('No instances found.');
      await UserPrompt.pressEnter();
      return;
    }

    final confirmed = await UserPrompt.confirm(
      'Delete all ${instances.length} instances for this consumer?',
      defaultValue: false,
    );
    if (!confirmed) {
      return;
    }

    var deleted = 0;
    var failed = 0;
    for (final instance in instances) {
      final code = await passthrough.run(<String>[
        'instance',
        'delete',
        instance,
      ]);
      if (code == 0) {
        deleted++;
      } else {
        failed++;
      }
    }

    if (failed == 0) {
      UserPrompt.success('Deleted $deleted instance(s).');
    } else {
      UserPrompt.warn('Deleted $deleted instance(s), failed $failed.');
    }
    await UserPrompt.pressEnter();
  }

  Future<void> _openConsoleForRunningServer() async {
    final servers = await _runningServers();
    if (servers.isEmpty) {
      UserPrompt.warn('No running servers.');
      await UserPrompt.pressEnter();
      return;
    }

    final statuses = <String, _RuntimeStatus>{};
    for (final server in servers) {
      statuses[server] = await _instanceRuntimeStatus(server);
    }

    String? target;
    if (servers.length == 1) {
      target = servers.first;
      UserPrompt.info('One running server detected: $target');
    } else {
      final options = servers
          .map((server) {
            final status = statuses[server];
            final mode = status?.mode ?? 'unknown';
            var suffix = '';
            if (mode == 'watchdog') {
              suffix = ' [restart to tmux]';
            } else if (mode != 'tmux') {
              suffix = ' [unavailable]';
            }
            return 'Console: $server (port ${status?.port ?? '?'})$suffix';
          })
          .toList(growable: false);

      final picked = await UserPrompt.pick(
        'Open console for which running server?',
        options,
      );
      target = _instanceNameFromAction(picked, 'Console: ');
      if (target == null) {
        UserPrompt.warn('Could not parse server selection.');
        await UserPrompt.pressEnter();
        return;
      }
    }

    final selectedTarget = target;

    final status = statuses[selectedTarget];
    final mode = status?.mode ?? 'unknown';
    if (mode == 'tmux') {
      UserPrompt.info('Opening console for $selectedTarget');
      UserPrompt.info(
        'Return to menu without killing server: Esc (or Ctrl+B then D)',
      );
      await _openConsoleInChildProcess(selectedTarget);
      return;
    }

    if (mode == 'watchdog') {
      UserPrompt.warn(
        'Live console attach is unavailable for $selectedTarget in watchdog mode.',
      );
      final restartToTmux = await UserPrompt.confirm(
        'Stop and restart $selectedTarget in tmux mode, then open console now?',
        defaultValue: true,
      );
      if (!restartToTmux) {
        return;
      }
      await passthrough.run(<String>['runtime', 'stop', selectedTarget]);
      await passthrough.run(<String>[
        'runtime',
        'start',
        selectedTarget,
        '--no-console',
      ]);
      UserPrompt.info('Opening tmux console for $selectedTarget');
      UserPrompt.info(
        'Return to menu without killing server: Esc (or Ctrl+B then D)',
      );
      await _openConsoleInChildProcess(selectedTarget);
      return;
    }

    UserPrompt.warn(
      'Console for $selectedTarget is unavailable in mode: $mode',
    );
    await UserPrompt.pressEnter();
  }

  Future<void> _openAllRunningConsoles(String layout) async {
    final servers = await _runningServers();
    if (servers.length < 2) {
      UserPrompt.warn(
        'Need at least two running servers for side-by-side view.',
      );
      await UserPrompt.pressEnter();
      return;
    }

    final label = layout == 'lateral' ? 'lateral' : 'grid';
    UserPrompt.info('Opening all running consoles in $label view...');
    UserPrompt.info(
      'Navigate panes with Left/Right. Scroll with mouse wheel (or Ctrl+B then [).',
    );
    final cmd = layout == 'lateral' ? 'consoles-lateral' : 'consoles';
    await passthrough.run(<String>['runtime', cmd]);
  }

  Future<void> _stopOneRunningServer() async {
    final servers = await _runningServers();
    if (servers.isEmpty) {
      UserPrompt.warn('No running servers.');
      await UserPrompt.pressEnter();
      return;
    }

    final options = <String>[];
    for (final server in servers) {
      final status = await _instanceRuntimeStatus(server);
      options.add('Stop: $server (port ${status.port ?? '?'})');
    }

    final picked = await UserPrompt.pick('Stop which running server?', options);
    final target = _instanceNameFromAction(picked, 'Stop: ');
    if (target == null) {
      UserPrompt.warn('Could not parse server selection.');
      await UserPrompt.pressEnter();
      return;
    }

    await passthrough.run(<String>['runtime', 'stop', target]);
    await UserPrompt.pressEnter();
  }

  Future<bool> _autoLaunchFirstInstance(String name) async {
    final all = await _instanceNames();
    final isFirstAndOnly = all.length == 1 && all.first == name;
    if (!isFirstAndOnly) {
      return false;
    }

    UserPrompt.info(
      'First instance created: auto-activating and opening console.',
    );
    await passthrough.run(<String>['instance', 'activate', name]);
    final startCode = await passthrough.run(<String>['runtime', 'start', name]);
    if (startCode != 0) {
      await UserPrompt.pressEnter();
      return true;
    }
    return true;
  }

  Future<void> _openConsoleInChildProcess(String instance) async {
    final consumer =
        (requestedConsumer ?? consumerService.readActive()).shortName;
    final startScript = p.join(appContext.rootDir, 'start.sh');
    final env = Map<String, String>.from(Platform.environment);
    final term = (env['TERM'] ?? '').trim().toLowerCase();
    if (term.isEmpty || term == 'dumb') {
      env['TERM'] = 'xterm-256color';
    }
    final process = await Process.start(
      startScript,
      <String>['--consumer', consumer, 'runtime', 'console', instance],
      workingDirectory: appContext.rootDir,
      environment: env,
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
    await process.exitCode;
  }

  Future<void> _switchConsumer() async {
    final options = consumerService
        .listProfiles()
        .map((e) => e.shortName)
        .toList(growable: false);

    final selected = await UserPrompt.pick('Consumer profile', options);
    await passthrough.run(<String>['consumer', 'use', selected]);
    await UserPrompt.pressEnter();
  }

  Future<void> _buildAndJvmMenu() async {
    const heapOptions = <String>['2G', '4G', '6G', '8G', '10G', '12G', '16G'];
    const presetLabels = <String, String>{
      'Aikar (recommended)': 'aikar',
      'Vanilla (minimal flags)': 'vanilla',
      'Conservative (lower pause pressure)': 'conservative',
    };

    while (true) {
      await _showHeader();
      final pluginConsumer = _isPluginConsumerSelected();
      final dropinCommand = pluginConsumer ? 'plugins' : 'mods';
      final dropinLabel = pluginConsumer ? 'Plugins' : 'Mods';
      final settings = await _runtimeSettings();
      UserPrompt.row('Heap size:', settings.heap ?? '4G');
      UserPrompt.row('Flag profile:', settings.profile ?? 'aikar');
      UserPrompt.info('Build cache, dropin sync, and JVM tuning in one menu.');
      final options = <String>[
        'Sync Repos (all)',
        'Show Build Cache',
        'Sync $dropinLabel to All Valid Targets',
        'Show $dropinLabel Source',
        'Set Heap Size',
        'Set JVM Flag Profile',
        'Reset JVM to Recommended (4G + Aikar)',
      ];
      late final int choice;
      try {
        choice = await UserPrompt.menu('Build/JVM', options);
      } on PromptBackNavigation {
        return;
      }

      switch (choice) {
        case 0:
          await passthrough.run(<String>['repos', 'sync', 'all']);
          await UserPrompt.pressEnter();
          break;
        case 1:
          await passthrough.run(<String>['build', 'list']);
          await UserPrompt.pressEnter();
          break;
        case 2:
          await passthrough.run(<String>[dropinCommand, 'sync', '--all']);
          await UserPrompt.pressEnter();
          break;
        case 3:
          await passthrough.run(<String>[dropinCommand, 'show-source']);
          await UserPrompt.pressEnter();
          break;
        case 4:
          final currentHeap = (settings.heap ?? '4G').toUpperCase();
          var heapIndex = heapOptions.indexWhere(
            (candidate) => candidate.toUpperCase() == currentHeap,
          );
          if (heapIndex < 0) {
            heapIndex = 1;
          }
          final selectedHeap = await UserPrompt.pick(
            'Heap size (Xms/Xmx)',
            heapOptions,
            initialIndex: heapIndex,
          );
          await passthrough.run(<String>[
            'runtime',
            'settings',
            'set-heap',
            selectedHeap,
          ]);
          await UserPrompt.pressEnter();
          break;
        case 5:
          final labels = presetLabels.keys.toList(growable: false);
          final currentProfile = (settings.profile ?? 'aikar').toLowerCase();
          var presetIndex = labels.indexWhere(
            (label) => presetLabels[label] == currentProfile,
          );
          if (presetIndex < 0) {
            presetIndex = 0;
          }
          final selectedLabel = await UserPrompt.pick(
            'JVM flag profile',
            labels,
            initialIndex: presetIndex,
          );
          final preset = presetLabels[selectedLabel]!;
          await passthrough.run(<String>[
            'runtime',
            'settings',
            'set-preset',
            preset,
          ]);
          await UserPrompt.pressEnter();
          break;
        case 6:
          await passthrough.run(<String>['runtime', 'settings', 'reset']);
          await UserPrompt.pressEnter();
          break;
      }
    }
  }

  Future<_RuntimeSettings> _runtimeSettings() async {
    final result = await passthrough.capture(<String>[
      'runtime',
      'settings',
      'show',
    ]);
    if (!result.success) {
      return const _RuntimeSettings();
    }

    final text = '${result.stdout}\n${result.stderr}';
    final heap = RegExp(
      r'^heap size:\s*(.+)$',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final profile = RegExp(
      r'^flags profile:\s*(.+)$',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final jvmArgs = RegExp(
      r'^jvm args:\s*(.+)$',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();

    return _RuntimeSettings(heap: heap, profile: profile, jvmArgs: jvmArgs);
  }

  Future<String?> _activeInstance() async {
    final line = await passthrough.captureStdoutLine(<String>[
      'instance',
      'current',
    ]);
    return _cleanLine(line);
  }

  Future<String?> _activeInstanceWithPort() async {
    final active = await _activeInstance();
    if (active == null) {
      return null;
    }
    final port = await _configuredInstancePort(active);
    if (port == null) {
      return active;
    }
    return '$active ($port)';
  }

  Future<String?> _dropinsSource() async {
    final active = requestedConsumer ?? consumerService.readActive();
    if (active == ConsumerProfile.plugin) {
      return _cleanLine(
        await passthrough.captureStdoutLine(<String>['plugins', 'show-source']),
      );
    }
    return _cleanLine(
      await passthrough.captureStdoutLine(<String>['mods', 'show-source']),
    );
  }

  Future<List<String>> _runningServers() async {
    final result = await passthrough.capture(<String>['runtime', 'list']);
    if (!result.success) {
      return const <String>[];
    }

    return result.stdout
        .split('\n')
        .map(_cleanLine)
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<String>> _runningServersWithPorts() async {
    final servers = await _runningServers();
    final out = <String>[];
    for (final s in servers) {
      final port = await _instancePort(s);
      if (port == null) {
        out.add('$s(?)');
      } else {
        out.add('$s($port)');
      }
    }
    return out;
  }

  Future<String?> _instancePort(String instance) async {
    final configured = await _configuredInstancePort(instance);
    if (configured != null) {
      return configured;
    }
    final status = await _instanceRuntimeStatus(instance);
    return status.port;
  }

  Future<String?> _configuredInstancePort(String instance) async {
    final raw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'port',
      instance,
    ]);
    final port = _cleanLine(raw);
    if (port == null) {
      return null;
    }
    return int.tryParse(port) == null ? null : port;
  }

  Future<_RuntimeStatus> _instanceRuntimeStatus(String instance) async {
    final result = await passthrough.capture(<String>[
      'runtime',
      'status',
      instance,
    ]);
    if (!result.success) {
      return const _RuntimeStatus();
    }

    final text = '${result.stdout}\n${result.stderr}';
    final modeMatch = RegExp(
      r'^mode:\s*(\S+)',
      multiLine: true,
    ).firstMatch(text);
    final portMatch = RegExp(
      r'^server port:\s*([^\s]+)',
      multiLine: true,
    ).firstMatch(text);
    final rawPort = portMatch?.group(1)?.trim();

    return _RuntimeStatus(
      mode: modeMatch?.group(1)?.trim(),
      port: rawPort == null || rawPort == 'unknown' ? null : rawPort,
    );
  }

  Future<List<String>> _instanceNames() async {
    final result = await passthrough.capture(<String>['instance', 'list']);
    if (!result.success) {
      return const <String>[];
    }

    return result.stdout
        .split('\n')
        .map(_cleanLine)
        .whereType<String>()
        .map((line) => line.replaceAll(' (active)', '').trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Future<String> _resolveLatestVersion(String type) async {
    final result = await passthrough.capture(<String>['build', 'latest', type]);
    if (!result.success) {
      return '1.21.1';
    }

    final combined = '${result.stdout}\n${result.stderr}'
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    for (final line in combined.reversed) {
      if (RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(line)) {
        return line;
      }
    }

    return '1.21.1';
  }

  bool _isValidInstanceName(String input) {
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(input.trim());
  }

  String _instanceNameFromMenuLine(String line) {
    final first = line.split(' (').first.trim();
    return first;
  }

  String? _instanceNameFromAction(String line, String prefix) {
    if (!line.startsWith(prefix)) {
      return null;
    }
    final tail = line.substring(prefix.length).trim();
    return _instanceNameFromMenuLine(tail);
  }

  String? _cleanLine(String? raw) {
    if (raw == null) {
      return null;
    }
    final cleaned = raw.trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  bool _isPluginConsumerSelected() {
    final active = requestedConsumer ?? consumerService.readActive();
    return active == ConsumerProfile.plugin;
  }
}

class _RuntimeStatus {
  const _RuntimeStatus({this.mode, this.port});

  final String? mode;
  final String? port;
}

class _RuntimeSettings {
  const _RuntimeSettings({this.heap, this.profile, this.jvmArgs});

  final String? heap;
  final String? profile;
  final String? jvmArgs;
}
