import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_files.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late _Local local;
  late _Remote remote;
  late PterodactylTransferService service;

  PterodactylTransferService reopen() =>
      PterodactylTransferService.withGateways(
        metadataDirectoryPath: p.join(root.path, 'metadata'),
        remoteGateway: remote,
        localInstances: local,
      );

  Future<PterodactylTransferResult> push() async {
    final PterodactylTransferPlan plan = await service.planPush(
      localInstanceName: 'leaf-local',
    );
    return service.push(
      localInstanceName: 'leaf-local',
      expectedPlanToken: plan.confirmationToken,
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-roundtrip-[qa]-');
    local = _Local(p.join(root.path, 'local'));
    remote = _Remote(p.join(root.path, 'remote'));
    _write(remote.path, 'server.jar', 'unchanged server jar');
    _write(
      remote.path,
      'server.properties',
      'motd=Remote\nserver-port=25565\n',
    );
    _write(remote.path, 'plugins/example.jar', 'plugin v1');
    _write(remote.path, 'world/level.dat', 'world v1');
    _write(remote.path, 'world/session.lock', 'remote lock');
    _write(remote.path, 'logs/latest.log', 'remote log');
    service = reopen();
    await service.pull(
      profileId: 'panel',
      serverIdentifier: 'leaf',
      localInstanceName: 'leaf-local',
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('pull then push sends no files and does not stop Remote', () async {
    expect(
      File(p.join(local.path, 'world/session.lock')).existsSync(),
      isFalse,
    );
    expect(File(p.join(local.path, 'logs/latest.log')).existsSync(), isFalse);
    remote.running = true;
    final PterodactylTransferResult result = await push();
    expect(result.plan.isNoop, isTrue);
    expect(remote.uploaded, isEmpty);
    expect(remote.stops, 0);
    expect(remote.running, isTrue);
  });

  test('only changed and new payloads reach the upload boundary', () async {
    _write(local.path, 'plugins/example.jar', 'plugin v2');
    _write(local.path, 'plugins/new.jar', 'new plugin');
    _write(local.path, 'world/session.lock', 'local lock');
    _write(
      local.path,
      '.multiplexor-runtime.env',
      'JAVA_EXECUTABLE=/local/java',
    );
    _write(local.path, '.multiplexor-dropins.json', '{}');
    _write(local.path, '.multiplexor-addons.json', '{}');
    _write(local.path, '.multiplexor-log4j2.xml', '<local/>');
    remote.running = true;
    final PterodactylTransferResult result = await push();
    expect(remote.uploaded, <String>['plugins/example.jar', 'plugins/new.jar']);
    expect(result.plan.transferBytes, 'plugin v2'.length + 'new plugin'.length);
    expect(remote.stops, 1);
    expect(remote.starts, 1);
    expect(_read(remote.path, 'world/session.lock'), 'remote lock');
    expect(
      File(p.join(remote.path, '.multiplexor-runtime.env')).existsSync(),
      isFalse,
    );
    remote.uploaded.clear();
    service = reopen();
    expect((await push()).plan.isNoop, isTrue);
    expect(remote.uploaded, isEmpty);
  });

  test(
    'Remote drift survives unrelated pushes and remains a conflict',
    () async {
      _write(remote.path, 'world/level.dat', 'world progressed remotely');
      _write(remote.path, 'remote-only.txt', 'keep');
      _write(local.path, 'plugins/example.jar', 'plugin v2');
      await push();
      expect(remote.uploaded, <String>['plugins/example.jar']);
      expect(
        _read(remote.path, 'world/level.dat'),
        'world progressed remotely',
      );
      expect(_read(remote.path, 'remote-only.txt'), 'keep');
      service = reopen();
      remote.uploaded.clear();
      expect((await push()).plan.isNoop, isTrue);
      _write(local.path, 'world/level.dat', 'world progressed locally');
      await expectLater(
        service.planPush(localInstanceName: 'leaf-local'),
        throwsA(
          isA<PterodactylTransferConflict>().having(
            (PterodactylTransferConflict error) => error.toString(),
            'message',
            contains('world/level.dat'),
          ),
        ),
      );
      expect(remote.uploaded, isEmpty);
      expect(
        _read(remote.path, 'world/level.dat'),
        'world progressed remotely',
      );
    },
  );

  test(
    'Local deletion preserves Remote and remote deletion is not resurrected',
    () async {
      File(p.join(local.path, 'plugins/example.jar')).deleteSync();
      File(p.join(remote.path, 'world/level.dat')).deleteSync();
      final PterodactylTransferResult result = await push();
      expect(result.plan.isNoop, isTrue);
      expect(remote.uploaded, isEmpty);
      expect(_read(remote.path, 'plugins/example.jar'), 'plugin v1');
      expect(
        File(p.join(remote.path, 'world/level.dat')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'failed partial upload restores Remote and keeps edits pending',
    () async {
      _write(local.path, 'plugins/example.jar', 'plugin v2');
      remote.failUpload = true;
      await expectLater(push(), throwsA(isA<StateError>()));
      expect(remote.restores, 1);
      expect(_read(remote.path, 'plugins/example.jar'), 'plugin v1');
      expect(_read(remote.path, 'world/session.lock'), 'remote lock');
      service = reopen();
      remote.failUpload = false;
      remote.uploaded.clear();
      await push();
      expect(remote.uploaded, <String>['plugins/example.jar']);
      expect(_read(remote.path, 'plugins/example.jar'), 'plugin v2');
    },
  );
  test('converged edits become the baseline for the next Local edit', () async {
    _write(local.path, 'plugins/example.jar', 'plugin v2');
    _write(remote.path, 'plugins/example.jar', 'plugin v2');
    expect((await push()).plan.isNoop, isTrue);
    expect(remote.uploaded, isEmpty);
    service = reopen();
    _write(local.path, 'plugins/example.jar', 'plugin v3');
    await push();
    expect(remote.uploaded, <String>['plugins/example.jar']);
    expect(_read(remote.path, 'plugins/example.jar'), 'plugin v3');
  });

  for (final String path in <String>['world/level.dat', 'world/session.lock']) {
    test('unexpected upload side effect on $path triggers rollback', () async {
      final String original = _read(remote.path, path);
      _write(local.path, 'plugins/example.jar', 'plugin v2');
      remote.afterUpload = () => _write(remote.path, path, 'unexpected change');
      await expectLater(push(), throwsA(isA<StateError>()));
      expect(remote.restores, 1);
      expect(_read(remote.path, path), original);
      expect(_read(remote.path, 'plugins/example.jar'), 'plugin v1');
      remote.afterUpload = null;
      remote.uploaded.clear();
      await push();
      expect(remote.uploaded, <String>['plugins/example.jar']);
    });
  }
}

void _write(String root, String relative, String contents) {
  final File file = File(p.join(root, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

String _read(String root, String relative) =>
    File(p.join(root, relative)).readAsStringSync();

void _copyTree(String source, String target, {List<String>? uploaded}) {
  Directory(target).createSync(recursive: true);
  final List<FileSystemEntity> entries = Directory(source).listSync(
    recursive: true,
  )..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
  for (final FileSystemEntity entry in entries) {
    final String relative = p.relative(entry.path, from: source);
    final String destination = p.join(target, relative);
    if (entry is Directory) {
      Directory(destination).createSync(recursive: true);
    } else if (entry is File) {
      File(destination).parent.createSync(recursive: true);
      entry.copySync(destination);
      uploaded?.add(p.posix.joinAll(p.split(relative)));
    }
  }
}

final class _Local implements PterodactylLocalInstanceGateway {
  _Local(this.path);
  final String path;
  late PterodactylLocalInstance instance;
  @override
  Future<String> currentConsumer() async => 'plugin';
  @override
  Future<PterodactylLocalInstance> createStopped(
    String name, {
    String? consumer,
  }) async {
    Directory(path).createSync(recursive: true);
    return instance = PterodactylLocalInstance(
      name: name,
      consumer: consumer ?? 'plugin',
      path: path,
    );
  }

  @override
  Future<PterodactylLocalInstance> resolve(
    String name, {
    String? consumer,
  }) async => instance;
  @override
  Future<bool> isRunning(PterodactylLocalInstance instance) async => false;
  @override
  Future<void> delete(PterodactylLocalInstance instance) async =>
      Directory(path).deleteSync(recursive: true);
  @override
  Future<void> start(PterodactylLocalInstance instance) async =>
      throw UnimplementedError();
  @override
  Future<void> stop(PterodactylLocalInstance instance) async =>
      throw UnimplementedError();
}

final class _Remote
    implements
        PterodactylTransferRemoteGateway,
        PterodactylTransferBackendSession {
  _Remote(this.path) {
    Directory(path).createSync(recursive: true);
  }
  final String path;
  final List<String> uploaded = <String>[];
  bool running = false;
  bool failUpload = false;
  void Function()? afterUpload;
  int stops = 0;
  int starts = 0;
  int restores = 0;
  @override
  Future<PterodactylTransferRemoteTarget> resolveTarget({
    required String profileId,
    required String serverIdentifier,
  }) async => const PterodactylTransferRemoteTarget(
    profileId: 'panel',
    identifier: 'leaf',
    uuid: 'leaf-uuid',
    name: 'LEAF',
    launchJar: 'server.jar',
  );
  @override
  Future<PterodactylTransferRemoteState> state(
    PterodactylTransferRemoteTarget target,
  ) async => running
      ? PterodactylTransferRemoteState.running
      : PterodactylTransferRemoteState.offline;
  @override
  Future<void> start(PterodactylTransferRemoteTarget target) async {
    starts++;
    running = true;
  }

  @override
  Future<void> stop(PterodactylTransferRemoteTarget target) async {
    stops++;
    running = false;
  }

  @override
  Future<PterodactylTransferBackendSession> openBackend(
    PterodactylTransferRemoteTarget target,
  ) async => this;
  @override
  Future<void> snapshotTo(String destinationPath) async =>
      _copyTree(path, destinationPath);
  @override
  Future<void> applyFrom({
    required String sourcePath,
    required PterodactylTransferMode mode,
  }) async {
    // Deliberately copy every staged file, as the real rclone --ignore-times does.
    _copyTree(sourcePath, path, uploaded: uploaded);
    afterUpload?.call();
    if (failUpload) throw StateError('Upload interrupted after mutation');
  }

  @override
  Future<void> restoreFrom(String backupPath) async {
    restores++;
    Directory(path).deleteSync(recursive: true);
    _copyTree(backupPath, path);
  }

  @override
  Future<void> close() async {}
}
