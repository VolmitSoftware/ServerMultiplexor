import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/build_cache.dart';
import '../models/consumer_profile.dart';
import '../utils/process_runner.dart';
import '../utils/terminal/theme.dart';
import '../utils/user_prompt.dart';
import 'consumer_service.dart';
import 'dashboard_glyphs.dart';
import 'monitor/log_tail.dart';
import 'monitor/metric_sample.dart';
import 'monitor/metrics_sampler.dart';
import 'monitor/monitor_keymap.dart';
import 'monitor/monitor_model.dart';
import 'monitor/monitor_screen.dart';
import 'monitor/trend_store.dart';
import 'passthrough_service.dart';
import 'runtime_state.dart';

/// Monitor-driven interactive wizard.
///
/// The landing view is the full-screen monitor ([MonitorScreen]): it owns
/// the dashboard, the charts, and the per-instance quick keys. Everything it
/// cannot do itself it hands back here — opening an instance, creating one,
/// the workspace menu, switching consumers — and each of those runs as a
/// flat, state-aware menu flow on a suspended terminal. All background
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
  ConsumerProfile? _consumerOverride;

  static const List<String> _serverTypes = <String>[
    'paper',
    'purpur',
    'folia',
    'canvas',
    'leaf',
    'spigot',
    'forge',
    'fabric',
    'neoforge',
  ];

  /// How far back a new monitor session backfills its charts from the trend
  /// store. Matches the longest window the dashboard can cycle to.
  static const Duration _trendSeedWindow = Duration(hours: 24);

  Future<void> run() async {
    if (!Ui.hasTerminal) {
      _printTextFallback();
      return;
    }
    await runMonitor();
  }

  /// Runs the full-screen monitor as the landing view, dispatching every
  /// hand-off it reports back into this wizard's own flows.
  ///
  /// Owns the terminal for its whole lifetime, so callers only have to have
  /// checked [Ui.hasTerminal] first. Shared with `runtime watch`, which
  /// lands on the same dashboard with the same flows behind it.
  Future<void> runMonitor() async {
    TermIo.instance.installSignalRestore();
    try {
      // A consumer switch invalidates the sampler, its trend store, and
      // every reading either holds, so that one hand-off rebuilds the
      // session rather than resuming it.
      while (await _monitorSession()) {}
    } on PromptInputUnavailable catch (e) {
      Ui.error('Input stream lost: $e');
      stdout.writeln('Wizard closed to avoid a redraw loop.');
    } finally {
      passthrough.disposeRcon();
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

  // ─── Monitor ─────────────────────────────────────────────────────────

  /// One monitor session, against whichever consumer is active when it
  /// starts. Returns true when the caller should build a fresh session:
  /// the user switched consumers, so every sample taken so far — and the
  /// trend directory they were written to — belongs to the old profile.
  Future<bool> _monitorSession() async {
    final MetricsSampler sampler = MetricsSampler(
      captureMetrics: _captureMetrics,
      store: await _trendStore(),
    );
    // Swept and seeded before the screen opens so the first frame carries
    // both live readings and whatever history the last session left behind.
    await Ui.spin('Loading servers', () async {
      await sampler.sweep();
      await sampler.seedFromStore(sampler.instances, window: _trendSeedWindow);
    });

    final MonitorScreen screen = MonitorScreen(
      sampler: sampler,
      theme: MonitorTheme.detect(),
      loadSnapshot: () => _monitorSnapshot(sampler),
      suspend: _suspendedFlow,
      quickAction: _monitorQuickAction,
      readLogTail: readLogTail,
    );

    while (true) {
      final MonitorResult result = await screen.run();
      switch (result) {
        case MonitorQuit():
          return false;
        case MonitorSwitchConsumer():
          await _monitorFlow(_switchConsumer);
          return true;
        case MonitorOpenInstance(:final String instance):
          await _monitorFlow(() => _instanceMenu(instance));
        case MonitorNewInstance():
          await _monitorFlow(_createInstance);
        case MonitorBuildMenu():
          await _monitorFlow(_workspaceMenu);
      }
    }
  }

  /// Runs a hand-off flow on a cleared screen, absorbing an Escape as a
  /// return to the dashboard. The monitor has already given the terminal
  /// back by the time this runs.
  Future<void> _monitorFlow(Future<void> Function() flow) async {
    Ui.clearScreen();
    await _runStep(flow);
  }

  /// The monitor's suspension callback. The screen brackets the call with
  /// its own terminal transitions, so all this adds is a clean canvas and a
  /// guarantee that nothing escapes: an exception thrown here propagates out
  /// of [MonitorScreen.run] and would end the session, so a failed quick
  /// action reports itself and returns to the dashboard instead.
  Future<void> _suspendedFlow(Future<void> Function() flow) async {
    Ui.clearScreen();
    try {
      await flow();
    } on PromptBackNavigation {
      // Escape backs out of the flow, not out of the dashboard.
    } catch (error) {
      Ui.error('$error');
      await Ui.pause();
    }
  }

  /// Per-instance quick actions, on the same commands the legacy dashboard's
  /// R/S/X/O keys ran. The consoles grid is workspace-level and ignores the
  /// instance it is handed (which may be empty). Every other action the
  /// monitor can report is handled by the screen itself.
  Future<void> _monitorQuickAction(
    String instance,
    MonitorAction action,
  ) async {
    switch (action) {
      case MonitorAction.restart:
        await _quickRestart(instance);
      case MonitorAction.stop:
        await _quickStop(instance);
      case MonitorAction.kill:
        await _quickKill(instance);
      case MonitorAction.console:
        await _quickConsole(instance);
      case MonitorAction.consolesGrid:
        await _shellRun(<String>['runtime', 'consoles']);
      case MonitorAction.up:
      case MonitorAction.down:
      case MonitorAction.open:
      case MonitorAction.detail:
      case MonitorAction.newInstance:
      case MonitorAction.buildMenu:
      case MonitorAction.switchConsumer:
      case MonitorAction.cycleRange:
      case MonitorAction.refresh:
      case MonitorAction.quit:
      case MonitorAction.back:
      case MonitorAction.none:
        return;
    }
  }

  /// The metrics feed behind the sampler: one `runtime metrics` capture per
  /// sweep. A failed capture yields no rows rather than an error, so the
  /// dashboard keeps its last good readings and tries again next sweep.
  Future<String> _captureMetrics() async {
    final CapturedResult result = await passthrough.capture(<String>[
      'runtime',
      'metrics',
    ]);
    return result.success ? result.stdout : '';
  }

  /// Assembles the workspace view around the rings the sampler already
  /// holds. Capturing metrics is the sampler's job; this only adds the two
  /// workspace facts the frame needs on top of them.
  Future<MonitorSnapshot> _monitorSnapshot(MetricsSampler sampler) async {
    final List<String> instances = sampler.instances;
    return MonitorSnapshot(
      instances: instances,
      history: <String, List<MetricSample>>{
        for (final String instance in instances)
          instance: sampler.history(instance),
      },
      consumerName: _activeConsumer().shortName,
      activeInstance: await _activeInstance(),
    );
  }

  /// The active consumer's trend directory: `state/trends`, the sibling of
  /// the `state/runtime` folder every metrics row's `logPath` points into.
  /// Null when the consumer root cannot be resolved, in which case the
  /// session runs on in-memory history alone.
  Future<TrendStore?> _trendStore() async {
    final String? root = await Ui.shielded(
      () => passthrough.captureStdoutLine(<String>['consumer', 'path']),
    );
    final String trimmed = (root ?? '').trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return TrendStore(Directory(p.join(trimmed, 'state', 'trends')));
  }

  /// Workspace-level actions the monitor has no key of its own for. Reached
  /// with `b` from the dashboard.
  Future<void> _workspaceMenu() async {
    while (true) {
      final List<_InstanceRow> rows = await Ui.spin(
        'Loading servers',
        _loadInstanceRows,
      );
      final int stopped = rows
          .where((_InstanceRow r) => r.state == RuntimeState.stopped)
          .length;
      final int running = rows.length - stopped;

      final List<MenuEntry<_WorkspaceAct>> entries = <MenuEntry<_WorkspaceAct>>[
        const MenuEntry<_WorkspaceAct>(
          'Build & tuning',
          value: _WorkspaceAct.buildMenu,
          shortcut: 'b',
          detail: 'jars, repos, sync, JVM',
        ),
        const MenuEntry<_WorkspaceAct>(
          'Pull latest builds',
          value: _WorkspaceAct.pullBuilds,
          shortcut: 'p',
          detail: 'refresh every platform jar, spigot included',
        ),
        const MenuEntry<_WorkspaceAct>(
          'Create many',
          value: _WorkspaceAct.createMany,
          shortcut: 'm',
          detail: 'one server per type, all at once',
        ),
        if (stopped > 1)
          MenuEntry<_WorkspaceAct>(
            'Start all stopped',
            value: _WorkspaceAct.startAll,
            shortcut: 's',
            detail: '$stopped instances',
          ),
        if (running > 1)
          MenuEntry<_WorkspaceAct>(
            'Stop all running',
            value: _WorkspaceAct.stopAll,
            shortcut: 'k',
            detail: '$running instances',
          ),
        const MenuEntry<_WorkspaceAct>.separator(),
        const MenuEntry<_WorkspaceAct>(
          'Wipe everything',
          value: _WorkspaceAct.wipeEverything,
          labelColor: Ansi.red,
          detail: 'delete all instances across all consumers',
        ),
        const MenuEntry<_WorkspaceAct>('Back', value: _WorkspaceAct.back),
      ];

      _WorkspaceAct action;
      try {
        action = await menuSelect<_WorkspaceAct>('Workspace', entries);
      } on PromptBackNavigation {
        return;
      }

      switch (action) {
        case _WorkspaceAct.buildMenu:
          await _runStep(_buildAndTuningMenu);
        case _WorkspaceAct.pullBuilds:
          await _runStep(_refreshAllBuilds);
        case _WorkspaceAct.createMany:
          await _runStep(_createMany);
        case _WorkspaceAct.startAll:
          await _runStep(
            () async => _startAllStopped(await Ui.shielded(_loadInstanceRows)),
          );
        case _WorkspaceAct.stopAll:
          await _runStep(
            () async => _stopAllRunning(await Ui.shielded(_loadInstanceRows)),
          );
        case _WorkspaceAct.wipeEverything:
          await _runStep(_wipeEverything);
        case _WorkspaceAct.back:
          return;
      }
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
          labelColor: Ansi.red,
          detail: 'wipes worlds, config, dropins',
        ),
      );
      entries.add(
        const MenuEntry<_InstanceAct>(
          'Delete',
          value: _InstanceAct.delete,
          labelColor: Ansi.red,
          detail: 'removes the instance entirely',
        ),
      );
    }
    entries.add(const MenuEntry<_InstanceAct>.separator());
    entries.add(
      const MenuEntry<_InstanceAct>('Back', value: _InstanceAct.back),
    );

    final String badge =
        '${animatedStateGlyph(row.state, 1)} ${row.state.name} on :${row.port}'
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
        await _shellRun(<String>['runtime', 'start', name]);
        return;
      case _InstanceAct.startBackground:
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
          defaultValue: false,
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'reset', name]);
          await Ui.pause();
        }
        return;
      case _InstanceAct.delete:
        final bool confirmed = await Ui.confirm(
          'Delete instance $name permanently?',
          defaultValue: false,
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'delete', name]);
        }
        return;
      case _InstanceAct.back:
        return;
    }
  }

  Future<void> _quickRestart(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    final bool running = row != null && row.state != RuntimeState.stopped;
    Ui.doing(running ? 'Restarting $name' : 'Starting $name');
    final int code = running
        ? await _shellRun(<String>['runtime', 'restart', name, '--no-console'])
        : await _shellRun(<String>['runtime', 'start', name, '--no-console']);
    if (code != 0) {
      await Ui.pause();
    }
  }

  Future<void> _quickStop(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    if (row == null || row.state == RuntimeState.stopped) {
      return;
    }
    Ui.doing('Stopping $name (graceful)');
    await _shellRun(<String>['runtime', 'stop', name, '--graceful']);
  }

  Future<void> _quickKill(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    if (row == null || row.state == RuntimeState.stopped) {
      return;
    }
    Ui.doing('Killing $name');
    await _shellRun(<String>['runtime', 'stop', name]);
  }

  Future<void> _quickConsole(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    final bool running = row != null && row.state != RuntimeState.stopped;
    if (running) {
      await _shellRun(<String>['runtime', 'console', name]);
    } else {
      await _shellRun(<String>['runtime', 'start', name]);
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
    final String type = await _pickServerPlatform();
    final _BuildVersionChoice versionChoice = await _pickSupportedVersion(type);
    final String version = versionChoice.version;

    final String name = await Ui.input(
      'Instance name',
      defaultValue: '$type-${version.trim()}',
      validator: _isValidInstanceName,
      validationMessage: 'Use letters, numbers, ., _, or - with no spaces.',
    );

    final bool refresh = _announceRefreshPlan(
      type: type,
      version: version,
      cachedAge: versionChoice.cachedAge,
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
    final bool subscribe = await Ui.confirm(
      'Subscribe new servers to plugin/mod dropins and shared ops?',
    );
    final bool isolated = !subscribe;

    // Auto-refresh instead of asking: stale cached builds are refreshed
    // up front, missing ones are fetched by create-many itself, and fresh
    // caches are reused as-is.
    final String? versionFilter = mc.trim().isEmpty ? null : mc.trim();
    final Map<String, Duration?> ages = <String, Duration?>{};
    await Ui.spin('Checking cached builds', () async {
      for (final String type in types) {
        ages[type] = newestCachedAge(
          await _cachedBuilds(type),
          version: versionFilter,
        );
      }
    });
    Ui.note(
      'Cached builds: ${types.map((String t) => '$t ${formatBuildAgeShort(ages[t])}').join(' · ')}',
    );
    for (final String type in types) {
      final Duration? age = ages[type];
      if (age == null ||
          !BuildCachePolicy.shouldRefresh(type: type, cachedAge: age)) {
        continue;
      }
      Ui.doing(
        'Refreshing ${_serverTypeLabel(type)} build (cached ${formatBuildAge(age)})',
      );
      await _shellRun(<String>[
        'build',
        type,
        if (versionFilter != null) ...<String>['--mc', versionFilter],
      ]);
    }

    Ui.doing('Creating ${types.length} server(s)');
    await _shellRun(<String>[
      'server',
      'create-many',
      '--types',
      types.join(','),
      if (prefix.trim().isNotEmpty) ...<String>['--prefix', prefix.trim()],
      if (mc.trim().isNotEmpty) ...<String>['--mc', mc.trim()],
      if (isolated) '--isolated',
    ]);
    if (!isolated) {
      await _syncDropinsAllTargets();
    }
    await Ui.pause();
  }

  /// Force re-downloads the newest build of every platform the active
  /// consumer owns, spigot included. Spigot only runs BuildTools when its
  /// upstream Jenkins build is newer than the cached jar, so the bulk pull
  /// stays fast on the common path.
  Future<void> _refreshAllBuilds() async {
    final List<String> types = _serverTypesForActiveConsumer();
    if (types.any(BuildCachePolicy.expensiveRebuild.contains)) {
      Ui.note(
        'spigot compiles with BuildTools when upstream moved — that step takes minutes.',
      );
    }
    int pulled = 0;
    final List<String> failed = <String>[];
    for (final String type in types) {
      Ui.doing('Pulling latest ${_serverTypeLabel(type)} build');
      final int code = await _shellRun(<String>['build', type]);
      if (code == 0) {
        pulled++;
      } else {
        failed.add(_serverTypeLabel(type));
      }
    }
    if (failed.isNotEmpty) {
      Ui.warn(
        'Pulled $pulled build(s); failed: ${failed.join(', ')} '
        '(see the errors above).',
      );
    } else {
      Ui.success('All $pulled platform build(s) fresh from upstream.');
    }
    await Ui.pause();
  }

  Future<void> _wipeEverything() async {
    Ui.warn(
      'This deletes EVERY instance across plugin/forge/fabric/neoforge consumers.',
    );
    final bool confirmed = await Ui.confirm(
      'Wipe every instance in every consumer profile?',
      defaultValue: false,
    );
    if (!confirmed) {
      return;
    }
    final bool reallySure = await Ui.confirm(
      'Are you sure? This cannot be undone.',
      defaultValue: false,
    );
    if (!reallySure) {
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
    final bool refresh = _announceRefreshPlan(
      type: currentType,
      version: choice.version,
      cachedAge: choice.cachedAge,
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
    final profile = ConsumerProfile.parse(selected)!;
    _consumerOverride = profile;
    passthrough.setConsumerOverride(profile);
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
      late final _RuntimeSettings settings;
      late final List<BuildCacheEntry> cache;
      await Ui.spin('Loading build & tuning state', () async {
        settings = await _runtimeSettings();
        cache = await _cachedBuilds('all');
      });
      final String heap = settings.heap ?? '4G';
      final String profile = settings.profile ?? 'aikar';
      final String wrap = settings.consoleWrap ?? 'off';
      final String logFormat = settings.consoleLogFormat ?? 'minimal';

      final List<MenuEntry<_BuildAct>> entries = <MenuEntry<_BuildAct>>[
        const MenuEntry<_BuildAct>.separator('build'),
        const MenuEntry<_BuildAct>(
          'Build server jar',
          value: _BuildAct.build,
          shortcut: 'b',
          detail: 'pick platform and version',
        ),
        const MenuEntry<_BuildAct>(
          'Pull latest builds',
          value: _BuildAct.pullAll,
          shortcut: 'p',
          detail: 'refresh every platform jar, spigot included',
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
        MenuEntry<_BuildAct>(
          'Console line wrap',
          value: _BuildAct.wrap,
          detail: wrap,
        ),
        MenuEntry<_BuildAct>(
          'Console log format',
          value: _BuildAct.logFormat,
          detail: logFormat,
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
        action = await menuSelect<_BuildAct>(
          'Build & tuning',
          entries,
          footer: _buildFreshnessFooter(cache),
        );
      } on PromptBackNavigation {
        return;
      }

      switch (action) {
        case _BuildAct.build:
          await _runStep(_buildServerArtifact);
          break;
        case _BuildAct.pullAll:
          await _refreshAllBuilds();
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
        case _BuildAct.wrap:
          await _runStep(() async {
            final String selected = await Ui.pick(
              'Console line wrap',
              const <String>['off', 'on'],
              initialIndex: wrap.startsWith('on') ? 1 : 0,
            );
            await _shellRun(<String>[
              'runtime',
              'settings',
              'set-wrap',
              selected,
            ]);
          });
          break;
        case _BuildAct.logFormat:
          await _runStep(() async {
            final String selected = await Ui.pick(
              'Console log format',
              const <String>['minimal', 'default'],
              initialIndex: logFormat.startsWith('default') ? 1 : 0,
            );
            await _shellRun(<String>[
              'runtime',
              'settings',
              'set-log-format',
              selected,
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
    final String type = await _pickServerPlatform();
    final _BuildVersionChoice versionChoice = await _pickSupportedVersion(type);
    final String label = _serverTypeLabel(type);
    Ui.doing('Building $label for Minecraft ${versionChoice.version}');
    await _shellRun(<String>['build', type, '--mc', versionChoice.version]);
    await Ui.pause();
  }

  /// Platform menu with per-type build freshness so nobody has to wonder
  /// whether picking a platform triggers a download.
  Future<String> _pickServerPlatform() async {
    final List<String> types = _serverTypesForActiveConsumer();
    if (types.length == 1) {
      return types.first;
    }
    final List<BuildCacheEntry> cache = await Ui.spin(
      'Checking cached builds',
      () => _cachedBuilds('all'),
    );
    final List<MenuEntry<String>> entries = <MenuEntry<String>>[
      for (final String type in types)
        MenuEntry<String>(
          _serverTypeLabel(type),
          value: type,
          detail: _freshnessDetail(_newestAgeForType(cache, type)),
        ),
    ];
    return menuSelect<String>(
      'Server platform',
      entries,
      footer: _buildFreshnessFooter(cache),
    );
  }

  Future<_BuildVersionChoice> _pickSupportedVersion(String type) async {
    final String label = _serverTypeLabel(type);
    late final List<String> supported;
    late final String latest;
    late final List<BuildCacheEntry> cache;
    await Ui.spin('Fetching $label versions', () async {
      supported = await _resolveSupportedVersions(type);
      latest = await _resolveLatestVersion(type);
      cache = await _cachedBuilds(type);
    });

    Future<_BuildVersionChoice> manualEntry() async {
      final String manual = await Ui.input(
        '$label Minecraft version',
        defaultValue: latest,
        validator: _looksLikeMinecraftVersion,
        validationMessage: 'Use a version like 1.21.11 or 26.1.2.',
      );
      final String trimmed = manual.trim();
      return _BuildVersionChoice(
        version: trimmed,
        isLatest: trimmed == latest,
        cachedAge: newestCachedAge(cache, version: trimmed),
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

    String? versionDetail(String version) {
      final List<String> parts = <String>[
        if (version == latest) Ansi.style('latest', Ansi.cyan),
      ];
      final Duration? age = newestCachedAge(cache, version: version);
      if (age != null) {
        parts.add(
          Ansi.style(
            'cached ${formatBuildAge(age)}',
            age <= BuildCachePolicy.ttl ? Ansi.green : Ansi.yellow,
          ),
        );
      }
      return parts.isEmpty ? null : parts.join(Ansi.style(' · ', Ansi.gray));
    }

    final Duration? newestAny = newestCachedAge(cache);
    final String footer = Ansi.style(
      newestAny == null
          ? '$label builds: none cached · create fetches fresh from upstream'
          : '$label builds updated ${formatBuildAge(newestAny)} · auto-refresh after ${BuildCachePolicy.ttl.inHours}h',
      Ansi.gray,
    );

    final List<MenuEntry<String>> entries = <MenuEntry<String>>[
      for (final String version in visible)
        MenuEntry<String>(
          'Minecraft $version',
          value: version,
          detail: versionDetail(version),
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
      footer: footer,
    );
    if (selected.isEmpty) {
      return manualEntry();
    }
    return _BuildVersionChoice(
      version: selected,
      isLatest: selected == latest,
      cachedAge: newestCachedAge(cache, version: selected),
    );
  }

  /// Decides whether a create/update pulls a fresh build and says so;
  /// replaces the old "Refresh from upstream first?" prompt.
  bool _announceRefreshPlan({
    required String type,
    required String version,
    required Duration? cachedAge,
  }) {
    final String label = _serverTypeLabel(type);
    final bool refresh = BuildCachePolicy.shouldRefresh(
      type: type,
      cachedAge: cachedAge,
    );
    if (refresh) {
      Ui.info(
        cachedAge == null
            ? 'No cached $label $version build — fetching fresh from upstream.'
            : 'Cached $label $version build is ${formatBuildAge(cachedAge)} — refreshing from upstream.',
      );
      return true;
    }
    final StringBuffer note = StringBuffer(
      'Using cached $label $version build (updated ${formatBuildAge(cachedAge)}).',
    );
    if (BuildCachePolicy.expensiveRebuild.contains(type) &&
        cachedAge != null &&
        cachedAge > BuildCachePolicy.ttl) {
      note.write(' Rebuilds are slow; force one from Build & tuning.');
    }
    Ui.note(note.toString());
    return false;
  }

  Future<List<BuildCacheEntry>> _cachedBuilds(String type) async {
    final CapturedResult result = await passthrough.capture(<String>[
      'build',
      'cache-info',
      type,
    ]);
    if (!result.success) {
      return const <BuildCacheEntry>[];
    }
    return BuildCacheEntry.parseAll(result.stdout);
  }

  Duration? _newestAgeForType(List<BuildCacheEntry> cache, String type) {
    return newestCachedAge(
      cache
          .where((BuildCacheEntry e) => e.type == type)
          .toList(growable: false),
    );
  }

  String _freshnessDetail(Duration? age) {
    if (age == null) {
      return Ansi.style('no cached build', Ansi.gray);
    }
    return Ansi.style(
      'updated ${formatBuildAge(age)}',
      age <= BuildCachePolicy.ttl ? Ansi.green : Ansi.yellow,
    );
  }

  /// Bottom status line: when each platform's build was last refreshed.
  String _buildFreshnessFooter(List<BuildCacheEntry> cache) {
    final List<String> parts = <String>[];
    for (final String type in _serverTypesForActiveConsumer()) {
      final Duration? age = _newestAgeForType(cache, type);
      final String token = formatBuildAgeShort(age);
      final String colored = age == null
          ? Ansi.style(token, Ansi.gray)
          : Ansi.style(
              token,
              age <= BuildCachePolicy.ttl ? Ansi.green : Ansi.yellow,
            );
      parts.add('${Ansi.style(type, Ansi.gray)} $colored');
    }
    return '${Ansi.style('builds', '${Ansi.gray}${Ansi.bold}')}  '
        '${parts.join(Ansi.style(' · ', Ansi.gray))}'
        '${Ansi.style('  ·  auto-refresh after ${BuildCachePolicy.ttl.inHours}h', Ansi.gray)}';
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
    return _consumerOverride ??
        requestedConsumer ??
        consumerService.readActive();
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
          isolated: parts.length > 5 && parts[5] == 'isolated',
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
      consoleWrap: extract('console wrap'),
      consoleLogFormat: extract('console log'),
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

  List<String> _serverTypesForActiveConsumer() {
    return switch (_activeConsumer()) {
      ConsumerProfile.plugin => const <String>[
        'paper',
        'purpur',
        'folia',
        'canvas',
        'leaf',
        'spigot',
      ],
      ConsumerProfile.forge => const <String>['forge'],
      ConsumerProfile.fabric => const <String>['fabric'],
      ConsumerProfile.neoforge => const <String>['neoforge'],
    };
  }

  String _serverTypeLabel(String type) {
    return switch (type) {
      'paper' => 'Paper',
      'purpur' => 'Purpur',
      'folia' => 'Folia',
      'canvas' => 'Canvas',
      'leaf' => 'Leaf',
      'spigot' => 'Spigot',
      'forge' => 'Forge',
      'fabric' => 'Fabric',
      'neoforge' => 'NeoForge',
      _ => type,
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

/// Workspace-level actions the monitor has no key of its own for.
enum _WorkspaceAct {
  buildMenu,
  pullBuilds,
  createMany,
  startAll,
  stopAll,
  wipeEverything,
  back,
}

enum _BuildAct {
  build,
  pullAll,
  cache,
  repos,
  sync,
  source,
  heap,
  flags,
  wrap,
  logFormat,
  resetJvm,
  back,
}

class _InstanceRow {
  const _InstanceRow({
    required this.name,
    required this.state,
    required this.port,
    this.locked = false,
    this.isolated = false,
  });

  final String name;
  final RuntimeState state;
  final String port;
  final bool locked;
  final bool isolated;
}

class _RuntimeSettings {
  const _RuntimeSettings({
    this.heap,
    this.profile,
    this.consoleWrap,
    this.consoleLogFormat,
  });

  final String? heap;
  final String? profile;
  final String? consoleWrap;
  final String? consoleLogFormat;
}

class _BuildVersionChoice {
  const _BuildVersionChoice({
    required this.version,
    required this.isLatest,
    this.cachedAge,
  });

  final String version;
  final bool isLatest;

  /// Age of the newest cached jar matching [version]; null when nothing is
  /// cached. Drives the automatic refresh decision.
  final Duration? cachedAge;
}
