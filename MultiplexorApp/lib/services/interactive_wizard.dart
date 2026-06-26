import 'dart:io';

import '../models/consumer_profile.dart';
import '../utils/process_runner.dart';
import '../utils/user_prompt.dart';
import 'consumer_service.dart';
import 'passthrough_service.dart';
import 'runtime_state.dart';

/// Dashboard-driven interactive wizard.
///
/// One screen lists every instance with its live state; selecting an
/// instance opens a flat, state-aware action menu. Global actions sit
/// below the instance list with single-key shortcuts. All background
/// commands run shielded so stray keystrokes cannot corrupt the UI.
class InteractiveWizard {
  InteractiveWizard({
    required this.consumerService,
    required this.passthrough,
    this.requestedConsumer,
  });

  final ConsumerService consumerService;
  final PassthroughService passthrough;
  final ConsumerProfile? requestedConsumer;

  static const List<String> _serverTypes = <String>[
    'paper',
    'purpur',
    'folia',
    'canvas',
    'spigot',
    'forge',
    'fabric',
    'neoforge',
  ];

  Future<void> run() async {
    if (!Ui.hasTerminal) {
      _printTextFallback();
      return;
    }

    TermIo.instance.installSignalRestore();
    try {
      while (true) {
        final _DashboardData data = await Ui.shielded(_loadDashboardData);
        _renderHeader(data);

        _DashChoice choice;
        try {
          choice = await _dashboardMenu(data);
        } on PromptBackNavigation {
          return;
        }

        if (choice.kind == _Act.quit) {
          return;
        }
        await _runStep(() => _dispatch(choice, data.rows));
      }
    } on PromptInputUnavailable catch (e) {
      Ui.error('Input stream lost: $e');
      stdout.writeln('Wizard closed to avoid a redraw loop.');
    } finally {
      TermIo.instance.restoreTerminal();
    }
  }

  void _printTextFallback() {
    stdout.writeln('Interactive mode requires a TTY.');
    stdout.writeln('Run commands directly, for example:');
    stdout.writeln('  ./start.sh runtime states');
    stdout.writeln('  ./start.sh runtime console <instance>');
    stdout.writeln('  ./start.sh server create demo --type purpur');
  }

  Future<void> _runStep(Future<void> Function() step) async {
    try {
      await step();
    } on PromptBackNavigation {
      // Escape returns to the dashboard.
    }
  }

  // ─── Dashboard ───────────────────────────────────────────────────────

  Future<_DashboardData> _loadDashboardData() async {
    return _DashboardData(
      rows: await _loadInstanceRows(),
      active: await _activeInstance(),
      dropins: await _dropinsSource(),
    );
  }

  void _renderHeader(_DashboardData data) {
    Ui.clearScreen();
    final ConsumerProfile consumer = _activeConsumer();
    Ui.appHeader('MULTIPLEXOR', <String>[
      'consumer: ${consumer.shortName}',
      if (data.active != null) 'active: ${data.active}',
      if (data.dropins != null)
        '${_isPluginConsumer() ? 'plugins' : 'mods'}: '
            '${_shortenPath(data.dropins!)}',
    ]);
    Ui.blank();
  }

  List<MenuEntry<_DashChoice>> _buildDashEntries(
    List<_InstanceRow> rows,
    String? active,
  ) {
    final List<_InstanceRow> running = rows
        .where((_InstanceRow r) => r.state != RuntimeState.stopped)
        .toList(growable: false);
    final List<_InstanceRow> stopped = rows
        .where((_InstanceRow r) => r.state == RuntimeState.stopped)
        .toList(growable: false);

    final List<MenuEntry<_DashChoice>> entries = <MenuEntry<_DashChoice>>[];

    if (rows.isEmpty) {
      entries.add(
        MenuEntry<_DashChoice>(
          'Create your first server',
          value: const _DashChoice(_Act.create),
          shortcut: 'n',
        ),
      );
    } else {
      entries.add(const MenuEntry<_DashChoice>.separator('servers'));
      for (final _InstanceRow row in rows) {
        final List<String> bits = <String>[':${row.port}'];
        if (row.players != null) {
          bits.add('${row.players}/${row.maxPlayers ?? '?'}');
        }
        if (row.tps != null) {
          bits.add('${row.tps!.toStringAsFixed(1)} tps');
        }
        if (row.version != null && row.version!.isNotEmpty) {
          bits.add(row.version!);
        }
        if (row.locked) {
          bits.add('locked');
        }
        final String activeMark = row.name == active
            ? '  ${Ansi.style('active', Ansi.cyan)}'
            : '';
        entries.add(
          MenuEntry<_DashChoice>(
            row.name,
            value: _DashChoice(_Act.instance, instance: row.name),
            badge: '${_stateGlyph(row.state)} ${row.state.name}',
            badgeColor: _stateColor(row.state),
            detail: '${bits.join(' · ')}$activeMark',
          ),
        );
      }
      entries.add(const MenuEntry<_DashChoice>.separator());
      entries.add(
        MenuEntry<_DashChoice>(
          'New instance',
          value: const _DashChoice(_Act.create),
          shortcut: 'n',
        ),
      );
      if (stopped.length > 1) {
        entries.add(
          MenuEntry<_DashChoice>(
            'Start all stopped',
            value: const _DashChoice(_Act.startAll),
            shortcut: 's',
            detail: '${stopped.length} instances',
          ),
        );
      }
      if (running.length > 1) {
        entries.add(
          MenuEntry<_DashChoice>(
            'Stop all running',
            value: const _DashChoice(_Act.stopAll),
            shortcut: 'k',
            detail: '${running.length} instances',
          ),
        );
        entries.add(
          MenuEntry<_DashChoice>(
            'All consoles',
            value: const _DashChoice(_Act.consolesGrid),
            shortcut: 'g',
            detail: 'grid view',
          ),
        );
        entries.add(
          MenuEntry<_DashChoice>(
            'All consoles',
            value: const _DashChoice(_Act.consolesLateral),
            detail: 'side-by-side view',
          ),
        );
      }
    }

    entries.add(
      MenuEntry<_DashChoice>(
        'Create many',
        value: const _DashChoice(_Act.createMany),
        shortcut: 'm',
        detail: 'one server per type, all at once',
      ),
    );
    entries.add(
      MenuEntry<_DashChoice>(
        'Build & tuning',
        value: const _DashChoice(_Act.buildMenu),
        shortcut: 'b',
        detail: 'jars, repos, sync, JVM',
      ),
    );
    entries.add(
      MenuEntry<_DashChoice>(
        'Wipe everything',
        value: const _DashChoice(_Act.wipeEverything),
        detail: 'delete all instances across all consumers',
      ),
    );
    entries.add(
      MenuEntry<_DashChoice>(
        'Switch consumer',
        value: const _DashChoice(_Act.consumer),
        shortcut: 'c',
        detail: _activeConsumer().shortName,
      ),
    );
    entries.add(
      MenuEntry<_DashChoice>(
        'Refresh',
        value: const _DashChoice(_Act.refresh),
        shortcut: 'r',
      ),
    );
    entries.add(
      MenuEntry<_DashChoice>(
        'Quit',
        value: const _DashChoice(_Act.quit),
        shortcut: 'q',
      ),
    );

    return entries;
  }

  Future<_DashChoice> _dashboardMenu(_DashboardData data) async {
    return menuSelect<_DashChoice>(
      'Dashboard',
      _buildDashEntries(data.rows, data.active),
      initialIndex: data.rows.isEmpty ? 0 : 1,
      // Live refresh: re-poll players/TPS/version and redraw in place ~1s.
      onTick: () async {
        final List<_InstanceRow> rows = await _loadInstanceMetricRows();
        final String? active = await _activeInstance();
        return _buildDashEntries(rows, active);
      },
    );
  }

  Future<void> _dispatch(_DashChoice choice, List<_InstanceRow> rows) async {
    switch (choice.kind) {
      case _Act.instance:
        await _instanceMenu(choice.instance!);
        return;
      case _Act.create:
        await _createInstance();
        return;
      case _Act.createMany:
        await _createMany();
        return;
      case _Act.startAll:
        await _startAllStopped(rows);
        return;
      case _Act.stopAll:
        await _stopAllRunning(rows);
        return;
      case _Act.wipeEverything:
        await _wipeEverything();
        return;
      case _Act.consolesGrid:
        await _shellRun(<String>['runtime', 'consoles']);
        return;
      case _Act.consolesLateral:
        await _shellRun(<String>['runtime', 'consoles-lateral']);
        return;
      case _Act.buildMenu:
        await _buildAndTuningMenu();
        return;
      case _Act.consumer:
        await _switchConsumer();
        return;
      case _Act.refresh:
      case _Act.quit:
        return;
    }
  }

  // ─── Instance actions ────────────────────────────────────────────────

  Future<void> _instanceMenu(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    if (row == null) {
      return;
    }
    final String? active = await Ui.shielded(_activeInstance);
    final bool isActive = name == active;
    final bool isStopped = row.state == RuntimeState.stopped;
    final bool isRunning = row.state == RuntimeState.running;
    final bool isolated = await Ui.shielded(() => _isolated(name));
    final bool locked = await Ui.shielded(() => _locked(name));

    final List<MenuEntry<_InstanceAct>> entries = <MenuEntry<_InstanceAct>>[];
    if (isStopped) {
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Start',
          value: _InstanceAct.startWithConsole,
          shortcut: 'o',
          detail: 'opens console',
        ),
      );
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Start in background',
          value: _InstanceAct.startBackground,
        ),
      );
    } else {
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Open console',
          value: _InstanceAct.console,
          shortcut: 'o',
          detail: 'esc detaches, server keeps running',
        ),
      );
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Restart',
          value: _InstanceAct.restart,
          shortcut: 't',
        ),
      );
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Stop',
          value: _InstanceAct.stop,
          shortcut: 'x',
        ),
      );
    }
    entries.add(const MenuEntry<_InstanceAct>.separator());
    if (!isActive) {
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Make active',
          value: _InstanceAct.activate,
        ),
      );
    }
    entries.add(
      const MenuEntry<_InstanceAct>('Set port', value: _InstanceAct.port),
    );
    entries.add(
      const MenuEntry<_InstanceAct>(
        'Apply styled MOTD',
        value: _InstanceAct.motd,
      ),
    );
    entries.add(
      const MenuEntry<_InstanceAct>(
        'Open folder',
        value: _InstanceAct.openFolder,
        shortcut: 'f',
        detail: 'opens the instance directory',
      ),
    );
    if (isStopped) {
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Update game version',
          value: _InstanceAct.update,
          shortcut: 'u',
          detail: 'pick a new MC version (risky)',
        ),
      );
    }
    entries.add(
      MenuEntry<_InstanceAct>(
        isolated ? 'Mark as shared' : 'Mark as isolated',
        value: _InstanceAct.toggleIsolated,
        detail: isolated
            ? 'rewire dropins, iris, shared ops'
            : 'unsubscribe from dropins, iris, shared ops',
      ),
    );
    entries.add(
      locked
          ? const MenuEntry<_InstanceAct>(
              'Unlock (PIN)',
              value: _InstanceAct.unlock,
              detail: 're-enable delete and factory reset',
            )
          : const MenuEntry<_InstanceAct>(
              'Lock (set PIN)',
              value: _InstanceAct.lock,
              detail: 'block delete and factory reset',
            ),
    );
    if (isStopped && !locked) {
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Factory reset',
          value: _InstanceAct.reset,
          detail: 'wipes worlds, config, dropins',
        ),
      );
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Delete',
          value: _InstanceAct.delete,
          detail: 'removes the instance entirely',
        ),
      );
    }
    entries.add(const MenuEntry<_InstanceAct>.separator());
    entries.add(
      const MenuEntry<_InstanceAct>('Back', value: _InstanceAct.back),
    );

    final String badge =
        '${_stateGlyph(row.state)} ${row.state.name} on :${row.port}'
        '${isActive ? ' · active' : ''}'
        '${isolated ? ' · isolated' : ''}'
        '${locked ? ' · locked' : ''}';
    if (!isRunning && !isStopped) {
      Ui.note('Server is ${row.state.name}; the dashboard updates on refresh.');
    }
    final _InstanceAct action = await menuSelect<_InstanceAct>(
      '$name  ${Ansi.style(badge, _stateColor(row.state))}',
      entries,
    );

    switch (action) {
      case _InstanceAct.startWithConsole:
        await _syncDropinsAllTargets();
        await _shellRun(<String>['runtime', 'start', name]);
        return;
      case _InstanceAct.startBackground:
        await _syncDropinsAllTargets();
        Ui.doing('Starting $name in background');
        final int code = await _shellRun(<String>[
          'runtime',
          'start',
          name,
          '--no-console',
        ]);
        if (code != 0) {
          await Ui.pause();
        }
        return;
      case _InstanceAct.console:
        await _shellRun(<String>['runtime', 'console', name]);
        return;
      case _InstanceAct.restart:
        Ui.doing('Restarting $name');
        // runtime restart stops, starts, and attaches the console; if start
        // fails the user gets a chance to read the error instead of being
        // bounced straight back to the dashboard.
        final int code = await _shellRun(<String>['runtime', 'restart', name]);
        if (code != 0) {
          await Ui.pause();
        }
        return;
      case _InstanceAct.stop:
        Ui.doing('Stopping $name');
        await _shellRun(<String>['runtime', 'stop', name]);
        return;
      case _InstanceAct.activate:
        await _shellRun(<String>['instance', 'activate', name]);
        return;
      case _InstanceAct.port:
        await _setInstancePort(name);
        return;
      case _InstanceAct.motd:
        await _shellRun(<String>['instance', 'motd-style', name]);
        await Ui.pause();
        return;
      case _InstanceAct.openFolder:
        await _shellRun(<String>['instance', 'open', name]);
        return;
      case _InstanceAct.update:
        await _updateInstance(name);
        return;
      case _InstanceAct.toggleIsolated:
        await _toggleIsolated(name, currentlyIsolated: isolated);
        return;
      case _InstanceAct.lock:
        await _lockInstance(name);
        return;
      case _InstanceAct.unlock:
        await _unlockInstance(name);
        return;
      case _InstanceAct.reset:
        final bool confirmed = await Ui.confirm(
          'Factory reset $name? Worlds, config, and dropins are wiped.',
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'reset', name]);
          await Ui.pause();
        }
        return;
      case _InstanceAct.delete:
        final bool confirmed = await Ui.confirm(
          'Delete instance $name permanently?',
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'delete', name]);
        }
        return;
      case _InstanceAct.back:
        return;
    }
  }

  Future<void> _startAllStopped(List<_InstanceRow> rows) async {
    final List<String> stopped = rows
        .where((_InstanceRow r) => r.state == RuntimeState.stopped)
        .map((_InstanceRow r) => r.name)
        .toList(growable: false);
    if (stopped.isEmpty) {
      return;
    }

    await _syncDropinsAllTargets();
    var started = 0;
    var failed = 0;
    final List<String> startedNames = <String>[];
    for (final String name in stopped) {
      Ui.doing('Starting $name');
      final int code = await _shellRun(<String>[
        'runtime',
        'start',
        name,
        '--no-console',
      ]);
      if (code == 0) {
        started++;
        startedNames.add(name);
      } else {
        failed++;
      }
    }

    if (failed > 0) {
      Ui.warn('Started $started instance(s), failed $failed.');
      await Ui.pause();
    }
    if (started == 1) {
      await _shellRun(<String>['runtime', 'console', startedNames.first]);
    } else if (started > 1) {
      await _shellRun(<String>['runtime', 'consoles']);
    }
  }

  Future<void> _stopAllRunning(List<_InstanceRow> rows) async {
    final List<String> running = rows
        .where((_InstanceRow r) => r.state != RuntimeState.stopped)
        .map((_InstanceRow r) => r.name)
        .toList(growable: false);
    for (final String name in running) {
      Ui.doing('Stopping $name');
      await _shellRun(<String>['runtime', 'stop', name]);
    }
  }

  // ─── Create flow ─────────────────────────────────────────────────────

  Future<void> _createInstance() async {
    final String type = await Ui.pick('Server platform', _serverTypes);
    final _BuildVersionChoice versionChoice = await _pickSupportedVersion(type);
    final String version = versionChoice.version;

    final String name = await Ui.input(
      'Instance name',
      defaultValue: '$type-${version.trim()}',
      validator: _isValidInstanceName,
      validationMessage: 'Use letters, numbers, ., _, or - with no spaces.',
    );

    final bool refresh = await Ui.confirm(
      'Refresh ${_serverTypeLabel(type)} $version from upstream first?',
    );

    // Confirms default YES — phrase as "subscribe?" so accepting keeps the
    // existing shared-dropin behavior. Decline to make the server isolated.
    final bool subscribe = await Ui.confirm(
      'Subscribe $name to plugin/mod dropins and shared ops?',
    );
    final bool isolated = !subscribe;

    Ui.doing('Creating ${_serverTypeLabel(type)} $version server "$name"');
    final int code = await _shellRun(<String>[
      'server',
      'create',
      name,
      '--type',
      type,
      '--mc',
      version.trim(),
      if (refresh) '--auto-build',
      if (isolated) '--isolated',
    ]);
    if (code != 0) {
      await Ui.pause();
      return;
    }

    if (!isolated) {
      await _syncDropinsAllTargets();
    }

    final List<String> all = await _instanceNames();
    if (all.length == 1 && all.first == name) {
      Ui.info('First instance: activating and opening console.');
      await _shellRun(<String>['instance', 'activate', name]);
      await _shellRun(<String>['runtime', 'start', name]);
      return;
    }

    final bool activate = await Ui.confirm('Make $name the active instance?');
    if (activate) {
      await _shellRun(<String>['instance', 'activate', name]);
    }
  }

  Future<void> _createMany() async {
    Ui.note(
      'Pick the server types to spin up, comma-separated. Available: ${_serverTypes.join(', ')}.',
    );
    final String raw = await Ui.input(
      'Types',
      defaultValue: 'paper,purpur,canvas,spigot',
      validator: (String input) => input.trim().isNotEmpty,
      validationMessage: 'Enter at least one type.',
    );
    final List<String> types = raw
        .split(',')
        .map((String t) => t.trim().toLowerCase())
        .where((String t) => _serverTypes.contains(t))
        .toList(growable: false);
    if (types.isEmpty) {
      Ui.error('No valid types selected.');
      await Ui.pause();
      return;
    }

    final String prefix = await Ui.input(
      'Name prefix (blank for type-only names like "paper", "purpur")',
      defaultValue: '',
    );
    final String mc = await Ui.input(
      'Shared Minecraft version (blank to resolve latest per type)',
      defaultValue: '',
    );
    final bool refresh = await Ui.confirm(
      'Refresh each type from upstream before creating?',
    );
    final bool subscribe = await Ui.confirm(
      'Subscribe new servers to plugin/mod dropins and shared ops?',
    );
    final bool isolated = !subscribe;

    Ui.doing('Creating ${types.length} server(s)');
    await _shellRun(<String>[
      'server',
      'create-many',
      '--types',
      types.join(','),
      if (prefix.trim().isNotEmpty) ...<String>['--prefix', prefix.trim()],
      if (mc.trim().isNotEmpty) ...<String>['--mc', mc.trim()],
      if (refresh) '--auto-build',
      if (isolated) '--isolated',
    ]);
    if (!isolated) {
      await _syncDropinsAllTargets();
    }
    await Ui.pause();
  }

  Future<void> _wipeEverything() async {
    Ui.warn(
      'This deletes EVERY instance across plugin/forge/fabric/neoforge consumers.',
    );
    final bool confirmed = await Ui.confirm(
      'Wipe every instance in every consumer profile?',
    );
    if (!confirmed) {
      return;
    }
    final String typed = await Ui.input(
      'Type WIPE EVERYTHING to confirm',
      defaultValue: '',
    );
    if (typed.trim() != 'WIPE EVERYTHING') {
      Ui.note('Wipe cancelled.');
      await Ui.pause();
      return;
    }
    Ui.doing('Wiping all consumers');
    await _shellRun(<String>[
      'instance',
      'delete-all',
      '--everywhere',
      '--force',
    ]);
    await Ui.pause();
  }

  Future<bool> _isolated(String name) async {
    final String? raw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'isolated',
      name,
    ]);
    return (raw ?? '').trim().toLowerCase() == 'true';
  }

  Future<bool> _locked(String name) async {
    final String? raw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'locked',
      name,
    ]);
    return (raw ?? '').trim().toLowerCase() == 'true';
  }

  Future<void> _lockInstance(String name) async {
    Ui.info(
      'Lock $name so it cannot be deleted or factory reset without a PIN.',
    );
    String pin;
    String confirm;
    try {
      pin = await Ui.secret('Set a PIN (4-12 digits)');
      confirm = await Ui.secret('Confirm PIN');
    } on PromptBackNavigation {
      return;
    }
    if (pin != confirm) {
      Ui.error('PINs do not match.');
      await Ui.pause();
      return;
    }
    // The service validates length/digits and reports any problem.
    await _shellRun(<String>['instance', 'lock', name, '--pin', pin]);
    await Ui.pause();
  }

  Future<void> _unlockInstance(String name) async {
    String pin;
    try {
      pin = await Ui.secret('Enter PIN to unlock $name');
    } on PromptBackNavigation {
      return;
    }
    await _shellRun(<String>['instance', 'unlock', name, '--pin', pin]);
    await Ui.pause();
  }

  Future<void> _toggleIsolated(
    String name, {
    required bool currentlyIsolated,
  }) async {
    final String target = currentlyIsolated ? 'false' : 'true';
    final String prompt = currentlyIsolated
        ? 'Re-subscribe $name to dropins, iris, and shared ops?'
        : 'Isolate $name? It will stop receiving dropins, iris packs, and shared ops.';
    final bool confirmed = await Ui.confirm(prompt);
    if (!confirmed) {
      return;
    }
    await _shellRun(<String>['instance', 'isolated', name, target]);
    if (target == 'false') {
      await _syncDropinsAllTargets();
    }
    await Ui.pause();
  }

  Future<void> _updateInstance(String name) async {
    final String? pathRaw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'path',
      name,
    ]);
    if (pathRaw == null || pathRaw.trim().isEmpty) {
      Ui.error('Could not resolve instance path for $name');
      await Ui.pause();
      return;
    }
    final File sourceFile = File('${pathRaw.trim()}/.server-source');
    String? type;
    if (sourceFile.existsSync()) {
      for (final String line in sourceFile.readAsLinesSync()) {
        if (line.startsWith('type=')) {
          type = line.substring('type='.length).trim();
          break;
        }
      }
    }
    type ??= 'purpur';
    final String currentType = type;

    final bool confirmedRisk = await Ui.confirm(
      'Update $name to a new $currentType version? '
      'Worlds may corrupt and dropins may stop loading.',
    );
    if (!confirmedRisk) {
      return;
    }

    final _BuildVersionChoice choice = await _pickSupportedVersion(currentType);
    final bool refresh = await Ui.confirm(
      'Refresh ${_serverTypeLabel(currentType)} ${choice.version} from upstream first?',
    );

    Ui.doing(
      'Updating $name -> ${_serverTypeLabel(currentType)} ${choice.version}',
    );
    final int code = await _shellRun(<String>[
      'instance',
      'update',
      name,
      '--type',
      currentType,
      '--mc',
      choice.version.trim(),
      if (refresh) '--auto-build',
    ]);
    if (code == 0) {
      Ui.success(
        '$name now points at ${_serverTypeLabel(currentType)} ${choice.version}.',
      );
    }
    await Ui.pause();
  }

  Future<void> _setInstancePort(String name) async {
    final String? currentRaw = await passthrough.captureStdoutLine(<String>[
      'instance',
      'port',
      name,
    ]);
    final int? current = int.tryParse((currentRaw ?? '').trim());

    final List<int> pool = <int>{
      for (int port = 25565; port <= 25575; port++) port,
      ?current,
    }.toList(growable: false)..sort();

    final List<MenuEntry<int>> entries = <MenuEntry<int>>[
      for (final int port in pool)
        MenuEntry<int>(
          '$port',
          value: port,
          detail: port == current ? 'current' : null,
        ),
    ];
    final int initialIndex = current == null
        ? 0
        : pool.indexOf(current).clamp(0, pool.length - 1);

    final int port = await menuSelect<int>(
      'Port for $name',
      entries,
      initialIndex: initialIndex,
    );
    await _shellRun(<String>['instance', 'port', name, '$port']);
  }

  Future<void> _switchConsumer() async {
    final List<String> options = consumerService
        .listProfiles()
        .map((ConsumerProfile e) => e.shortName)
        .toList(growable: false);
    final String selected = await Ui.pick('Consumer profile', options);
    await _shellRun(<String>['consumer', 'use', selected]);
  }

  // ─── Build & tuning ──────────────────────────────────────────────────

  Future<void> _buildAndTuningMenu() async {
    const List<String> heapOptions = <String>[
      '2G',
      '4G',
      '6G',
      '8G',
      '10G',
      '12G',
      '16G',
    ];
    const Map<String, String> presetLabels = <String, String>{
      'Aikar (recommended)': 'aikar',
      'Vanilla (minimal flags)': 'vanilla',
      'Conservative (lower pause pressure)': 'conservative',
    };

    while (true) {
      final bool plugins = _isPluginConsumer();
      final String dropinCommand = plugins ? 'plugins' : 'mods';
      final String dropinLabel = plugins ? 'plugins' : 'mods';
      final _RuntimeSettings settings = await _runtimeSettings();
      final String heap = settings.heap ?? '4G';
      final String profile = settings.profile ?? 'aikar';

      final List<MenuEntry<_BuildAct>> entries = <MenuEntry<_BuildAct>>[
        const MenuEntry<_BuildAct>.separator('build'),
        const MenuEntry<_BuildAct>(
          'Build server jar',
          value: _BuildAct.build,
          shortcut: 'b',
          detail: 'pick platform and version',
        ),
        const MenuEntry<_BuildAct>('Show build cache', value: _BuildAct.cache),
        const MenuEntry<_BuildAct>(
          'Sync upstream repos',
          value: _BuildAct.repos,
        ),
        const MenuEntry<_BuildAct>.separator('dropins'),
        MenuEntry<_BuildAct>(
          'Sync $dropinLabel to instances',
          value: _BuildAct.sync,
        ),
        MenuEntry<_BuildAct>(
          'Show $dropinLabel source',
          value: _BuildAct.source,
        ),
        const MenuEntry<_BuildAct>.separator('jvm'),
        MenuEntry<_BuildAct>('Heap size', value: _BuildAct.heap, detail: heap),
        MenuEntry<_BuildAct>(
          'Flag profile',
          value: _BuildAct.flags,
          detail: profile,
        ),
        const MenuEntry<_BuildAct>(
          'Reset JVM defaults',
          value: _BuildAct.resetJvm,
          detail: '4G + aikar',
        ),
        const MenuEntry<_BuildAct>.separator(),
        const MenuEntry<_BuildAct>('Back', value: _BuildAct.back),
      ];

      _BuildAct action;
      try {
        action = await menuSelect<_BuildAct>('Build & tuning', entries);
      } on PromptBackNavigation {
        return;
      }

      switch (action) {
        case _BuildAct.build:
          await _runStep(_buildServerArtifact);
          break;
        case _BuildAct.cache:
          await _shellRun(<String>['build', 'list']);
          await Ui.pause();
          break;
        case _BuildAct.repos:
          Ui.doing('Syncing upstream repos');
          await _shellRun(<String>['repos', 'sync', 'all']);
          await Ui.pause();
          break;
        case _BuildAct.sync:
          await _shellRun(<String>[dropinCommand, 'sync', '--all']);
          await Ui.pause();
          break;
        case _BuildAct.source:
          await _shellRun(<String>[dropinCommand, 'show-source']);
          await Ui.pause();
          break;
        case _BuildAct.heap:
          await _runStep(() async {
            int index = heapOptions.indexWhere(
              (String candidate) =>
                  candidate.toUpperCase() == heap.toUpperCase(),
            );
            if (index < 0) {
              index = 1;
            }
            final String selected = await Ui.pick(
              'Heap size (Xms/Xmx)',
              heapOptions,
              initialIndex: index,
            );
            await _shellRun(<String>[
              'runtime',
              'settings',
              'set-heap',
              selected,
            ]);
          });
          break;
        case _BuildAct.flags:
          await _runStep(() async {
            final List<String> labels = presetLabels.keys.toList(
              growable: false,
            );
            int index = labels.indexWhere(
              (String label) => presetLabels[label] == profile.toLowerCase(),
            );
            if (index < 0) {
              index = 0;
            }
            final String selected = await Ui.pick(
              'JVM flag profile',
              labels,
              initialIndex: index,
            );
            await _shellRun(<String>[
              'runtime',
              'settings',
              'set-preset',
              presetLabels[selected]!,
            ]);
          });
          break;
        case _BuildAct.resetJvm:
          await _shellRun(<String>['runtime', 'settings', 'reset']);
          break;
        case _BuildAct.back:
          return;
      }
    }
  }

  Future<void> _buildServerArtifact() async {
    final String type = await Ui.pick('Server platform', _serverTypes);
    final _BuildVersionChoice versionChoice = await _pickSupportedVersion(type);
    final String label = _serverTypeLabel(type);
    Ui.doing('Building $label for Minecraft ${versionChoice.version}');
    await _shellRun(<String>['build', type, '--mc', versionChoice.version]);
    await Ui.pause();
  }

  Future<_BuildVersionChoice> _pickSupportedVersion(String type) async {
    final String label = _serverTypeLabel(type);
    Ui.note('Checking supported Minecraft versions for $label...');
    final List<String> supported = await _resolveSupportedVersions(type);
    final String latest = await _resolveLatestVersion(type);

    Future<_BuildVersionChoice> manualEntry() async {
      final String manual = await Ui.input(
        '$label Minecraft version',
        defaultValue: latest,
        validator: _looksLikeMinecraftVersion,
        validationMessage: 'Use a version like 1.21.11 or 26.1.2.',
      );
      return _BuildVersionChoice(
        version: manual.trim(),
        isLatest: manual.trim() == latest,
      );
    }

    if (supported.isEmpty) {
      return manualEntry();
    }

    final List<String> newestFirst = supported.reversed.toList(growable: false);
    final List<String> visible = newestFirst.take(30).toList(growable: true);
    if (!visible.contains(latest)) {
      visible.insert(0, latest);
    }

    final List<MenuEntry<String>> entries = <MenuEntry<String>>[
      for (final String version in visible)
        MenuEntry<String>(
          'Minecraft $version',
          value: version,
          detail: version == latest ? 'latest supported by $label' : null,
        ),
      MenuEntry<String>(
        'Enter another version',
        value: '',
        detail: supported.length > visible.length
            ? '${supported.length - visible.length} older not shown'
            : null,
      ),
    ];

    final String selected = await menuSelect<String>(
      '$label version (${supported.length} supported)',
      entries,
    );
    if (selected.isEmpty) {
      return manualEntry();
    }
    return _BuildVersionChoice(version: selected, isLatest: selected == latest);
  }

  // ─── Backend helpers ─────────────────────────────────────────────────

  /// Runs a native command shielded: echo off while it runs, stale
  /// keystrokes drained afterwards.
  Future<int> _shellRun(List<String> args) {
    return Ui.shielded(() => passthrough.run(args));
  }

  Future<void> _syncDropinsAllTargets() async {
    final String command = _isPluginConsumer() ? 'plugins' : 'mods';
    await _shellRun(<String>[command, 'sync', '--all']);
  }

  ConsumerProfile _activeConsumer() {
    return requestedConsumer ?? consumerService.readActive();
  }

  bool _isPluginConsumer() {
    return _activeConsumer() == ConsumerProfile.plugin;
  }

  Future<List<_InstanceRow>> _loadInstanceRows() async {
    final CapturedResult result = await passthrough.capture(<String>[
      'runtime',
      'states',
    ]);
    if (!result.success) {
      return const <_InstanceRow>[];
    }

    final List<_InstanceRow> rows = <_InstanceRow>[];
    for (final String line in result.stdout.split('\n')) {
      final List<String> parts = line.trim().split('\t');
      if (parts.length < 3 || parts[0].isEmpty) {
        continue;
      }
      rows.add(
        _InstanceRow(
          name: parts[0],
          state: RuntimeState.values.firstWhere(
            (RuntimeState s) => s.name == parts[1],
            orElse: () => RuntimeState.stopped,
          ),
          port: parts[2],
          locked: parts.length > 4 && parts[4] == 'locked',
        ),
      );
    }
    return rows;
  }

  /// Loads rows with live metrics (players, TPS, version) via `runtime metrics`.
  /// Slower than [_loadInstanceRows] because it pings each running server, so
  /// it drives the dashboard's periodic refresh rather than the first paint.
  Future<List<_InstanceRow>> _loadInstanceMetricRows() async {
    final CapturedResult result = await passthrough.capture(<String>[
      'runtime',
      'metrics',
    ]);
    if (!result.success) {
      return const <_InstanceRow>[];
    }

    final List<_InstanceRow> rows = <_InstanceRow>[];
    for (final String line in result.stdout.split('\n')) {
      // name, state, port, locked, players, max, version, tps
      final List<String> parts = line.trim().split('\t');
      if (parts.length < 8 || parts[0].isEmpty) {
        continue;
      }
      rows.add(
        _InstanceRow(
          name: parts[0],
          state: RuntimeState.values.firstWhere(
            (RuntimeState s) => s.name == parts[1],
            orElse: () => RuntimeState.stopped,
          ),
          port: parts[2],
          locked: parts[3] == 'locked',
          players: int.tryParse(parts[4]),
          maxPlayers: int.tryParse(parts[5]),
          version: parts[6] == '-' ? null : parts[6],
          tps: double.tryParse(parts[7]),
        ),
      );
    }
    return rows;
  }

  Future<_InstanceRow?> _loadInstanceRow(String name) async {
    final List<_InstanceRow> rows = await _loadInstanceRows();
    for (final _InstanceRow row in rows) {
      if (row.name == name) {
        return row;
      }
    }
    return null;
  }

  Future<List<String>> _instanceNames() async {
    final CapturedResult result = await passthrough.capture(<String>[
      'instance',
      'list',
    ]);
    if (!result.success) {
      return const <String>[];
    }
    return result.stdout
        .split('\n')
        .map((String line) => line.replaceAll(' (active)', '').trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Future<String?> _activeInstance() async {
    final String? line = await passthrough.captureStdoutLine(<String>[
      'instance',
      'current',
    ]);
    final String cleaned = (line ?? '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  Future<String?> _dropinsSource() async {
    final String command = _isPluginConsumer() ? 'plugins' : 'mods';
    final String? line = await passthrough.captureStdoutLine(<String>[
      command,
      'show-source',
    ]);
    final String cleaned = (line ?? '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  Future<_RuntimeSettings> _runtimeSettings() async {
    final CapturedResult result = await passthrough.capture(<String>[
      'runtime',
      'settings',
      'show',
    ]);
    if (!result.success) {
      return const _RuntimeSettings();
    }
    final String text = '${result.stdout}\n${result.stderr}';
    String? extract(String key) {
      return RegExp(
        '^$key:\\s*(.+)\$',
        multiLine: true,
      ).firstMatch(text)?.group(1)?.trim();
    }

    return _RuntimeSettings(
      heap: extract('heap size'),
      profile: extract('flags profile'),
    );
  }

  Future<String> _resolveLatestVersion(String type) async {
    final CapturedResult result = await passthrough.capture(<String>[
      'build',
      'latest',
      type,
    ]);
    if (!result.success) {
      return '1.21.1';
    }
    final List<String> lines = '${result.stdout}\n${result.stderr}'
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    for (final String line in lines.reversed) {
      if (RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(line)) {
        return line;
      }
    }
    return '1.21.1';
  }

  Future<List<String>> _resolveSupportedVersions(String type) async {
    final CapturedResult result = await passthrough.capture(<String>[
      'build',
      'versions',
      type,
    ]);
    if (!result.success) {
      return const <String>[];
    }
    final List<String> versions =
        '${result.stdout}\n${result.stderr}'
            .split('\n')
            .map(
              (String line) => RegExp(
                r'^\s*-\s*(\d+\.\d+(?:\.\d+)?)\s*$',
              ).firstMatch(line)?.group(1),
            )
            .whereType<String>()
            .toSet()
            .toList(growable: false)
          ..sort(_compareMinecraftVersions);
    return versions;
  }

  int _compareMinecraftVersions(String a, String b) {
    final List<int> av = _versionParts(a);
    final List<int> bv = _versionParts(b);
    final int length = av.length > bv.length ? av.length : bv.length;
    for (int i = 0; i < length; i++) {
      final int left = i < av.length ? av[i] : 0;
      final int right = i < bv.length ? bv[i] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }
    return a.compareTo(b);
  }

  List<int> _versionParts(String value) {
    return value
        .split('.')
        .map((String part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }

  bool _looksLikeMinecraftVersion(String input) {
    return RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(input.trim());
  }

  bool _isValidInstanceName(String input) {
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(input.trim());
  }

  String _serverTypeLabel(String type) {
    return switch (type) {
      'paper' => 'Paper',
      'purpur' => 'Purpur',
      'folia' => 'Folia',
      'canvas' => 'Canvas',
      'spigot' => 'Spigot',
      'forge' => 'Forge',
      'fabric' => 'Fabric',
      'neoforge' => 'NeoForge',
      _ => type,
    };
  }

  String _stateGlyph(RuntimeState state) {
    return switch (state) {
      RuntimeState.running => '●',
      RuntimeState.starting => '◐',
      RuntimeState.stopping => '◑',
      RuntimeState.restarting => '↻',
      RuntimeState.stopped => '○',
    };
  }

  String _stateColor(RuntimeState state) {
    return switch (state) {
      RuntimeState.running => Ansi.green,
      RuntimeState.starting ||
      RuntimeState.stopping ||
      RuntimeState.restarting => Ansi.yellow,
      RuntimeState.stopped => Ansi.gray,
    };
  }

  String _shortenPath(String path) {
    final String? home = Platform.environment['HOME'];
    String shortened = path;
    if (home != null && home.isNotEmpty && shortened.startsWith(home)) {
      shortened = '~${shortened.substring(home.length)}';
    }
    if (shortened.length > 32) {
      shortened = '…${shortened.substring(shortened.length - 31)}';
    }
    return shortened;
  }
}

enum _Act {
  instance,
  create,
  createMany,
  startAll,
  stopAll,
  wipeEverything,
  consolesGrid,
  consolesLateral,
  buildMenu,
  consumer,
  refresh,
  quit,
}

class _DashChoice {
  const _DashChoice(this.kind, {this.instance});

  final _Act kind;
  final String? instance;
}

enum _InstanceAct {
  startWithConsole,
  startBackground,
  console,
  restart,
  stop,
  activate,
  port,
  motd,
  openFolder,
  update,
  toggleIsolated,
  lock,
  unlock,
  reset,
  delete,
  back,
}

enum _BuildAct {
  build,
  cache,
  repos,
  sync,
  source,
  heap,
  flags,
  resetJvm,
  back,
}

class _InstanceRow {
  const _InstanceRow({
    required this.name,
    required this.state,
    required this.port,
    this.locked = false,
    this.players,
    this.maxPlayers,
    this.version,
    this.tps,
  });

  final String name;
  final RuntimeState state;
  final String port;
  final bool locked;

  /// Live metrics, populated by the metrics sweep (`runtime metrics`). Null on
  /// the fast state-only load and for servers that are not currently pingable.
  final int? players;
  final int? maxPlayers;
  final String? version;
  final double? tps;
}

class _DashboardData {
  const _DashboardData({
    required this.rows,
    required this.active,
    required this.dropins,
  });

  final List<_InstanceRow> rows;
  final String? active;
  final String? dropins;
}

class _RuntimeSettings {
  const _RuntimeSettings({this.heap, this.profile});

  final String? heap;
  final String? profile;
}

class _BuildVersionChoice {
  const _BuildVersionChoice({required this.version, required this.isLatest});

  final String version;
  final bool isLatest;
}
