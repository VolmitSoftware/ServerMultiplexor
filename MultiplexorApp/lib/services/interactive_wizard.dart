import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/build_cache.dart';
import '../models/consumer_profile.dart';
import '../utils/process_runner.dart';
import '../utils/terminal/theme.dart';
import '../utils/user_prompt.dart';
import 'consumer_service.dart';
import 'monitor/log_tail.dart';
import 'monitor/metric_sample.dart';
import 'monitor/metrics_sampler.dart';
import 'monitor/monitor_frame_util.dart';
import 'monitor/monitor_keymap.dart';
import 'monitor/monitor_modal.dart';
import 'monitor/monitor_screen.dart';
import 'monitor/trend_store.dart';
import 'passthrough_service.dart';
import 'pterodactyl/pterodactyl_console_protocol.dart';
import 'pterodactyl/pterodactyl_console_session.dart';
import 'pterodactyl/pterodactyl_console_terminal.dart';
import 'pterodactyl/pterodactyl_credential.dart';
import 'pterodactyl/pterodactyl_errors.dart';
import 'pterodactyl/pterodactyl_models.dart';
import 'pterodactyl/pterodactyl_monitor_feed.dart';
import 'pterodactyl/pterodactyl_profile.dart';
import 'pterodactyl/pterodactyl_service.dart';
import 'runtime_state.dart';

/// The side effect a Remote quick key is allowed to perform after a fresh
/// resource-state check.
enum RemoteQuickActionEffect { none, start, stop, restart, kill, console }

/// Resolves a Remote quick key against Pterodactyl's current runtime state.
///
/// Offline `R` mirrors the Local dashboard by starting the server. Operations
/// that require a live process become no-ops while the server is offline.
RemoteQuickActionEffect remoteQuickActionEffect({
  required MonitorAction action,
  required String currentState,
}) {
  final bool offline = currentState.trim().toLowerCase() == 'offline';
  return switch (action) {
    MonitorAction.restart =>
      offline ? RemoteQuickActionEffect.start : RemoteQuickActionEffect.restart,
    MonitorAction.stop =>
      offline ? RemoteQuickActionEffect.none : RemoteQuickActionEffect.stop,
    MonitorAction.kill =>
      offline ? RemoteQuickActionEffect.none : RemoteQuickActionEffect.kill,
    MonitorAction.console =>
      offline ? RemoteQuickActionEffect.none : RemoteQuickActionEffect.console,
    _ => RemoteQuickActionEffect.none,
  };
}

String _safeRemoteText(String value) => PterodactylConsoleSanitizer.text(
  value,
).replaceAll(RegExp(r'[\r\n\t]'), ' ');

/// Monitor-driven interactive wizard.
///
/// The landing view is the full-screen monitor ([MonitorScreen]): it owns the
/// dashboard, the charts, the modal cards, and the per-instance quick keys.
/// The flows behind those cards live here and are injected into the screen,
/// which runs each one on a suspended terminal — so a card button and a key
/// reach the same command by the same route. The one hand-off that still ends
/// a session is the consumer switch, which invalidates the sampler and its
/// trend store. All background commands run shielded so stray keystrokes
/// cannot corrupt the UI.
class InteractiveWizard {
  InteractiveWizard({
    required this.consumerService,
    required this.passthrough,
    required this.pterodactyl,
    this.requestedConsumer,
  });

  final ConsumerService consumerService;
  final PassthroughService passthrough;
  final PterodactylService pterodactyl;
  final ConsumerProfile? requestedConsumer;
  ConsumerProfile? _consumerOverride;
  MonitorView _monitorView = MonitorView.local;
  String? _remoteProfileId;
  bool _remoteConnectionChanged = false;

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
    if (_monitorView == MonitorView.remote) {
      return _remoteMonitorSession();
    }
    return _localMonitorSession();
  }

  Future<bool> _localMonitorSession() async {
    // The sampler drops the lock and isolation columns — they are workspace
    // facts, not readings — but the modal card needs them, and asking for
    // them separately would mean a second capture per sweep. So the feed is
    // tee'd on the way past: one `runtime metrics` call, samples to the
    // sampler and flags to the snapshot.
    Map<String, InstanceFlags> flags = const <String, InstanceFlags>{};
    Future<String> captureMetrics() async {
      final String raw = await _captureMetrics();
      if (raw.isNotEmpty) {
        // An empty capture is a failed one; the last good flags outlive it,
        // the same way the last good readings do.
        flags = metricsTsvFlagsByInstance(raw);
      }
      return raw;
    }

    final MetricsSampler sampler = MetricsSampler(
      captureMetrics: captureMetrics,
      store: await _trendStore(),
    );
    // Swept and seeded before the screen opens so the first frame carries
    // both live readings and whatever history the last session left behind.
    await Ui.spin('Loading servers', () async {
      await sampler.sweep();
      await sampler.seedFromStore(sampler.instances, window: _trendSeedWindow);
      // Session start is the one moment retention can be applied without
      // stealing time from a frame, and it has to happen after the seed so
      // this session still charts full-resolution history before the older
      // half of it is rolled up. Awaited rather than fired and forgotten: an
      // unawaited failure here would reach the root zone and take the
      // isolate — and the dashboard — with it.
      await sampler.compactStore(sampler.instances);
    });

    final MonitorScreen screen = MonitorScreen(
      sampler: sampler,
      theme: MonitorTheme.detect(),
      loadSnapshot: () => _monitorSnapshot(sampler, flags),
      suspend: _suspendedFlow,
      quickAction: _monitorQuickAction,
      instanceAction: _monitorInstanceAction,
      workspaceAction: _monitorWorkspaceAction,
      readLogTail: readLogTail,
      refreshImmediately: false,
    );

    while (true) {
      final MonitorResult result = await screen.run();
      switch (result) {
        case MonitorQuit():
          return false;
        case MonitorSwitchView():
          _monitorView = _monitorView == MonitorView.local
              ? MonitorView.remote
              : MonitorView.local;
          return true;
        case MonitorSwitchConsumer():
          // Only an actual profile change invalidates this session. Backing
          // out of the picker, or re-picking the profile already in use,
          // leaves the sampler and its trend directory correct.
          if (await _monitorFlowChanged(_switchConsumer)) {
            return true;
          }
      }
    }
  }

  Future<bool> _remoteMonitorSession() async {
    _remoteConnectionChanged = false;
    final PterodactylProfile? profile = _selectedRemoteProfile();
    final PterodactylMonitorFeed? feed = profile == null
        ? null
        : PterodactylMonitorFeed(service: pterodactyl, profileId: profile.id);

    final TrendStore? store = profile == null
        ? null
        : TrendStore(
            Directory(
              p.join(
                passthrough.context.globalStateDir,
                'pterodactyl',
                profile.id,
                'trends',
              ),
            ),
          );
    final MetricsSampler sampler = MetricsSampler(
      captureMetrics: feed?.captureMetrics ?? () async => '',
      store: store,
    );
    if (profile != null) {
      await Ui.spin('Loading remote servers', () async {
        await sampler.sweep();
        final List<String> instances = feed?.instances ?? const <String>[];
        await sampler.seedFromStore(instances, window: _trendSeedWindow);
        await sampler.compactStore(instances);
      });
    }
    Future<MonitorSnapshot> loadSnapshot() async {
      final bool connectionFailed = feed?.connectionFailed == true;
      final List<String> instances = connectionFailed
          ? const <String>[]
          : feed?.instances ?? const <String>[];
      return MonitorSnapshot(
        instances: instances,
        history: <String, List<MetricSample>>{
          for (final String instance in instances)
            instance: sampler.history(instance),
        },
        consumerName: profile == null || connectionFailed
            ? 'remote:not connected'
            : 'remote:${profile.name}',
        view: MonitorView.remote,
        displayNames: feed?.displayNames ?? const <String, String>{},
        advertisedEndpoints:
            feed?.advertisedEndpoints ?? const <String, String>{},
        bindEndpoints: feed?.bindEndpoints ?? const <String, String>{},
        operationBlockReasons: connectionFailed
            ? const <String, String>{}
            : feed?.operationBlockReasons ?? const <String, String>{},
      );
    }

    final MonitorScreen screen = MonitorScreen(
      sampler: sampler,
      theme: MonitorTheme.detect(),
      loadSnapshot: loadSnapshot,
      suspend: _suspendedFlow,
      quickAction: _monitorQuickAction,
      instanceAction: _monitorInstanceAction,
      workspaceAction: _monitorWorkspaceAction,
      readLogTail: (String _, int _) async => const <String>[
        'Remote console output is available from the live CONSOLE action.',
      ],
      sweepIntervalProvider: () => PterodactylService.recommendedPollInterval(
        feed?.instances.length ?? 0,
      ),
      refreshImmediately: false,
      sessionInvalidated: () => _remoteConnectionChanged,
    );

    while (true) {
      final MonitorResult result = await screen.run();
      switch (result) {
        case MonitorQuit():
          return false;
        case MonitorSwitchView():
          _monitorView = MonitorView.local;
          return true;
        case MonitorSwitchConsumer():
          if (_remoteConnectionChanged) {
            return true;
          }
          if (await _monitorFlowChanged(_connectPterodactyl)) {
            return true;
          }
          continue;
      }
    }
  }

  PterodactylProfile? _selectedRemoteProfile() {
    final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
    if (profiles.isEmpty) {
      _remoteProfileId = null;
      return null;
    }
    final String? selected = _remoteProfileId;
    if (selected != null) {
      for (final PterodactylProfile profile in profiles) {
        if (profile.id == selected) {
          return profile;
        }
      }
    }
    _remoteProfileId = profiles.first.id;
    return profiles.first;
  }

  /// Runs a hand-off flow on a cleared screen that reports whether it changed
  /// anything. A flow that backs out or fails reports no change.
  Future<bool> _monitorFlowChanged(Future<bool> Function() flow) async {
    Ui.clearScreen();
    bool changed = false;
    await _guardedFlow(() async {
      changed = await flow();
    });
    return changed;
  }

  /// Runs [flow], absorbing an Escape and reporting-then-swallowing any
  /// failure, so a broken flow returns to the dashboard instead of unwinding
  /// the whole wizard for one failed command.
  ///
  /// A lost stdin is the one thing that propagates: there is no dashboard
  /// left to return to, and [runMonitor]'s handler closes the session down
  /// cleanly instead of spinning on a terminal that cannot answer.
  Future<void> _guardedFlow(Future<void> Function() flow) async {
    try {
      await flow();
    } on PromptBackNavigation {
      // Escape backs out of the flow, not out of the dashboard.
    } on PromptInputUnavailable {
      rethrow;
    } catch (error) {
      Ui.error('$error');
      await Ui.pause();
    }
  }

  /// The monitor's suspension callback. The screen brackets the call with
  /// its own terminal transitions, so all this adds is a clean canvas and an
  /// absolute guarantee that nothing escapes: an exception thrown here
  /// propagates out of [MonitorScreen.run] and would end the session.
  ///
  /// That guarantee is load-bearing now, not belt and braces. What runs
  /// through here is no longer only the non-prompting quick actions: every
  /// card button and action-bar chip lands here too, and those flows do
  /// prompt — for a port, a PIN, a confirmation. A lost stdin mid-prompt is
  /// therefore reachable, and it is reported and swallowed rather than
  /// rethrown, because there is still a dashboard to return to.
  Future<void> _suspendedFlow(Future<void> Function() flow) async {
    Ui.clearScreen();
    try {
      await _guardedFlow(flow);
    } on PromptInputUnavailable catch (error) {
      Ui.error('Input stream lost: $error');
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
    if (_monitorView == MonitorView.remote) {
      await _remoteQuickAction(instance, action);
      return;
    }
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
      case MonitorAction.workspaceCard:
      case MonitorAction.switchView:
      case MonitorAction.switchConsumer:
      case MonitorAction.cycleRange:
      case MonitorAction.refresh:
      case MonitorAction.quit:
      case MonitorAction.back:
      case MonitorAction.none:
        return;
    }
  }

  /// Every per-instance action a card button or an action-bar chip can
  /// dispatch, on the same commands the flat menus ran. The screen has
  /// already suspended itself and cleared the screen, so a flow here is free
  /// to prompt.
  ///
  /// The isolation pair carries its own answer: the card only ever offers
  /// ISOLATE for a shared instance and SHARE for an isolated one, both read
  /// from the same capture the frame was drawn from, so which button was
  /// pressed *is* the current state.
  Future<void> _monitorInstanceAction(
    String name,
    InstanceModalAction action,
  ) async {
    if (_monitorView == MonitorView.remote) {
      await _remoteInstanceAction(name, action);
      return;
    }
    switch (action) {
      case InstanceModalAction.start:
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
      case InstanceModalAction.stop:
        await _quickStop(name);
      case InstanceModalAction.restart:
        await _quickRestart(name);
      case InstanceModalAction.console:
        await _quickConsole(name);
      case InstanceModalAction.setPort:
        await _setInstancePort(name);
      case InstanceModalAction.makeActive:
        await _shellRun(<String>['instance', 'activate', name]);
      case InstanceModalAction.motd:
        await _shellRun(<String>['instance', 'motd-style', name]);
        await Ui.pause();
      case InstanceModalAction.lock:
        await _lockInstance(name);
      case InstanceModalAction.unlock:
        await _unlockInstance(name);
      case InstanceModalAction.isolated:
        await _toggleIsolated(name, currentlyIsolated: false);
      case InstanceModalAction.shared:
        await _toggleIsolated(name, currentlyIsolated: true);
      case InstanceModalAction.folder:
        await _shellRun(<String>['instance', 'open', name]);
      case InstanceModalAction.update:
        await _updateInstance(name);
      case InstanceModalAction.factoryReset:
        final bool confirmed = await Ui.confirm(
          'Factory reset $name? Worlds, config, and dropins are wiped.',
          defaultValue: false,
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'reset', name]);
          await Ui.pause();
        }
      case InstanceModalAction.delete:
        final bool confirmed = await Ui.confirm(
          'Delete instance $name permanently?',
          defaultValue: false,
        );
        if (confirmed) {
          await _shellRun(<String>['instance', 'delete', name]);
        }
    }
  }

  /// Every workspace action the card, the workspace bar, and the `n`/`b`
  /// keys can dispatch. Same suspension contract as
  /// [_monitorInstanceAction].
  ///
  /// The card offers START ALL and STOP ALL unconditionally — it is a fixed
  /// grid, not the old menu that hid entries it had no work for — so this is
  /// where "nothing to do" is answered. Saying so and pausing is the point:
  /// a suspension that runs no command and returns immediately reads as a
  /// flash of the screen and nothing else.
  Future<void> _monitorWorkspaceAction(WorkspaceModalAction action) async {
    if (_monitorView == MonitorView.remote) {
      await _remoteWorkspaceAction(action);
      return;
    }
    switch (action) {
      case WorkspaceModalAction.buildTuning:
        await _buildAndTuningMenu();
      case WorkspaceModalAction.pullBuilds:
        await _refreshAllBuilds();
      case WorkspaceModalAction.createMany:
        await _createMany();
      case WorkspaceModalAction.startAll:
        final List<_InstanceRow> rows = await Ui.shielded(_loadInstanceRows);
        if (!rows.any((_InstanceRow r) => r.state == RuntimeState.stopped)) {
          Ui.note('No stopped servers.');
          await Ui.pause();
          return;
        }
        await _startAllStopped(rows);
      case WorkspaceModalAction.stopAll:
        final List<_InstanceRow> rows = await Ui.shielded(_loadInstanceRows);
        if (!rows.any((_InstanceRow r) => r.state != RuntimeState.stopped)) {
          Ui.note('No running servers.');
          await Ui.pause();
          return;
        }
        await _stopAllRunning(rows);
      case WorkspaceModalAction.wipe:
        await _wipeEverything();
      case WorkspaceModalAction.newInstance:
        await _createInstance();
      case WorkspaceModalAction.connect:
        Ui.note('Remote connection settings are not available in Local view.');
        await Ui.pause();
    }
  }

  Future<void> _remoteQuickAction(
    String identifier,
    MonitorAction action,
  ) async {
    switch (action) {
      case MonitorAction.restart:
      case MonitorAction.stop:
      case MonitorAction.kill:
      case MonitorAction.console:
        final PterodactylProfile profile = _requireRemoteProfile();
        final PterodactylResourceUsage resources = await Ui.spin(
          'Checking remote server',
          () => pterodactyl.resources(profile.id, identifier),
        );
        final RemoteQuickActionEffect effect = remoteQuickActionEffect(
          action: action,
          currentState: resources.currentState,
        );
        switch (effect) {
          case RemoteQuickActionEffect.none:
            if (action == MonitorAction.console) {
              Ui.note(
                'Remote console is unavailable while $identifier is offline. '
                'Press R to start it.',
              );
              await Ui.pause();
            }
          case RemoteQuickActionEffect.start:
            await _remotePower(identifier, PterodactylPowerSignal.start);
          case RemoteQuickActionEffect.stop:
            await _remotePower(identifier, PterodactylPowerSignal.stop);
          case RemoteQuickActionEffect.restart:
            await _remotePower(identifier, PterodactylPowerSignal.restart);
          case RemoteQuickActionEffect.kill:
            final bool confirmed = await Ui.confirm(
              'Kill remote server $identifier immediately?',
              defaultValue: false,
            );
            if (confirmed) {
              await _remotePower(identifier, PterodactylPowerSignal.kill);
            }
          case RemoteQuickActionEffect.console:
            await _remoteConsole(identifier);
        }
      case MonitorAction.consolesGrid:
        Ui.note('The remote fleet does not expose a multi-console grid.');
        await Ui.pause();
      case MonitorAction.up:
      case MonitorAction.down:
      case MonitorAction.open:
      case MonitorAction.detail:
      case MonitorAction.newInstance:
      case MonitorAction.buildMenu:
      case MonitorAction.workspaceCard:
      case MonitorAction.switchView:
      case MonitorAction.switchConsumer:
      case MonitorAction.cycleRange:
      case MonitorAction.refresh:
      case MonitorAction.quit:
      case MonitorAction.back:
      case MonitorAction.none:
        return;
    }
  }

  Future<void> _remoteInstanceAction(
    String identifier,
    InstanceModalAction action,
  ) async {
    switch (action) {
      case InstanceModalAction.start:
        await _remotePower(identifier, PterodactylPowerSignal.start);
      case InstanceModalAction.stop:
        await _remotePower(identifier, PterodactylPowerSignal.stop);
      case InstanceModalAction.restart:
        await _remotePower(identifier, PterodactylPowerSignal.restart);
      case InstanceModalAction.console:
        await _remoteConsole(identifier);
      case InstanceModalAction.setPort:
      case InstanceModalAction.makeActive:
      case InstanceModalAction.motd:
      case InstanceModalAction.lock:
      case InstanceModalAction.unlock:
      case InstanceModalAction.isolated:
      case InstanceModalAction.shared:
      case InstanceModalAction.folder:
      case InstanceModalAction.update:
      case InstanceModalAction.factoryReset:
      case InstanceModalAction.delete:
        Ui.note('That action is Local-only.');
        await Ui.pause();
    }
  }

  Future<void> _remoteWorkspaceAction(WorkspaceModalAction action) async {
    switch (action) {
      case WorkspaceModalAction.connect:
        await _connectPterodactyl();
      case WorkspaceModalAction.newInstance:
        await _createRemoteInstance();
      case WorkspaceModalAction.startAll:
        await _remotePowerAll(PterodactylPowerSignal.start);
      case WorkspaceModalAction.stopAll:
        final bool confirmed = await Ui.confirm(
          'Stop every server in the selected remote panel?',
          defaultValue: false,
        );
        if (confirmed) {
          await _remotePowerAll(PterodactylPowerSignal.stop);
        }
      case WorkspaceModalAction.buildTuning:
      case WorkspaceModalAction.pullBuilds:
      case WorkspaceModalAction.createMany:
      case WorkspaceModalAction.wipe:
        Ui.note('That workspace action is Local-only.');
        await Ui.pause();
    }
  }

  Future<void> _remotePower(
    String identifier,
    PterodactylPowerSignal signal,
  ) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    await Ui.spin(
      '${signal.name} remote server',
      () => pterodactyl.power(profile.id, identifier, signal),
    );
    Ui.success('${signal.name} sent to $identifier');
  }

  Future<void> _remoteConsole(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylConsoleConnection connection = await pterodactyl
        .openConsole(profile.id, identifier);
    Ui.info(
      'Attaching to $identifier. Press Esc, Ctrl-C, or enter :exit to detach.',
    );
    await PterodactylConsoleTerminal(connection: connection).run();
  }

  Future<void> _remotePowerAll(PterodactylPowerSignal signal) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final List<PterodactylFleetSample> fleet = await Ui.spin(
      'Loading remote fleet',
      () => pterodactyl.captureFleet(profile.id),
    );
    int succeeded = 0;
    int eligible = 0;
    for (final PterodactylFleetSample sample in fleet) {
      final PterodactylClientServer server = sample.server;
      final PterodactylResourceUsage? resources = sample.resources;
      final bool blocked =
          server.isNodeUnderMaintenance ||
          server.status != null ||
          resources == null ||
          resources.isSuspended;
      final bool wantedState = switch (signal) {
        PterodactylPowerSignal.start =>
          resources?.currentState.toLowerCase() == 'offline',
        PterodactylPowerSignal.stop ||
        PterodactylPowerSignal.restart ||
        PterodactylPowerSignal.kill =>
          resources?.currentState.toLowerCase() != 'offline',
      };
      if (blocked || !wantedState) continue;
      eligible += 1;
      try {
        await pterodactyl.power(profile.id, server.identifier, signal);
        succeeded += 1;
      } catch (error) {
        Ui.warn('${_safeRemoteText(server.name)}: $error');
      }
    }
    Ui.success('${signal.name} sent to $succeeded/$eligible eligible servers');
    await Ui.pause();
  }

  Future<bool> _connectPterodactyl() async {
    final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
    PterodactylProfile profile;
    bool newProfile = false;
    if (profiles.isEmpty) {
      final String id = await Ui.input(
        'Connection ID',
        defaultValue: 'remote',
        validator: PterodactylProfile.isValidId,
        validationMessage: 'Use lowercase letters, digits, - or _',
      );
      final String name = await Ui.input('Connection name', defaultValue: id);
      final String url = await Ui.input(
        'Pterodactyl panel URL',
        validator: _validPanelUrl,
        validationMessage:
            'Enter an HTTPS origin such as https://panel.example.com',
      );
      profile = PterodactylProfile(
        id: id,
        name: name,
        panelUri: Uri.parse(url),
      );
      newProfile = true;
    } else if (profiles.length == 1) {
      profile = profiles.single;
    } else {
      final String selected = await Ui.pick('Remote connection', <String>[
        for (final PterodactylProfile item in profiles)
          '${item.name} (${item.id})',
      ]);
      profile =
          profiles[profiles.indexWhere(
            (PterodactylProfile item) => selected.endsWith('(${item.id})'),
          )];
    }
    final String? previousProfileId = _remoteProfileId;
    final PterodactylVerification verification;
    try {
      if (!await pterodactyl.hasClientCredential(profile)) {
        await _enrollPterodactylCredential(
          profile,
          PterodactylCredentialRole.client,
        );
      }
      verification = await _verifyRemoteWithRepair(profile);
      if (newProfile) {
        pterodactyl.saveProfile(profile);
      }
      _remoteProfileId = profile.id;
      // A verified connect/repair always rebuilds the Remote session. Besides
      // changing credentials and permissions, it may reveal a differently
      // sized admin-all fleet whose safe polling cadence must be recomputed.
      _remoteConnectionChanged = true;
    } catch (_) {
      _remoteProfileId = previousProfileId;
      rethrow;
    }
    Ui.success('Connected to ${verification.profile.origin}');
    Ui.keyValue('servers', '${verification.serverCount}');
    Ui.keyValue('nodes', verification.nodeCount?.toString() ?? 'not granted');
    Ui.keyValue(
      'capabilities',
      verification.capabilities
          .map((PterodactylCapability item) => item.name)
          .join(', '),
    );
    for (final String warning in verification.warnings) {
      Ui.warn(warning);
    }
    await Ui.pause();
    return _remoteConnectionChanged;
  }

  Future<void> _enrollPterodactylCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    switch (role) {
      case PterodactylCredentialRole.client:
        Ui.info('Create a Client API key at ${profile.origin}/account/api');
      case PterodactylCredentialRole.application:
        Ui.info(
          'Create an Application API key at ${profile.origin}/admin/api/new',
        );
        Ui.note('Grant Servers read/write, Allocations read, and Nodes read.');
    }
    Ui.note('Paste it only into the macOS Keychain prompt that follows.');
    await pterodactyl.enrollCredential(profile, role);
  }

  Future<PterodactylVerification> _verifyRemoteWithRepair(
    PterodactylProfile profile,
  ) async {
    try {
      return await Ui.spin(
        'Verifying Pterodactyl connection',
        () => pterodactyl.verifyProfile(profile),
      );
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      Ui.warn('The stored Client API key was rejected by the panel.');
      final bool replace = await Ui.confirm(
        'Replace the stored Client API key now?',
        defaultValue: true,
      );
      if (!replace) rethrow;
      return _replaceCredentialAndVerify(
        profile,
        PterodactylCredentialRole.client,
        progressLabel: 'Verifying replacement key',
      );
    }
  }

  Future<PterodactylVerification> _ensureApplicationCredential(
    PterodactylProfile profile,
  ) async {
    PterodactylVerification verification = await _verifyRemoteWithRepair(
      profile,
    );
    if (verification.capabilities.contains(PterodactylCapability.create)) {
      return verification;
    }
    if (!await pterodactyl.hasApplicationCredential(profile)) {
      await _enrollPterodactylCredential(
        profile,
        PterodactylCredentialRole.application,
      );
    }
    verification = await _verifyRemoteWithRepair(profile);
    if (!verification.capabilities.contains(PterodactylCapability.create)) {
      Ui.warn('The stored Application key cannot create servers.');
      final bool replace = await Ui.confirm(
        'Replace the Application API key now?',
        defaultValue: true,
      );
      if (!replace) return verification;
      verification = await _replaceCredentialAndVerify(
        profile,
        PterodactylCredentialRole.application,
        progressLabel: 'Verifying replacement Application key',
      );
    }
    return verification;
  }

  Future<PterodactylVerification> _replaceCredentialAndVerify(
    PterodactylProfile profile,
    PterodactylCredentialRole role, {
    required String progressLabel,
  }) async {
    final PterodactylCredential? previous = await pterodactyl
        .credentialForRollback(profile, role);
    try {
      await _enrollPterodactylCredential(profile, role);
      return await Ui.spin(
        progressLabel,
        () => pterodactyl.verifyProfile(profile),
      );
    } catch (_) {
      if (previous != null) {
        await pterodactyl.restoreCredential(profile, role, previous);
      }
      rethrow;
    }
  }

  Future<void> _createRemoteInstance() async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylVerification verification =
        await _ensureApplicationCredential(profile);
    if (!verification.capabilities.contains(PterodactylCapability.create)) {
      Ui.warn('Remote creation is unavailable for this connection.');
      await Ui.pause();
      return;
    }
    final List<PterodactylClientServer> allServers = await Ui.spin(
      'Loading remote templates',
      () => pterodactyl.listServers(profile.id),
    );
    final List<PterodactylClientServer> servers = allServers
        .where(
          (PterodactylClientServer server) =>
              pterodactyl.canUseAsTemplate(profile.id, server),
        )
        .toList(growable: false);
    if (servers.isEmpty) {
      Ui.warn('No owned remote server exists to use as a template.');
      await Ui.pause();
      return;
    }
    final String selected =
        await Ui.pick('Clone remote configuration from', <String>[
          for (final PterodactylClientServer server in servers)
            '${_safeRemoteText(server.name)} (${server.identifier})',
        ]);
    final PterodactylClientServer template = servers.firstWhere(
      (PterodactylClientServer server) =>
          selected.endsWith('(${server.identifier})'),
    );
    final String name = await Ui.input(
      'New remote server name',
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Name cannot be empty',
    );
    final bool confirmed = await Ui.confirm(
      'Create $name from ${_safeRemoteText(template.name)} using the next free allocation(s)?',
      defaultValue: false,
    );
    if (!confirmed) {
      return;
    }
    PterodactylApplicationServer created;
    try {
      created = await _submitRemoteCreate(
        profile: profile,
        template: template,
        name: name,
        progressLabel: 'Creating remote server',
      );
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      Ui.warn(
        'The Application key can read creation data but cannot write servers.',
      );
      final bool replace = await Ui.confirm(
        'Replace the Application API key and retry?',
        defaultValue: true,
      );
      if (!replace) rethrow;
      final PterodactylVerification repaired =
          await _replaceCredentialAndVerify(
            profile,
            PterodactylCredentialRole.application,
            progressLabel: 'Verifying replacement Application key',
          );
      if (!repaired.capabilities.contains(PterodactylCapability.create)) {
        throw StateError(
          'The replacement key cannot read the nodes and allocations needed '
          'for remote creation.',
        );
      }
      created = await _submitRemoteCreate(
        profile: profile,
        template: template,
        name: name,
        progressLabel: 'Retrying remote creation',
      );
    }
    Ui.success(
      'Created ${_safeRemoteText(created.name)} (${created.identifier})',
    );
    await Ui.pause();
  }

  Future<PterodactylApplicationServer> _submitRemoteCreate({
    required PterodactylProfile profile,
    required PterodactylClientServer template,
    required String name,
    required String progressLabel,
  }) => Ui.spin(
    progressLabel,
    () => pterodactyl.createFromTemplate(
      profileId: profile.id,
      template: template.identifier,
      name: name,
    ),
  );

  PterodactylProfile _requireRemoteProfile() {
    final PterodactylProfile? profile = _selectedRemoteProfile();
    if (profile == null) {
      throw StateError('No Pterodactyl connection. Open CONNECTION first.');
    }
    return profile;
  }

  static bool _validPanelUrl(String value) {
    try {
      PterodactylProfile(
        id: 'validation',
        name: 'Validation',
        panelUri: Uri.parse(value),
      );
      return true;
    } on FormatException {
      return false;
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
  /// holds. Capturing metrics is the sampler's job; this only adds the
  /// workspace facts the frame needs on top of them — [flags] among them,
  /// tee'd off the same capture the sampler parsed.
  Future<MonitorSnapshot> _monitorSnapshot(
    MetricsSampler sampler,
    Map<String, InstanceFlags> flags,
  ) async {
    final List<String> instances = sampler.instances;
    return MonitorSnapshot(
      instances: instances,
      history: <String, List<MetricSample>>{
        for (final String instance in instances)
          instance: sampler.history(instance),
      },
      flags: flags,
      consumerName: _activeConsumer().shortName,
      activeInstance: await _activeInstance(),
      view: _monitorView,
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

  // ─── Instance actions ────────────────────────────────────────────────

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

  /// Picks a consumer profile and points the session at it. Returns whether
  /// the active profile actually changed, so a caller holding per-profile
  /// state (the monitor's sampler and trend store) only rebuilds when it has
  /// to. Escaping the picker throws and never reaches the return.
  Future<bool> _switchConsumer() async {
    final ConsumerProfile before = _activeConsumer();
    final List<String> options = consumerService
        .listProfiles()
        .map((ConsumerProfile e) => e.shortName)
        .toList(growable: false);
    final int initialIndex = options
        .indexOf(before.shortName)
        .clamp(0, options.isEmpty ? 0 : options.length - 1);
    final String selected = await Ui.pick(
      'Consumer profile',
      options,
      initialIndex: initialIndex,
    );
    await _shellRun(<String>['consumer', 'use', selected]);
    final ConsumerProfile profile = ConsumerProfile.parse(selected)!;
    _consumerOverride = profile;
    passthrough.setConsumerOverride(profile);
    return profile != before;
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
