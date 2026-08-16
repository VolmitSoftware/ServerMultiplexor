import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pterodactyl_models.dart';
import 'pterodactyl_service.dart';
import 'pterodactyl_smb_service.dart';
import 'pterodactyl_transfer_files.dart';
import 'pterodactyl_transfer_link_store.dart';
import 'pterodactyl_transfer_models.dart';
import 'pterodactyl_transfer_path_policy.dart';

/// Shared Remote <-> Local transfer engine used by both CLI and dashboard.
///
/// Concrete transfer behavior is implemented below this public surface; all
/// mutating methods revalidate their plan token before changing either side.
final class PterodactylTransferService {
  factory PterodactylTransferService({
    required String metadataDirectoryPath,
    required PterodactylSmbService drive,
    required PterodactylService remote,
    required PterodactylLocalInstanceGateway localInstances,
    DateTime Function()? clock,
    Duration remoteReadyTimeout = const Duration(minutes: 5),
  }) => PterodactylTransferService.withGateways(
    metadataDirectoryPath: metadataDirectoryPath,
    remoteGateway: PterodactylDriveTransferGateway(
      drive: drive,
      remote: remote,
      readyTimeout: remoteReadyTimeout,
    ),
    localInstances: localInstances,
    clock: clock,
    remoteReadyTimeout: remoteReadyTimeout,
  );

  PterodactylTransferService.withGateways({
    required String metadataDirectoryPath,
    required PterodactylTransferRemoteGateway remoteGateway,
    required PterodactylLocalInstanceGateway localInstances,
    DateTime Function()? clock,
    Duration remoteReadyTimeout = const Duration(minutes: 5),
    Future<void> Function(Duration duration)? delay,
    PterodactylTransferFileEngine fileEngine =
        const PterodactylTransferFileEngine(),
    PterodactylTransferLinkStore linkStore =
        const PterodactylTransferLinkStore(),
  }) : _metadataDirectoryPath = metadataDirectoryPath,
       _remoteGateway = remoteGateway,
       _localInstances = localInstances,
       _clock = clock ?? DateTime.now,
       _remoteReadyTimeout = remoteReadyTimeout,
       _delay = delay ?? Future<void>.delayed,
       _fileEngine = fileEngine,
       _linkStore = linkStore;

  final String _metadataDirectoryPath;
  final PterodactylTransferRemoteGateway _remoteGateway;
  final PterodactylLocalInstanceGateway _localInstances;
  final DateTime Function() _clock;
  final Duration _remoteReadyTimeout;
  final Future<void> Function(Duration duration) _delay;
  final PterodactylTransferFileEngine _fileEngine;
  final PterodactylTransferLinkStore _linkStore;

  static const String _driveRaceWarning =
      'Close files for this server in Multiplexor Drive before transferring; '
      'another SFTP client can still change Remote files during the operation.';
  static const Duration _startOfflineAcceptanceGrace = Duration(seconds: 10);
  static final Set<String> _heldTransferLocks = <String>{};

  Future<PterodactylTransferPlan> planPull({
    required String profileId,
    required String serverIdentifier,
    required String localInstanceName,
  }) async {
    final String localName = _requiredName(
      localInstanceName,
      noun: 'local instance',
    );
    final String consumer = await _localInstances.currentConsumer();
    final PterodactylTransferRemoteTarget target = await _resolveStableTarget(
      profileId: _requiredName(profileId, noun: 'profile'),
      serverIdentifier: _requiredName(serverIdentifier, noun: 'remote server'),
      operation: 'Pull',
    );
    await _requireRemoteOffline(target, operation: 'Pull');
    _BackendSnapshot? snapshot;
    try {
      snapshot = await _captureBackend(target);
      await _recheckStableTarget(target, operation: 'Pull');
      await _requireRemoteOffline(target, operation: 'Pull');
      final List<PterodactylTransferChange> changes = _allAdds(
        snapshot.transferable,
      );
      return _plan(
        direction: PterodactylTransferDirection.pull,
        mode: PterodactylTransferMode.mirror,
        localInstanceName: localName,
        localConsumer: consumer,
        localInstancePath: '',
        target: target,
        targetExists: true,
        targetWasRunning: false,
        sourceFingerprint: snapshot.transferable.fingerprint,
        changes: changes,
        destination: null,
      );
    } finally {
      _deleteSnapshot(snapshot);
    }
  }

  Future<PterodactylTransferResult> pull({
    required String profileId,
    required String serverIdentifier,
    required String localInstanceName,
    String? expectedPlanToken,
  }) async {
    final PterodactylTransferPlan plan = await planPull(
      profileId: profileId,
      serverIdentifier: serverIdentifier,
      localInstanceName: localInstanceName,
    );
    _requireExpectedToken(expectedPlanToken, plan, optional: true);
    final PterodactylTransferRemoteTarget approved =
        PterodactylTransferRemoteTarget(
          profileId: plan.profileId,
          identifier: plan.serverIdentifier,
          uuid: plan.serverUuid,
          name: plan.remoteServerName,
        );
    final _TransferLockSet locks = _acquireTransferLocks(<String>[
      'local-name:${plan.localConsumer}:${plan.localInstanceName}',
      'remote:${plan.profileId}:${plan.serverUuid}',
    ]);
    PterodactylLocalInstance? local;
    PterodactylTransferBackendSession? backend;
    _BackendSnapshot? snapshot;
    try {
      final PterodactylTransferRemoteTarget target = await _recheckStableTarget(
        approved,
        operation: 'Pull',
      );
      await _requireRemoteOffline(target, operation: 'Pull');
      backend = await _remoteGateway.openBackend(target);
      snapshot = await _captureBackend(target, session: backend);
      await _recheckStableTarget(target, operation: 'Pull');
      await _requireRemoteOffline(target, operation: 'Pull');
      if (snapshot.transferable.fingerprint != plan.sourceFingerprint) {
        throw StateError(
          'Remote files changed after Pull preview. Review a new preview.',
        );
      }
      await backend.close();
      backend = null;
      local = await _localInstances.createStopped(
        plan.localInstanceName,
        consumer: plan.localConsumer,
      );
      _requireLocalIdentity(
        local,
        consumer: plan.localConsumer,
        expectedPath: null,
      );
      if (await _localInstances.isRunning(local)) {
        throw StateError('A pulled Local instance must remain stopped.');
      }
      final PterodactylTransferFileManifest localFiles =
          await _scanLocalTransfer(local);
      final List<PterodactylTransferChange> actualChanges = _fileEngine.diff(
        source: snapshot.transferable,
        target: localFiles,
        mode: PterodactylTransferMode.mirror,
      );
      await _fileEngine.apply(
        source: snapshot.transferable,
        targetRootPath: local.path,
        changes: actualChanges,
        mode: PterodactylTransferMode.mirror,
        operationId: _operationId(target),
        replaceDestinationLinks: true,
      );
      final List<String> warnings = <String>[];
      if (!_writeLaunchMetadata(local, target)) {
        warnings.add(
          'No safe server jar or unix_args.txt was found; choose the Local '
          'launch target before starting this instance.',
        );
      }
      final PterodactylRemoteLink link = _newLink(local: local, target: target);
      _linkStore.save(local.path, link);
      return PterodactylTransferResult(
        plan: plan,
        localInstance: local,
        link: link,
        remoteRestarted: false,
        linkPersisted: true,
        warnings: warnings,
      );
    } catch (error, stackTrace) {
      if (local != null) {
        try {
          await _localInstances.delete(local);
        } catch (deleteError) {
          throw StateError(
            'Pull failed and its incomplete Local instance could not be '
            'removed: $deleteError (original error: $error)',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _deleteSnapshot(snapshot);
      if (backend != null) await backend.close();
      locks.release();
    }
  }

  Future<PterodactylTransferPlan> planPush({
    required String localInstanceName,
    String? profileId,
    String? serverIdentifier,
    PterodactylTransferMode mode = PterodactylTransferMode.update,
  }) async {
    final String consumer = await _localInstances.currentConsumer();
    return _planPushForConsumer(
      localInstanceName: localInstanceName,
      consumer: consumer,
      profileId: profileId,
      serverIdentifier: serverIdentifier,
      mode: mode,
    );
  }

  Future<PterodactylTransferPlan> _planPushForConsumer({
    required String localInstanceName,
    required String consumer,
    required String? profileId,
    required String? serverIdentifier,
    required PterodactylTransferMode mode,
  }) async {
    final PterodactylLocalInstance local = await _localInstances.resolve(
      _requiredName(localInstanceName, noun: 'local instance'),
      consumer: consumer,
    );
    _requireLocalIdentity(local, consumer: consumer, expectedPath: null);
    if (await _localInstances.isRunning(local)) {
      throw StateError('Push requires Local ${local.name} to be stopped.');
    }
    final _TargetSelection selection = _resolveTargetSelection(
      local: local,
      profileId: profileId,
      serverIdentifier: serverIdentifier,
    );
    final PterodactylTransferRemoteTarget target = await _resolveStableTarget(
      profileId: selection.profileId,
      serverIdentifier: selection.serverIdentifier,
      expectedUuid: selection.expectedUuid,
      operation: 'Push',
    );
    final PterodactylTransferRemoteState remoteState = await _remoteGateway
        .state(target);
    if (remoteState != PterodactylTransferRemoteState.offline &&
        remoteState != PterodactylTransferRemoteState.running) {
      throw StateError(
        'Remote ${target.name} is ${remoteState.name}; wait until it is '
        'offline or running before Push.',
      );
    }
    final PterodactylTransferFileManifest source = await _scanLocalTransfer(
      local,
    );
    _BackendSnapshot? snapshot;
    try {
      snapshot = await _captureBackend(target);
      await _recheckStableTarget(target, operation: 'Push');
      final PterodactylTransferRemoteState afterState = await _remoteGateway
          .state(target);
      if (afterState != remoteState) {
        throw StateError(
          'Remote ${target.name} changed state during Push preview. Retry.',
        );
      }
      final List<PterodactylTransferChange> changes = _fileEngine.diff(
        source: source,
        target: snapshot.transferable,
        mode: mode,
      );
      return _plan(
        direction: PterodactylTransferDirection.push,
        mode: mode,
        localInstanceName: local.name,
        localConsumer: local.consumer,
        localInstancePath: _canonicalPath(local.path),
        target: target,
        targetExists: true,
        targetWasRunning: remoteState == PterodactylTransferRemoteState.running,
        sourceFingerprint: source.fingerprint,
        changes: changes,
        destination: snapshot.transferable,
      );
    } finally {
      _deleteSnapshot(snapshot);
    }
  }

  Future<PterodactylTransferPlan> planNewPush({
    required String localInstanceName,
    required String profileId,
    required String proposedServerName,
  }) async {
    final String consumer = await _localInstances.currentConsumer();
    final PterodactylLocalInstance local = await _localInstances.resolve(
      _requiredName(localInstanceName, noun: 'local instance'),
      consumer: consumer,
    );
    _requireLocalIdentity(local, consumer: consumer, expectedPath: null);
    if (await _localInstances.isRunning(local)) {
      throw StateError('Push requires Local ${local.name} to be stopped.');
    }
    final String normalizedProfile = _requiredName(profileId, noun: 'profile');
    final String proposedName = _requiredName(
      proposedServerName,
      noun: 'new remote server',
    );
    final PterodactylTransferFileManifest source = await _scanLocalTransfer(
      local,
    );
    final List<PterodactylTransferChange> changes = _allAdds(source);
    final PterodactylTransferRemoteTarget proposedTarget =
        PterodactylTransferRemoteTarget(
          profileId: normalizedProfile,
          identifier: proposedName,
          uuid: '',
          name: proposedName,
        );
    return _plan(
      direction: PterodactylTransferDirection.push,
      mode: PterodactylTransferMode.update,
      localInstanceName: local.name,
      localConsumer: local.consumer,
      localInstancePath: _canonicalPath(local.path),
      target: proposedTarget,
      targetExists: false,
      targetWasRunning: false,
      sourceFingerprint: source.fingerprint,
      changes: changes,
      destination: null,
    );
  }

  Future<PterodactylTransferResult> push({
    required String localInstanceName,
    String? profileId,
    String? serverIdentifier,
    PterodactylTransferMode mode = PterodactylTransferMode.update,
    required String expectedPlanToken,
    bool relink = false,
    bool restorePreviousRunningState = true,
    bool startIfStopped = false,
  }) async {
    final PterodactylTransferPlan plan = await planPush(
      localInstanceName: localInstanceName,
      profileId: profileId,
      serverIdentifier: serverIdentifier,
      mode: mode,
    );
    _requireExpectedToken(expectedPlanToken, plan);
    return _executePush(
      initialPlan: plan,
      relink: relink,
      restorePreviousRunningState: restorePreviousRunningState,
      startIfStopped: startIfStopped,
      newTarget: false,
    );
  }

  Future<PterodactylTransferResult> pushNew({
    required PterodactylTransferPlan plan,
    required String createdServerIdentifier,
    bool relink = true,
    bool startAfter = false,
  }) async {
    if (plan.direction != PterodactylTransferDirection.push ||
        plan.targetExists ||
        plan.mode != PterodactylTransferMode.update) {
      throw ArgumentError('pushNew requires an approved planNewPush plan.');
    }
    final PterodactylLocalInstance approvedLocal = await _localInstances
        .resolve(plan.localInstanceName, consumer: plan.localConsumer);
    _requireLocalIdentity(
      approvedLocal,
      consumer: plan.localConsumer,
      expectedPath: plan.localInstancePath,
    );
    if (await _localInstances.isRunning(approvedLocal)) {
      throw StateError(
        'Push requires Local ${approvedLocal.name} to be stopped.',
      );
    }
    final PterodactylTransferFileManifest approvedSource =
        await _scanLocalTransfer(approvedLocal);
    final PterodactylTransferRemoteTarget proposedTarget =
        PterodactylTransferRemoteTarget(
          profileId: plan.profileId,
          identifier: plan.serverIdentifier,
          uuid: '',
          name: plan.remoteServerName,
        );
    final PterodactylTransferPlan currentSourcePlan = _plan(
      direction: PterodactylTransferDirection.push,
      mode: PterodactylTransferMode.update,
      localInstanceName: approvedLocal.name,
      localConsumer: approvedLocal.consumer,
      localInstancePath: _canonicalPath(approvedLocal.path),
      target: proposedTarget,
      targetExists: false,
      targetWasRunning: false,
      sourceFingerprint: approvedSource.fingerprint,
      changes: _allAdds(approvedSource),
      destination: null,
    );
    if (currentSourcePlan.confirmationToken != plan.confirmationToken) {
      throw StateError(
        'Local files changed after Create & Push confirmation. The new '
        'Remote server was left stopped; review a new preview.',
      );
    }
    final PterodactylTransferRemoteTarget target = await waitForNewTargetReady(
      profileId: plan.profileId,
      serverIdentifier: createdServerIdentifier,
    );
    final PterodactylLocalInstance readyLocal = await _localInstances.resolve(
      plan.localInstanceName,
      consumer: plan.localConsumer,
    );
    _requireLocalIdentity(
      readyLocal,
      consumer: plan.localConsumer,
      expectedPath: plan.localInstancePath,
    );
    if (await _localInstances.isRunning(readyLocal) ||
        (await _scanLocalTransfer(readyLocal)).fingerprint !=
            plan.sourceFingerprint) {
      throw StateError(
        'Local files or runtime changed while the new Remote server was '
        'installing. It was left stopped; review a new preview.',
      );
    }
    final PterodactylTransferPlan actualPlan = await _planPushForConsumer(
      localInstanceName: plan.localInstanceName,
      consumer: plan.localConsumer,
      profileId: target.profileId,
      serverIdentifier: target.identifier,
      mode: PterodactylTransferMode.update,
    );
    return _executePush(
      initialPlan: actualPlan,
      relink: relink,
      restorePreviousRunningState: false,
      startIfStopped: startAfter,
      newTarget: true,
      approvedSourceFingerprint: plan.sourceFingerprint,
    );
  }

  /// Repairs only the durable-link and requested-running postconditions of a
  /// previously committed Create & Push. Remote files are never opened or
  /// mutated by this operation.
  Future<PterodactylTransferResult> repairNewPushPostconditions({
    required PterodactylTransferPlan plan,
    required String createdServerIdentifier,
    bool relink = true,
    bool startAfter = false,
  }) async {
    if (plan.direction != PterodactylTransferDirection.push ||
        plan.targetExists ||
        plan.mode != PterodactylTransferMode.update) {
      throw ArgumentError(
        'repairNewPushPostconditions requires an approved planNewPush plan.',
      );
    }
    final PterodactylLocalInstance local = await _localInstances.resolve(
      plan.localInstanceName,
      consumer: plan.localConsumer,
    );
    _requireLocalIdentity(
      local,
      consumer: plan.localConsumer,
      expectedPath: plan.localInstancePath,
    );
    if (await _localInstances.isRunning(local)) {
      throw StateError(
        'Postcondition repair requires Local ${local.name} to remain stopped.',
      );
    }
    final PterodactylTransferFileManifest source = await _scanLocalTransfer(
      local,
    );
    _requireApprovedNewPushSource(plan, local, source);

    final PterodactylTransferRemoteTarget resolved = await _resolveStableTarget(
      profileId: plan.profileId,
      serverIdentifier: _requiredName(
        createdServerIdentifier,
        noun: 'created remote server',
      ),
      operation: 'Create & Push postcondition repair',
    );
    if (resolved.name != plan.remoteServerName) {
      throw StateError(
        'Created Remote identity does not match the approved server name.',
      );
    }
    final _TransferLockSet locks = _acquireTransferLocks(<String>[
      'local:${local.consumer}:${_canonicalPath(local.path)}',
      'remote:${resolved.profileId}:${resolved.uuid}',
    ]);
    try {
      final PterodactylLocalInstance lockedLocal = await _localInstances
          .resolve(local.name, consumer: plan.localConsumer);
      _requireLocalIdentity(
        lockedLocal,
        consumer: plan.localConsumer,
        expectedPath: plan.localInstancePath,
      );
      if (await _localInstances.isRunning(lockedLocal)) {
        throw StateError(
          'Local ${lockedLocal.name} started during postcondition repair.',
        );
      }
      final PterodactylTransferFileManifest lockedSource =
          await _scanLocalTransfer(lockedLocal);
      _requireApprovedNewPushSource(plan, lockedLocal, lockedSource);
      final PterodactylTransferRemoteTarget target = await _recheckStableTarget(
        resolved,
        operation: 'Create & Push postcondition repair',
      );
      if (target.name != plan.remoteServerName) {
        throw StateError(
          'Created Remote identity changed during postcondition repair.',
        );
      }
      final PterodactylTransferRemoteState state = await _remoteGateway.state(
        target,
      );
      if (state != PterodactylTransferRemoteState.offline &&
          state != PterodactylTransferRemoteState.running &&
          !(startAfter &&
              (state == PterodactylTransferRemoteState.starting ||
                  state == PterodactylTransferRemoteState.stopping))) {
        throw StateError(
          'Remote ${target.name} is ${state.name}; postcondition repair '
          'cannot safely continue yet.',
        );
      }

      final List<String> warnings = <String>[];
      PterodactylRemoteLink link = _newLink(local: lockedLocal, target: target);
      bool linkPersisted = false;
      try {
        link = _linkForTarget(local: lockedLocal, target: target);
        linkPersisted = _persistLinkIfNeeded(
          local: lockedLocal,
          target: target,
          link: link,
          relink: relink,
        );
      } catch (error) {
        warnings.add('The Local Remote link could not be repaired: $error');
      }
      final bool runningPostcondition = await _finishRuntimeState(
        target,
        shouldStart: startAfter,
        warnings: warnings,
      );
      return PterodactylTransferResult(
        plan: plan,
        localInstance: lockedLocal,
        link: link,
        remoteRestarted: runningPostcondition,
        linkPersisted: linkPersisted,
        warnings: warnings,
      );
    } finally {
      locks.release();
    }
  }

  void _requireApprovedNewPushSource(
    PterodactylTransferPlan approved,
    PterodactylLocalInstance local,
    PterodactylTransferFileManifest source,
  ) {
    final PterodactylTransferPlan current = _plan(
      direction: PterodactylTransferDirection.push,
      mode: PterodactylTransferMode.update,
      localInstanceName: local.name,
      localConsumer: local.consumer,
      localInstancePath: _canonicalPath(local.path),
      target: PterodactylTransferRemoteTarget(
        profileId: approved.profileId,
        identifier: approved.serverIdentifier,
        uuid: '',
        name: approved.remoteServerName,
      ),
      targetExists: false,
      targetWasRunning: false,
      sourceFingerprint: source.fingerprint,
      changes: _allAdds(source),
      destination: null,
    );
    if (source.fingerprint != approved.sourceFingerprint ||
        current.confirmationToken != approved.confirmationToken) {
      throw StateError(
        'Local files changed after Create & Push confirmation; '
        'postconditions were not changed.',
      );
    }
  }

  Future<PterodactylRemoteLink?> linkForLocalInstance(String name) async {
    final PterodactylLocalInstance local = await _localInstances.resolve(
      _requiredName(name, noun: 'local instance'),
      consumer: await _localInstances.currentConsumer(),
    );
    final PterodactylRemoteLink? link = _linkStore.load(local.path);
    if (link == null) return null;
    if (link.localInstanceName != local.name ||
        link.localConsumer != local.consumer) {
      throw StateError(
        'Remote link identity does not match this Local instance.',
      );
    }
    return link;
  }

  Future<PterodactylTransferResult> _executePush({
    required PterodactylTransferPlan initialPlan,
    required bool relink,
    required bool restorePreviousRunningState,
    required bool startIfStopped,
    required bool newTarget,
    String? approvedSourceFingerprint,
  }) async {
    final PterodactylLocalInstance local = await _localInstances.resolve(
      initialPlan.localInstanceName,
      consumer: initialPlan.localConsumer,
    );
    _requireLocalIdentity(
      local,
      consumer: initialPlan.localConsumer,
      expectedPath: initialPlan.localInstancePath,
    );
    if (await _localInstances.isRunning(local)) {
      throw StateError('Push requires Local ${local.name} to remain stopped.');
    }
    final PterodactylTransferFileManifest source = await _scanLocalTransfer(
      local,
    );
    if (source.fingerprint != initialPlan.sourceFingerprint) {
      throw StateError(
        'Local files changed after Push preview. Review a new preview.',
      );
    }
    if (approvedSourceFingerprint != null &&
        source.fingerprint != approvedSourceFingerprint) {
      throw StateError(
        'Local files changed after Create & Push confirmation. The new '
        'Remote server was left stopped.',
      );
    }
    final PterodactylTransferRemoteTarget approved =
        PterodactylTransferRemoteTarget(
          profileId: initialPlan.profileId,
          identifier: initialPlan.serverIdentifier,
          uuid: initialPlan.serverUuid,
          name: initialPlan.remoteServerName,
        );
    final _TransferLockSet locks = _acquireTransferLocks(<String>[
      'local:${local.consumer}:${_canonicalPath(local.path)}',
      'remote:${approved.profileId}:${approved.uuid}',
    ]);
    PterodactylTransferBackendSession? backend;
    _BackendSnapshot? authoritativeSnapshot;
    _BackendSnapshot? preApplySnapshot;
    _BackendSnapshot? verificationSnapshot;
    Directory? stage;
    _TransferBackup? backup;
    bool remoteMutationStarted = false;
    bool committed = false;
    bool wasRunning = false;
    final List<String> cleanupWarnings = <String>[];
    late PterodactylTransferRemoteTarget target;
    late PterodactylTransferPlan authoritativePlan;
    try {
      final PterodactylLocalInstance lockedLocal = await _localInstances
          .resolve(local.name, consumer: initialPlan.localConsumer);
      _requireLocalIdentity(
        lockedLocal,
        consumer: initialPlan.localConsumer,
        expectedPath: initialPlan.localInstancePath,
      );
      if (await _localInstances.isRunning(lockedLocal)) {
        throw StateError(
          'Push requires Local ${local.name} to remain stopped.',
        );
      }
      final PterodactylTransferFileManifest lockedSource =
          await _scanLocalTransfer(lockedLocal);
      if (lockedSource.fingerprint != source.fingerprint) {
        throw StateError(
          'Local files changed while Push was acquiring its lock.',
        );
      }
      if (approvedSourceFingerprint != null &&
          lockedSource.fingerprint != approvedSourceFingerprint) {
        throw StateError(
          'Local files changed after Create & Push confirmation. The new '
          'Remote server was left stopped.',
        );
      }
      target = await _recheckStableTarget(approved, operation: 'Push');
      final PterodactylTransferRemoteState beforeState = await _remoteGateway
          .state(target);
      wasRunning = beforeState == PterodactylTransferRemoteState.running;
      if (newTarget &&
          !wasRunning &&
          beforeState != PterodactylTransferRemoteState.offline) {
        throw StateError(
          'New Remote ${target.name} must remain offline until Push finishes.',
        );
      }
      if (newTarget && wasRunning) {
        throw StateError(
          'New Remote ${target.name} started before Push. It was left running.',
        );
      }
      if (!wasRunning &&
          beforeState != PterodactylTransferRemoteState.offline) {
        throw StateError(
          'Remote ${target.name} is ${beforeState.name}; Push was not started.',
        );
      }

      if (initialPlan.isNoop) {
        backend = await _remoteGateway.openBackend(target);
        authoritativeSnapshot = await _captureBackend(target, session: backend);
        await _recheckStableTarget(target, operation: 'Push');
        if (await _remoteGateway.state(target) != beforeState) {
          throw StateError('Remote state changed during Push verification.');
        }
        authoritativePlan = _planFromManifests(
          initialPlan: initialPlan,
          local: local,
          target: target,
          source: source,
          destination: authoritativeSnapshot.transferable,
          targetWasRunning: wasRunning,
        );
        _requireAuthoritativePlan(initialPlan, authoritativePlan);
        if (authoritativePlan.isNoop) {
          await backend.close();
          backend = null;
          final List<String> warnings = <String>[];
          final bool started = await _finishRuntimeState(
            target,
            shouldStart: startIfStopped && !wasRunning,
            warnings: warnings,
          );
          final PterodactylRemoteLink link = _linkForTarget(
            local: local,
            target: target,
          );
          final bool linkPersisted = _persistLinkIfNeeded(
            local: local,
            target: target,
            link: link,
            relink: relink,
          );
          return PterodactylTransferResult(
            plan: authoritativePlan,
            localInstance: local,
            link: link,
            remoteRestarted: started,
            linkPersisted: linkPersisted,
            warnings: warnings,
          );
        }
      }

      if (wasRunning) {
        await _remoteGateway.stop(target);
        await _waitUntilOffline(target);
      }
      target = await _recheckStableTarget(target, operation: 'Push');
      await _requireRemoteOffline(target, operation: 'Push');
      backend ??= await _remoteGateway.openBackend(target);
      _deleteSnapshot(authoritativeSnapshot);
      authoritativeSnapshot = await _captureBackend(target, session: backend);
      target = await _recheckStableTarget(target, operation: 'Push');
      await _requireRemoteOffline(target, operation: 'Push');
      authoritativePlan = _planFromManifests(
        initialPlan: initialPlan,
        local: local,
        target: target,
        source: source,
        destination: authoritativeSnapshot.transferable,
        targetWasRunning: wasRunning,
      );
      _requireAuthoritativePlan(initialPlan, authoritativePlan);
      if (authoritativePlan.isNoop) {
        await backend.close();
        backend = null;
        final List<String> warnings = <String>[];
        final bool started = await _finishRuntimeState(
          target,
          shouldStart:
              startIfStopped || wasRunning && restorePreviousRunningState,
          warnings: warnings,
        );
        final PterodactylRemoteLink link = _linkForTarget(
          local: local,
          target: target,
        );
        final bool linkPersisted = _persistLinkIfNeeded(
          local: local,
          target: target,
          link: link,
          relink: relink,
        );
        return PterodactylTransferResult(
          plan: authoritativePlan,
          localInstance: local,
          link: link,
          remoteRestarted: started,
          linkPersisted: linkPersisted,
          warnings: warnings,
        );
      }

      final String operationId = _operationId(target);
      backup = await _createBackupFromSnapshot(
        target: target,
        snapshot: authoritativeSnapshot,
        operationId: operationId,
      );
      stage = await _stageTransferSource(source, operationId: operationId);

      await _recheckLocalBeforeApply(local, initialPlan, source.fingerprint);
      target = await _recheckStableTarget(target, operation: 'Push');
      await _requireRemoteOffline(target, operation: 'Push');
      preApplySnapshot = await _captureBackend(target, session: backend);
      if (preApplySnapshot.full.fingerprint !=
          authoritativeSnapshot.full.fingerprint) {
        throw StateError(
          'Remote files changed after backup and before Push. No files were '
          'uploaded; review a new preview.',
        );
      }
      await _recheckLocalBeforeApply(local, initialPlan, source.fingerprint);
      target = await _recheckStableTarget(target, operation: 'Push');
      await _requireRemoteOffline(target, operation: 'Push');

      remoteMutationStarted = true;
      await backend.applyFrom(
        sourcePath: stage.path,
        mode: authoritativePlan.mode,
      );
      target = await _recheckStableTarget(target, operation: 'Push');
      await _requireRemoteOffline(target, operation: 'Push');
      verificationSnapshot = await _captureBackend(target, session: backend);
      _verifyAppliedTransfer(
        source: source,
        remote: verificationSnapshot.transferable,
        mode: authoritativePlan.mode,
      );
      target = await _recheckStableTarget(target, operation: 'Push commit');
      await _requireRemoteOffline(target, operation: 'Push commit');
      _writeRecoveryManifest(backup, status: 'completed');
      target = await _recheckStableTarget(target, operation: 'Push commit');
      await _requireRemoteOffline(target, operation: 'Push commit');
      committed = true;
    } catch (error, stackTrace) {
      if (remoteMutationStarted &&
          !committed &&
          backup != null &&
          backend != null) {
        Object? rollbackFailure;
        try {
          target = await _prepareRemoteForRollback(target);
          await backend.restoreFrom(backup.backupPath);
          target = await _prepareRemoteForRollback(target);
          _deleteSnapshot(verificationSnapshot);
          verificationSnapshot = await _captureBackend(
            target,
            session: backend,
          );
          final PterodactylTransferRemoteState verificationState =
              await _remoteGateway.state(target);
          if (verificationState != PterodactylTransferRemoteState.offline) {
            target = await _prepareRemoteForRollback(target);
            _deleteSnapshot(verificationSnapshot);
            verificationSnapshot = await _captureBackend(
              target,
              session: backend,
            );
          }
          target = await _recheckStableTarget(
            target,
            operation: 'Push rollback verification',
          );
          await _requireRemoteOffline(
            target,
            operation: 'Push rollback verification',
          );
          if (verificationSnapshot.full.fingerprint != backup.fingerprint) {
            throw StateError(
              'Remote rollback verification did not match backup.',
            );
          }
          target = await _recheckStableTarget(
            target,
            operation: 'Push rollback commit',
          );
          await _requireRemoteOffline(
            target,
            operation: 'Push rollback commit',
          );
        } catch (rollbackError) {
          rollbackFailure = rollbackError;
        }
        if (rollbackFailure == null) {
          String? manifestWarning;
          try {
            _writeRecoveryManifest(
              backup,
              status: 'rolled_back',
              failure: '$error',
            );
          } catch (manifestError) {
            manifestWarning = '$manifestError';
          }
          try {
            await backend.close();
          } catch (closeError) {
            final String closeWarning =
                'Direct backend cleanup failed after verified rollback: '
                '$closeError';
            manifestWarning = manifestWarning == null
                ? closeWarning
                : '$manifestWarning; $closeWarning';
          } finally {
            backend = null;
          }
          String? runtimeFailure;
          if (wasRunning) {
            try {
              await _restorePriorRunningState(target);
            } catch (restoreError) {
              runtimeFailure = '$restoreError';
            }
          }
          if (manifestWarning != null || runtimeFailure != null) {
            throw StateError(
              'Push failed, Remote rollback was verified'
              '${runtimeFailure == null ? '' : ', but runtime restoration failed: $runtimeFailure'}'
              '${manifestWarning == null ? '' : '. Recovery metadata warning: $manifestWarning'}'
              '. Original failure: $error',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
        bool recoveryOffline = false;
        try {
          target = await _prepareRemoteForRollback(target);
          recoveryOffline = true;
        } catch (_) {
          // Keep the original rollback failure and report unknown live state.
        }
        try {
          _writeRecoveryManifest(
            backup,
            status: 'rollback_failed',
            failure: '$error',
            rollbackFailure: '$rollbackFailure',
          );
        } catch (_) {
          // Preserve the actual Remote recovery failure.
        }
        throw StateError(
          'Push failed and automatic rollback verification also failed. '
          '${recoveryOffline ? 'Remote was left stopped.' : 'Remote runtime state could not be verified.'} '
          'Recovery manifest: '
          '${backup.recoveryManifestPath}. Original failure: $error. '
          'Rollback failure: $rollbackFailure',
        );
      }
      if (wasRunning) {
        try {
          await _restorePriorRunningState(target);
        } catch (restoreError) {
          throw StateError(
            'Push failed before upload, and prior Remote runtime restoration '
            'could not be verified: $restoreError. Original failure: $error',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _cleanupSnapshot(authoritativeSnapshot, cleanupWarnings);
      _cleanupSnapshot(preApplySnapshot, cleanupWarnings);
      _cleanupSnapshot(verificationSnapshot, cleanupWarnings);
      if (stage != null) {
        _cleanupPrivateDirectory(stage, cleanupWarnings, noun: 'staging');
      }
      if (backend != null) {
        try {
          await backend.close();
        } catch (error) {
          cleanupWarnings.add('Direct backend cleanup failed: $error');
        }
      }
      if (!committed) {
        locks.release();
      }
    }

    try {
      final List<String> warnings = <String>[...cleanupWarnings];
      PterodactylRemoteLink link = _newLink(local: local, target: target);
      bool linkPersisted = false;
      try {
        link = _linkForTarget(local: local, target: target);
        linkPersisted = _persistLinkIfNeeded(
          local: local,
          target: target,
          link: link,
          relink: relink,
        );
      } catch (error) {
        warnings.add(
          'Remote files were committed, but the Local link could not be '
          'saved: $error',
        );
      }
      final bool restarted = await _finishRuntimeState(
        target,
        shouldStart:
            startIfStopped || wasRunning && restorePreviousRunningState,
        warnings: warnings,
      );
      return PterodactylTransferResult(
        plan: authoritativePlan,
        localInstance: local,
        link: link,
        backupPath: backup.backupPath,
        recoveryManifestPath: backup.recoveryManifestPath,
        remoteRestarted: restarted,
        linkPersisted: linkPersisted,
        warnings: warnings,
      );
    } finally {
      locks.release();
    }
  }

  Future<PterodactylTransferRemoteTarget> waitForNewTargetReady({
    required String profileId,
    required String serverIdentifier,
  }) async {
    final int attempts = _pollAttempts(_remoteReadyTimeout);
    Object? lastError;
    for (int attempt = 0; attempt < attempts; attempt++) {
      try {
        final PterodactylTransferRemoteTarget target = await _remoteGateway
            .resolveTarget(
              profileId: profileId,
              serverIdentifier: serverIdentifier,
            );
        final String installStatus = _normalizedInstallStatus(target);
        if (installStatus == 'install_failed' || installStatus == 'suspended') {
          throw StateError(
            'New Remote ${target.name} is $installStatus and cannot receive '
            'files.',
          );
        }
        if (target.nodeUnderMaintenance) {
          throw StateError(
            'New Remote ${target.name} is on a node under maintenance.',
          );
        }
        if (installStatus.isEmpty || installStatus == 'installed') {
          final PterodactylTransferRemoteState current = await _remoteGateway
              .state(target);
          if (current == PterodactylTransferRemoteState.running ||
              current == PterodactylTransferRemoteState.starting) {
            throw StateError(
              'New Remote ${target.name} started before its files were pushed.',
            );
          }
          if (current == PterodactylTransferRemoteState.offline) {
            return _recheckStableTarget(target, operation: 'Create & Push');
          }
        }
      } catch (error) {
        if (error is StateError &&
            ('$error'.contains('cannot receive files') ||
                '$error'.contains('started before') ||
                '$error'.contains('under maintenance'))) {
          rethrow;
        }
        lastError = error;
      }
      if (attempt + 1 < attempts) {
        await _delay(const Duration(milliseconds: 500));
      }
    }
    throw StateError(
      'New Remote server did not finish installing and become offline within '
      '${_remoteReadyTimeout.inMinutes} minute(s)'
      '${lastError == null ? '.' : ': $lastError'}',
    );
  }

  Future<void> _waitUntilOffline(PterodactylTransferRemoteTarget target) async {
    final int attempts = _pollAttempts(_remoteReadyTimeout);
    for (int attempt = 0; attempt < attempts; attempt++) {
      if (await _remoteGateway.state(target) ==
          PterodactylTransferRemoteState.offline) {
        return;
      }
      if (attempt + 1 < attempts) {
        await _delay(const Duration(milliseconds: 500));
      }
    }
    throw StateError(
      'Remote ${target.name} did not stop within '
      '${_remoteReadyTimeout.inMinutes} minute(s).',
    );
  }

  Future<void> _restorePriorRunningState(
    PterodactylTransferRemoteTarget target,
  ) async {
    PterodactylTransferRemoteState current = await _remoteGateway.state(target);
    final int attempts = _pollAttempts(_remoteReadyTimeout);
    for (
      int attempt = 0;
      attempt < attempts &&
          (current == PterodactylTransferRemoteState.stopping ||
              current == PterodactylTransferRemoteState.starting);
      attempt++
    ) {
      if (attempt + 1 < attempts) {
        await _delay(const Duration(milliseconds: 500));
      }
      current = await _remoteGateway.state(target);
    }
    if (current == PterodactylTransferRemoteState.running) return;
    if (current != PterodactylTransferRemoteState.offline) {
      throw StateError(
        'Remote ${target.name} never reached a safe state for restart '
        '(last state: ${current.name}).',
      );
    }
    await _remoteGateway.start(target);
    await _waitUntilRunning(target);
  }

  Future<void> _waitUntilRunning(PterodactylTransferRemoteTarget target) async {
    final int attempts = _pollAttempts(_remoteReadyTimeout);
    final int graceAttempts = _pollAttempts(_startOfflineAcceptanceGrace);
    final int offlineAcceptanceAttempts = graceAttempts < attempts
        ? graceAttempts
        : attempts;
    PterodactylTransferRemoteState current =
        PterodactylTransferRemoteState.unknown;
    bool observedStarting = false;
    for (int attempt = 0; attempt < attempts; attempt++) {
      current = await _remoteGateway.state(target);
      if (current == PterodactylTransferRemoteState.running) return;
      if (current == PterodactylTransferRemoteState.starting) {
        observedStarting = true;
      } else if (current == PterodactylTransferRemoteState.offline &&
          (observedStarting || attempt + 1 >= offlineAcceptanceAttempts)) {
        if (observedStarting) {
          throw StateError(
            'Remote ${target.name} returned offline after reporting starting.',
          );
        }
        break;
      }
      if (attempt + 1 < attempts) {
        await _delay(const Duration(milliseconds: 500));
      }
    }
    throw StateError(
      'Remote ${target.name} did not reach running state '
      '(last state: ${current.name}).',
    );
  }

  Future<bool> _finishRuntimeState(
    PterodactylTransferRemoteTarget target, {
    required bool shouldStart,
    required List<String> warnings,
  }) async {
    if (!shouldStart) return false;
    try {
      await _restorePriorRunningState(target);
      return true;
    } catch (error) {
      warnings.add(
        'Transfer succeeded, but Remote ${target.name} did not reach running '
        'state: $error',
      );
      return false;
    }
  }

  Future<PterodactylTransferRemoteTarget> _prepareRemoteForRollback(
    PterodactylTransferRemoteTarget approved,
  ) async {
    final PterodactylTransferRemoteTarget target = await _recheckStableTarget(
      approved,
      operation: 'Push rollback',
    );
    final PterodactylTransferRemoteState state = await _remoteGateway.state(
      target,
    );
    if (state == PterodactylTransferRemoteState.running ||
        state == PterodactylTransferRemoteState.starting) {
      await _remoteGateway.stop(target);
      await _waitUntilOffline(target);
    } else if (state == PterodactylTransferRemoteState.stopping) {
      await _waitUntilOffline(target);
    } else if (state != PterodactylTransferRemoteState.offline) {
      throw StateError(
        'Remote ${target.name} entered ${state.name}; rollback cannot safely '
        'overwrite its files.',
      );
    }
    await _requireRemoteOffline(target, operation: 'Push rollback');
    return target;
  }

  int _pollAttempts(Duration timeout) {
    final int milliseconds = timeout.inMilliseconds;
    if (milliseconds <= 0) return 1;
    return (milliseconds / 500).ceil() + 1;
  }

  Future<PterodactylTransferRemoteTarget> _resolveStableTarget({
    required String profileId,
    required String serverIdentifier,
    String? expectedUuid,
    required String operation,
  }) async {
    final PterodactylTransferRemoteTarget target = await _remoteGateway
        .resolveTarget(
          profileId: profileId,
          serverIdentifier: serverIdentifier,
        );
    if (expectedUuid != null &&
        expectedUuid.isNotEmpty &&
        target.uuid != expectedUuid) {
      throw StateError(
        '$operation target identity changed: the saved Remote UUID no longer '
        'matches this server. Choose the target explicitly to relink.',
      );
    }
    _requireStableTarget(target, operation: operation);
    return target;
  }

  Future<PterodactylTransferRemoteTarget> _recheckStableTarget(
    PterodactylTransferRemoteTarget approved, {
    required String operation,
  }) async {
    final PterodactylTransferRemoteTarget current = await _resolveStableTarget(
      profileId: approved.profileId,
      serverIdentifier: approved.identifier,
      expectedUuid: approved.uuid,
      operation: operation,
    );
    if (current.identifier.toLowerCase() != approved.identifier.toLowerCase()) {
      throw StateError('$operation target identifier changed.');
    }
    return current;
  }

  void _requireStableTarget(
    PterodactylTransferRemoteTarget target, {
    required String operation,
  }) {
    if (target.nodeUnderMaintenance) {
      throw StateError(
        '$operation is unavailable while Remote ${target.name} is on a node '
        'under maintenance.',
      );
    }
    final String status = _normalizedInstallStatus(target);
    if (status.isEmpty || status == 'installed') return;
    throw StateError(
      '$operation requires a stable installed Remote target; '
      '${target.name} is $status.',
    );
  }

  String _normalizedInstallStatus(PterodactylTransferRemoteTarget target) =>
      (target.installStatus ?? '').trim().toLowerCase();

  Future<void> _requireRemoteOffline(
    PterodactylTransferRemoteTarget target, {
    required String operation,
  }) async {
    final PterodactylTransferRemoteState state = await _remoteGateway.state(
      target,
    );
    if (state != PterodactylTransferRemoteState.offline) {
      throw StateError(
        '$operation requires Remote ${target.name} to be offline; it is '
        '${state.name}.',
      );
    }
  }

  String _canonicalPath(String path) =>
      Directory(p.normalize(p.absolute(path))).resolveSymbolicLinksSync();

  void _requireLocalIdentity(
    PterodactylLocalInstance local, {
    required String consumer,
    required String? expectedPath,
  }) {
    if (local.consumer != consumer) {
      throw StateError(
        'Local consumer changed from $consumer to ${local.consumer}.',
      );
    }
    if (expectedPath != null &&
        expectedPath.isNotEmpty &&
        !p.equals(_canonicalPath(local.path), expectedPath)) {
      throw StateError(
        'Local instance identity changed after transfer preview.',
      );
    }
  }

  Future<void> _recheckLocalBeforeApply(
    PterodactylLocalInstance approved,
    PterodactylTransferPlan plan,
    String fingerprint,
  ) async {
    final PterodactylLocalInstance current = await _localInstances.resolve(
      approved.name,
      consumer: plan.localConsumer,
    );
    _requireLocalIdentity(
      current,
      consumer: plan.localConsumer,
      expectedPath: plan.localInstancePath,
    );
    if (await _localInstances.isRunning(current)) {
      throw StateError(
        'Local ${current.name} started while Push was preparing.',
      );
    }
    if ((await _scanLocalTransfer(current)).fingerprint != fingerprint) {
      throw StateError(
        'Local files changed while Push was preparing. Review a new preview.',
      );
    }
  }

  List<PterodactylTransferChange> _allAdds(
    PterodactylTransferFileManifest source,
  ) => _fileEngine.diff(
    source: source,
    target: PterodactylTransferFileManifest(
      rootPath: '',
      files: const <String, PterodactylTransferFileEntry>{},
      directories: const <String>{},
      excludedContentDirectories: const <String>{},
    ),
    mode: PterodactylTransferMode.update,
  );

  PterodactylTransferPlan _planFromManifests({
    required PterodactylTransferPlan initialPlan,
    required PterodactylLocalInstance local,
    required PterodactylTransferRemoteTarget target,
    required PterodactylTransferFileManifest source,
    required PterodactylTransferFileManifest destination,
    required bool targetWasRunning,
  }) => _plan(
    direction: PterodactylTransferDirection.push,
    mode: initialPlan.mode,
    localInstanceName: local.name,
    localConsumer: local.consumer,
    localInstancePath: _canonicalPath(local.path),
    target: target,
    targetExists: true,
    targetWasRunning: targetWasRunning,
    sourceFingerprint: source.fingerprint,
    changes: _fileEngine.diff(
      source: source,
      target: destination,
      mode: initialPlan.mode,
    ),
    destination: destination,
  );

  void _requireAuthoritativePlan(
    PterodactylTransferPlan approved,
    PterodactylTransferPlan authoritative,
  ) {
    if (approved.sourceFingerprint != authoritative.sourceFingerprint ||
        approved.confirmationToken != authoritative.confirmationToken) {
      throw StateError(
        'The overwrite/delete scope covered by the Push preview changed. '
        'No Remote files were uploaded; review a new preview.',
      );
    }
  }

  Future<Directory> _stageTransferSource(
    PterodactylTransferFileManifest source, {
    required String operationId,
  }) async {
    final Directory stage = _createPrivateTempDirectory('stage-');
    try {
      final PterodactylTransferFileManifest empty = await _fileEngine.scan(
        stage.path,
        allowSymlinks: false,
      );
      await _fileEngine.apply(
        source: source,
        targetRootPath: stage.path,
        changes: _fileEngine.diff(
          source: source,
          target: empty,
          mode: PterodactylTransferMode.update,
        ),
        mode: PterodactylTransferMode.update,
        operationId: '$operationId-stage',
      );
      _hardenPrivateTree(stage.path);
      if ((await _scanRemoteTransfer(stage.path)).fingerprint !=
          source.fingerprint) {
        throw StateError('Local staging verification failed.');
      }
      return stage;
    } catch (_) {
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      rethrow;
    }
  }

  void _verifyAppliedTransfer({
    required PterodactylTransferFileManifest source,
    required PterodactylTransferFileManifest remote,
    required PterodactylTransferMode mode,
  }) {
    for (final MapEntry<String, PterodactylTransferFileEntry> item
        in source.files.entries) {
      final PterodactylTransferFileEntry? uploaded = remote.files[item.key];
      if (uploaded == null || uploaded.sha256 != item.value.sha256) {
        throw StateError(
          'Remote verification failed for transferable file ${item.key}.',
        );
      }
    }
    for (final String path in source.directories) {
      if (!source.excludedContentDirectories.contains(path) &&
          !remote.directories.contains(path)) {
        throw StateError(
          'Remote verification failed for transferable directory $path.',
        );
      }
    }
    if (mode == PterodactylTransferMode.mirror &&
        remote.files.keys.any(
          (String path) => !source.files.containsKey(path),
        )) {
      throw StateError(
        'Remote mirror verification found unexpected transferable files.',
      );
    }
    if (mode == PterodactylTransferMode.mirror &&
        remote.directories.any(
          (String path) =>
              !remote.excludedContentDirectories.contains(path) &&
              !source.directories.contains(path),
        )) {
      throw StateError(
        'Remote mirror verification found unexpected transferable '
        'directories.',
      );
    }
  }

  Future<PterodactylTransferFileManifest> _scanLocalTransfer(
    PterodactylLocalInstance local,
  ) {
    for (final String root in local.safeSymlinkRoots) {
      _requireSafeLocalSymlinkRoot(root);
    }
    return _fileEngine.scan(
      local.path,
      exclude: PterodactylTransferPathPolicy.excludes,
      allowSymlinks: true,
      allowedSymlinkRoots: local.safeSymlinkRoots,
    );
  }

  Future<PterodactylTransferFileManifest> _scanRemoteTransfer(String path) =>
      _fileEngine.scan(
        path,
        exclude: PterodactylTransferPathPolicy.excludes,
        allowSymlinks: false,
      );

  Future<_BackendSnapshot> _captureBackend(
    PterodactylTransferRemoteTarget target, {
    PterodactylTransferBackendSession? session,
  }) async {
    final Directory directory = _createPrivateTempDirectory('snapshot-');
    final bool ownsSession = session == null;
    final PterodactylTransferBackendSession backend =
        session ?? await _remoteGateway.openBackend(target);
    try {
      await backend.snapshotTo(directory.path);
      _hardenPrivateTree(directory.path);
      final PterodactylTransferFileManifest full = await _fileEngine.scan(
        directory.path,
        allowSymlinks: false,
      );
      final PterodactylTransferFileManifest transferable =
          await _scanRemoteTransfer(directory.path);
      if (full.files.keys.any(
        (String path) => path.toLowerCase().endsWith('.rclonelink'),
      )) {
        throw StateError(
          'Remote symlinks are not supported by safe transfer operations.',
        );
      }
      return _BackendSnapshot(
        directory: directory,
        full: full,
        transferable: transferable,
      );
    } catch (_) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      rethrow;
    } finally {
      if (ownsSession) await backend.close();
    }
  }

  void _deleteSnapshot(_BackendSnapshot? snapshot) {
    if (snapshot != null && snapshot.directory.existsSync()) {
      snapshot.directory.deleteSync(recursive: true);
    }
  }

  void _cleanupSnapshot(_BackendSnapshot? snapshot, List<String> warnings) {
    if (snapshot == null) return;
    _cleanupPrivateDirectory(
      snapshot.directory,
      warnings,
      noun: 'Remote snapshot',
    );
  }

  void _cleanupPrivateDirectory(
    Directory directory,
    List<String> warnings, {
    required String noun,
  }) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } catch (error) {
      warnings.add('$noun cleanup failed: $error');
    }
  }

  Directory _createPrivateTempDirectory(String prefix) {
    final Directory root = _ensurePrivateDirectory(
      p.join(_metadataDirectoryPath, 'pterodactyl-transfers', 'tmp'),
    );
    final Directory directory = root.createTempSync(prefix);
    _hardenPrivateTree(directory.path);
    return directory;
  }

  Directory _ensurePrivateDirectory(String path) {
    final String metadata = p.normalize(p.absolute(_metadataDirectoryPath));
    final String target = p.normalize(p.absolute(path));
    if (!p.equals(metadata, target) && !p.isWithin(metadata, target)) {
      throw StateError('Private transfer data escaped Multiplexor metadata.');
    }
    final Directory metadataDirectory = Directory(metadata);
    final FileSystemEntityType metadataType = FileSystemEntity.typeSync(
      metadata,
      followLinks: false,
    );
    if (metadataType == FileSystemEntityType.notFound) {
      metadataDirectory.createSync(recursive: true);
    } else if (metadataType != FileSystemEntityType.directory) {
      throw StateError('Multiplexor metadata must be a real directory.');
    }
    String current = metadata;
    for (final String part in p.split(p.relative(target, from: metadata))) {
      if (part == '.' || part.isEmpty) continue;
      current = p.join(current, part);
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        current,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('Private transfer directories cannot use symlinks.');
      }
    }
    _hardenPrivateTree(target);
    return Directory(target);
  }

  void _hardenPrivateTree(String path) {
    if (Platform.isWindows) return;
    final String executable = File('/bin/chmod').existsSync()
        ? '/bin/chmod'
        : 'chmod';
    final ProcessResult result = Process.runSync(executable, <String>[
      '-R',
      'go-rwx',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not secure private transfer data.');
    }
  }

  void _requireSafeLocalSymlinkRoot(String root) {
    final String normalized = p.normalize(p.absolute(root));
    final List<String> parts = p
        .split(normalized)
        .map((String part) => part.toLowerCase())
        .toList(growable: false);
    const Set<String> forbidden = <String>{
      '.multiplexor',
      '.manager-state',
      'state',
      'repos',
      'backups',
      'keys',
      'pterodactyl-smb',
    };
    if (parts.any(forbidden.contains)) {
      throw StateError('A Local symlink points into protected metadata.');
    }
  }

  _TargetSelection _resolveTargetSelection({
    required PterodactylLocalInstance local,
    required String? profileId,
    required String? serverIdentifier,
  }) {
    final String profile = profileId?.trim() ?? '';
    final String server = serverIdentifier?.trim() ?? '';
    if (profile.isNotEmpty != server.isNotEmpty) {
      throw ArgumentError(
        'profileId and serverIdentifier must be supplied together.',
      );
    }
    if (profile.isNotEmpty) {
      return _TargetSelection(
        profileId: _requiredName(profile, noun: 'profile'),
        serverIdentifier: _requiredName(server, noun: 'remote server'),
        expectedUuid: null,
      );
    }
    final PterodactylRemoteLink? link = _linkStore.load(local.path);
    if (link == null) {
      throw StateError(
        'Local ${local.name} is not linked. Choose a Remote target.',
      );
    }
    if (link.localInstanceName != local.name ||
        link.localConsumer != local.consumer) {
      throw StateError(
        'Remote link identity does not match this Local instance.',
      );
    }
    return _TargetSelection(
      profileId: link.profileId,
      serverIdentifier: link.serverIdentifier,
      expectedUuid: link.serverUuid,
    );
  }

  PterodactylTransferPlan _plan({
    required PterodactylTransferDirection direction,
    required PterodactylTransferMode mode,
    required String localInstanceName,
    required String localConsumer,
    required String localInstancePath,
    required PterodactylTransferRemoteTarget target,
    required bool targetExists,
    required bool targetWasRunning,
    required String sourceFingerprint,
    required List<PterodactylTransferChange> changes,
    required PterodactylTransferFileManifest? destination,
  }) {
    final List<String> confirmationScope =
        changes
            .where(
              (PterodactylTransferChange change) =>
                  change.kind != PterodactylTransferChangeKind.add,
            )
            .map((PterodactylTransferChange change) {
              final PterodactylTransferFileEntry? targetEntry =
                  destination?.files[change.path];
              return '${change.entryKind.name}:${change.kind.name}:'
                  '${change.path}:'
                  '${targetEntry?.sha256 ?? '-'}';
            })
            .toList(growable: false)
          ..sort();
    final List<String> tokenParts = <String>[
      'v2',
      direction.name,
      mode.name,
      localInstanceName,
      localConsumer,
      localInstancePath,
      target.profileId,
      target.identifier,
      target.uuid,
      target.name,
      '$targetExists',
      sourceFingerprint,
      ...confirmationScope,
    ];
    final String token = sha256
        .convert(utf8.encode(tokenParts.join('\u0000')))
        .toString();
    return PterodactylTransferPlan(
      direction: direction,
      mode: mode,
      localInstanceName: localInstanceName,
      localConsumer: localConsumer,
      localInstancePath: localInstancePath,
      profileId: target.profileId,
      serverIdentifier: target.identifier,
      serverUuid: target.uuid,
      remoteServerName: target.name,
      targetExists: targetExists,
      targetWasRunning: targetWasRunning,
      sourceFingerprint: sourceFingerprint,
      confirmationToken: token,
      createdAt: _clock().toUtc(),
      changes: changes,
      warnings: const <String>[_driveRaceWarning],
    );
  }

  void _requireExpectedToken(
    String? expected,
    PterodactylTransferPlan plan, {
    bool optional = false,
  }) {
    if (optional && (expected == null || expected.trim().isEmpty)) return;
    if (expected == null || expected.trim() != plan.confirmationToken) {
      throw StateError(
        'Transfer preview expired or files changed. Review a new preview.',
      );
    }
  }

  PterodactylRemoteLink _newLink({
    required PterodactylLocalInstance local,
    required PterodactylTransferRemoteTarget target,
  }) {
    final DateTime now = _clock().toUtc();
    return PterodactylRemoteLink(
      profileId: target.profileId,
      serverIdentifier: target.identifier,
      serverUuid: target.uuid,
      serverName: target.name,
      localInstanceName: local.name,
      localConsumer: local.consumer,
      linkedAt: now,
      lastTransferredAt: now,
    );
  }

  PterodactylRemoteLink _linkForTarget({
    required PterodactylLocalInstance local,
    required PterodactylTransferRemoteTarget target,
  }) {
    final PterodactylRemoteLink? existing = _linkStore.load(local.path);
    final DateTime now = _clock().toUtc();
    final bool sameTarget =
        existing != null &&
        existing.profileId == target.profileId &&
        existing.serverIdentifier == target.identifier &&
        existing.serverUuid == target.uuid;
    return PterodactylRemoteLink(
      profileId: target.profileId,
      serverIdentifier: target.identifier,
      serverUuid: target.uuid,
      serverName: target.name,
      localInstanceName: local.name,
      localConsumer: local.consumer,
      linkedAt: sameTarget ? existing.linkedAt : now,
      lastTransferredAt: now,
    );
  }

  bool _persistLinkIfNeeded({
    required PterodactylLocalInstance local,
    required PterodactylTransferRemoteTarget target,
    required PterodactylRemoteLink link,
    required bool relink,
  }) {
    final PterodactylRemoteLink? existing = _linkStore.load(local.path);
    final bool sameTarget =
        existing != null &&
        existing.profileId == target.profileId &&
        existing.serverIdentifier == target.identifier &&
        existing.serverUuid == target.uuid;
    if (!sameTarget && !relink) return false;
    _linkStore.save(local.path, link);
    return true;
  }

  bool _writeLaunchMetadata(
    PterodactylLocalInstance local,
    PterodactylTransferRemoteTarget target,
  ) {
    String? jar = target.launchJar?.trim();
    if (jar != null &&
        (p.posix.basename(jar) != jar ||
            p.windows.basename(jar) != jar ||
            !jar.toLowerCase().endsWith('.jar') ||
            !File(p.join(local.path, jar)).existsSync())) {
      jar = null;
    }
    if (jar == null && File(p.join(local.path, 'server.jar')).existsSync()) {
      jar = 'server.jar';
    }
    if (jar == null) {
      final List<File> jars = Directory(local.path)
          .listSync(followLinks: false)
          .whereType<File>()
          .where((File file) => file.path.toLowerCase().endsWith('.jar'))
          .toList(growable: false);
      if (jars.length == 1) jar = p.basename(jars.single.path);
    }
    final File destination = File(p.join(local.path, '.server-source'));
    String? argsFile = target.launchArgsFile?.trim();
    if (!_safeRelativeLaunchFile(local.path, argsFile, 'unix_args.txt')) {
      argsFile = null;
    }
    if (jar == null && argsFile == null) {
      final List<File> argsFiles = Directory(local.path)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (File file) =>
                p.basename(file.path).toLowerCase() == 'unix_args.txt',
          )
          .toList(growable: false);
      if (argsFiles.length == 1) {
        argsFile = p
            .relative(argsFiles.single.path, from: local.path)
            .replaceAll(p.separator, '/');
      }
    }
    if (jar == null && argsFile == null) return false;
    final Map<String, String> metadata = <String, String>{};
    if (destination.existsSync()) {
      for (final String line in destination.readAsLinesSync()) {
        final int separator = line.indexOf('=');
        if (separator <= 0) continue;
        metadata[line.substring(0, separator).trim()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    metadata['type'] = 'custom';
    if (jar != null) {
      metadata['launch'] = 'jar';
      metadata['jar_rel'] = jar;
      metadata.remove('jar');
      metadata.remove('args_file_rel');
    } else {
      metadata['launch'] = 'argsfile';
      metadata['args_file_rel'] = argsFile!;
      metadata.remove('jar');
      metadata.remove('jar_rel');
    }
    final List<String> keys = metadata.keys.toList()..sort();
    final File temporary = File('${destination.path}.tmp');
    temporary.writeAsStringSync(
      '${keys.map((String key) => '$key=${metadata[key]}').join('\n')}\n',
      flush: true,
    );
    _replaceLocalFileAtomically(temporary, destination);
    return true;
  }

  bool _safeRelativeLaunchFile(
    String localRoot,
    String? candidate,
    String requiredBasename,
  ) {
    if (candidate == null || candidate.isEmpty) return false;
    final String relative = candidate.replaceAll('\\', '/');
    if (p.posix.isAbsolute(relative) ||
        p.windows.isAbsolute(relative) ||
        p.posix.basename(relative).toLowerCase() != requiredBasename ||
        p.posix
            .split(relative)
            .any(
              (String part) => part.isEmpty || part == '.' || part == '..',
            )) {
      return false;
    }
    final String resolved = p.normalize(
      p.joinAll(<String>[localRoot, ...p.posix.split(relative)]),
    );
    return p.isWithin(p.normalize(localRoot), resolved) &&
        FileSystemEntity.typeSync(resolved, followLinks: false) ==
            FileSystemEntityType.file;
  }

  Future<_TransferBackup> _createBackupFromSnapshot({
    required PterodactylTransferRemoteTarget target,
    required _BackendSnapshot snapshot,
    required String operationId,
  }) async {
    final Directory backupsRoot = _ensurePrivateDirectory(
      p.join(_metadataDirectoryPath, 'pterodactyl-transfers', 'backups'),
    );
    final String stem =
        '$operationId-${_safePathPart(target.profileId)}-'
        '${_safePathPart(target.identifier)}';
    String rootPath = p.join(backupsRoot.path, stem);
    int suffix = 1;
    while (FileSystemEntity.typeSync(rootPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      rootPath = p.join(backupsRoot.path, '$stem-${suffix++}');
    }
    final Directory backupRoot = Directory(rootPath)..createSync();
    final Directory files = Directory(p.join(backupRoot.path, 'files'))
      ..createSync();
    _hardenPrivateTree(backupRoot.path);
    try {
      final PterodactylTransferFileManifest empty = await _fileEngine.scan(
        files.path,
        allowSymlinks: false,
      );
      await _fileEngine.apply(
        source: snapshot.full,
        targetRootPath: files.path,
        changes: _fileEngine.diff(
          source: snapshot.full,
          target: empty,
          mode: PterodactylTransferMode.update,
        ),
        mode: PterodactylTransferMode.update,
        operationId: '$operationId-backup',
      );
      _hardenPrivateTree(backupRoot.path);
      final PterodactylTransferFileManifest verified = await _fileEngine.scan(
        files.path,
        allowSymlinks: false,
      );
      if (verified.fingerprint != snapshot.full.fingerprint) {
        throw StateError('Remote pre-Push backup verification failed.');
      }
      final _TransferBackup backup = _TransferBackup(
        backupPath: files.path,
        recoveryManifestPath: p.join(backupRoot.path, 'recovery.json'),
        target: target,
        createdAt: _clock().toUtc(),
        fingerprint: verified.fingerprint,
      );
      _writeRecoveryManifest(backup, status: 'prepared');
      _hardenPrivateTree(backupRoot.path);
      return backup;
    } catch (_) {
      if (backupRoot.existsSync()) backupRoot.deleteSync(recursive: true);
      rethrow;
    }
  }

  void _writeRecoveryManifest(
    _TransferBackup backup, {
    required String status,
    String? failure,
    String? rollbackFailure,
  }) {
    final File destination = File(backup.recoveryManifestPath);
    destination.parent.createSync(recursive: true);
    final File temporary = File('${destination.path}.tmp');
    final String encoded = const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{
          'schema_version': 1,
          'status': status,
          'profile_id': backup.target.profileId,
          'server_identifier': backup.target.identifier,
          'server_uuid': backup.target.uuid,
          'server_name': backup.target.name,
          'backup_path': backup.backupPath,
          'backup_fingerprint': backup.fingerprint,
          'created_at': backup.createdAt.toIso8601String(),
          'updated_at': _clock().toUtc().toIso8601String(),
          'failure': ?failure,
          'rollback_failure': ?rollbackFailure,
        });
    temporary.writeAsStringSync('$encoded\n', flush: true);
    _replaceLocalFileAtomically(temporary, destination);
  }

  void _replaceLocalFileAtomically(File temporary, File destination) {
    final File previous = File('${destination.path}.previous');
    if (previous.existsSync()) {
      if (temporary.existsSync()) temporary.deleteSync();
      throw StateError('Transfer metadata recovery file already exists.');
    }
    bool movedPrevious = false;
    bool installedNew = false;
    try {
      if (destination.existsSync()) {
        destination.renameSync(previous.path);
        movedPrevious = true;
      }
      temporary.renameSync(destination.path);
      installedNew = true;
      if (movedPrevious) previous.deleteSync();
    } catch (_) {
      if (installedNew && destination.existsSync()) destination.deleteSync();
      if (movedPrevious && previous.existsSync()) {
        previous.renameSync(destination.path);
      }
      rethrow;
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  String _operationId(PterodactylTransferRemoteTarget target) {
    final String material =
        '${_clock().toUtc().microsecondsSinceEpoch}:${target.profileId}:'
        '${target.identifier}';
    return sha256.convert(utf8.encode(material)).toString().substring(0, 16);
  }

  _TransferLockSet _acquireTransferLocks(Iterable<String> keys) {
    final Directory lockRoot = _ensurePrivateDirectory(
      p.join(_metadataDirectoryPath, 'pterodactyl-transfers', 'locks'),
    );
    final List<String> sorted = keys.toSet().toList()..sort();
    final List<_HeldTransferLock> acquired = <_HeldTransferLock>[];
    try {
      for (final String key in sorted) {
        if (_heldTransferLocks.contains(key)) {
          throw StateError(
            'Another transfer is already using this Local or Remote server.',
          );
        }
        final String name = sha256.convert(utf8.encode(key)).toString();
        final File file = File(p.join(lockRoot.path, '$name.lock'));
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          file.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          throw StateError('Transfer lock storage is not a real file.');
        }
        final RandomAccessFile handle = file.openSync(mode: FileMode.append);
        try {
          handle.lockSync(FileLock.exclusive);
        } catch (_) {
          handle.closeSync();
          throw StateError(
            'Another Multiplexor process is transferring this Local or '
            'Remote server.',
          );
        }
        _heldTransferLocks.add(key);
        acquired.add(_HeldTransferLock(key: key, handle: handle));
      }
      _hardenPrivateTree(lockRoot.path);
      return _TransferLockSet(acquired, _heldTransferLocks);
    } catch (_) {
      _TransferLockSet(acquired, _heldTransferLocks).release();
      rethrow;
    }
  }

  String _safePathPart(String value) {
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'remote' : safe;
  }

  String _requiredName(String value, {required String noun}) {
    final String normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.contains('/') ||
        normalized.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
      throw ArgumentError('$noun is empty or contains unsafe characters.');
    }
    return normalized;
  }
}

final class _TargetSelection {
  const _TargetSelection({
    required this.profileId,
    required this.serverIdentifier,
    required this.expectedUuid,
  });

  final String profileId;
  final String serverIdentifier;
  final String? expectedUuid;
}

final class _BackendSnapshot {
  const _BackendSnapshot({
    required this.directory,
    required this.full,
    required this.transferable,
  });

  final Directory directory;
  final PterodactylTransferFileManifest full;
  final PterodactylTransferFileManifest transferable;
}

final class _TransferBackup {
  const _TransferBackup({
    required this.backupPath,
    required this.recoveryManifestPath,
    required this.target,
    required this.createdAt,
    required this.fingerprint,
  });

  final String backupPath;
  final String recoveryManifestPath;
  final PterodactylTransferRemoteTarget target;
  final DateTime createdAt;
  final String fingerprint;
}

final class _HeldTransferLock {
  const _HeldTransferLock({required this.key, required this.handle});

  final String key;
  final RandomAccessFile handle;
}

final class _TransferLockSet {
  _TransferLockSet(this._locks, this._heldKeys);

  final List<_HeldTransferLock> _locks;
  final Set<String> _heldKeys;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    for (final _HeldTransferLock lock in _locks.reversed) {
      try {
        lock.handle.unlockSync();
      } catch (_) {
        // Closing the descriptor below still releases the OS advisory lock.
      }
      try {
        lock.handle.closeSync();
      } finally {
        _heldKeys.remove(lock.key);
      }
    }
  }
}

/// Production remote adapter. File access always enters through the already
/// authenticated Multiplexor Drive; API credentials are never duplicated.
final class PterodactylDriveTransferGateway
    implements PterodactylTransferRemoteGateway {
  PterodactylDriveTransferGateway({
    required this.drive,
    required this.remote,
    this.readyTimeout = const Duration(minutes: 5),
  });

  final PterodactylSmbService drive;
  final PterodactylService remote;
  final Duration readyTimeout;

  @override
  Future<PterodactylTransferRemoteTarget> resolveTarget({
    required String profileId,
    required String serverIdentifier,
  }) async {
    final String selector = serverIdentifier.trim().toLowerCase();
    if (selector.isEmpty) {
      throw ArgumentError.value(
        serverIdentifier,
        'serverIdentifier',
        'must not be empty',
      );
    }
    final List<PterodactylClientServer> servers = await remote.listServers(
      profileId,
    );
    final List<PterodactylClientServer> exactIdentity = servers
        .where(
          (PterodactylClientServer server) =>
              server.identifier.toLowerCase() == selector ||
              server.uuid.toLowerCase() == selector,
        )
        .toList(growable: false);
    PterodactylClientServer? selected;
    if (exactIdentity.length == 1) {
      selected = exactIdentity.single;
    } else if (exactIdentity.isEmpty) {
      final List<PterodactylClientServer> names = servers
          .where(
            (PterodactylClientServer server) =>
                server.name.toLowerCase() == selector,
          )
          .toList(growable: false);
      if (names.length == 1) selected = names.single;
      if (names.length > 1) {
        throw StateError(
          'Remote server name is ambiguous; use its exact identifier.',
        );
      }
    }
    if (selected == null) {
      throw StateError('Remote server not found: $serverIdentifier');
    }
    return PterodactylTransferRemoteTarget(
      profileId: profileId.trim(),
      identifier: selected.identifier,
      uuid: selected.uuid,
      name: selected.name,
      installStatus: selected.status,
      launchJar: _launchJar(selected),
      launchArgsFile: _launchArgsFile(selected),
      nodeUnderMaintenance: selected.isNodeUnderMaintenance,
    );
  }

  @override
  Future<PterodactylTransferRemoteState> state(
    PterodactylTransferRemoteTarget target,
  ) async {
    final PterodactylResourceUsage usage = await remote.resources(
      target.profileId,
      target.identifier,
    );
    if (usage.isSuspended) return PterodactylTransferRemoteState.unknown;
    return switch (usage.currentState.trim().toLowerCase()) {
      'offline' => PterodactylTransferRemoteState.offline,
      'running' => PterodactylTransferRemoteState.running,
      'starting' => PterodactylTransferRemoteState.starting,
      'stopping' => PterodactylTransferRemoteState.stopping,
      _ => PterodactylTransferRemoteState.unknown,
    };
  }

  @override
  Future<void> stop(PterodactylTransferRemoteTarget target) => remote.power(
    target.profileId,
    target.identifier,
    PterodactylPowerSignal.stop,
  );

  @override
  Future<void> start(PterodactylTransferRemoteTarget target) => remote.power(
    target.profileId,
    target.identifier,
    PterodactylPowerSignal.start,
  );

  @override
  Future<PterodactylTransferBackendSession> openBackend(
    PterodactylTransferRemoteTarget target,
  ) async => _PterodactylDriveBackendSession(
    await drive.openDirectServerFiles(
      profileId: target.profileId,
      serverIdentifier: target.identifier,
    ),
  );

  String? _launchJar(PterodactylClientServer server) {
    for (final PterodactylStartupVariable variable in server.variables) {
      if (!variable.environmentVariable.toUpperCase().contains('JAR')) {
        continue;
      }
      final String value = (variable.serverValue ?? variable.defaultValue ?? '')
          .trim();
      if (_rootJarName(value)) return value;
    }
    final RegExp jarArgument = RegExp(
      r'''(?:^|\s)-jar\s+(?:"([^"]+\.jar)"|'([^']+\.jar)'|([^\s]+\.jar))''',
      caseSensitive: false,
    );
    final RegExpMatch? match = jarArgument.firstMatch(server.invocation);
    if (match == null) return null;
    final String value =
        (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
    return _rootJarName(value) ? value : null;
  }

  bool _rootJarName(String value) =>
      value.isNotEmpty &&
      value.toLowerCase().endsWith('.jar') &&
      p.posix.basename(value) == value &&
      p.windows.basename(value) == value;

  String? _launchArgsFile(PterodactylClientServer server) {
    final RegExp argument = RegExp(
      r'''(?:^|\s)@(?:(?:"([^"]*unix_args\.txt)")|(?:'([^']*unix_args\.txt)')|([^\s]+unix_args\.txt))''',
      caseSensitive: false,
    );
    final RegExpMatch? match = argument.firstMatch(server.invocation);
    if (match == null) return null;
    final String value =
        (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
            .trim()
            .replaceAll('\\', '/');
    if (value.isEmpty ||
        p.posix.isAbsolute(value) ||
        p.windows.isAbsolute(value) ||
        p.posix
            .split(value)
            .any(
              (String part) => part.isEmpty || part == '.' || part == '..',
            )) {
      return null;
    }
    return value;
  }
}

final class _PterodactylDriveBackendSession
    implements PterodactylTransferBackendSession {
  const _PterodactylDriveBackendSession(this._session);

  final PterodactylSmbDirectSession _session;

  @override
  Future<void> snapshotTo(String destinationPath) =>
      _session.snapshotTo(destinationPath);

  @override
  Future<void> applyFrom({
    required String sourcePath,
    required PterodactylTransferMode mode,
  }) => _session.applyFrom(
    sourcePath: sourcePath,
    mode: mode == PterodactylTransferMode.update
        ? PterodactylSmbDirectWriteMode.update
        : PterodactylSmbDirectWriteMode.mirror,
  );

  @override
  Future<void> restoreFrom(String backupPath) => _session.applyFrom(
    sourcePath: backupPath,
    mode: PterodactylSmbDirectWriteMode.restore,
  );

  @override
  Future<void> close() => _session.close();
}
