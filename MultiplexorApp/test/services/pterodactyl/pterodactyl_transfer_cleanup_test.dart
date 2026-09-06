import 'dart:io';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late _Remote remote;
  late _Local local;
  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-transfer-cleanup-');
    remote = _Remote();
    local = _Local(p.join(root.path, 'instances'));
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });
  PterodactylTransferService service(
    Future<void> Function(Directory) deleter,
  ) => PterodactylTransferService.withGateways(
    metadataDirectoryPath: p.join(root.path, '.multiplexor'),
    remoteGateway: remote,
    localInstances: local,
    temporaryDirectoryDeleter: deleter,
    delay: (Duration _) async {},
  );
  Future<PterodactylTransferPlan> preview(
    PterodactylTransferService transfers,
  ) => transfers.planPull(
    profileId: 'panel',
    serverIdentifier: 'server',
    localInstanceName: 'copy',
  );

  test(
    'snapshot cleanup retries transient ENOTEMPTY after backend closes',
    () async {
      int attempts = 0;
      final PterodactylTransferService transfers = service((
        Directory directory,
      ) async {
        expect(
          remote.sessions.every((_Session session) => session.closed),
          isTrue,
        );
        attempts++;
        if (attempts == 1) {
          throw FileSystemException(
            'Directory not empty',
            directory.path,
            const OSError('Directory not empty', 66),
          );
        }
        await directory.delete(recursive: true);
      });
      final PterodactylTransferPlan plan = await preview(transfers);
      expect(attempts, 2);
      expect(
        plan.warnings.where((String item) => item.contains('cleanup failed')),
        isEmpty,
      );
      expect(_snapshots(root), isEmpty);
    },
  );
  test(
    'persistent cleanup errors warn without failing completed pull or leaking locks',
    () async {
      int attempts = 0;
      final PterodactylTransferService transfers = service((
        Directory directory,
      ) async {
        attempts++;
        throw FileSystemException(
          'Directory not empty',
          directory.path,
          const OSError('Directory not empty', 66),
        );
      });
      final PterodactylTransferResult first = await transfers.pull(
        profileId: 'panel',
        serverIdentifier: 'server',
        localInstanceName: 'first',
      );
      expect(
        File(p.join(first.localInstance.path, 'server.jar')).readAsStringSync(),
        'jar',
      );
      expect(
        first.plan.warnings,
        contains(contains('Remote snapshot cleanup failed')),
      );
      expect(
        first.warnings,
        contains(contains('Remote snapshot cleanup failed')),
      );
      expect(attempts, 6);
      final PterodactylTransferResult second = await transfers.pull(
        profileId: 'panel',
        serverIdentifier: 'server',
        localInstanceName: 'second',
      );
      expect(second.localInstance.name, 'second');
      expect(
        remote.sessions.every((_Session session) => session.closed),
        isTrue,
      );
    },
  );
  test(
    'snapshot failure retains original cause even if close and cleanup fail',
    () async {
      remote.failSnapshot = true;
      remote.failClose = true;
      int attempts = 0;
      final PterodactylTransferService transfers = service((
        Directory directory,
      ) async {
        attempts++;
        expect(remote.sessions.single.closed, isTrue);
        throw FileSystemException('Directory not empty', directory.path);
      });
      await expectLater(
        preview(transfers),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            'original snapshot failure',
          ),
        ),
      );
      expect(attempts, 3);
      expect(local.created, isEmpty);
    },
  );
  test('backend open failure cleans allocated temporary directory', () async {
    remote.failOpen = true;
    final PterodactylTransferService transfers = service((
      Directory directory,
    ) async {
      await directory.delete(recursive: true);
    });
    await expectLater(
      preview(transfers),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          'original open failure',
        ),
      ),
    );
    expect(_snapshots(root), isEmpty);
  });
  test(
    'failed pull releases remote lock despite backend cleanup failure',
    () async {
      local.failCreate = true;
      remote.failClose = true;
      final PterodactylTransferService transfers = service((
        Directory directory,
      ) async {
        await directory.delete(recursive: true);
      });
      await expectLater(
        transfers.pull(
          profileId: 'panel',
          serverIdentifier: 'server',
          localInstanceName: 'first',
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            'local create failure',
          ),
        ),
      );
      local.failCreate = false;
      final PterodactylTransferResult retried = await transfers.pull(
        profileId: 'panel',
        serverIdentifier: 'server',
        localInstanceName: 'first',
      );
      expect(retried.localInstance.name, 'first');
      expect(
        remote.sessions.every((_Session session) => session.closed),
        isTrue,
      );
    },
  );
}

List<FileSystemEntity> _snapshots(Directory root) {
  final Directory temporary = Directory(
    p.join(root.path, '.multiplexor', 'pterodactyl-transfers', 'tmp'),
  );
  return temporary.existsSync() ? temporary.listSync() : <FileSystemEntity>[];
}

const PterodactylTransferRemoteTarget _target = PterodactylTransferRemoteTarget(
  profileId: 'panel',
  identifier: 'server',
  uuid: 'uuid-server',
  name: 'Server',
  launchJar: 'server.jar',
);

class _Remote implements PterodactylTransferRemoteGateway {
  final List<_Session> sessions = <_Session>[];
  bool failOpen = false;
  bool failSnapshot = false;
  bool failClose = false;
  @override
  Future<PterodactylTransferBackendSession> openBackend(
    PterodactylTransferRemoteTarget target,
  ) async {
    if (failOpen) throw StateError('original open failure');
    final _Session session = _Session(this);
    sessions.add(session);
    return session;
  }

  @override
  Future<PterodactylTransferRemoteTarget> resolveTarget({
    required String profileId,
    required String serverIdentifier,
  }) async => _target;
  @override
  Future<PterodactylTransferRemoteState> state(
    PterodactylTransferRemoteTarget target,
  ) async => PterodactylTransferRemoteState.offline;
  @override
  Future<void> start(PterodactylTransferRemoteTarget target) async =>
      throw UnsupportedError('unused');
  @override
  Future<void> stop(PterodactylTransferRemoteTarget target) async =>
      throw UnsupportedError('unused');
}

class _Session implements PterodactylTransferBackendSession {
  _Session(this.remote);
  final _Remote remote;
  bool closed = false;
  @override
  Future<void> snapshotTo(String destinationPath) async {
    File(p.join(destinationPath, 'server.jar')).writeAsStringSync('jar');
    if (remote.failSnapshot) throw StateError('original snapshot failure');
  }

  @override
  Future<void> close() async {
    closed = true;
    if (remote.failClose) throw StateError('secondary close failure');
  }

  @override
  Future<void> applyFrom({
    required String sourcePath,
    required PterodactylTransferMode mode,
  }) async => throw UnsupportedError('unused');
  @override
  Future<void> restoreFrom(String backupPath) async =>
      throw UnsupportedError('unused');
}

class _Local implements PterodactylLocalInstanceGateway {
  _Local(this.rootPath);
  final String rootPath;
  final Map<String, PterodactylLocalInstance> created =
      <String, PterodactylLocalInstance>{};
  bool failCreate = false;
  @override
  Future<PterodactylLocalInstance> createStopped(
    String name, {
    String? consumer,
  }) async {
    if (failCreate) throw StateError('local create failure');
    if (created.containsKey(name)) throw StateError('already exists');
    final Directory directory = Directory(p.join(rootPath, name))
      ..createSync(recursive: true);
    final PterodactylLocalInstance instance = PterodactylLocalInstance(
      name: name,
      consumer: consumer ?? 'plugin',
      path: directory.path,
    );
    created[name] = instance;
    return instance;
  }

  @override
  Future<String> currentConsumer() async => 'plugin';
  @override
  Future<void> delete(PterodactylLocalInstance instance) async {
    await Directory(instance.path).delete(recursive: true);
    created.remove(instance.name);
  }

  @override
  Future<bool> isRunning(PterodactylLocalInstance instance) async => false;
  @override
  Future<PterodactylLocalInstance> resolve(
    String name, {
    String? consumer,
  }) async => created[name]!;
  @override
  Future<void> start(PterodactylLocalInstance instance) async =>
      throw UnsupportedError('unused');
  @override
  Future<void> stop(PterodactylLocalInstance instance) async =>
      throw UnsupportedError('unused');
}
