import 'dart:collection';

enum PterodactylTransferDirection { pull, push }

enum PterodactylTransferMode { update, mirror }

enum PterodactylTransferChangeKind { add, update, delete }

enum PterodactylTransferEntryKind { file, directory }

enum PterodactylTransferRemoteState {
  offline,
  running,
  starting,
  stopping,
  unknown,
}

final class PterodactylLocalInstance {
  const PterodactylLocalInstance({
    required this.name,
    required this.consumer,
    required this.path,
    this.safeSymlinkRoots = const <String>[],
  });

  final String name;
  final String consumer;
  final String path;
  final List<String> safeSymlinkRoots;
}

abstract interface class PterodactylLocalInstanceGateway {
  Future<String> currentConsumer();

  Future<PterodactylLocalInstance> createStopped(
    String name, {
    String? consumer,
  });

  Future<PterodactylLocalInstance> resolve(String name, {String? consumer});

  Future<bool> isRunning(PterodactylLocalInstance instance);

  Future<void> stop(PterodactylLocalInstance instance);

  Future<void> start(PterodactylLocalInstance instance);

  Future<void> delete(PterodactylLocalInstance instance);
}

final class PterodactylTransferRemoteTarget {
  const PterodactylTransferRemoteTarget({
    required this.profileId,
    required this.identifier,
    required this.uuid,
    required this.name,
    this.installStatus,
    this.launchJar,
    this.launchArgsFile,
    this.nodeUnderMaintenance = false,
  });

  final String profileId;
  final String identifier;
  final String uuid;
  final String name;
  final String? installStatus;
  final String? launchJar;
  final String? launchArgsFile;
  final bool nodeUnderMaintenance;
}

abstract interface class PterodactylTransferRemoteGateway {
  Future<PterodactylTransferRemoteTarget> resolveTarget({
    required String profileId,
    required String serverIdentifier,
  });

  Future<PterodactylTransferRemoteState> state(
    PterodactylTransferRemoteTarget target,
  );

  Future<void> stop(PterodactylTransferRemoteTarget target);

  Future<void> start(PterodactylTransferRemoteTarget target);

  Future<PterodactylTransferBackendSession> openBackend(
    PterodactylTransferRemoteTarget target,
  );
}

abstract interface class PterodactylTransferBackendSession {
  Future<void> snapshotTo(String destinationPath);

  Future<void> applyFrom({
    required String sourcePath,
    required PterodactylTransferMode mode,
  });

  Future<void> restoreFrom(String backupPath);

  Future<void> close();
}

final class PterodactylTransferChange {
  const PterodactylTransferChange({
    required this.path,
    required this.kind,
    this.entryKind = PterodactylTransferEntryKind.file,
    this.sourceSize,
    this.targetSize,
  });

  final String path;
  final PterodactylTransferChangeKind kind;
  final PterodactylTransferEntryKind entryKind;
  final int? sourceSize;
  final int? targetSize;
}

final class PterodactylRemoteLink {
  const PterodactylRemoteLink({
    required this.profileId,
    required this.serverIdentifier,
    required this.serverUuid,
    required this.serverName,
    required this.localInstanceName,
    required this.localConsumer,
    required this.linkedAt,
    required this.lastTransferredAt,
  });

  final String profileId;
  final String serverIdentifier;
  final String serverUuid;
  final String serverName;
  final String localInstanceName;
  final String localConsumer;
  final DateTime linkedAt;
  final DateTime lastTransferredAt;
}

final class PterodactylTransferPlan {
  PterodactylTransferPlan({
    required this.direction,
    required this.mode,
    required this.localInstanceName,
    this.localConsumer = '',
    this.localInstancePath = '',
    required this.profileId,
    required this.serverIdentifier,
    this.serverUuid = '',
    required this.remoteServerName,
    required this.targetExists,
    required this.targetWasRunning,
    required this.sourceFingerprint,
    required this.confirmationToken,
    required this.createdAt,
    required List<PterodactylTransferChange> changes,
    List<String> warnings = const <String>[],
  }) : changes = UnmodifiableListView<PterodactylTransferChange>(changes),
       warnings = UnmodifiableListView<String>(warnings);

  final PterodactylTransferDirection direction;
  final PterodactylTransferMode mode;
  final String localInstanceName;
  final String localConsumer;
  final String localInstancePath;
  final String profileId;
  final String serverIdentifier;
  final String serverUuid;
  final String remoteServerName;
  final bool targetExists;
  final bool targetWasRunning;
  final String sourceFingerprint;
  final String confirmationToken;
  final DateTime createdAt;
  final List<PterodactylTransferChange> changes;
  final List<String> warnings;

  int get addCount => changes
      .where(
        (PterodactylTransferChange change) =>
            change.kind == PterodactylTransferChangeKind.add,
      )
      .length;

  int get updateCount => changes
      .where(
        (PterodactylTransferChange change) =>
            change.kind == PterodactylTransferChangeKind.update,
      )
      .length;

  int get deleteCount => changes
      .where(
        (PterodactylTransferChange change) =>
            change.kind == PterodactylTransferChangeKind.delete,
      )
      .length;

  int get transferBytes => changes.fold<int>(
    0,
    (int total, PterodactylTransferChange change) =>
        total + (change.sourceSize ?? 0),
  );

  bool get isNoop => changes.isEmpty;
}

final class PterodactylTransferResult {
  PterodactylTransferResult({
    required this.plan,
    required this.localInstance,
    required this.link,
    required this.remoteRestarted,
    this.linkPersisted = false,
    this.backupPath,
    this.recoveryManifestPath,
    List<String> warnings = const <String>[],
  }) : warnings = UnmodifiableListView<String>(warnings);

  final PterodactylTransferPlan plan;
  final PterodactylLocalInstance localInstance;
  final PterodactylRemoteLink link;
  final String? backupPath;
  final String? recoveryManifestPath;
  final bool remoteRestarted;
  final bool linkPersisted;
  final List<String> warnings;
}
