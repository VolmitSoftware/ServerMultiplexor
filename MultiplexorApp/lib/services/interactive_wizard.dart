import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/build_cache.dart';
import '../models/consumer_profile.dart';
import '../utils/duration_format.dart';
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
import 'pterodactyl/pterodactyl_create_push.dart';
import 'pterodactyl/pterodactyl_credential.dart';
import 'pterodactyl/pterodactyl_errors.dart';
import 'pterodactyl/pterodactyl_models.dart';
import 'pterodactyl/pterodactyl_monitor_feed.dart';
import 'pterodactyl/pterodactyl_profile.dart';
import 'pterodactyl/pterodactyl_service.dart';
import 'pterodactyl/pterodactyl_smb_models.dart';
import 'pterodactyl/pterodactyl_smb_service.dart';
import 'pterodactyl/pterodactyl_transfer_models.dart';
import 'pterodactyl/pterodactyl_transfer_service.dart';
import 'runtime_state.dart';

/// The side effect a Remote quick key is allowed to perform after a fresh
/// resource-state check.
enum RemoteQuickActionEffect { none, start, stop, restart, kill, console }

/// Fleet operation exposed by the Remote bulk-actions workflow.
enum RemoteBulkAction {
  start,
  stop,
  restart,
  kill,
  reinstall,
  delete,
  createMany,
  done,
}

/// Which live subset of the Remote fleet a bulk operation targets.
enum RemoteBulkTargetScope { all, selected, running, stopped }

/// Configuration source offered by Remote server creation.
enum RemoteCreateSource { panelEgg, cloneExisting, done }

/// Destination choices shown by the Local-to-Remote transfer form.
enum RemoteTransferDestination { linked, existing, createNew, done }

/// Builds the transfer destination menu without presenting dead-end choices.
List<RemoteTransferDestination> remoteTransferDestinations({
  required bool hasLink,
  required bool hasProfiles,
}) => <RemoteTransferDestination>[
  if (hasLink) RemoteTransferDestination.linked,
  if (hasProfiles) RemoteTransferDestination.existing,
  if (hasProfiles) RemoteTransferDestination.createNew,
  RemoteTransferDestination.done,
];

/// Suggests a path-safe Local instance name for a pulled Remote server.
String remotePullDefaultLocalName({
  required String remoteName,
  required String serverIdentifier,
}) {
  String clean(String value) => value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');

  final String cleanedName = clean(remoteName);
  final String cleanedIdentifier = clean(serverIdentifier);
  final String base = cleanedName.isNotEmpty
      ? cleanedName
      : cleanedIdentifier.isNotEmpty
      ? cleanedIdentifier
      : 'remote';
  return base.toLowerCase().endsWith('-local') ? base : '$base-local';
}

bool remoteTransferRequiresTypedConfirmation(PterodactylTransferMode mode) =>
    mode == PterodactylTransferMode.mirror;

bool remoteTransferConfirmationMatches({
  required String expected,
  required String typed,
}) => typed == expected;

String remoteMirrorConfirmationPhrase(String serverIdentifier) =>
    'MIRROR ${serverIdentifier.trim()}';

bool remoteTransferRelinkDefault({required bool hasExistingLink}) =>
    !hasExistingLink;

/// Sanitized preflight warnings shown before a transfer is approved.
List<String> remoteTransferPlanWarnings(PterodactylTransferPlan plan) =>
    List<String>.unmodifiable(plan.warnings.map(_safeRemoteText));

String? remoteTransferRuntimeResultMessage({
  required bool remoteStarted,
  required bool newTarget,
}) {
  if (!remoteStarted) return null;
  return newTarget
      ? 'The new Remote target was started after validation.'
      : 'The Remote target was restored to its previous running state.';
}

enum RemoteCreatePushClaimAction { create, resume, completed }

RemoteCreatePushClaimAction remoteCreatePushClaimAction({
  required bool shouldCreate,
  required bool alreadyCompleted,
}) {
  if (shouldCreate && alreadyCompleted) {
    throw StateError('A completed Create & Push intent cannot create again.');
  }
  if (alreadyCompleted) return RemoteCreatePushClaimAction.completed;
  return shouldCreate
      ? RemoteCreatePushClaimAction.create
      : RemoteCreatePushClaimAction.resume;
}

/// Routes a durable postcondition failure to the repair-only engine path.
/// A create or completed claim can never legitimately need this repair.
bool remoteCreatePushUsesPostconditionRepair({
  required RemoteCreatePushClaimAction action,
  required bool needsPostconditionRepair,
}) {
  if (!needsPostconditionRepair) return false;
  if (action != RemoteCreatePushClaimAction.resume) {
    throw StateError(
      'Only a resumable Create & Push intent can repair postconditions.',
    );
  }
  return true;
}

/// Panel egg metadata does not reliably identify confidential values, so the
/// wizard masks every environment override rather than risking terminal or
/// scrollback disclosure.
bool remoteCreateVariableUsesSecretInput(PterodactylEggVariable _) => true;

List<MapEntry<String, String>> remoteCreatePushPreviewDetails({
  required PterodactylCreatePushPlan creation,
  required PterodactylTransferPlan transferPlan,
  required PterodactylRemoteLink? existingLink,
  required bool startAfterTransfer,
  required bool persistNewLink,
  required String intentId,
  required String confirmationToken,
}) {
  final List<String> environmentNames = creation.environment.keys.toList(
    growable: false,
  )..sort();
  final String redactedEnvironment = environmentNames.isEmpty
      ? '<none>'
      : environmentNames
            .map<String>((String name) => '${_safeRemoteText(name)}=<redacted>')
            .join(', ');
  final String linkAction;
  if (existingLink == null) {
    linkAction = persistNewLink
        ? 'save new Remote server · Local is unlinked'
        : 'leave Local unlinked · new server is one-time';
  } else {
    final String savedTarget =
        '${_safeRemoteText(existingLink.profileId)}/'
        '${_safeRemoteText(existingLink.serverIdentifier)}';
    linkAction = persistNewLink
        ? 'replace $savedTarget with new Remote server'
        : 'preserve $savedTarget · new server is one-time';
  }
  final List<MapEntry<String, String>> details = <MapEntry<String, String>>[
    MapEntry<String, String>(
      'create from',
      '${creation.sourceKind} · ${_safeRemoteText(creation.sourceName)}',
    ),
    MapEntry<String, String>(
      creation.sourceKind == 'template' ? 'template UUID' : 'egg UUID',
      _safeRemoteText(creation.sourceIdentity),
    ),
    MapEntry<String, String>('egg ID', '${creation.sourceEggId}'),
    MapEntry<String, String>('server name', _safeRemoteText(creation.name)),
    MapEntry<String, String>(
      'external ID',
      _safeRemoteText(creation.externalId ?? '<pending>'),
    ),
    MapEntry<String, String>(
      'owner',
      '${creation.ownerId} · ${_safeRemoteText(creation.ownerName)}',
    ),
    MapEntry<String, String>(
      'node',
      '${creation.nodeId} · ${_safeRemoteText(creation.nodeName)}',
    ),
    MapEntry<String, String>('image', _safeRemoteText(creation.dockerImage)),
    MapEntry<String, String>('startup', _safeRemoteText(creation.startup)),
    MapEntry<String, String>('environment', redactedEnvironment),
    MapEntry<String, String>(
      'resources',
      'memory=${creation.memoryMiB} MiB · swap=${creation.swapMiB} MiB · '
          'disk=${creation.diskMiB} MiB · io=${creation.ioWeight} · '
          'cpu=${creation.cpuPercent}% · '
          'threads=${_safeRemoteText(creation.threads ?? '<none>')}',
    ),
    MapEntry<String, String>(
      'features',
      'databases=${creation.databaseLimit ?? 'unlimited'} · '
          'allocations=${creation.allocationLimit ?? 'unlimited'} · '
          'backups=${creation.backupLimit ?? 'unlimited'}',
    ),
    MapEntry<String, String>(
      'create flags',
      'oom_disabled=${creation.oomDisabled} · '
          'skip_scripts=${creation.skipScripts} · '
          'start_on_completion=false',
    ),
    MapEntry<String, String>(
      'final state',
      startAfterTransfer ? 'running after validation' : 'stopped',
    ),
    MapEntry<String, String>('link action', linkAction),
    MapEntry<String, String>(
      'transfer fingerprint',
      _safeRemoteText(transferPlan.sourceFingerprint),
    ),
    MapEntry<String, String>(
      'transfer token',
      _safeRemoteText(transferPlan.confirmationToken),
    ),
    MapEntry<String, String>('intent', _safeRemoteText(intentId)),
    MapEntry<String, String>(
      'confirmation token',
      _safeRemoteText(confirmationToken),
    ),
  ];
  return List<MapEntry<String, String>>.unmodifiable(details);
}

const bool remoteCreateFinalConfirmationDefault = false;

List<RemoteCreateSource> remoteCreateSources({
  required bool hasPanelEggs,
  required bool hasTemplates,
}) => <RemoteCreateSource>[
  if (hasPanelEggs) RemoteCreateSource.panelEgg,
  if (hasTemplates) RemoteCreateSource.cloneExisting,
  RemoteCreateSource.done,
];

List<String> remoteCreateNames({required String pattern, required int count}) {
  final String normalized = pattern.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(pattern, 'pattern', 'must not be empty');
  }
  if (count < 1 || count > 100) {
    throw RangeError.range(count, 1, 100, 'count');
  }
  return List<String>.unmodifiable(<String>[
    for (int index = 1; index <= count; index++)
      normalized.contains('{n}')
          ? normalized.replaceAll('{n}', '$index').trim()
          : count == 1
          ? normalized
          : '$normalized $index',
  ]);
}

int remoteCreateOwnerInitialIndex(
  List<PterodactylUser> users,
  int? recommendedOwnerId,
) {
  if (recommendedOwnerId == null) return 0;
  final int index = users.indexWhere(
    (PterodactylUser user) => user.id == recommendedOwnerId,
  );
  return index < 0 ? 0 : index;
}

List<PterodactylEggVariable> remoteCreatePromptVariables(PterodactylEgg egg) =>
    List<PterodactylEggVariable>.unmodifiable(
      egg.variables.where(
        (PterodactylEggVariable variable) =>
            variable.userEditable ||
            (variable.isRequired && variable.defaultValue.trim().isEmpty),
      ),
    );

List<PterodactylNode> remoteCreateEligibleNodes(
  PterodactylCreationCatalog catalog,
  int serverCount,
) {
  if (serverCount < 1) {
    throw RangeError.range(serverCount, 1, null, 'serverCount');
  }
  return List<PterodactylNode>.unmodifiable(
    catalog.nodes.where(
      (PterodactylNode node) =>
          !node.maintenanceMode &&
          catalog.freeAllocationCount(node.id) >= serverCount,
    ),
  );
}

List<PterodactylEgg> remoteCreateUsableEggs(
  PterodactylCreationCatalog catalog,
) => List<PterodactylEgg>.unmodifiable(
  catalog.eggs.where(
    (PterodactylEgg egg) =>
        egg.startup?.trim().isNotEmpty == true && egg.dockerImages.isNotEmpty,
  ),
);

String? remoteCreatePartialEggInventoryNote(
  PterodactylCreationCatalog catalog,
) {
  final String? permission = catalog.eggInventoryUnavailablePermission;
  if (permission == null || catalog.templates.isEmpty) return null;
  return 'Panel egg creation is unavailable (missing $permission); '
      'continuing with clone existing.';
}

bool remoteCreateResultNeedsCredentialRepair(PterodactylBulkResult result) {
  return result.items.any((PterodactylBulkItemResult item) {
    final String error = (item.error ?? '').toLowerCase();
    return !item.succeeded &&
        (error.contains('http 401') ||
            error.contains('http 403') ||
            error.contains('unauthor') ||
            error.contains('forbidden'));
  });
}

bool remoteCreationCatalogErrorNeedsCredentialRepair(Object error) =>
    error is PterodactylCreationCatalogPermissionException ||
    (error is PterodactylApiException && error.isUnauthorized);

bool remoteCreationCatalogAccessAvailable(
  PterodactylVerification verification,
) => verification.capabilities.contains(PterodactylCapability.configure);

Future<bool> remoteCreateStepOrBack(Future<void> Function() operation) async {
  try {
    await operation();
    return true;
  } on PromptBackNavigation {
    return false;
  }
}

final class RemoteCreateResultRow {
  const RemoteCreateResultRow({
    required this.position,
    required this.total,
    required this.item,
  });

  final int position;
  final int total;
  final PterodactylBulkItemResult item;
}

List<RemoteCreateResultRow> remoteCreateResultRows(
  PterodactylBulkResult result,
) => List<RemoteCreateResultRow>.unmodifiable(<RemoteCreateResultRow>[
  for (int index = 0; index < result.items.length; index++)
    RemoteCreateResultRow(
      position: index + 1,
      total: result.totalCount,
      item: result.items[index],
    ),
]);

final class _RemoteEggChoice {
  const _RemoteEggChoice({required this.nest, required this.egg});

  final PterodactylNest nest;
  final PterodactylEgg egg;
}

final class _RemoteEggPlanSelection {
  const _RemoteEggPlanSelection({
    required this.plan,
    required this.owner,
    required this.node,
    required this.nest,
    required this.egg,
    required this.imageLabel,
  });

  final PterodactylEggCreatePlan plan;
  final PterodactylUser owner;
  final PterodactylNode node;
  final PterodactylNest nest;
  final PterodactylEgg egg;
  final String imageLabel;
}

sealed class _RemotePushCreateSelection {
  const _RemotePushCreateSelection();
}

final class _RemotePushTemplateSelection extends _RemotePushCreateSelection {
  const _RemotePushTemplateSelection({
    required this.template,
    required this.owner,
    required this.node,
  });

  final PterodactylApplicationServer template;
  final PterodactylUser owner;
  final PterodactylNode node;
}

final class _RemotePushEggSelection extends _RemotePushCreateSelection {
  const _RemotePushEggSelection(this.selection);

  final _RemoteEggPlanSelection selection;
}

enum _RemoteAccountAction {
  verify,
  switchAccount,
  add,
  rename,
  replaceClientKey,
  replaceApplicationKey,
  remove,
  done,
}

enum _RemoteLimitField {
  memory,
  swap,
  disk,
  io,
  cpu,
  threads,
  databases,
  allocations,
  backups,
}

enum _RemoteFilesAction {
  configureActive,
  configureAll,
  trustHostKeys,
  doctor,
  start,
  open,
  stop,
  done,
}

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

/// Whether [action] requires a typed, count-bound confirmation phrase.
bool remoteBulkActionRequiresTypedConfirmation(RemoteBulkAction action) =>
    action == RemoteBulkAction.kill ||
    action == RemoteBulkAction.reinstall ||
    action == RemoteBulkAction.delete;

String remoteBulkConfirmationPhrase(
  RemoteBulkAction action,
  int targetCount, {
  String? allProfileId,
}) {
  if (!remoteBulkActionRequiresTypedConfirmation(action)) {
    throw ArgumentError.value(
      action,
      'action',
      'does not use typed confirmation',
    );
  }
  if (targetCount < 1) {
    throw RangeError.range(targetCount, 1, null, 'targetCount');
  }
  final String? normalizedProfile = allProfileId?.trim().toLowerCase();
  if (normalizedProfile != null && normalizedProfile.isNotEmpty) {
    return '${action.name.toUpperCase()} ALL $normalizedProfile';
  }
  return '${action.name.toUpperCase()} $targetCount';
}

/// Resolves a fresh fleet snapshot into the exact targets for one operation.
///
/// Power operations exclude suspended, installing, maintenance, unavailable,
/// and unknown-state servers, then retain only the runtime state the signal
/// can act on. Reinstall and delete remain available for every accessible
/// server, mirroring their per-server management actions; running/stopped
/// scopes still require a known runtime state.
List<PterodactylFleetSample> remoteBulkTargets({
  required Iterable<PterodactylFleetSample> fleet,
  required RemoteBulkAction action,
  required RemoteBulkTargetScope scope,
  String? selectedIdentifier,
}) {
  final String? selected = selectedIdentifier?.trim().toLowerCase();
  final List<PterodactylFleetSample> result = <PterodactylFleetSample>[];
  for (final PterodactylFleetSample sample in fleet) {
    final PterodactylResourceUsage? resources = sample.resources;
    final String state = resources?.currentState.trim().toLowerCase() ?? '';
    final bool stopped = state == 'offline';
    final bool running = const <String>{
      'starting',
      'running',
      'stopping',
    }.contains(state);
    final bool matchesScope = switch (scope) {
      RemoteBulkTargetScope.all => true,
      RemoteBulkTargetScope.selected =>
        selected != null && sample.server.identifier.toLowerCase() == selected,
      RemoteBulkTargetScope.running => running,
      RemoteBulkTargetScope.stopped => stopped,
    };
    if (!matchesScope) continue;

    final bool powerBlocked =
        sample.server.isNodeUnderMaintenance ||
        sample.server.status != null ||
        resources == null ||
        resources.isSuspended ||
        (!running && !stopped);
    final bool eligible = switch (action) {
      RemoteBulkAction.start => !powerBlocked && stopped,
      RemoteBulkAction.stop ||
      RemoteBulkAction.restart ||
      RemoteBulkAction.kill => !powerBlocked && running,
      RemoteBulkAction.reinstall || RemoteBulkAction.delete => true,
      RemoteBulkAction.createMany || RemoteBulkAction.done => false,
    };
    if (eligible) result.add(sample);
  }
  return List<PterodactylFleetSample>.unmodifiable(result);
}

String _safeRemoteText(String value) => PterodactylConsoleSanitizer.text(
  value,
).replaceAll(RegExp(r'[\r\n\t]'), ' ');

bool pterodactylCredentialMatchesRole(
  PterodactylCredential credential,
  PterodactylCredentialRole expected,
) {
  final PterodactylCredentialRole? inferred = inferPterodactylCredentialRole(
    credential.value,
  );
  return inferred == null || inferred == expected;
}

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
    required this.pterodactylSmb,
    required this.transfer,
    this.requestedConsumer,
  });

  final ConsumerService consumerService;
  final PassthroughService passthrough;
  final PterodactylService pterodactyl;
  final PterodactylSmbService pterodactylSmb;
  final PterodactylTransferService transfer;
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
  static const Duration _trendSeedWindow = Duration(days: 7);

  /// Full-resolution retention is 24 hours before older samples are rolled
  /// into five-minute buckets. These capacities keep that entire retained
  /// window chartable at the Local two-second and Remote twenty-second floors.
  static const int _localTrendCapacity = 65536;
  static const int _remoteTrendCapacity = 32768;

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
      ringCapacity: _localTrendCapacity,
    );
    // Swept and seeded before the screen opens so the first frame carries
    // both live readings and whatever history the last session left behind.
    await Ui.spin('Loading servers', () async {
      await sampler.sweep();
      await sampler.compactStore(sampler.instances);
      await sampler.seedFromStore(sampler.instances, window: _trendSeedWindow);
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
      ringCapacity: _remoteTrendCapacity,
    );
    if (profile != null) {
      await Ui.spin('Loading remote servers', () async {
        await sampler.sweep();
        final List<String> instances = feed?.instances ?? const <String>[];
        await sampler.compactStore(instances);
        await sampler.seedFromStore(instances, window: _trendSeedWindow);
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
    final PterodactylProfile? active = pterodactyl.activeProfile();
    if (active != null) {
      _remoteProfileId = active.id;
      return active;
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
      case InstanceModalAction.pushToRemote:
        await _pushLocalToRemote(name);
      case InstanceModalAction.pullToLocal:
        Ui.note('That action is Remote-only.');
        await Ui.pause();
      case InstanceModalAction.settings:
      case InstanceModalAction.history:
      case InstanceModalAction.reinstall:
        Ui.note('That action is Remote-only.');
        await Ui.pause();
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
      case InstanceModalAction.copyDropins:
        await _copyDropinsIntoIsolated(name);
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
  Future<void> _monitorWorkspaceAction(
    WorkspaceModalAction action,
    String? selectedIdentifier,
  ) async {
    if (_monitorView == MonitorView.remote) {
      await _remoteWorkspaceAction(action, selectedIdentifier);
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
      case WorkspaceModalAction.files:
        Ui.note('Remote file sharing is not available in Local view.');
        await Ui.pause();
      case WorkspaceModalAction.bulkActions:
        Ui.note('Remote bulk actions are not available in Local view.');
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
      case InstanceModalAction.pullToLocal:
        await _pullRemoteToLocal(identifier);
      case InstanceModalAction.pushToRemote:
        Ui.note('That action is Local-only.');
        await Ui.pause();
      case InstanceModalAction.settings:
        await _remoteSettings(identifier);
      case InstanceModalAction.history:
        await _remoteHistory(identifier);
      case InstanceModalAction.reinstall:
        await _remoteReinstall(identifier);
      case InstanceModalAction.folder:
        await _remoteOpenFolder(identifier);
      case InstanceModalAction.delete:
        await _remoteDelete(identifier);
      case InstanceModalAction.setPort:
      case InstanceModalAction.makeActive:
      case InstanceModalAction.motd:
      case InstanceModalAction.lock:
      case InstanceModalAction.unlock:
      case InstanceModalAction.isolated:
      case InstanceModalAction.shared:
      case InstanceModalAction.copyDropins:
      case InstanceModalAction.update:
      case InstanceModalAction.factoryReset:
        Ui.note('That action is Local-only.');
        await Ui.pause();
    }
  }

  Future<void> _remoteWorkspaceAction(
    WorkspaceModalAction action,
    String? selectedIdentifier,
  ) async {
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
      case WorkspaceModalAction.files:
        await _remoteFiles();
      case WorkspaceModalAction.bulkActions:
        await _remoteBulkActions(selectedIdentifier);
      case WorkspaceModalAction.createMany:
        await _remoteCreateMany();
      case WorkspaceModalAction.buildTuning:
      case WorkspaceModalAction.pullBuilds:
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

  Future<void> _pullRemoteToLocal(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylClientServerAccess access = await Ui.spin(
      'Checking remote server',
      () => pterodactyl.serverAccess(profile.id, identifier),
    );
    final String localName = await Ui.input(
      'Local instance name',
      defaultValue: remotePullDefaultLocalName(
        remoteName: access.server.name,
        serverIdentifier: access.server.identifier,
      ),
      validator: _isValidInstanceName,
      validationMessage: 'Use letters, numbers, ., _, or - with no spaces.',
    );
    if (!await _prepareDirectTransferFiles(
      profileId: profile.id,
      serverIdentifier: access.server.identifier,
    )) {
      return;
    }
    final PterodactylTransferPlan plan = await Ui.spin(
      'Comparing Remote with Local',
      () => transfer.planPull(
        profileId: profile.id,
        serverIdentifier: access.server.identifier,
        localInstanceName: localName,
      ),
    );
    _showTransferPlan(plan, profileName: profile.name);
    final bool confirmed = await Ui.confirm(
      'Create this stopped Local instance?',
      defaultValue: false,
    );
    if (!confirmed) return;

    final PterodactylTransferResult result = await Ui.spin(
      'Pulling Remote server to Local',
      () => transfer.pull(
        profileId: profile.id,
        serverIdentifier: access.server.identifier,
        localInstanceName: localName,
        expectedPlanToken: plan.confirmationToken,
      ),
    );
    await _finishTransfer(result);
  }

  Future<void> _pushLocalToRemote(String localName) async {
    while (true) {
      final PterodactylRemoteLink? link = await transfer.linkForLocalInstance(
        localName,
      );
      final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
      final List<RemoteTransferDestination> destinations =
          remoteTransferDestinations(
            hasLink: link != null,
            hasProfiles: profiles.isNotEmpty,
          );

      if (destinations.length == 1) {
        Ui.warn(
          '$localName has no linked Remote and no Remote account exists.',
        );
        final bool connect = await Ui.confirm(
          'Open the Remote connection manager?',
          defaultValue: true,
        );
        if (connect) {
          await _connectPterodactyl();
          continue;
        }
        return;
      }

      final int selected = await Ui.choose('Push $localName to', <String>[
        for (final RemoteTransferDestination destination in destinations)
          switch (destination) {
            RemoteTransferDestination.linked =>
              'Linked · ${_safeRemoteText(link!.serverName)} (${link.serverIdentifier})',
            RemoteTransferDestination.existing =>
              'Choose any existing Remote server',
            RemoteTransferDestination.createNew =>
              'Create a stopped Remote server, then push',
            RemoteTransferDestination.done => 'Back to dashboard',
          },
      ]);
      final RemoteTransferDestination destination = destinations[selected];
      if (destination == RemoteTransferDestination.done) return;

      try {
        switch (destination) {
          case RemoteTransferDestination.linked:
            if (!await _prepareDirectTransferFiles(
              profileId: link!.profileId,
              serverIdentifier: link.serverIdentifier,
            )) {
              return;
            }
            final PterodactylTransferMode mode =
                await _chooseRemoteTransferMode();
            await _pushLocalToExisting(
              localName: localName,
              mode: mode,
              relink: false,
            );
            return;
          case RemoteTransferDestination.existing:
            final PterodactylProfile profile = await _chooseTransferProfile();
            final PterodactylClientServer? server = await _chooseTransferServer(
              profile,
            );
            if (server == null) return;
            if (!await _prepareDirectTransferFiles(
              profileId: profile.id,
              serverIdentifier: server.identifier,
            )) {
              return;
            }
            final PterodactylTransferMode mode =
                await _chooseRemoteTransferMode();
            final bool relink = await Ui.confirm(
              'Use ${_safeRemoteText(server.name)} as the linked target for future pushes?',
              defaultValue: remoteTransferRelinkDefault(
                hasExistingLink: link != null,
              ),
            );
            await _pushLocalToExisting(
              localName: localName,
              mode: mode,
              profile: profile,
              server: server,
              relink: relink,
            );
            return;
          case RemoteTransferDestination.createNew:
            final PterodactylProfile profile = await _chooseTransferProfile();
            await _createRemoteAndPush(localName, profile, existingLink: link);
            return;
          case RemoteTransferDestination.done:
            return;
        }
      } on PromptBackNavigation {
        // Escape unwinds the target form back to this destination card.
      }
    }
  }

  Future<PterodactylProfile> _chooseTransferProfile() async {
    final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
    if (profiles.isEmpty) {
      throw StateError('No Remote account is configured.');
    }
    if (profiles.length == 1) return profiles.single;
    final String? activeId = pterodactyl.activeProfile()?.id;
    int initialIndex = profiles.indexWhere(
      (PterodactylProfile profile) => profile.id == activeId,
    );
    if (initialIndex < 0) initialIndex = 0;
    final int selected = await Ui.choose('Remote account', <String>[
      for (final PterodactylProfile profile in profiles)
        '${_safeRemoteText(profile.name)} · ${_safeRemoteText(profile.origin.toString())}',
    ], initialIndex: initialIndex);
    return profiles[selected];
  }

  Future<PterodactylClientServer?> _chooseTransferServer(
    PterodactylProfile profile,
  ) async {
    final List<PterodactylClientServer> servers =
        List<PterodactylClientServer>.of(
          await Ui.spin(
            'Loading remote servers',
            () => pterodactyl.listServers(profile.id),
          ),
        );
    servers.sort(
      (PterodactylClientServer left, PterodactylClientServer right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    if (servers.isEmpty) {
      Ui.note('${_safeRemoteText(profile.name)} has no existing server.');
      await Ui.pause();
      return null;
    }
    final int selected = await Ui.choose('Existing Remote server', <String>[
      for (final PterodactylClientServer server in servers)
        '${_safeRemoteText(server.name)} (${server.identifier})',
    ]);
    return servers[selected];
  }

  Future<PterodactylTransferMode> _chooseRemoteTransferMode() async {
    final int selected = await Ui.choose('Transfer mode', <String>[
      'Update · copy changed/new files, preserve Remote-only files',
      'Mirror · exact Local copy, delete Remote-only files',
      'Back to destination',
    ]);
    return switch (selected) {
      0 => PterodactylTransferMode.update,
      1 => PterodactylTransferMode.mirror,
      _ => throw const PromptBackNavigation(),
    };
  }

  Future<void> _pushLocalToExisting({
    required String localName,
    required PterodactylTransferMode mode,
    PterodactylProfile? profile,
    PterodactylClientServer? server,
    required bool relink,
  }) async {
    final PterodactylTransferPlan plan = await Ui.spin(
      'Comparing Local with Remote',
      () => transfer.planPush(
        localInstanceName: localName,
        profileId: profile?.id,
        serverIdentifier: server?.identifier,
        mode: mode,
      ),
    );
    _showTransferPlan(
      plan,
      profileName: profile?.name ?? _remoteProfileName(plan.profileId),
    );
    if (!await _confirmTransferPlan(plan)) return;

    final PterodactylTransferResult result = await Ui.spin(
      'Pushing Local instance to Remote',
      () => transfer.push(
        localInstanceName: localName,
        profileId: profile?.id,
        serverIdentifier: server?.identifier,
        mode: mode,
        expectedPlanToken: plan.confirmationToken,
        relink: relink,
        restorePreviousRunningState: true,
      ),
    );
    await _finishTransfer(result);
  }

  Future<void> _createRemoteAndPush(
    String localName,
    PterodactylProfile profile, {
    required PterodactylRemoteLink? existingLink,
  }) async {
    final PterodactylVerification verification =
        await _ensureApplicationCredential(profile);
    if (!remoteCreationCatalogAccessAvailable(verification)) {
      Ui.warn('Remote creation inventory is unavailable for this connection.');
      _showRemoteCreationPermissionHelp();
      await Ui.pause();
      return;
    }
    final PterodactylCreationCatalog? loaded = await _loadRemoteCreationCatalog(
      profile,
    );
    if (loaded == null) return;
    final PterodactylCreationCatalog catalog = loaded;
    final _RemotePushCreateSelection? selection =
        await _chooseRemotePushCreateSelection(catalog);
    if (selection == null) return;
    final String remoteName = await Ui.input(
      'New Remote server name',
      defaultValue: localName,
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Server name cannot be empty.',
    );
    final bool startAfterPush = await Ui.confirm(
      'Start the new server only after the push succeeds?',
      defaultValue: false,
    );
    final bool relink =
        existingLink == null ||
        await Ui.confirm(
          'Replace the saved link to ${_safeRemoteText(existingLink.serverName)} with this new server?',
          defaultValue: false,
        );
    final PterodactylTransferPlan plan = await Ui.spin(
      'Planning create and push',
      () => transfer.planNewPush(
        localInstanceName: localName,
        profileId: profile.id,
        proposedServerName: remoteName,
      ),
    );
    final PterodactylCreatePushPlan unresolvedCreation =
        _remotePushCreationPlan(selection: selection, name: remoteName);
    final String intentId = pterodactylCreatePushIntentId(
      transferPlan: plan,
      canonicalCreation: unresolvedCreation.canonicalJson,
      startAfterTransfer: startAfterPush,
      persistNewLink: relink,
    );
    final PterodactylCreatePushPlan creation = unresolvedCreation
        .withExternalId(intentId);
    final String confirmationToken = pterodactylCreatePushConfirmationToken(
      transferConfirmationToken: plan.confirmationToken,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: startAfterPush,
      persistNewLink: relink,
    );
    _showTransferPlan(
      plan,
      profileName: profile.name,
      title: 'CREATE & PUSH',
      details: remoteCreatePushPreviewDetails(
        creation: creation,
        transferPlan: plan,
        existingLink: existingLink,
        startAfterTransfer: startAfterPush,
        persistNewLink: relink,
        intentId: intentId,
        confirmationToken: confirmationToken,
      ),
    );
    if (!await Ui.confirm(
      'Create this stopped server and push the Local instance?',
      defaultValue: false,
    )) {
      return;
    }

    final PterodactylCreatePushIntentCoordinator coordinator =
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: passthrough.context.metadataDir,
          service: pterodactyl,
        );
    late final PterodactylCreatePushIntentClaim claim;
    try {
      claim = await Ui.spin(
        'Opening durable Create & Push intent',
        () => coordinator.claim(
          id: intentId,
          confirmationToken: confirmationToken,
          transferPlan: plan,
          creation: creation,
          startAfterTransfer: startAfterPush,
          persistNewLink: relink,
        ),
      );
    } on Object catch (error) {
      Ui.error('Create & Push intent refused: ${_safeRemoteText('$error')}');
      await Ui.pause();
      return;
    }

    try {
      Ui.keyValue('recovery journal', claim.path);
      final RemoteCreatePushClaimAction action = remoteCreatePushClaimAction(
        shouldCreate: claim.shouldCreate,
        alreadyCompleted: claim.alreadyCompleted,
      );
      if (action == RemoteCreatePushClaimAction.completed) {
        Ui.success('This exact Create & Push intent already completed.');
        if (claim.server case final PterodactylApplicationServer server) {
          Ui.keyValue(
            'Remote server',
            '${_safeRemoteText(server.name)} (${server.identifier})',
          );
        }
        Ui.note('No server was created and no files were transferred again.');
        await Ui.pause();
        return;
      }

      if (remoteCreatePushUsesPostconditionRepair(
        action: action,
        needsPostconditionRepair: claim.needsPostconditionRepair,
      )) {
        final PterodactylApplicationServer? resumed = claim.server;
        if (resumed == null) {
          throw StateError(
            'A repairable Create & Push intent has no Remote server.',
          );
        }
        Ui.info(
          'Repairing completion for ${_safeRemoteText(resumed.name)} '
          '(${resumed.identifier}); no files will be uploaded again.',
        );
        late final PterodactylTransferResult result;
        try {
          result = await Ui.spin(
            'Repairing Create & Push completion',
            () => transfer.repairNewPushPostconditions(
              plan: plan,
              createdServerIdentifier: resumed.identifier,
              relink: relink,
              startAfter: startAfterPush,
            ),
          );
          claim.complete(
            created: resumed,
            result: result,
            filesTransferred: false,
          );
        } on Object catch (error) {
          Ui.error(
            'Create & Push completion repair paused: '
            '${_safeRemoteText('$error')}',
          );
          Ui.warn(
            'No files were uploaded. Retry this exact form to continue '
            'repairing the saved link or requested running state.',
          );
          Ui.keyValue('recovery journal', claim.path);
          await Ui.pause();
          return;
        }
        await _finishTransfer(result, newTarget: true);
        return;
      }

      try {
        await _prepareTransferAccount(profile.id);
      } on Object catch (error) {
        Ui.warn(
          'Remote file account preparation failed: '
          '${_safeRemoteText('$error')}',
        );
        await Ui.pause();
        return;
      }

      late final PterodactylApplicationServer created;
      if (action == RemoteCreatePushClaimAction.create) {
        try {
          claim.record(state: 'creating');
          created = await Ui.spin(
            'Creating stopped Remote server',
            () => creation.create(service: pterodactyl, profileId: profile.id),
          );
          claim.record(state: 'created', created: created);
        } on Object catch (error) {
          claim.record(state: 'create-unknown', failure: '$error');
          Ui.error(
            'Remote creation status is ambiguous: ${_safeRemoteText('$error')}',
          );
          Ui.warn(
            'Do not create another server manually. Retry this exact form; '
            'Multiplexor will reconcile Panel external ID $intentId first.',
          );
          Ui.keyValue('recovery journal', claim.path);
          await Ui.pause();
          return;
        }
      } else {
        final PterodactylApplicationServer? resumed = claim.server;
        if (resumed == null) {
          throw StateError('A resumable Create & Push intent has no server.');
        }
        created = resumed;
        Ui.info(
          'Resuming ${_safeRemoteText(created.name)} '
          '(${created.identifier}); no new server was created.',
        );
      }

      try {
        claim.record(state: 'waiting-for-install', created: created);
        await Ui.spin(
          'Waiting for the stopped Remote server',
          () => transfer.waitForNewTargetReady(
            profileId: profile.id,
            serverIdentifier: created.identifier,
          ),
        );
      } on Object catch (error) {
        claim.record(
          state: 'transfer-failed',
          created: created,
          failure: '$error',
        );
        _showCreatePushRetry(created, claim.path, error);
        await Ui.pause();
        return;
      }
      if (!await _prepareDirectTransferFiles(
        profileId: profile.id,
        serverIdentifier: created.identifier,
        pauseOnFailure: false,
      )) {
        claim.record(
          state: 'transfer-failed',
          created: created,
          failure: 'Direct Remote file access was not prepared.',
        );
        Ui.warn(
          '${_safeRemoteText(created.name)} (${created.identifier}) remains '
          'stopped until direct file access is prepared.',
        );
        await Ui.pause();
        return;
      }

      late final PterodactylTransferResult result;
      try {
        claim.record(state: 'transferring', created: created);
        result = await Ui.spin(
          'Uploading Local instance before first start',
          () => transfer.pushNew(
            plan: plan,
            createdServerIdentifier: created.identifier,
            relink: relink,
            startAfter: startAfterPush,
          ),
        );
      } on Object catch (error) {
        claim.record(
          state: 'transfer-failed',
          created: created,
          failure: '$error',
        );
        _showCreatePushRetry(created, claim.path, error);
        await Ui.pause();
        return;
      }
      claim.complete(created: created, result: result);
      await _finishTransfer(result, newTarget: true);
    } finally {
      claim.close();
    }
  }

  void _showCreatePushRetry(
    PterodactylApplicationServer created,
    String journalPath,
    Object error,
  ) {
    Ui.error('Create & Push paused: ${_safeRemoteText('$error')}');
    Ui.warn(
      '${_safeRemoteText(created.name)} (${created.identifier}) remains '
      'stopped for a safe retry.',
    );
    Ui.keyValue('recovery journal', journalPath);
  }

  Future<_RemotePushCreateSelection?> _chooseRemotePushCreateSelection(
    PterodactylCreationCatalog catalog,
  ) async {
    final String? partialEggNote = remoteCreatePartialEggInventoryNote(catalog);
    if (partialEggNote != null) Ui.note(partialEggNote);
    final List<PterodactylEgg> usableEggs = remoteCreateUsableEggs(catalog);
    final List<RemoteCreateSource> sources = remoteCreateSources(
      hasPanelEggs: usableEggs.isNotEmpty,
      hasTemplates: catalog.templates.isNotEmpty,
    );
    if (sources.length == 1) {
      Ui.warn('No creation-ready Panel egg or existing template is available.');
      await Ui.pause();
      return null;
    }

    RemoteCreateSource source = sources.first;
    if (sources.length > 2) {
      final int selected =
          await Ui.choose('Create Remote target from', <String>[
            'Panel egg · works without an existing server',
            'Clone an existing server configuration',
            'Back to destination',
          ]);
      source = sources[selected];
    }
    switch (source) {
      case RemoteCreateSource.panelEgg:
        final _RemoteEggChoice? choice = await _chooseRemoteEgg(
          catalog,
          usableEggs,
        );
        if (choice == null) return null;
        final _RemoteEggPlanSelection? selection =
            await _buildRemoteEggCreatePlan(
              catalog: catalog,
              choice: choice,
              serverCount: 1,
              promptForStart: false,
            );
        return selection == null ? null : _RemotePushEggSelection(selection);
      case RemoteCreateSource.cloneExisting:
        final int selected =
            await Ui.choose('Clone remote configuration from', <String>[
              for (final PterodactylApplicationServer template
                  in catalog.templates)
                '${_safeRemoteText(template.name)} (${template.identifier})',
            ]);
        final PterodactylApplicationServer template =
            catalog.templates[selected];
        final PterodactylUser? owner = await _chooseRemoteCreationOwner(
          catalog,
        );
        if (owner == null) return null;
        final List<PterodactylNode> matchingNodes = catalog.nodes
            .where((PterodactylNode node) => node.id == template.nodeId)
            .toList(growable: false);
        if (matchingNodes.isEmpty ||
            !remoteCreateEligibleNodes(
              catalog,
              1,
            ).any((PterodactylNode node) => node.id == template.nodeId)) {
          Ui.warn(
            'The template node is unavailable, under maintenance, or has no '
            'free allocation.',
          );
          await Ui.pause();
          return null;
        }
        return _RemotePushTemplateSelection(
          template: template,
          owner: owner,
          node: matchingNodes.single,
        );
      case RemoteCreateSource.done:
        throw const PromptBackNavigation();
    }
  }

  PterodactylCreatePushPlan _remotePushCreationPlan({
    required String name,
    required _RemotePushCreateSelection selection,
  }) => switch (selection) {
    _RemotePushTemplateSelection(
      template: final PterodactylApplicationServer template,
      owner: final PterodactylUser owner,
      node: final PterodactylNode node,
    ) =>
      PterodactylCreatePushPlan.template(
        plan: PterodactylTemplateCreatePlan.fromTemplate(
          template: template,
          name: name,
          ownerId: owner.id,
          startOnCompletion: false,
        ),
        ownerName: owner.username,
        nodeName: node.name,
      ),
    _RemotePushEggSelection(selection: final _RemoteEggPlanSelection egg) =>
      PterodactylCreatePushPlan.egg(
        name: name,
        source: egg.egg,
        plan: egg.plan,
        ownerName: egg.owner.username,
        nodeName: egg.node.name,
      ),
  };

  void _showTransferPlan(
    PterodactylTransferPlan plan, {
    String? profileName,
    String? title,
    List<MapEntry<String, String>> details = const <MapEntry<String, String>>[],
  }) {
    Ui.clearScreen();
    Ui.appHeader(
      title ??
          (plan.direction == PterodactylTransferDirection.pull
              ? 'PULL TO LOCAL'
              : 'PUSH TO REMOTE'),
      <String>[
        profileName ?? plan.profileId,
        plan.mode.name,
        plan.targetWasRunning ? 'Remote currently running' : 'Remote stopped',
      ],
    );
    if (plan.direction == PterodactylTransferDirection.pull) {
      Ui.keyValue(
        'source',
        '${_safeRemoteText(plan.remoteServerName)} (${plan.serverIdentifier})',
      );
      Ui.keyValue('destination', 'Local ${plan.localInstanceName} · stopped');
    } else {
      Ui.keyValue('source', 'Local ${plan.localInstanceName} · stopped');
      Ui.keyValue(
        'destination',
        '${_safeRemoteText(plan.remoteServerName)} (${plan.serverIdentifier})',
      );
    }
    for (final MapEntry<String, String> detail in details) {
      Ui.keyValue(detail.key, detail.value);
    }
    Ui.keyValue(
      'changes',
      '${plan.addCount} add · ${plan.updateCount} update · ${plan.deleteCount} delete',
    );
    Ui.keyValue('transfer', formatBytes(plan.transferBytes));
    if (plan.direction == PterodactylTransferDirection.push) {
      Ui.keyValue(
        'Remote state',
        !plan.targetExists
            ? 'create stopped, upload, validate before first start'
            : plan.targetWasRunning
            ? 'stop, backup, push, restore running state'
            : 'backup and remain stopped',
      );
    }
    if (plan.mode == PterodactylTransferMode.mirror) {
      Ui.warn('Mirror deletes every Remote-only file listed below.');
    }
    for (final String warning in remoteTransferPlanWarnings(plan)) {
      Ui.warn(warning);
    }
    final int previewCount = plan.changes.length > 8 ? 8 : plan.changes.length;
    for (int index = 0; index < previewCount; index++) {
      final PterodactylTransferChange change = plan.changes[index];
      Ui.info(
        '${change.kind.name.toUpperCase().padRight(6)} ${_safeRemoteText(change.path)}',
      );
    }
    if (plan.changes.length > previewCount) {
      Ui.note('${plan.changes.length - previewCount} more changes');
    }
    if (plan.isNoop) Ui.note('No file changes are required.');
  }

  Future<bool> _confirmTransferPlan(PterodactylTransferPlan plan) async {
    if (!remoteTransferRequiresTypedConfirmation(plan.mode)) {
      return Ui.confirm('Push these changes?', defaultValue: false);
    }
    Ui.warn('This is the destructive exact-mirror mode.');
    final String phrase = remoteMirrorConfirmationPhrase(plan.serverIdentifier);
    final String typed = await Ui.input('Type "$phrase" to mirror');
    if (!remoteTransferConfirmationMatches(expected: phrase, typed: typed)) {
      Ui.warn('Confirmation did not match. Nothing was changed.');
      await Ui.pause();
      return false;
    }
    return true;
  }

  String _remoteProfileName(String profileId) {
    for (final PterodactylProfile profile in pterodactyl.listProfiles()) {
      if (profile.id == profileId) return profile.name;
    }
    return profileId;
  }

  Future<void> _finishTransfer(
    PterodactylTransferResult result, {
    bool newTarget = false,
  }) async {
    Ui.blank();
    final PterodactylTransferPlan plan = result.plan;
    Ui.success(
      plan.direction == PterodactylTransferDirection.pull
          ? 'Pulled ${_safeRemoteText(plan.remoteServerName)} to ${plan.localInstanceName}'
          : 'Pushed ${plan.localInstanceName} to ${_safeRemoteText(plan.remoteServerName)}',
    );
    Ui.keyValue(
      result.linkPersisted ? 'linked target' : 'one-time target',
      '${result.link.profileId}/${result.link.serverIdentifier}',
    );
    if (!result.linkPersisted) {
      Ui.note('The Local instance link was not changed.');
    }
    if (result.backupPath != null) {
      Ui.keyValue('backup', result.backupPath!);
    }
    if (result.recoveryManifestPath != null) {
      Ui.keyValue('recovery', result.recoveryManifestPath!);
    }
    final String? runtimeMessage = remoteTransferRuntimeResultMessage(
      remoteStarted: result.remoteRestarted,
      newTarget: newTarget,
    );
    if (runtimeMessage != null) {
      Ui.info(runtimeMessage);
    }
    for (final String warning in result.warnings) {
      Ui.warn(_safeRemoteText(warning));
    }
    await Ui.pause();
  }

  Future<void> _prepareTransferAccount(String profileId) async {
    final String normalized = PterodactylProfile.normalizeId(profileId);
    final PterodactylSftpAccount? account =
        pterodactylSmb.settings?.accounts[normalized];
    if (account == null || !account.enabled) {
      await Ui.spin('Preparing Multiplexor Drive account', () {
        return pterodactylSmb.installDrive(profileIds: <String>[normalized]);
      });
    }
  }

  /// Prepares only the selected server's direct transfer backend. It never
  /// starts, diagnoses, or mounts the aggregate browsing Drive; enrolling a
  /// missing account may pause that Drive while its shared settings change.
  Future<bool> _prepareDirectTransferFiles({
    required String profileId,
    required String serverIdentifier,
    bool pauseOnFailure = true,
  }) async {
    final String normalizedProfile = PterodactylProfile.normalizeId(profileId);
    try {
      await _prepareTransferAccount(normalizedProfile);
      final bool trusted = await Ui.spin(
        'Checking selected Remote host key',
        () => pterodactylSmb.isServerHostKeyTrusted(
          profileId: normalizedProfile,
          serverIdentifier: serverIdentifier,
        ),
      );
      if (!trusted) {
        final List<PterodactylSshHostKeyCandidate> candidates = await Ui.spin(
          'Scanning selected Wings SSH host keys',
          () => pterodactylSmb.scanServerHostKeys(
            profileId: normalizedProfile,
            serverIdentifier: serverIdentifier,
          ),
        );
        if (candidates.isEmpty) {
          Ui.warn('No SSH host key was returned for the selected server.');
          if (pauseOnFailure) await Ui.pause();
          return false;
        }
        Ui.appHeader('SELECTED WINGS SSH HOST KEYS', <String>[
          '$serverIdentifier · ${candidates.length} fingerprints',
        ]);
        for (final PterodactylSshHostKeyCandidate candidate in candidates) {
          Ui.keyValue(
            '${_safeRemoteText(candidate.endpoint)} ${_safeRemoteText(candidate.keyType)}',
            _safeRemoteText(candidate.fingerprint),
          );
        }
        Ui.warn(
          'Compare these fingerprints with this Wings host before trusting '
          'them.',
        );
        if (!await Ui.confirm(
          'Trust exactly these SSH host keys for this server?',
          defaultValue: false,
        )) {
          Ui.note('Transfer cancelled; no SSH trust settings were changed.');
          if (pauseOnFailure) await Ui.pause();
          return false;
        }
        await pterodactylSmb.trustHostKeys(candidates);
        Ui.success('Selected Wings SSH host keys trusted');
      }
      await Ui.spin(
        'Verifying direct Remote file access',
        () => pterodactylSmb.verifyDirectServerFilesReady(
          profileId: normalizedProfile,
          serverIdentifier: serverIdentifier,
        ),
      );
      return true;
    } on Object catch (error) {
      Ui.warn(
        'Direct Remote file access is not ready: '
        '${_safeRemoteText('$error')}',
      );
      if (pauseOnFailure) await Ui.pause();
      return false;
    }
  }

  Future<void> _remoteOpenFolder(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylSftpAccount? driveAccount =
        pterodactylSmb.settings?.accounts[profile.id];
    if (driveAccount == null || !driveAccount.enabled) {
      await Ui.spin('Preparing Multiplexor Drive', () {
        return pterodactylSmb.installDrive(profileIds: <String>[profile.id]);
      });
    }
    final PterodactylSmbDoctorReport report = await pterodactylSmb.doctor();
    final bool needsHostTrust = report.checks.any(
      (PterodactylSmbCheck check) =>
          check.name == 'ssh-host-keys' &&
          check.level == PterodactylSmbCheckLevel.error,
    );
    if (needsHostTrust && !await _trustRemoteFileHostKeys(pauseAfter: false)) {
      Ui.note('Open Folder cancelled; no SSH host keys were trusted.');
      await Ui.pause();
      return;
    }
    final String openedPath = await Ui.spin(
      'Opening remote server folder',
      () => pterodactylSmb.openServerFolder(
        profileId: profile.id,
        serverIdentifier: identifier,
      ),
    );
    Ui.success('Opened $openedPath');
  }

  Future<void> _remoteSettings(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylClientServerAccess access = await Ui.spin(
      'Loading remote settings',
      () => pterodactyl.serverAccess(profile.id, identifier),
    );
    final PterodactylClientServer server = access.server;
    PterodactylServerStartup? startup;
    if (access.allows(PterodactylServerPermission.startupRead)) {
      startup = await Ui.spin(
        'Loading startup settings',
        () => pterodactyl.startup(profile.id, server.identifier),
      );
    }

    Ui.appHeader('REMOTE SETTINGS', <String>[
      _safeRemoteText(server.name),
      profile.name,
    ]);
    Ui.keyValue('identifier', server.identifier);
    Ui.keyValue('name', _safeRemoteText(server.name));
    Ui.keyValue(
      'description',
      server.description.isEmpty ? 'none' : _safeRemoteText(server.description),
    );
    Ui.keyValue(
      'permissions',
      access.isOwner
          ? 'owner (all)'
          : (access.permissions.toList()..sort()).join(', '),
    );
    Ui.keyValue(
      'limits',
      '${server.limits.memoryMiB} MiB RAM · ${server.limits.cpuPercent}% CPU · '
          '${server.limits.diskMiB} MiB disk',
    );
    Ui.keyValue(
      'features',
      '${server.featureLimits.databases ?? 0} db · '
          '${server.featureLimits.allocations ?? 0} allocations · '
          '${server.featureLimits.backups ?? 0} backups',
    );
    Ui.keyValue(
      'docker image',
      server.dockerImage.isEmpty ? 'not reported' : server.dockerImage,
    );
    Ui.keyValue(
      'startup',
      startup?.rawStartupCommand ??
          (access.allows(PterodactylServerPermission.startupRead)
              ? 'not reported'
              : 'hidden (startup.read not granted)'),
    );
    Ui.blank();

    final int selected = await Ui.choose('Modify remote settings', <String>[
      'Name & description',
      'Startup variable',
      'Docker image',
      'Resource & feature limits',
      'Startup command',
    ]);
    switch (selected) {
      case 0:
        await _remoteRename(profile, access);
      case 1:
        await _remoteStartupVariable(profile, access, startup);
      case 2:
        await _remoteDockerImage(profile, access, startup);
      case 3:
        await _remoteLimits(profile, access);
      case 4:
        await _remoteStartupCommand(profile, access, startup);
    }
  }

  Future<void> _remoteRename(
    PterodactylProfile profile,
    PterodactylClientServerAccess access,
  ) async {
    final PterodactylClientServer server = access.server;
    if (!access.allows(PterodactylServerPermission.settingsRename)) {
      Ui.note(
        'Client permission settings.rename is absent; Multiplexor will try '
        'the Application API.',
      );
    }
    final String name = await Ui.input(
      'Server name',
      defaultValue: server.name,
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Name cannot be empty',
    );
    final String description = await Ui.input(
      'Description',
      defaultValue: server.description,
    );
    final bool updated = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Updating remote server details',
      purpose: 'rename or describe this server',
      operation: () => pterodactyl.rename(
        profileId: profile.id,
        server: server.identifier,
        name: name,
        description: description,
      ),
    );
    if (updated) Ui.success('Updated ${server.identifier}');
    await Ui.pause();
  }

  Future<void> _remoteStartupVariable(
    PterodactylProfile profile,
    PterodactylClientServerAccess access,
    PterodactylServerStartup? startup,
  ) async {
    if (startup == null) {
      Ui.warn(
        'The Client account lacks startup.read, so editable variables cannot '
        'be listed safely.',
      );
      await Ui.pause();
      return;
    }
    final List<PterodactylStartupVariable> variables = startup.variables
        .where((PterodactylStartupVariable item) => item.isEditable)
        .toList(growable: false);
    if (variables.isEmpty) {
      Ui.note('This server exposes no editable startup variables.');
      await Ui.pause();
      return;
    }
    final int selected = await Ui.choose('Startup variable', <String>[
      for (final PterodactylStartupVariable variable in variables)
        '${variable.name} (${variable.environmentVariable}) = '
            '${variable.serverValue ?? variable.defaultValue ?? ''}',
    ]);
    final PterodactylStartupVariable variable = variables[selected];
    Ui.keyValue('variable', variable.environmentVariable);
    if (variable.description?.isNotEmpty == true) {
      Ui.keyValue('description', _safeRemoteText(variable.description!));
    }
    if (variable.rules.isNotEmpty) Ui.keyValue('rules', variable.rules);
    final String value = await Ui.input(
      'New value',
      defaultValue: variable.serverValue ?? variable.defaultValue ?? '',
    );
    if (!access.allows(PterodactylServerPermission.startupUpdate)) {
      Ui.note(
        'Client permission startup.update is absent; Multiplexor will try '
        'the Application API.',
      );
    }
    final bool updated = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Updating startup variable',
      purpose: 'modify startup variables',
      operation: () async {
        await pterodactyl.updateStartupVariable(
          profileId: profile.id,
          server: access.server.identifier,
          key: variable.environmentVariable,
          value: value,
        );
      },
    );
    if (updated) Ui.success('Updated ${variable.environmentVariable}');
    await Ui.pause();
  }

  Future<void> _remoteDockerImage(
    PterodactylProfile profile,
    PterodactylClientServerAccess access,
    PterodactylServerStartup? startup,
  ) async {
    if (startup == null) {
      Ui.warn(
        'The Client account lacks startup.read, so the Panel\'s allowed '
        'Docker images cannot be listed.',
      );
      await Ui.pause();
      return;
    }
    final List<MapEntry<String, String>> images = startup.dockerImages.entries
        .toList(growable: false);
    if (images.isEmpty) {
      Ui.note('This server exposes no selectable Docker images.');
      await Ui.pause();
      return;
    }
    final int selected = await Ui.choose('Allowed Docker image', <String>[
      for (final MapEntry<String, String> image in images)
        '${image.key}: ${image.value}',
    ]);
    final String dockerImage = images[selected].value;
    if (!access.allows(PterodactylServerPermission.startupDockerImage)) {
      Ui.note(
        'Client permission startup.docker-image is absent; Multiplexor will '
        'try the Application API.',
      );
    }
    final bool updated = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Updating Docker image',
      purpose: 'change the Docker image',
      operation: () => pterodactyl.updateDockerImage(
        profileId: profile.id,
        server: access.server.identifier,
        dockerImage: dockerImage,
      ),
    );
    if (updated) Ui.success('Docker image set to $dockerImage');
    await Ui.pause();
  }

  Future<void> _remoteLimits(
    PterodactylProfile profile,
    PterodactylClientServerAccess access,
  ) async {
    final PterodactylServerLimits limits = access.server.limits;
    final PterodactylFeatureLimits features = access.server.featureLimits;
    final List<_RemoteLimitField> fields = _RemoteLimitField.values;
    final int selected = await Ui.choose('Admin limit', <String>[
      'Memory MiB (${limits.memoryMiB})',
      'Swap MiB (${limits.swapMiB})',
      'Disk MiB (${limits.diskMiB})',
      'IO weight (${limits.ioWeight})',
      'CPU percent (${limits.cpuPercent})',
      'CPU threads (${limits.threads ?? 'all'})',
      'Database limit (${features.databases ?? 0})',
      'Allocation limit (${features.allocations ?? 0})',
      'Backup limit (${features.backups ?? 0})',
    ]);
    final _RemoteLimitField field = fields[selected];
    final String current = switch (field) {
      _RemoteLimitField.memory => '${limits.memoryMiB}',
      _RemoteLimitField.swap => '${limits.swapMiB}',
      _RemoteLimitField.disk => '${limits.diskMiB}',
      _RemoteLimitField.io => '${limits.ioWeight}',
      _RemoteLimitField.cpu => '${limits.cpuPercent}',
      _RemoteLimitField.threads => limits.threads ?? 'all',
      _RemoteLimitField.databases => '${features.databases ?? 0}',
      _RemoteLimitField.allocations => '${features.allocations ?? 0}',
      _RemoteLimitField.backups => '${features.backups ?? 0}',
    };
    final String value = await Ui.input(
      field == _RemoteLimitField.threads
          ? 'New value (use "all" to clear)'
          : 'New integer value',
      defaultValue: current,
      validator: field == _RemoteLimitField.threads
          ? (String candidate) => candidate.trim().isNotEmpty
          : (String candidate) => int.tryParse(candidate) != null,
      validationMessage: field == _RemoteLimitField.threads
          ? 'Enter a thread set or "all"'
          : 'Enter an integer accepted by Pterodactyl',
    );
    final int? integer = field == _RemoteLimitField.threads
        ? null
        : int.parse(value);
    final bool updated = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Updating server limits',
      purpose: 'change administrative server limits',
      operation: () async {
        await pterodactyl.updateBuildSettings(
          profileId: profile.id,
          server: access.server.identifier,
          memoryMiB: field == _RemoteLimitField.memory ? integer : null,
          swapMiB: field == _RemoteLimitField.swap ? integer : null,
          diskMiB: field == _RemoteLimitField.disk ? integer : null,
          ioWeight: field == _RemoteLimitField.io ? integer : null,
          cpuPercent: field == _RemoteLimitField.cpu ? integer : null,
          threads: field == _RemoteLimitField.threads && value != 'all'
              ? value
              : null,
          clearThreads: field == _RemoteLimitField.threads && value == 'all',
          databaseLimit: field == _RemoteLimitField.databases ? integer : null,
          allocationLimit: field == _RemoteLimitField.allocations
              ? integer
              : null,
          backupLimit: field == _RemoteLimitField.backups ? integer : null,
        );
      },
    );
    if (updated) Ui.success('Updated ${field.name}');
    await Ui.pause();
  }

  Future<void> _remoteStartupCommand(
    PterodactylProfile profile,
    PterodactylClientServerAccess access,
    PterodactylServerStartup? startup,
  ) async {
    final String current = startup?.rawStartupCommand.isNotEmpty == true
        ? startup!.rawStartupCommand
        : access.server.invocation;
    final String command = await Ui.input(
      'Startup command',
      defaultValue: current,
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Startup command cannot be empty',
    );
    final bool updated = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Updating startup command',
      purpose: 'change the startup command',
      operation: () async {
        await pterodactyl.updateStartupCommand(
          profileId: profile.id,
          server: access.server.identifier,
          startup: command,
        );
      },
    );
    if (updated) Ui.success('Updated startup command');
    await Ui.pause();
  }

  Future<void> _remoteHistory(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylClientServerAccess access = await Ui.spin(
      'Checking activity permission',
      () => pterodactyl.serverAccess(profile.id, identifier),
    );
    if (!access.allows(PterodactylServerPermission.activityRead)) {
      Ui.warn(
        'The Client account lacks activity.read for '
        '${_safeRemoteText(access.server.name)}.',
      );
      await Ui.pause();
      return;
    }
    final PterodactylPage<PterodactylActivity> page = await Ui.spin(
      'Loading remote activity history',
      () => pterodactyl.activity(
        profile.id,
        access.server.identifier,
        perPage: 25,
      ),
    );
    Ui.appHeader('REMOTE ACTIVITY', <String>[
      _safeRemoteText(access.server.name),
      '${page.pagination.total} events',
    ]);
    if (page.items.isEmpty) {
      Ui.note('No activity events were returned.');
    } else {
      for (final PterodactylActivity event in page.items) {
        final String timestamp = event.timestamp
            .toLocal()
            .toIso8601String()
            .replaceFirst('T', ' ');
        final String detail = event.description.isEmpty
            ? event.event
            : '${event.event} · ${_safeRemoteText(event.description)}';
        Ui.info('$timestamp  ${_safeRemoteText(detail)}');
      }
    }
    Ui.note('Resource charts retain seven days of sampled monitor history.');
    await Ui.pause();
  }

  Future<PterodactylClientServerAccess?> _confirmRemoteDestructiveAction({
    required String identifier,
    required String action,
    required String consequence,
  }) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylClientServerAccess access = await Ui.spin(
      'Loading remote server identity',
      () => pterodactyl.serverAccess(profile.id, identifier),
    );
    final PterodactylClientServer server = access.server;
    final bool continueToTypedConfirmation = await Ui.confirm(
      '$action ${_safeRemoteText(server.name)}? $consequence',
      defaultValue: false,
    );
    if (!continueToTypedConfirmation) return null;
    final String typed = await Ui.input(
      'Type "${_safeRemoteText(server.name)}" or "${server.identifier}"',
    );
    if (typed != server.name && typed != server.identifier) {
      Ui.warn('Confirmation did not match; $action cancelled.');
      await Ui.pause();
      return null;
    }
    return access;
  }

  Future<void> _remoteReinstall(String identifier) async {
    final PterodactylClientServerAccess? access =
        await _confirmRemoteDestructiveAction(
          identifier: identifier,
          action: 'Reinstall',
          consequence: 'All server files will be replaced.',
        );
    if (access == null) return;
    final PterodactylProfile profile = _requireRemoteProfile();
    if (!access.allows(PterodactylServerPermission.settingsReinstall)) {
      Ui.note(
        'Client permission settings.reinstall is absent; Multiplexor will '
        'try the Application API.',
      );
    }
    final bool reinstalled = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Requesting remote reinstall',
      purpose: 'reinstall this server',
      operation: () =>
          pterodactyl.reinstall(profile.id, access.server.identifier),
    );
    if (reinstalled) {
      Ui.success('Reinstall requested for ${access.server.name}');
    }
    await Ui.pause();
  }

  Future<void> _remoteDelete(String identifier) async {
    final PterodactylClientServerAccess? access =
        await _confirmRemoteDestructiveAction(
          identifier: identifier,
          action: 'Delete',
          consequence: 'This permanently destroys the server and its files.',
        );
    if (access == null) return;
    final PterodactylProfile profile = _requireRemoteProfile();
    final bool deleted = await _runRemoteMutationWithApplicationRepair(
      profile: profile,
      progressLabel: 'Deleting remote server',
      purpose: 'delete this server',
      operation: () => pterodactyl.delete(profile.id, access.server.identifier),
    );
    if (deleted) Ui.success('Deleted ${_safeRemoteText(access.server.name)}');
    await Ui.pause();
  }

  Future<bool> _runRemoteMutationWithApplicationRepair({
    required PterodactylProfile profile,
    required String progressLabel,
    required String purpose,
    required Future<void> Function() operation,
  }) async {
    try {
      await Ui.spin(progressLabel, operation);
      return true;
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      Ui.warn('The current API credentials are not allowed to $purpose.');
      final bool repair = await Ui.confirm(
        'Add or replace the Application API key and retry?',
        defaultValue: false,
      );
      if (!repair) return false;
      final PterodactylCredential? previous = await pterodactyl
          .credentialForRollback(
            profile,
            PterodactylCredentialRole.application,
          );
      try {
        await _enrollPterodactylCredential(
          profile,
          PterodactylCredentialRole.application,
        );
        await pterodactyl.verifyCredential(
          profile,
          PterodactylCredentialRole.application,
        );
        await Ui.spin('Retrying: $progressLabel', operation);
        return true;
      } catch (_) {
        if (previous != null) {
          await pterodactyl.restoreCredential(
            profile,
            PterodactylCredentialRole.application,
            previous,
          );
        } else {
          await pterodactyl.removeCredential(
            profile,
            PterodactylCredentialRole.application,
          );
        }
        rethrow;
      }
    }
  }

  Future<void> _remoteFiles() async {
    while (true) {
      final PterodactylSmbStatus status = await pterodactylSmb.status();
      final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
      final PterodactylProfile? active = _selectedRemoteProfile();
      Ui.clearScreen();
      Ui.appHeader('MULTIPLEXOR DRIVE', <String>[
        status.running
            ? 'available'
            : status.runningMounts > 0
            ? 'needs repair'
            : 'stopped',
        '${status.runningMounts}/${status.mounts.length} mounted',
      ]);
      Ui.info(
        'Every accessible Pterodactyl server appears in one local folder as '
        '<account>/<server-name>--<id>.',
      );
      Ui.keyValue('local drive', status.mountRoot ?? pterodactylSmb.drivePath);

      final List<_RemoteFilesAction> actions = <_RemoteFilesAction>[
        if (active != null) _RemoteFilesAction.configureActive,
        if (profiles.length > 1) _RemoteFilesAction.configureAll,
        if (status.configured) _RemoteFilesAction.trustHostKeys,
        _RemoteFilesAction.doctor,
        if (status.configured && !status.running) _RemoteFilesAction.start,
        if (status.configured) _RemoteFilesAction.open,
        if (status.runningMounts > 0) _RemoteFilesAction.stop,
        _RemoteFilesAction.done,
      ];
      final int selected = await Ui.choose('Multiplexor Drive', <String>[
        for (final _RemoteFilesAction action in actions)
          switch (action) {
            _RemoteFilesAction.configureActive =>
              'Configure active account (${active!.name})',
            _RemoteFilesAction.configureAll => 'Configure every saved account',
            _RemoteFilesAction.trustHostKeys =>
              'Verify and trust Wings SSH host keys',
            _RemoteFilesAction.doctor => 'Run drive diagnostics',
            _RemoteFilesAction.start => 'Start Multiplexor Drive',
            _RemoteFilesAction.open => 'Open Multiplexor Drive',
            _RemoteFilesAction.stop => 'Stop Multiplexor Drive',
            _RemoteFilesAction.done => 'Return to dashboard',
          },
      ]);
      switch (actions[selected]) {
        case _RemoteFilesAction.configureActive:
          await _configureRemoteFiles(<PterodactylProfile>[active!]);
        case _RemoteFilesAction.configureAll:
          await _configureRemoteFiles(profiles);
        case _RemoteFilesAction.trustHostKeys:
          await _trustRemoteFileHostKeys();
        case _RemoteFilesAction.doctor:
          await _showRemoteFilesDoctor();
        case _RemoteFilesAction.start:
          final PterodactylSmbStatus started = await Ui.spin(
            'Starting Multiplexor Drive',
            pterodactylSmb.startDrive,
          );
          if (started.running) {
            Ui.success(
              'Multiplexor Drive is available at ${started.mountRoot}',
            );
          } else {
            Ui.warn('Multiplexor Drive did not become fully ready.');
          }
          await Ui.pause();
        case _RemoteFilesAction.open:
          final String openedPath = await Ui.spin(
            'Opening Multiplexor Drive',
            pterodactylSmb.openDrive,
          );
          Ui.success('Opened $openedPath');
          await Ui.pause();
        case _RemoteFilesAction.stop:
          await Ui.spin('Stopping Multiplexor Drive', pterodactylSmb.stopDrive);
          Ui.success('Multiplexor Drive stopped');
          await Ui.pause();
        case _RemoteFilesAction.done:
          return;
      }
    }
  }

  Future<void> _configureRemoteFiles(List<PterodactylProfile> profiles) async {
    if (profiles.isEmpty) {
      Ui.warn('Add a remote account before configuring Multiplexor Drive.');
      await Ui.pause();
      return;
    }
    await Ui.spin('Generating and registering SFTP identities', () async {
      await pterodactylSmb.installDrive(
        profileIds: profiles.map((PterodactylProfile profile) => profile.id),
      );
    });
    Ui.success('Configured ${profiles.length} remote file account(s)');
    Ui.note(
      'Next, verify the Wings SSH fingerprints before starting the drive.',
    );
    await Ui.pause();
  }

  Future<bool> _trustRemoteFileHostKeys({bool pauseAfter = true}) async {
    final List<PterodactylSshHostKeyCandidate> candidates = await Ui.spin(
      'Scanning Wings SSH host keys',
      pterodactylSmb.scanHostKeys,
    );
    Ui.appHeader('WINGS SSH HOST KEYS', <String>[
      '${candidates.length} fingerprints',
    ]);
    for (final PterodactylSshHostKeyCandidate candidate in candidates) {
      Ui.keyValue(
        '${candidate.endpoint} ${candidate.keyType}',
        candidate.fingerprint,
      );
    }
    Ui.warn(
      'Compare these fingerprints with the Wings host before trusting them.',
    );
    final bool confirmed = await Ui.confirm(
      'Trust exactly these SSH host keys?',
      defaultValue: false,
    );
    if (!confirmed) {
      Ui.note('No SSH trust settings were changed.');
      if (pauseAfter) await Ui.pause();
      return false;
    }
    await pterodactylSmb.trustHostKeys(candidates);
    Ui.success('Wings SSH host keys trusted');
    if (pauseAfter) await Ui.pause();
    return true;
  }

  Future<void> _showRemoteFilesDoctor() async {
    final PterodactylSmbDoctorReport report = await Ui.spin(
      'Checking Multiplexor Drive prerequisites',
      pterodactylSmb.doctor,
    );
    Ui.appHeader('MULTIPLEXOR DRIVE DOCTOR', <String>[
      report.isReady ? 'ready' : 'needs attention',
    ]);
    for (final PterodactylSmbCheck check in report.checks) {
      switch (check.level) {
        case PterodactylSmbCheckLevel.ready:
          Ui.success('${check.name}: ${check.message}');
        case PterodactylSmbCheckLevel.warning:
          Ui.warn('${check.name}: ${check.message}');
        case PterodactylSmbCheckLevel.error:
          Ui.error('${check.name}: ${check.message}');
      }
    }
    await Ui.pause();
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

  Future<void> _remoteBulkActions(String? selectedIdentifier) async {
    while (true) {
      Ui.clearScreen();
      Ui.appHeader('REMOTE BULK ACTIONS', <String>[
        _requireRemoteProfile().name,
        'Esc returns to dashboard',
      ]);
      final List<RemoteBulkAction> actions = <RemoteBulkAction>[
        RemoteBulkAction.start,
        RemoteBulkAction.restart,
        RemoteBulkAction.stop,
        RemoteBulkAction.kill,
        RemoteBulkAction.reinstall,
        RemoteBulkAction.delete,
        RemoteBulkAction.createMany,
        RemoteBulkAction.done,
      ];
      final int selected = await Ui.choose('Bulk action', <String>[
        'Start stopped servers',
        'Restart running servers',
        'Stop running servers',
        'Kill running servers',
        'Reinstall servers',
        'Delete servers',
        'Create many servers',
        'Return to dashboard',
      ]);
      final RemoteBulkAction action = actions[selected];
      if (action == RemoteBulkAction.done) return;
      try {
        if (action == RemoteBulkAction.createMany) {
          await _remoteCreateMany();
        } else {
          await _runRemoteBulkAction(action, selectedIdentifier);
        }
      } on PromptBackNavigation {
        // Escape inside target selection or confirmation returns to the bulk
        // action list. Escape on that outer list returns to the dashboard.
      }
    }
  }

  Future<void> _runRemoteBulkAction(
    RemoteBulkAction action,
    String? selectedIdentifier,
  ) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final List<PterodactylFleetSample> fleet = await Ui.spin(
      'Refreshing remote fleet',
      () => pterodactyl.captureFleet(profile.id),
    );
    final List<PterodactylFleetSample>? targets = await _pickRemoteBulkTargets(
      fleet: fleet,
      action: action,
      selectedIdentifier: selectedIdentifier,
    );
    if (targets == null) return;
    if (targets.isEmpty) {
      Ui.note('No eligible servers are selected.');
      await Ui.pause();
      return;
    }
    final List<PterodactylFleetSample> allEligible = remoteBulkTargets(
      fleet: fleet,
      action: action,
      scope: RemoteBulkTargetScope.all,
      selectedIdentifier: selectedIdentifier,
    );
    if (!await _confirmRemoteBulkAction(
      profile: profile,
      action: action,
      targets: targets,
      allEligibleCount: allEligible.length,
    )) {
      return;
    }

    final List<String> identifiers = targets
        .map((PterodactylFleetSample sample) => sample.server.identifier)
        .toList(growable: false);
    for (final PterodactylFleetSample sample in targets) {
      Ui.keyValue(
        'pending',
        '${_safeRemoteText(sample.server.name)} '
            '(${sample.server.identifier})',
      );
    }
    final PterodactylBulkResult result = await Ui.spin(
      '${action.name}: ${targets.length} remote servers',
      () => switch (action) {
        RemoteBulkAction.start => pterodactyl.bulkPower(
          profileId: profile.id,
          serverIdentifiers: identifiers,
          signal: PterodactylPowerSignal.start,
        ),
        RemoteBulkAction.stop => pterodactyl.bulkPower(
          profileId: profile.id,
          serverIdentifiers: identifiers,
          signal: PterodactylPowerSignal.stop,
        ),
        RemoteBulkAction.restart => pterodactyl.bulkPower(
          profileId: profile.id,
          serverIdentifiers: identifiers,
          signal: PterodactylPowerSignal.restart,
        ),
        RemoteBulkAction.kill => pterodactyl.bulkPower(
          profileId: profile.id,
          serverIdentifiers: identifiers,
          signal: PterodactylPowerSignal.kill,
        ),
        RemoteBulkAction.reinstall => pterodactyl.bulkReinstall(
          profileId: profile.id,
          serverIdentifiers: identifiers,
        ),
        RemoteBulkAction.delete => pterodactyl.bulkDelete(
          profileId: profile.id,
          serverIdentifiers: identifiers,
        ),
        RemoteBulkAction.createMany || RemoteBulkAction.done =>
          throw StateError('Invalid existing-server bulk action: $action'),
      },
    );
    Ui.blank();
    for (int index = 0; index < result.items.length; index++) {
      final PterodactylBulkItemResult item = result.items[index];
      final String target = item.identifier ?? item.target;
      final String label =
          '${index + 1}/${result.totalCount} '
          '${_safeRemoteText(item.name)} (${_safeRemoteText(target)})';
      if (item.succeeded) {
        Ui.success('$label: ${result.action.name} accepted');
      } else {
        Ui.error('$label: ${_safeRemoteText(item.error ?? 'unknown failure')}');
      }
    }
    Ui.blank();
    if (result.isSuccess) {
      Ui.success(
        '${result.action.name}: all ${result.succeededCount} targets succeeded',
      );
    } else {
      Ui.warn(
        '${result.action.name}: ${result.succeededCount} succeeded, '
        '${result.failedCount} failed',
      );
    }
    await Ui.pause();
  }

  Future<List<PterodactylFleetSample>?> _pickRemoteBulkTargets({
    required List<PterodactylFleetSample> fleet,
    required RemoteBulkAction action,
    required String? selectedIdentifier,
  }) async {
    final List<PterodactylFleetSample> eligible = remoteBulkTargets(
      fleet: fleet,
      action: action,
      scope: RemoteBulkTargetScope.all,
      selectedIdentifier: selectedIdentifier,
    );
    if (eligible.isEmpty) {
      Ui.note('No servers are currently eligible for ${action.name}.');
      await Ui.pause();
      return const <PterodactylFleetSample>[];
    }
    final List<RemoteBulkTargetScope> candidatePresets =
        <RemoteBulkTargetScope>[
          RemoteBulkTargetScope.all,
          if (selectedIdentifier != null) RemoteBulkTargetScope.selected,
          RemoteBulkTargetScope.running,
          RemoteBulkTargetScope.stopped,
        ];
    final Map<RemoteBulkTargetScope, List<PterodactylFleetSample>> byPreset =
        <RemoteBulkTargetScope, List<PterodactylFleetSample>>{
          for (final RemoteBulkTargetScope scope in candidatePresets)
            scope: remoteBulkTargets(
              fleet: fleet,
              action: action,
              scope: scope,
              selectedIdentifier: selectedIdentifier,
            ),
        };
    final List<RemoteBulkTargetScope> presets = candidatePresets
        .where(
          (RemoteBulkTargetScope scope) =>
              scope == RemoteBulkTargetScope.all || byPreset[scope]!.isNotEmpty,
        )
        .toList(growable: false);
    final Set<String> selectedIds = <String>{
      for (final PterodactylFleetSample sample
          in byPreset[RemoteBulkTargetScope.selected] ??
              const <PterodactylFleetSample>[])
        sample.server.identifier,
    };

    while (true) {
      final List<String> options = <String>[
        for (final RemoteBulkTargetScope scope in presets)
          '${scope == RemoteBulkTargetScope.all ? 'Select' : 'Preset'} '
              '${scope.name} (${byPreset[scope]!.length})',
        for (final PterodactylFleetSample sample in eligible)
          '${selectedIds.contains(sample.server.identifier) ? '[x]' : '[ ]'} '
              '${_safeRemoteText(sample.server.name)} '
              '(${sample.server.identifier}) · '
              '${sample.resources?.currentState ?? 'state unavailable'}',
        'Continue with ${selectedIds.length} selected',
        'Back to bulk actions',
      ];
      final int choice;
      try {
        choice = await Ui.choose('Select ${action.name} targets', options);
      } on PromptBackNavigation {
        return null;
      }
      if (choice < presets.length) {
        selectedIds
          ..clear()
          ..addAll(
            byPreset[presets[choice]]!.map(
              (PterodactylFleetSample sample) => sample.server.identifier,
            ),
          );
        continue;
      }
      final int serverIndex = choice - presets.length;
      if (serverIndex < eligible.length) {
        final String identifier = eligible[serverIndex].server.identifier;
        if (!selectedIds.remove(identifier)) selectedIds.add(identifier);
        continue;
      }
      if (serverIndex == eligible.length) {
        if (selectedIds.isEmpty) {
          Ui.warn('Select at least one server.');
          await Ui.pause();
          continue;
        }
        return List<PterodactylFleetSample>.unmodifiable(
          eligible.where(
            (PterodactylFleetSample sample) =>
                selectedIds.contains(sample.server.identifier),
          ),
        );
      }
      return null;
    }
  }

  Future<bool> _confirmRemoteBulkAction({
    required PterodactylProfile profile,
    required RemoteBulkAction action,
    required List<PterodactylFleetSample> targets,
    required int allEligibleCount,
  }) async {
    Ui.clearScreen();
    Ui.appHeader('CONFIRM BULK ${action.name.toUpperCase()}', <String>[
      profile.name,
      '${targets.length} targets',
    ]);
    for (final PterodactylFleetSample sample in targets) {
      Ui.keyValue(
        sample.server.identifier,
        '${_safeRemoteText(sample.server.name)} · '
        '${sample.resources?.currentState ?? 'state unavailable'}',
      );
    }
    final bool confirmed = await Ui.confirm(
      '${action.name} these ${targets.length} remote servers?',
      defaultValue: false,
    );
    if (!confirmed) return false;
    if (!remoteBulkActionRequiresTypedConfirmation(action)) return true;

    final bool entireEligibleFleet = targets.length == allEligibleCount;
    final String phrase = remoteBulkConfirmationPhrase(
      action,
      targets.length,
      allProfileId:
          entireEligibleFleet &&
              (action == RemoteBulkAction.reinstall ||
                  action == RemoteBulkAction.delete)
          ? profile.id
          : null,
    );
    final String typed = await Ui.input('Type "$phrase" to continue');
    if (typed != phrase) {
      Ui.warn('Confirmation did not match; bulk ${action.name} cancelled.');
      await Ui.pause();
      return false;
    }
    return true;
  }

  Future<void> _remoteCreateMany() => _createRemoteServers(many: true);

  Future<void> _createRemoteServers({required bool many}) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    final PterodactylVerification verification =
        await _ensureApplicationCredential(profile);
    if (!remoteCreationCatalogAccessAvailable(verification)) {
      Ui.warn('Remote creation inventory is unavailable for this connection.');
      _showRemoteCreationPermissionHelp();
      await Ui.pause();
      return;
    }

    final PterodactylCreationCatalog? initialCatalog =
        await _loadRemoteCreationCatalog(profile);
    if (initialCatalog == null) return;
    final PterodactylCreationCatalog catalog = initialCatalog;
    final String? partialEggNote = remoteCreatePartialEggInventoryNote(catalog);
    if (partialEggNote != null) Ui.note(partialEggNote);
    final List<PterodactylEgg> usableEggs = remoteCreateUsableEggs(catalog);
    if (usableEggs.isEmpty && catalog.templates.isEmpty) {
      Ui.warn(
        catalog.eggs.isEmpty
            ? 'The panel has no existing server to clone and no eggs to '
                  'create from.'
            : 'The panel has no existing server to clone, and every egg is '
                  'missing a startup command or Docker image.',
      );
      Ui.note(
        'Add an egg in the Pterodactyl admin panel, or configure a startup '
        'command and Docker image on an existing egg, then try again.',
      );
      await Ui.pause();
      return;
    }

    final List<RemoteCreateSource> sources = remoteCreateSources(
      hasPanelEggs: usableEggs.isNotEmpty,
      hasTemplates: catalog.templates.isNotEmpty,
    );
    if (usableEggs.isNotEmpty && catalog.templates.isNotEmpty) {
      while (true) {
        final int sourceIndex = await Ui.choose(
          many ? 'Create many servers from' : 'Create server from',
          <String>[
            'Panel egg · works without an existing server',
            'Clone an existing server configuration',
            'Back',
          ],
        );
        final RemoteCreateSource source = sources[sourceIndex];
        if (source == RemoteCreateSource.done) return;
        final bool completed = await remoteCreateStepOrBack(
          () => _runRemoteCreateSource(
            source: source,
            profile: profile,
            catalog: catalog,
            usableEggs: usableEggs,
            many: many,
          ),
        );
        if (completed) return;
      }
    }
    await _runRemoteCreateSource(
      source: sources.first,
      profile: profile,
      catalog: catalog,
      usableEggs: usableEggs,
      many: many,
    );
  }

  Future<void> _runRemoteCreateSource({
    required RemoteCreateSource source,
    required PterodactylProfile profile,
    required PterodactylCreationCatalog catalog,
    required List<PterodactylEgg> usableEggs,
    required bool many,
  }) async {
    switch (source) {
      case RemoteCreateSource.panelEgg:
        return _createRemoteServersFromEgg(
          profile: profile,
          catalog: catalog,
          usableEggs: usableEggs,
          many: many,
        );
      case RemoteCreateSource.cloneExisting:
        return _createRemoteServersFromTemplate(
          profile: profile,
          catalog: catalog,
          many: many,
        );
      case RemoteCreateSource.done:
        return;
    }
  }

  Future<PterodactylCreationCatalog?> _loadRemoteCreationCatalog(
    PterodactylProfile profile,
  ) async {
    while (true) {
      try {
        return await Ui.spin(
          'Loading panel creation catalog',
          () => pterodactyl.creationCatalog(
            profile.id,
            allowPartialEggInventory: true,
          ),
        );
      } on Object catch (error) {
        if (!remoteCreationCatalogErrorNeedsCredentialRepair(error)) rethrow;
        if (error is PterodactylCreationCatalogPermissionException) {
          Ui.warn(
            'The Application API key is missing ${error.permission} for the '
            'panel creation catalog.',
          );
        } else {
          Ui.warn(
            'The Application API key cannot read the panel creation catalog.',
          );
        }
        _showRemoteCreationPermissionHelp();
        final bool repaired = await _repairRemoteCreationCatalog(profile);
        if (!repaired) return null;
      }
    }
  }

  Future<bool> _repairRemoteCreationCatalog(PterodactylProfile profile) async {
    final bool repair = await Ui.confirm(
      'Replace the Application API key and retry?',
      defaultValue: true,
    );
    if (!repair) {
      await Ui.pause();
      return false;
    }
    final PterodactylVerification repaired = await _replaceCredentialAndVerify(
      profile,
      PterodactylCredentialRole.application,
      progressLabel: 'Verifying replacement Application key',
    );
    if (remoteCreationCatalogAccessAvailable(repaired)) {
      return true;
    }
    Ui.warn('The replacement Application key still cannot create servers.');
    _showRemoteCreationPermissionHelp();
    await Ui.pause();
    return false;
  }

  void _showRemoteCreationPermissionHelp() {
    Ui.note(
      'Application key permissions needed: Users READ, Nodes READ, '
      'Allocations READ, Nests READ, Eggs READ, and Servers READ/WRITE.',
    );
  }

  Future<void> _createRemoteServersFromTemplate({
    required PterodactylProfile profile,
    required PterodactylCreationCatalog catalog,
    required bool many,
  }) async {
    final int templateIndex =
        await Ui.choose('Clone remote configuration from', <String>[
          for (final PterodactylApplicationServer template in catalog.templates)
            '${_safeRemoteText(template.name)} (${template.identifier})',
        ]);
    final PterodactylApplicationServer template =
        catalog.templates[templateIndex];
    final List<String> names = await _promptRemoteCreateNames(
      many: many,
      defaultPattern: many ? '${template.name} {n}' : '${template.name} Copy',
    );
    final bool startOnCompletion = await Ui.confirm(
      many
          ? 'Start each server after creation?'
          : 'Start the server after creation?',
      defaultValue: false,
    );
    Ui.clearScreen();
    Ui.appHeader(
      many ? 'CREATE MANY REMOTE SERVERS' : 'CREATE REMOTE SERVER',
      <String>[
        profile.name,
        '${names.length} server${names.length == 1 ? '' : 's'}',
      ],
    );
    Ui.keyValue('source', 'Clone ${_safeRemoteText(template.name)}');
    Ui.keyValue('resources', 'Inherited from template');
    Ui.keyValue('start', startOnCompletion ? 'after creation' : 'no');
    _showRemoteCreateNames(names);
    if (!await Ui.confirm(
      names.length == 1
          ? 'Create this remote server?'
          : 'Create all ${names.length} remote servers?',
      defaultValue: remoteCreateFinalConfirmationDefault,
    )) {
      return;
    }
    final PterodactylBulkResult? result = await _runRemoteBulkCreate(
      profile: profile,
      progressLabel: 'Creating ${names.length} remote server(s)',
      operation: () => pterodactyl.bulkCreateFromTemplate(
        profileId: profile.id,
        template: template.identifier,
        names: names,
        startOnCompletion: startOnCompletion,
      ),
    );
    if (result == null) return;
    await _finishRemoteCreation(profile, result);
  }

  Future<void> _createRemoteServersFromEgg({
    required PterodactylProfile profile,
    required PterodactylCreationCatalog catalog,
    required List<PterodactylEgg> usableEggs,
    required bool many,
  }) async {
    final _RemoteEggChoice? choice = await _chooseRemoteEgg(
      catalog,
      usableEggs,
    );
    if (choice == null) return;
    final List<String> names = await _promptRemoteCreateNames(
      many: many,
      defaultPattern: many
          ? '${choice.egg.name} {n}'
          : '${choice.egg.name} Server',
    );
    final _RemoteEggPlanSelection? selection = await _buildRemoteEggCreatePlan(
      catalog: catalog,
      choice: choice,
      serverCount: names.length,
    );
    if (selection == null) return;

    Ui.clearScreen();
    Ui.appHeader(
      many ? 'CREATE MANY REMOTE SERVERS' : 'CREATE REMOTE SERVER',
      <String>[
        profile.name,
        '${names.length} server${names.length == 1 ? '' : 's'}',
      ],
    );
    Ui.keyValue(
      'source',
      '${_safeRemoteText(selection.nest.name)} / '
          '${_safeRemoteText(selection.egg.name)}',
    );
    Ui.keyValue('owner', _safeRemoteText(selection.owner.username));
    Ui.keyValue(
      'node',
      '${_safeRemoteText(selection.node.name)} · '
          '${catalog.freeAllocationCount(selection.node.id)} free allocations'
          '${selection.node.maintenanceMode ? ' · MAINTENANCE' : ''}',
    );
    Ui.keyValue('image', _safeRemoteText(selection.imageLabel));
    Ui.keyValue('memory', '${selection.plan.memoryMiB} MiB');
    Ui.keyValue(
      'disk',
      selection.plan.diskMiB == 0
          ? 'unlimited'
          : '${selection.plan.diskMiB} MiB',
    );
    Ui.keyValue(
      'CPU',
      selection.plan.cpuPercent == 0
          ? 'unlimited'
          : '${selection.plan.cpuPercent}%',
    );
    Ui.keyValue('variables', '${selection.plan.environment.length} customized');
    Ui.keyValue(
      'start',
      selection.plan.startOnCompletion ? 'after creation' : 'no',
    );
    _showRemoteCreateNames(names);
    if (!await Ui.confirm(
      names.length == 1
          ? 'Create this remote server?'
          : 'Create all ${names.length} remote servers?',
      defaultValue: remoteCreateFinalConfirmationDefault,
    )) {
      return;
    }

    final PterodactylBulkResult? result = await _runRemoteBulkCreate(
      profile: profile,
      progressLabel: 'Creating ${names.length} remote server(s)',
      operation: () => pterodactyl.bulkCreateFromEgg(
        profileId: profile.id,
        names: names,
        plan: selection.plan,
      ),
    );
    if (result == null) return;
    await _finishRemoteCreation(profile, result);
  }

  Future<List<String>> _promptRemoteCreateNames({
    required bool many,
    required String defaultPattern,
  }) async {
    int count = 1;
    if (many) {
      final String countText = await Ui.input(
        'How many servers (1-50)',
        defaultValue: '2',
        validator: (String value) {
          final int? parsed = int.tryParse(value.trim());
          return parsed != null && parsed >= 1 && parsed <= 50;
        },
        validationMessage: 'Enter a whole number from 1 through 50',
      );
      count = int.parse(countText.trim());
    }
    final String pattern = await Ui.input(
      many ? 'Server name pattern (use {n} for the number)' : 'Server name',
      defaultValue: defaultPattern,
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Server name cannot be empty',
    );
    return remoteCreateNames(pattern: pattern, count: count);
  }

  Future<_RemoteEggChoice?> _chooseRemoteEgg(
    PterodactylCreationCatalog catalog,
    List<PterodactylEgg> usableEggs,
  ) async {
    final List<PterodactylNest> nests = catalog.nests
        .where(
          (PterodactylNest nest) =>
              usableEggs.any((PterodactylEgg egg) => egg.nestId == nest.id),
        )
        .toList(growable: false);
    if (nests.isEmpty) {
      Ui.warn('No readable nest contains a creation-ready egg.');
      _showRemoteCreationPermissionHelp();
      await Ui.pause();
      return null;
    }
    final int nestIndex = await Ui.choose('Panel nest', <String>[
      for (final PterodactylNest nest in nests)
        '${_safeRemoteText(nest.name)} · '
            '${usableEggs.where((PterodactylEgg egg) => egg.nestId == nest.id).length} eggs',
    ]);
    final PterodactylNest nest = nests[nestIndex];
    final List<PterodactylEgg> eggs = usableEggs
        .where((PterodactylEgg egg) => egg.nestId == nest.id)
        .toList(growable: false);
    final int eggIndex = await Ui.choose('Panel egg', <String>[
      for (final PterodactylEgg egg in eggs)
        '${_safeRemoteText(egg.name)} · ${egg.dockerImages.length} image(s)',
    ]);
    return _RemoteEggChoice(nest: nest, egg: eggs[eggIndex]);
  }

  Future<PterodactylUser?> _chooseRemoteCreationOwner(
    PterodactylCreationCatalog catalog,
  ) async {
    if (catalog.users.isEmpty) {
      Ui.warn('No panel user is available to own the new server(s).');
      Ui.note(
        'Create a panel user or repair Users READ on the Application key.',
      );
      _showRemoteCreationPermissionHelp();
      await Ui.pause();
      return null;
    }
    final int ownerIndex = await Ui.choose(
      'Server owner',
      <String>[
        for (final PterodactylUser user in catalog.users)
          '${_safeRemoteText(user.username)} · '
              '${_safeRemoteText('${user.firstName} ${user.lastName}'.trim())}'
              '${user.id == catalog.recommendedOwnerId ? ' · connected account' : ''}',
      ],
      initialIndex: remoteCreateOwnerInitialIndex(
        catalog.users,
        catalog.recommendedOwnerId,
      ),
    );
    return catalog.users[ownerIndex];
  }

  Future<_RemoteEggPlanSelection?> _buildRemoteEggCreatePlan({
    required PterodactylCreationCatalog catalog,
    required _RemoteEggChoice choice,
    required int serverCount,
    bool promptForStart = true,
  }) async {
    final PterodactylUser? selectedOwner = await _chooseRemoteCreationOwner(
      catalog,
    );
    if (selectedOwner == null) return null;
    final PterodactylUser owner = selectedOwner;
    final List<PterodactylNode> nodes = remoteCreateEligibleNodes(
      catalog,
      serverCount,
    );
    if (nodes.isEmpty) {
      Ui.warn(
        'No node has $serverCount free allocation${serverCount == 1 ? '' : 's'}.',
      );
      Ui.note(
        'Add free allocations on a node, or repair Nodes and Allocations READ '
        'on the Application key.',
      );
      _showRemoteCreationPermissionHelp();
      await Ui.pause();
      return null;
    }
    final int nodeIndex = await Ui.choose('Deployment node', <String>[
      for (final PterodactylNode node in nodes)
        '${_safeRemoteText(node.name)} · '
            '${catalog.freeAllocationCount(node.id)} free allocations'
            '${node.maintenanceMode ? ' · MAINTENANCE' : ''}',
    ]);
    final PterodactylNode node = nodes[nodeIndex];

    final List<MapEntry<String, String>> images = choice
        .egg
        .dockerImages
        .entries
        .toList(growable: false);
    final int imageIndex = await Ui.choose('Docker image', <String>[
      for (final MapEntry<String, String> image in images)
        '${_safeRemoteText(image.key)} → ${_safeRemoteText(image.value)}',
    ]);
    final MapEntry<String, String> image = images[imageIndex];
    final Map<String, String> environment = <String, String>{};
    for (final PterodactylEggVariable variable in remoteCreatePromptVariables(
      choice.egg,
    )) {
      environment[variable.environmentVariable] =
          await _promptRemoteEggVariable(variable);
    }
    final int memoryMiB = await _promptRemoteResourceLimit(
      'Memory limit MiB (0 = unlimited)',
      4096,
    );
    final int diskMiB = await _promptRemoteResourceLimit(
      'Disk limit MiB (0 = unlimited)',
      0,
    );
    final int cpuPercent = await _promptRemoteResourceLimit(
      'CPU limit percent (0 = unlimited)',
      0,
    );
    final bool startOnCompletion = promptForStart
        ? await Ui.confirm(
            serverCount == 1
                ? 'Start the server after creation?'
                : 'Start each server after creation?',
            defaultValue: false,
          )
        : false;
    final String startup = choice.egg.startup!;
    return _RemoteEggPlanSelection(
      plan: PterodactylEggCreatePlan(
        ownerId: owner.id,
        nodeId: node.id,
        eggId: choice.egg.id,
        eggUuid: choice.egg.uuid,
        dockerImage: image.value,
        startup: startup,
        environment: environment,
        memoryMiB: memoryMiB,
        diskMiB: diskMiB,
        cpuPercent: cpuPercent,
        startOnCompletion: startOnCompletion,
      ),
      owner: owner,
      node: node,
      nest: choice.nest,
      egg: choice.egg,
      imageLabel: image.key,
    );
  }

  Future<String> _promptRemoteEggVariable(
    PterodactylEggVariable variable,
  ) async {
    final bool valueRequired =
        variable.isRequired && variable.defaultValue.trim().isEmpty;
    final String label =
        '${variable.name} (${variable.environmentVariable})'
        '${valueRequired ? ' · required' : ''}';
    while (true) {
      final String value = await Ui.secret(
        '$label${variable.defaultValue.isEmpty ? '' : ' · blank keeps configured default'}',
      );
      final String resolved = value.isEmpty ? variable.defaultValue : value;
      if (!valueRequired || resolved.trim().isNotEmpty) return resolved;
      Ui.warn('${variable.environmentVariable} is required');
    }
  }

  Future<int> _promptRemoteResourceLimit(
    String prompt,
    int defaultValue,
  ) async {
    final String value = await Ui.input(
      prompt,
      defaultValue: '$defaultValue',
      validator: (String input) {
        final int? parsed = int.tryParse(input.trim());
        return parsed != null && parsed >= 0;
      },
      validationMessage: 'Enter zero or a positive whole number',
    );
    return int.parse(value.trim());
  }

  void _showRemoteCreateNames(List<String> names) {
    for (int index = 0; index < names.length; index++) {
      Ui.keyValue('name ${index + 1}', _safeRemoteText(names[index]));
    }
  }

  Future<PterodactylBulkResult?> _runRemoteBulkCreate({
    required PterodactylProfile profile,
    required String progressLabel,
    required Future<PterodactylBulkResult> Function() operation,
  }) async {
    try {
      return await Ui.spin(progressLabel, operation);
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      Ui.warn('The Application API key cannot complete server creation.');
      _showRemoteCreationPermissionHelp();
      final bool repair = await Ui.confirm(
        'Replace the Application API key and retry?',
        defaultValue: true,
      );
      if (!repair) return null;
      final PterodactylVerification repaired =
          await _replaceCredentialAndVerify(
            profile,
            PterodactylCredentialRole.application,
            progressLabel: 'Verifying replacement Application key',
          );
      if (!remoteCreationCatalogAccessAvailable(repaired)) {
        Ui.warn('The replacement Application key still cannot create servers.');
        _showRemoteCreationPermissionHelp();
        await Ui.pause();
        return null;
      }
      return Ui.spin('Retrying: $progressLabel', operation);
    }
  }

  Future<void> _finishRemoteCreation(
    PterodactylProfile profile,
    PterodactylBulkResult result,
  ) async {
    Ui.blank();
    for (final RemoteCreateResultRow row in remoteCreateResultRows(result)) {
      final PterodactylBulkItemResult item = row.item;
      final String label =
          '${row.position}/${row.total} ${_safeRemoteText(item.name)}';
      if (item.succeeded) {
        Ui.success(
          '$label: created ${_safeRemoteText(item.identifier ?? item.target)}',
        );
      } else {
        Ui.error('$label: ${_safeRemoteText(item.error ?? 'unknown failure')}');
      }
    }
    Ui.blank();
    if (result.isSuccess) {
      Ui.success('Created all ${result.succeededCount} remote server(s)');
    } else {
      Ui.warn(
        'Creation: ${result.succeededCount} succeeded, '
        '${result.failedCount} failed',
      );
    }
    if (remoteCreateResultNeedsCredentialRepair(result)) {
      Ui.warn('One or more requests were rejected by the Application API key.');
      _showRemoteCreationPermissionHelp();
      final bool repair = await Ui.confirm(
        'Replace the Application API key for the next attempt?',
        defaultValue: true,
      );
      if (repair) {
        await _replaceCredentialAndVerify(
          profile,
          PterodactylCredentialRole.application,
          progressLabel: 'Verifying replacement Application key',
        );
        Ui.success('Application API key replaced. Retry only failed names.');
      }
    }
    await Ui.pause();
  }

  Future<bool> _connectPterodactyl() async {
    bool changed = false;
    while (true) {
      final List<PterodactylProfile> profiles = pterodactyl.listProfiles();
      final PterodactylProfile? active = pterodactyl.activeProfile();
      Ui.clearScreen();
      Ui.appHeader('REMOTE ACCOUNTS', <String>[
        if (active != null)
          '${active.name} · ${active.origin}'
        else
          'not connected',
        '${profiles.length} saved',
      ]);
      final List<_RemoteAccountAction> actions = <_RemoteAccountAction>[
        if (active != null) _RemoteAccountAction.verify,
        if (profiles.length > 1) _RemoteAccountAction.switchAccount,
        _RemoteAccountAction.add,
        if (active != null) _RemoteAccountAction.rename,
        if (active != null) _RemoteAccountAction.replaceClientKey,
        if (active != null) _RemoteAccountAction.replaceApplicationKey,
        if (active != null) _RemoteAccountAction.remove,
        _RemoteAccountAction.done,
      ];
      final int selected = await Ui.choose('Connection manager', <String>[
        for (final _RemoteAccountAction action in actions)
          switch (action) {
            _RemoteAccountAction.verify => 'Verify active connection',
            _RemoteAccountAction.switchAccount => 'Switch active connection',
            _RemoteAccountAction.add => 'Add connection',
            _RemoteAccountAction.rename => 'Rename display name',
            _RemoteAccountAction.replaceClientKey => 'Replace Client API key',
            _RemoteAccountAction.replaceApplicationKey =>
              'Replace Application API key',
            _RemoteAccountAction.remove => 'Remove connection',
            _RemoteAccountAction.done => 'Return to dashboard',
          },
      ]);
      final _RemoteAccountAction action = actions[selected];
      switch (action) {
        case _RemoteAccountAction.verify:
          final PterodactylVerification verification =
              await _verifyRemoteWithRepair(active!);
          _showRemoteVerification(verification);
          changed = true;
          _remoteConnectionChanged = true;
          await Ui.pause();
        case _RemoteAccountAction.switchAccount:
          final PterodactylProfile selectedProfile = await _pickRemoteProfile(
            profiles,
            'Use remote connection',
          );
          pterodactyl.selectProfile(selectedProfile.id);
          _remoteProfileId = selectedProfile.id;
          changed = true;
          _remoteConnectionChanged = true;
          Ui.success('Using ${selectedProfile.name}');
        case _RemoteAccountAction.add:
          await _addPterodactylConnection(profiles);
          changed = true;
          _remoteConnectionChanged = true;
        case _RemoteAccountAction.rename:
          final String name = await Ui.input(
            'Connection display name',
            defaultValue: active!.name,
            validator: (String value) => value.trim().isNotEmpty,
            validationMessage: 'Name cannot be empty',
          );
          pterodactyl.saveProfile(
            PterodactylProfile(
              id: active.id,
              name: name,
              panelUri: active.panelUri,
              trustedCertificatePath: active.trustedCertificatePath,
            ),
          );
          changed = true;
          _remoteConnectionChanged = true;
          Ui.success('Renamed connection to $name');
        case _RemoteAccountAction.replaceClientKey:
          final PterodactylVerification verification =
              await _replaceCredentialAndVerify(
                active!,
                PterodactylCredentialRole.client,
                progressLabel: 'Verifying replacement Client key',
              );
          _showRemoteVerification(verification);
          changed = true;
          _remoteConnectionChanged = true;
          await Ui.pause();
        case _RemoteAccountAction.replaceApplicationKey:
          final PterodactylVerification verification =
              await _replaceCredentialAndVerify(
                active!,
                PterodactylCredentialRole.application,
                progressLabel: 'Verifying replacement Application key',
              );
          _showRemoteVerification(verification);
          changed = true;
          _remoteConnectionChanged = true;
          await Ui.pause();
        case _RemoteAccountAction.remove:
          final bool confirmed = await Ui.confirm(
            'Remove ${active!.name} and its stored API credentials?',
            defaultValue: false,
          );
          if (confirmed) {
            await pterodactyl.removeProfile(active.id);
            final PterodactylProfile? next = pterodactyl.activeProfile();
            _remoteProfileId = next?.id;
            changed = true;
            _remoteConnectionChanged = true;
            Ui.success('Removed ${active.name}');
          }
        case _RemoteAccountAction.done:
          _remoteConnectionChanged = _remoteConnectionChanged || changed;
          return changed;
      }
    }
  }

  Future<void> _addPterodactylConnection(
    List<PterodactylProfile> existing,
  ) async {
    final String id = await Ui.input(
      'Connection ID',
      defaultValue: 'remote',
      validator: (String value) =>
          PterodactylProfile.isValidId(value) &&
          !existing.any(
            (PterodactylProfile item) =>
                item.id == PterodactylProfile.normalizeId(value),
          ),
      validationMessage:
          'Use a unique ID with lowercase letters, digits, - or _',
    );
    final String name = await Ui.input('Connection name', defaultValue: id);
    final String url = await Ui.input(
      'Pterodactyl panel URL',
      validator: _validPanelUrl,
      validationMessage:
          'Enter an HTTPS origin such as https://panel.example.com',
    );
    final PterodactylProfile profile = PterodactylProfile(
      id: id,
      name: name,
      panelUri: Uri.parse(url),
    );
    try {
      final PterodactylCredentialRole firstRole =
          await _promptAnyPterodactylCredential(profile);
      if (firstRole == PterodactylCredentialRole.application) {
        Ui.warn(
          'Application keys cannot open Client server, console, or activity '
          'routes. Add a Client key for day-to-day access.',
        );
        await _enrollPterodactylCredential(
          profile,
          PterodactylCredentialRole.client,
        );
        await pterodactyl.verifyCredential(
          profile,
          PterodactylCredentialRole.application,
        );
      }
      final PterodactylVerification verification =
          await _verifyRemoteWithRepair(profile);
      pterodactyl.saveProfile(profile);
      pterodactyl.selectProfile(profile.id);
      _remoteProfileId = profile.id;
      _showRemoteVerification(verification);
      await Ui.pause();
    } catch (_) {
      await pterodactyl.removeCredential(
        profile,
        PterodactylCredentialRole.client,
      );
      await pterodactyl.removeCredential(
        profile,
        PterodactylCredentialRole.application,
      );
      rethrow;
    }
  }

  Future<PterodactylCredentialRole> _promptAnyPterodactylCredential(
    PterodactylProfile profile,
  ) async {
    Ui.info(
      'Paste a Client (ptlc_) or Application (ptla_) API key. Unknown '
      'prefixes are accepted after you identify the key type.',
    );
    final PterodactylCredential credential = await _promptCredential('API key');
    PterodactylCredentialRole? role = inferPterodactylCredentialRole(
      credential.value,
    );
    if (role == null) {
      final int choice = await Ui.choose('API key type', <String>[
        'Client API key',
        'Application API key',
      ]);
      role = choice == 0
          ? PterodactylCredentialRole.client
          : PterodactylCredentialRole.application;
    }
    await pterodactyl.saveCredential(profile, role, credential);
    return role;
  }

  Future<PterodactylProfile> _pickRemoteProfile(
    List<PterodactylProfile> profiles,
    String title,
  ) async {
    final int selected = await Ui.choose(title, <String>[
      for (final PterodactylProfile profile in profiles)
        '${profile.name} (${profile.id}) · ${profile.origin}',
    ]);
    return profiles[selected];
  }

  void _showRemoteVerification(PterodactylVerification verification) {
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
        Ui.note(
          'Grant Users, Nodes, Allocations, Nests, and Eggs read plus Servers '
          'read/write.',
        );
    }
    final PterodactylCredential credential = await _promptCredential(
      role == PterodactylCredentialRole.client
          ? 'Client API key'
          : 'Application API key',
    );
    if (!pterodactylCredentialMatchesRole(credential, role)) {
      throw FormatException(
        'That is a standard '
        '${inferPterodactylCredentialRole(credential.value)!.name} API key, '
        'not a ${role.name} API key.',
      );
    }
    await pterodactyl.saveCredential(profile, role, credential);
  }

  Future<PterodactylCredential> _promptCredential(String prompt) async {
    while (true) {
      final String value = (await Ui.secret(prompt)).trim();
      try {
        return PterodactylCredential(value);
      } on FormatException {
        Ui.warn('Enter a non-empty API key without spaces or control bytes.');
      }
    }
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
    if (remoteCreationCatalogAccessAvailable(verification)) {
      return verification;
    }
    if (!await pterodactyl.hasApplicationCredential(profile)) {
      await _enrollPterodactylCredential(
        profile,
        PterodactylCredentialRole.application,
      );
    }
    verification = await _verifyRemoteWithRepair(profile);
    if (!remoteCreationCatalogAccessAvailable(verification)) {
      Ui.warn('The stored Application key cannot read creation inventory.');
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
      await pterodactyl.verifyCredential(profile, role);
      return await Ui.spin(
        progressLabel,
        () => pterodactyl.verifyProfile(profile),
      );
    } catch (_) {
      if (previous != null) {
        await pterodactyl.restoreCredential(profile, role, previous);
      } else {
        await pterodactyl.removeCredential(profile, role);
      }
      rethrow;
    }
  }

  Future<void> _createRemoteInstance() => _createRemoteServers(many: false);

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
    final List<String> artifacts = isolated
        ? await _selectDropinArtifacts(
            'Copy artifacts into this isolated server',
          )
        : const <String>[];

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
      for (final String artifact in artifacts) ...<String>[
        '--artifact',
        artifact,
      ],
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

  Future<List<String>> _selectDropinArtifacts(String prompt) async {
    final String command = _isPluginConsumer() ? 'plugins' : 'mods';
    final String? source = await Ui.shielded(
      () => passthrough.captureStdoutLine(<String>[command, 'show-source']),
    );
    if (source == null || source.isEmpty) {
      Ui.warn(
        'Drop-ins folder could not be resolved; creating with no artifacts.',
      );
      return const <String>[];
    }

    final Directory directory = Directory(source);
    final List<String> artifacts =
        directory
            .listSync(recursive: false, followLinks: false)
            .where(
              (FileSystemEntity entity) =>
                  FileSystemEntity.typeSync(entity.path, followLinks: true) ==
                      FileSystemEntityType.file &&
                  entity.path.toLowerCase().endsWith('.jar'),
            )
            .map((FileSystemEntity entity) => p.basename(entity.path))
            .toList(growable: false)
          ..sort(
            (String left, String right) =>
                left.toLowerCase().compareTo(right.toLowerCase()),
          );
    if (artifacts.isEmpty) {
      Ui.note('No .jar artifacts are available in $source.');
      return const <String>[];
    }

    final Set<int> selected = await Ui.checklist(prompt, artifacts);
    return <String>[
      for (int index = 0; index < artifacts.length; index++)
        if (selected.contains(index)) artifacts[index],
    ];
  }

  Future<void> _copyDropinsIntoIsolated(String name) async {
    final List<String> artifacts = await _selectDropinArtifacts(
      'Copy drop-ins into $name',
    );
    if (artifacts.isEmpty) {
      Ui.note('No drop-ins selected.');
      await Ui.pause();
      return;
    }

    final String command = _isPluginConsumer() ? 'plugins' : 'mods';
    await _shellRun(<String>[
      command,
      'copy',
      name,
      for (final String artifact in artifacts) ...<String>[
        '--artifact',
        artifact,
      ],
    ]);
    await Ui.pause();
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
    final String value = input.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
      return false;
    }
    if (value.endsWith('.') || value.endsWith(' ')) {
      return false;
    }
    if (!Platform.isWindows) {
      return true;
    }
    final String stem = value.split('.').first.toUpperCase();
    return stem != 'CON' &&
        stem != 'PRN' &&
        stem != 'AUX' &&
        stem != 'NUL' &&
        !RegExp(r'^COM[1-9]$').hasMatch(stem) &&
        !RegExp(r'^LPT[1-9]$').hasMatch(stem);
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
