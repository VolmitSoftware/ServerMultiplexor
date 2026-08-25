import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_files.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_link_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_path_policy.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('transfer file engine', () {
    test(
      'shared exclusion policy covers nested transfer artifacts exactly',
      () {
        for (final String path in <String>[
          '.multiplexor-transfer/pending',
          'world/.multiplexor-transfer/pending',
          '.server.properties.multiplexor-a1.part',
          'world/.level.dat.multiplexor-a1-stage.part',
          'world/session.lock',
          'multiplexor-restart.cmd',
        ]) {
          expect(
            PterodactylTransferPathPolicy.excludes(path),
            isTrue,
            reason: path,
          );
        }
        for (final String path in <String>[
          'world/logs/data.txt',
          'world/.multiplexor-transferable/data.txt',
          'world/level.dat.multiplexor-a1.part',
          'world/.level.dat.multiplexor-.part',
          'world/SESSION.LOCK',
        ]) {
          expect(
            PterodactylTransferPathPolicy.excludes(path),
            isFalse,
            reason: path,
          );
        }
      },
    );

    test('produces deterministic update and mirror diffs', () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-transfer-diff-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final Directory source = Directory(p.join(temporary.path, 'source'))
        ..createSync();
      final Directory target = Directory(p.join(temporary.path, 'target'))
        ..createSync();
      _write(source.path, 'same.txt', 'same');
      _write(source.path, 'changed.txt', 'new');
      _write(source.path, 'new.txt', 'added');
      _write(target.path, 'same.txt', 'same');
      _write(target.path, 'changed.txt', 'old');
      _write(target.path, 'remote-only.txt', 'keep');
      const PterodactylTransferFileEngine engine =
          PterodactylTransferFileEngine();

      final PterodactylTransferFileManifest sourceManifest = await engine.scan(
        source.path,
      );
      final PterodactylTransferFileManifest secondManifest = await engine.scan(
        source.path,
      );
      final PterodactylTransferFileManifest targetManifest = await engine.scan(
        target.path,
      );
      final List<PterodactylTransferChange> update = engine.diff(
        source: sourceManifest,
        target: targetManifest,
        mode: PterodactylTransferMode.update,
      );
      final List<PterodactylTransferChange> mirror = engine.diff(
        source: sourceManifest,
        target: targetManifest,
        mode: PterodactylTransferMode.mirror,
      );

      expect(secondManifest.fingerprint, sourceManifest.fingerprint);
      expect(
        update.map((PterodactylTransferChange change) => change.path),
        <String>['changed.txt', 'new.txt'],
      );
      expect(
        update.map((PterodactylTransferChange change) => change.kind),
        <PterodactylTransferChangeKind>[
          PterodactylTransferChangeKind.update,
          PterodactylTransferChangeKind.add,
        ],
      );
      expect(
        mirror.last,
        isA<PterodactylTransferChange>()
            .having(
              (PterodactylTransferChange change) => change.path,
              'path',
              'remote-only.txt',
            )
            .having(
              (PterodactylTransferChange change) => change.kind,
              'kind',
              PterodactylTransferChangeKind.delete,
            ),
      );
    });

    test('represents and applies empty directory tree deltas', () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-transfer-empty-directories-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final Directory source = Directory(p.join(temporary.path, 'source'))
        ..createSync();
      final Directory target = Directory(p.join(temporary.path, 'target'))
        ..createSync();
      Directory(
        p.join(source.path, 'new-empty', 'nested'),
      ).createSync(recursive: true);
      Directory(
        p.join(target.path, 'remote-empty', 'nested'),
      ).createSync(recursive: true);
      const PterodactylTransferFileEngine engine =
          PterodactylTransferFileEngine();
      final PterodactylTransferFileManifest sourceManifest = await engine.scan(
        source.path,
      );
      final PterodactylTransferFileManifest targetManifest = await engine.scan(
        target.path,
      );

      final List<PterodactylTransferChange> update = engine.diff(
        source: sourceManifest,
        target: targetManifest,
        mode: PterodactylTransferMode.update,
      );
      final List<PterodactylTransferChange> mirror = engine.diff(
        source: sourceManifest,
        target: targetManifest,
        mode: PterodactylTransferMode.mirror,
      );

      expect(
        update
            .where(
              (PterodactylTransferChange change) =>
                  change.entryKind == PterodactylTransferEntryKind.directory,
            )
            .map((PterodactylTransferChange change) => change.path),
        <String>['new-empty', 'new-empty/nested'],
      );
      expect(
        mirror
            .where(
              (PterodactylTransferChange change) =>
                  change.entryKind == PterodactylTransferEntryKind.directory &&
                  change.kind == PterodactylTransferChangeKind.delete,
            )
            .map((PterodactylTransferChange change) => change.path),
        <String>['remote-empty', 'remote-empty/nested'],
      );
      expect(sourceManifest.fingerprint, isNot(targetManifest.fingerprint));

      await engine.apply(
        source: sourceManifest,
        targetRootPath: target.path,
        changes: mirror,
        mode: PterodactylTransferMode.mirror,
        operationId: 'empty-directories',
      );
      expect(
        Directory(p.join(target.path, 'new-empty', 'nested')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(target.path, 'remote-empty')).existsSync(),
        isFalse,
      );
      expect(
        engine.diff(
          source: sourceManifest,
          target: await engine.scan(target.path),
          mode: PterodactylTransferMode.mirror,
        ),
        isEmpty,
      );
    });

    test(
      'excluded descendants protect their parent from mirror deletion',
      () async {
        final Directory temporary = Directory.systemTemp.createTempSync(
          'multiplexor-transfer-protected-directory-',
        );
        addTearDown(() => temporary.deleteSync(recursive: true));
        final Directory source = Directory(p.join(temporary.path, 'source'))
          ..createSync();
        final Directory target = Directory(p.join(temporary.path, 'target'))
          ..createSync();
        _write(target.path, 'world/session.lock', 'runtime lock');
        const PterodactylTransferFileEngine engine =
            PterodactylTransferFileEngine();
        final PterodactylTransferFileManifest sourceManifest = await engine
            .scan(source.path, exclude: PterodactylTransferPathPolicy.excludes);
        final PterodactylTransferFileManifest targetManifest = await engine
            .scan(target.path, exclude: PterodactylTransferPathPolicy.excludes);

        expect(targetManifest.excludedContentDirectories, contains('world'));
        expect(
          engine.diff(
            source: sourceManifest,
            target: targetManifest,
            mode: PterodactylTransferMode.mirror,
          ),
          isEmpty,
        );
      },
    );

    test('dereferences only instance or explicit safe content roots', () async {
      if (Platform.isWindows) return;
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-transfer-links-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final Directory instance = Directory(
        p.join(temporary.path, 'external-instance'),
      )..createSync();
      final Directory builds = Directory(p.join(temporary.path, 'builds'))
        ..createSync();
      final Directory privateKeys = Directory(
        p.join(temporary.path, '.multiplexor', 'pterodactyl-smb', 'keys'),
      )..createSync(recursive: true);
      _write(builds.path, 'server.jar', 'jar');
      _write(instance.path, 'internal.txt', 'inside');
      _write(privateKeys.path, 'panel.ed25519', 'private');
      Link(
        p.join(instance.path, 'server.jar'),
      ).createSync(p.join(builds.path, 'server.jar'));
      Link(
        p.join(instance.path, 'internal-link.txt'),
      ).createSync(p.join(instance.path, 'internal.txt'));
      const PterodactylTransferFileEngine engine =
          PterodactylTransferFileEngine();

      final PterodactylTransferFileManifest safe = await engine.scan(
        instance.path,
        allowSymlinks: true,
        allowedSymlinkRoots: <String>[builds.path],
      );
      expect(safe.files['server.jar']!.size, 3);
      expect(safe.files['internal-link.txt']!.size, 6);

      Link(
        p.join(instance.path, 'private-key'),
      ).createSync(p.join(privateKeys.path, 'panel.ed25519'));
      await expectLater(
        engine.scan(
          instance.path,
          allowSymlinks: true,
          allowedSymlinkRoots: <String>[builds.path],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('replaces a destination link without writing through it', () async {
      if (Platform.isWindows) return;
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-transfer-destination-link-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final Directory source = Directory(p.join(temporary.path, 'source'))
        ..createSync();
      final Directory target = Directory(p.join(temporary.path, 'target'))
        ..createSync();
      final File shared = File(p.join(temporary.path, 'shared.json'))
        ..writeAsStringSync('shared');
      _write(source.path, 'ops.json', 'pulled');
      Link(p.join(target.path, 'ops.json')).createSync(shared.path);
      const PterodactylTransferFileEngine engine =
          PterodactylTransferFileEngine();
      final PterodactylTransferFileManifest sourceManifest = await engine.scan(
        source.path,
      );
      final PterodactylTransferFileManifest targetManifest = await engine.scan(
        target.path,
        allowSymlinks: true,
        allowedSymlinkRoot: temporary.path,
      );

      await engine.apply(
        source: sourceManifest,
        targetRootPath: target.path,
        changes: engine.diff(
          source: sourceManifest,
          target: targetManifest,
          mode: PterodactylTransferMode.update,
        ),
        mode: PterodactylTransferMode.update,
        operationId: 'test',
        replaceDestinationLinks: true,
      );

      expect(shared.readAsStringSync(), 'shared');
      expect(
        FileSystemEntity.typeSync(
          p.join(target.path, 'ops.json'),
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      expect(
        File(p.join(target.path, 'ops.json')).readAsStringSync(),
        'pulled',
      );
    });
  });

  test('link store uses collision-safe adjacent metadata files', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-link-store-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    const PterodactylTransferLinkStore store = PterodactylTransferLinkStore();
    final DateTime firstTime = DateTime.utc(2026, 1, 1);
    final PterodactylRemoteLink first = PterodactylRemoteLink(
      profileId: 'panel',
      serverIdentifier: 'one',
      serverUuid: 'uuid-one',
      serverName: 'One',
      localInstanceName: 'local',
      localConsumer: 'plugin',
      linkedAt: firstTime,
      lastTransferredAt: firstTime,
    );
    store.save(temporary.path, first);
    File(
      p.join(
        temporary.path,
        '${PterodactylTransferLinkStore.fileName}.previous',
      ),
    ).writeAsStringSync('blocked');

    File(
      p.join(temporary.path, '${PterodactylTransferLinkStore.fileName}.tmp'),
    ).writeAsStringSync('unrelated fixed collision');

    store.save(
      temporary.path,
      PterodactylRemoteLink(
        profileId: 'panel',
        serverIdentifier: 'two',
        serverUuid: 'uuid-two',
        serverName: 'Two',
        localInstanceName: 'local',
        localConsumer: 'plugin',
        linkedAt: firstTime,
        lastTransferredAt: firstTime,
      ),
    );

    expect(store.load(temporary.path)!.serverIdentifier, 'two');
    expect(
      File(
        p.join(temporary.path, '${PterodactylTransferLinkStore.fileName}.tmp'),
      ).readAsStringSync(),
      'unrelated fixed collision',
    );
    expect(
      Directory(temporary.path)
          .listSync(followLinks: false)
          .map((FileSystemEntity entity) => p.basename(entity.path))
          .where(
            (String name) =>
                name.startsWith(
                  '${PterodactylTransferLinkStore.fileName}.tmp.',
                ) ||
                name.startsWith(
                  '${PterodactylTransferLinkStore.fileName}.previous.',
                ),
          ),
      isEmpty,
    );
  });

  test('link store refuses link metadata symlinks without touching target', () {
    if (Platform.isWindows) return;
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-link-symlink-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final File outside = File(
      p.join(temporary.parent.path, 'outside-link.json'),
    )..writeAsStringSync('keep outside');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });
    Link(
      p.join(temporary.path, PterodactylTransferLinkStore.fileName),
    ).createSync(outside.path);
    const PterodactylTransferLinkStore store = PterodactylTransferLinkStore();

    expect(() => store.load(temporary.path), throwsStateError);
    expect(
      () => store.save(
        temporary.path,
        PterodactylRemoteLink(
          profileId: 'panel',
          serverIdentifier: 'one',
          serverUuid: 'uuid-one',
          serverName: 'One',
          localInstanceName: 'local',
          localConsumer: 'plugin',
          linkedAt: DateTime.utc(2026),
          lastTransferredAt: DateTime.utc(2026),
        ),
      ),
      throwsStateError,
    );
    expect(outside.readAsStringSync(), 'keep outside');
  });

  test('link store refuses a symlinked instance root', () {
    if (Platform.isWindows) return;
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-link-root-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final Directory real = Directory(p.join(temporary.path, 'real'))
      ..createSync();
    final Link redirected = Link(p.join(temporary.path, 'redirected'))
      ..createSync(real.path);
    const PterodactylTransferLinkStore store = PterodactylTransferLinkStore();

    expect(() => store.load(redirected.path), throwsStateError);
    expect(
      File(
        p.join(real.path, PterodactylTransferLinkStore.fileName),
      ).existsSync(),
      isFalse,
    );
  });

  test('link store refuses a symlinked instance parent', () {
    if (Platform.isWindows) return;
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-link-parent-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final Directory realParent = Directory(
      p.join(temporary.path, 'real-parent'),
    )..createSync();
    Directory(p.join(realParent.path, 'instance')).createSync();
    final Link redirectedParent = Link(
      p.join(temporary.path, 'redirected-parent'),
    )..createSync(realParent.path);
    const PterodactylTransferLinkStore store = PterodactylTransferLinkStore();

    expect(
      () => store.load(p.join(redirectedParent.path, 'instance')),
      throwsStateError,
    );
  });

  group('transfer service', () {
    late Directory temporary;
    late _FakeLocalGateway local;
    late _FakeRemoteGateway remote;
    late PterodactylTransferService service;
    final DateTime clock = DateTime.utc(2026, 8, 14, 20, 30);

    PterodactylTransferService createService({
      Duration remoteReadyTimeout = const Duration(milliseconds: 10),
      List<Duration>? observedDelays,
    }) => PterodactylTransferService.withGateways(
      metadataDirectoryPath: p.join(temporary.path, '.multiplexor'),
      remoteGateway: remote,
      localInstances: local,
      clock: () => clock,
      remoteReadyTimeout: remoteReadyTimeout,
      delay: (Duration duration) async {
        observedDelays?.add(duration);
      },
    );

    setUp(() {
      temporary = Directory.systemTemp.createTempSync(
        'multiplexor-transfer-service-',
      );
      local = _FakeLocalGateway(p.join(temporary.path, 'local'));
      remote = _FakeRemoteGateway(p.join(temporary.path, 'remote'));
      service = createService();
    });

    tearDown(() {
      temporary.deleteSync(recursive: true);
    });

    test('pull imports a stopped Remote into a new linked Local', () async {
      _write(remote.folder.path, 'server.jar', 'jar');
      _write(remote.folder.path, 'world/level.dat', 'world');
      Directory(
        p.join(remote.folder.path, 'plugins', 'empty', 'nested'),
      ).createSync(recursive: true);
      remote.target = _target(launchJar: 'server.jar');

      final PterodactylTransferPlan plan = await service.planPull(
        profileId: 'panel',
        serverIdentifier: 'abc123',
        localInstanceName: 'pulled',
      );
      final PterodactylTransferResult result = await service.pull(
        profileId: 'panel',
        serverIdentifier: 'abc123',
        localInstanceName: 'pulled',
        expectedPlanToken: plan.confirmationToken,
      );

      expect(
        File(p.join(result.localInstance.path, 'server.jar')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(result.localInstance.path, 'world', 'level.dat'),
        ).readAsStringSync(),
        'world',
      );
      expect(
        Directory(
          p.join(result.localInstance.path, 'plugins', 'empty', 'nested'),
        ).existsSync(),
        isTrue,
      );
      expect(
        plan.changes.any(
          (PterodactylTransferChange change) =>
              change.entryKind == PterodactylTransferEntryKind.directory &&
              change.path == 'plugins/empty/nested',
        ),
        isTrue,
      );
      expect(
        File(
          p.join(result.localInstance.path, '.server-source'),
        ).readAsStringSync(),
        contains('jar_rel=server.jar'),
      );
      expect(
        File(
          p.join(result.localInstance.path, '.server-source'),
        ).readAsStringSync(),
        contains('isolated=true'),
      );
      expect(result.link.serverIdentifier, 'abc123');
      expect(result.linkPersisted, isTrue);
      expect(await service.linkForLocalInstance('pulled'), isNotNull);
      expect(
        File(p.join(result.localInstance.path, 'eula.txt')).existsSync(),
        isFalse,
      );
      expect(remote.stopCount, 0);
      expect(remote.startCount, 0);
    });

    test('pull preserves isolation and infers a safe Forge argsfile', () async {
      final String argsFileName = Platform.isWindows
          ? 'win_args.txt'
          : 'unix_args.txt';
      final String argsFilePath =
          'libraries/net/minecraftforge/forge/$argsFileName';
      _write(remote.folder.path, argsFilePath, '--launchTarget forge_server');
      _write(remote.folder.path, 'world/level.dat', 'world');
      remote.target = _target(launchArgsFile: argsFilePath);

      final PterodactylTransferPlan plan = await service.planPull(
        profileId: 'panel',
        serverIdentifier: 'abc123',
        localInstanceName: 'forge-pull',
      );
      final PterodactylTransferResult result = await service.pull(
        profileId: 'panel',
        serverIdentifier: 'abc123',
        localInstanceName: 'forge-pull',
        expectedPlanToken: plan.confirmationToken,
      );

      final String metadata = File(
        p.join(result.localInstance.path, '.server-source'),
      ).readAsStringSync();
      expect(metadata, contains('isolated=true'));
      expect(metadata, contains('launch=argsfile'));
      expect(metadata, contains('args_file_rel=$argsFilePath'));
      expect(result.warnings, isEmpty);
    });

    test('pull refuses a live Remote without creating Local state', () async {
      remote.currentState = PterodactylTransferRemoteState.running;
      _write(remote.folder.path, 'server.jar', 'jar');

      await expectLater(
        service.planPull(
          profileId: 'panel',
          serverIdentifier: 'abc123',
          localInstanceName: 'unsafe',
        ),
        throwsA(isA<StateError>()),
      );

      expect(local.instances, isEmpty);
      expect(remote.stopCount, 0);
    });

    test(
      'update push preserves Remote-only files and restores runtime',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(instance.path, 'plugins/example.jar', 'plugin');
        _write(instance.path, '.server-source', 'type=custom');
        _write(instance.path, 'logs/latest.log', 'local log');
        _write(remote.folder.path, 'server.properties', 'old');
        _write(remote.folder.path, 'remote-only.txt', 'preserve');
        _write(remote.folder.path, 'logs/latest.log', 'remote log');
        remote.currentState = PterodactylTransferRemoteState.running;
        remote.onStop = () {
          _write(remote.folder.path, 'shutdown-created.dat', 'flushed');
        };

        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );
        final PterodactylTransferResult result = await service.push(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
          expectedPlanToken: plan.confirmationToken,
        );

        expect(
          File(
            p.join(remote.folder.path, 'server.properties'),
          ).readAsStringSync(),
          'new',
        );
        expect(
          File(
            p.join(remote.folder.path, 'remote-only.txt'),
          ).readAsStringSync(),
          'preserve',
        );
        expect(
          File(
            p.join(remote.folder.path, 'logs/latest.log'),
          ).readAsStringSync(),
          'remote log',
        );
        expect(
          File(p.join(remote.folder.path, '.server-source')).existsSync(),
          isFalse,
        );
        expect(remote.stopCount, 1);
        expect(remote.startCount, 1);
        expect(result.remoteRestarted, isTrue);
        expect(result.linkPersisted, isFalse);
        expect(result.backupPath, isNotNull);
        expect(
          File(
            p.join(result.backupPath!, 'server.properties'),
          ).readAsStringSync(),
          'old',
        );
        expect(
          File(p.join(result.backupPath!, 'shutdown-created.dat')).existsSync(),
          isTrue,
        );
        final Map<String, Object?> recovery = _json(
          result.recoveryManifestPath!,
        );
        expect(recovery['status'], 'completed');
      },
    );

    test(
      'mirror aborts when stopping exposes a new deletion candidate',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        _write(remote.folder.path, 'old.txt', 'delete');
        remote.currentState = PterodactylTransferRemoteState.running;
        remote.onStop = () {
          _write(remote.folder.path, 'new-after-preview.txt', 'new');
        };

        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
          mode: PterodactylTransferMode.mirror,
        );
        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            mode: PterodactylTransferMode.mirror,
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsA(isA<StateError>()),
        );

        expect(
          File(p.join(remote.folder.path, 'old.txt')).existsSync(),
          isTrue,
        );
        expect(remote.stopCount, 1);
        expect(remote.startCount, 1);
        expect(
          Directory(
            p.join(
              temporary.path,
              '.multiplexor',
              'pterodactyl-transfers',
              'backups',
            ),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'failed upload rolls back backup and restores prior runtime',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.currentState = PterodactylTransferRemoteState.running;
        remote.failApplyAfterMutation = true;

        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );
        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsA(isA<StateError>()),
        );

        expect(
          File(
            p.join(remote.folder.path, 'server.properties'),
          ).readAsStringSync(),
          'old',
        );
        expect(remote.stopCount, 1);
        expect(remote.startCount, 1);
        final List<File> manifests =
            Directory(
                  p.join(
                    temporary.path,
                    '.multiplexor',
                    'pterodactyl-transfers',
                  ),
                )
                .listSync(recursive: true)
                .whereType<File>()
                .where((File file) => p.basename(file.path) == 'recovery.json')
                .toList(growable: false);
        expect(manifests, hasLength(1));
        expect(_json(manifests.single.path)['status'], 'rolled_back');
      },
    );

    test('no-op push does not stop or create a backup', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'same');
      _write(remote.folder.path, 'server.properties', 'same');
      Directory(
        p.join(instance.path, 'empty', 'nested'),
      ).createSync(recursive: true);
      Directory(
        p.join(remote.folder.path, 'empty', 'nested'),
      ).createSync(recursive: true);
      remote.currentState = PterodactylTransferRemoteState.running;

      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );
      expect(plan.isNoop, isTrue);
      final PterodactylTransferResult result = await service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        expectedPlanToken: plan.confirmationToken,
      );

      expect(result.backupPath, isNull);
      expect(remote.stopCount, 0);
      expect(remote.startCount, 0);
    });

    test('update push applies an empty-directory-only delta', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'same');
      _write(remote.folder.path, 'server.properties', 'same');
      Directory(
        p.join(instance.path, 'plugins', 'empty', 'nested'),
      ).createSync(recursive: true);

      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );
      expect(plan.isNoop, isFalse);
      expect(
        plan.changes.any(
          (PterodactylTransferChange change) =>
              change.entryKind == PterodactylTransferEntryKind.directory,
        ),
        isTrue,
      );
      await service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        expectedPlanToken: plan.confirmationToken,
      );

      expect(
        Directory(
          p.join(remote.folder.path, 'plugins', 'empty', 'nested'),
        ).existsSync(),
        isTrue,
      );
      expect(remote.applyCount, 1);
    });

    test('mirror push removes a remote-only empty directory tree', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'same');
      _write(remote.folder.path, 'server.properties', 'same');
      Directory(
        p.join(remote.folder.path, 'orphan', 'empty', 'nested'),
      ).createSync(recursive: true);

      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        mode: PterodactylTransferMode.mirror,
      );
      expect(plan.isNoop, isFalse);
      expect(
        plan.changes.any(
          (PterodactylTransferChange change) =>
              change.entryKind == PterodactylTransferEntryKind.directory &&
              change.kind == PterodactylTransferChangeKind.delete,
        ),
        isTrue,
      );
      await service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        mode: PterodactylTransferMode.mirror,
        expectedPlanToken: plan.confirmationToken,
      );

      expect(
        Directory(p.join(remote.folder.path, 'orphan')).existsSync(),
        isFalse,
      );
      expect(remote.applyCount, 1);
    });

    test(
      'missing empty directory after apply fails verification and rolls back',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'same');
        _write(remote.folder.path, 'server.properties', 'same');
        final Directory required = Directory(
          p.join(instance.path, 'plugins', 'required-empty'),
        )..createSync(recursive: true);
        remote.onSnapshot = (int count) async {
          if (count == 5) {
            final Directory uploaded = Directory(
              p.join(remote.folder.path, 'plugins', 'required-empty'),
            );
            if (uploaded.existsSync()) uploaded.deleteSync(recursive: true);
          }
        };

        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );
        expect(required.existsSync(), isTrue);
        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsStateError,
        );

        expect(remote.restoreCount, 1);
        expect(
          Directory(p.join(remote.folder.path, 'plugins')).existsSync(),
          isFalse,
        );
        expect(_latestRecoveryStatus(temporary.path), 'rolled_back');
      },
    );

    test(
      'same-target Push refreshes an existing link without relink',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        const PterodactylTransferLinkStore store =
            PterodactylTransferLinkStore();
        final DateTime old = DateTime.utc(2025);
        store.save(
          instance.path,
          PterodactylRemoteLink(
            profileId: 'panel',
            serverIdentifier: 'abc123',
            serverUuid: 'uuid-abc123',
            serverName: 'Survival',
            localInstanceName: 'local',
            localConsumer: 'plugin',
            linkedAt: old,
            lastTransferredAt: old,
          ),
        );

        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
        );
        final PterodactylTransferResult result = await service.push(
          localInstanceName: 'local',
          expectedPlanToken: plan.confirmationToken,
        );

        expect(result.linkPersisted, isTrue);
        expect(result.link.linkedAt, old);
        expect(result.link.lastTransferredAt, clock);
      },
    );

    test(
      'Create & Push waits for offline target and never starts it',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'egg default');
        remote.installStatuses.addAll(<String?>['installing', null]);

        final PterodactylTransferPlan plan = await service.planNewPush(
          localInstanceName: 'local',
          profileId: 'panel',
          proposedServerName: 'New Survival',
        );
        final PterodactylTransferResult result = await service.pushNew(
          plan: plan,
          createdServerIdentifier: 'abc123',
          relink: false,
        );

        expect(
          File(
            p.join(remote.folder.path, 'server.properties'),
          ).readAsStringSync(),
          'new',
        );
        expect(result.remoteRestarted, isFalse);
        expect(result.linkPersisted, isFalse);
        expect(remote.stopCount, 0);
        expect(remote.startCount, 0);
      },
    );

    test('Create & Push rejects Local changes during install wait', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'confirmed');
      _write(remote.folder.path, 'server.properties', 'egg default');
      remote.installStatuses.addAll(<String?>['installing', null]);
      remote.onResolveTarget = (int count) {
        if (count == 1) {
          _write(instance.path, 'server.properties', 'changed during install');
        }
      };
      final PterodactylTransferPlan plan = await service.planNewPush(
        localInstanceName: 'local',
        profileId: 'panel',
        proposedServerName: 'New Survival',
      );

      await expectLater(
        service.pushNew(
          plan: plan,
          createdServerIdentifier: 'abc123',
          relink: false,
        ),
        throwsStateError,
      );

      expect(remote.applyCount, 0);
      expect(remote.startCount, 0);
      expect(
        File(
          p.join(remote.folder.path, 'server.properties'),
        ).readAsStringSync(),
        'egg default',
      );
    });

    test(
      'postcondition repair persists link and accepts already-running target',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        remote.currentState = PterodactylTransferRemoteState.running;
        final PterodactylTransferPlan plan = await service.planNewPush(
          localInstanceName: 'local',
          profileId: 'panel',
          proposedServerName: 'Survival',
        );

        final PterodactylTransferResult result = await service
            .repairNewPushPostconditions(
              plan: plan,
              createdServerIdentifier: 'abc123',
              relink: true,
              startAfter: true,
            );

        expect(result.linkPersisted, isTrue);
        expect(result.remoteRestarted, isTrue);
        expect(result.link.serverUuid, 'uuid-abc123');
        expect(remote.startCount, 0);
        expect(remote.snapshotCount, 0);
        expect(remote.applyCount, 0);
        expect(
          const PterodactylTransferLinkStore().load(instance.path)!.serverUuid,
          'uuid-abc123',
        );
      },
    );

    test('postcondition repair retries a previously failed start', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      final PterodactylTransferPlan plan = await service.planNewPush(
        localInstanceName: 'local',
        profileId: 'panel',
        proposedServerName: 'Survival',
      );

      final PterodactylTransferResult result = await service
          .repairNewPushPostconditions(
            plan: plan,
            createdServerIdentifier: 'abc123',
            relink: false,
            startAfter: true,
          );

      expect(result.linkPersisted, isFalse);
      expect(result.remoteRestarted, isTrue);
      expect(remote.startCount, 1);
      expect(remote.currentState, PterodactylTransferRemoteState.running);
      expect(remote.snapshotCount, 0);
      expect(remote.applyCount, 0);
    });

    test(
      'postcondition start accepts delayed offline to starting transition',
      () async {
        final List<Duration> observedDelays = <Duration>[];
        service = createService(
          remoteReadyTimeout: const Duration(seconds: 3),
          observedDelays: observedDelays,
        );
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        final PterodactylTransferPlan plan = await service.planNewPush(
          localInstanceName: 'local',
          profileId: 'panel',
          proposedServerName: 'Survival',
        );
        remote.statesAfterStart.addAll(<PterodactylTransferRemoteState>[
          PterodactylTransferRemoteState.offline,
          PterodactylTransferRemoteState.offline,
          PterodactylTransferRemoteState.starting,
          PterodactylTransferRemoteState.running,
        ]);

        final PterodactylTransferResult result = await service
            .repairNewPushPostconditions(
              plan: plan,
              createdServerIdentifier: 'abc123',
              relink: false,
              startAfter: true,
            );

        expect(result.remoteRestarted, isTrue);
        expect(result.warnings, isEmpty);
        expect(remote.startCount, 1);
        expect(remote.stateCountAfterStart, 4);
        expect(observedDelays, hasLength(3));
        expect(observedDelays, everyElement(const Duration(milliseconds: 500)));
      },
    );

    test('postcondition start fails promptly after a real crash', () async {
      final List<Duration> observedDelays = <Duration>[];
      service = createService(
        remoteReadyTimeout: const Duration(seconds: 30),
        observedDelays: observedDelays,
      );
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      final PterodactylTransferPlan plan = await service.planNewPush(
        localInstanceName: 'local',
        profileId: 'panel',
        proposedServerName: 'Survival',
      );
      remote.statesAfterStart.addAll(<PterodactylTransferRemoteState>[
        PterodactylTransferRemoteState.starting,
        PterodactylTransferRemoteState.offline,
        PterodactylTransferRemoteState.running,
      ]);

      final PterodactylTransferResult result = await service
          .repairNewPushPostconditions(
            plan: plan,
            createdServerIdentifier: 'abc123',
            relink: false,
            startAfter: true,
          );

      expect(result.remoteRestarted, isFalse);
      expect(
        result.warnings,
        contains(contains('returned offline after reporting starting')),
      );
      expect(remote.startCount, 1);
      expect(remote.stateCountAfterStart, 2);
      expect(observedDelays, <Duration>[const Duration(milliseconds: 500)]);
      expect(remote.statesAfterStart, <PterodactylTransferRemoteState>[
        PterodactylTransferRemoteState.running,
      ]);
    });

    test('postcondition start bounds a permanently offline target', () async {
      final List<Duration> observedDelays = <Duration>[];
      service = createService(
        remoteReadyTimeout: const Duration(seconds: 30),
        observedDelays: observedDelays,
      );
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      final PterodactylTransferPlan plan = await service.planNewPush(
        localInstanceName: 'local',
        profileId: 'panel',
        proposedServerName: 'Survival',
      );
      remote.statesAfterStart.add(PterodactylTransferRemoteState.offline);

      final PterodactylTransferResult result = await service
          .repairNewPushPostconditions(
            plan: plan,
            createdServerIdentifier: 'abc123',
            relink: false,
            startAfter: true,
          );

      expect(result.remoteRestarted, isFalse);
      expect(result.warnings, contains(contains('last state: offline')));
      expect(remote.startCount, 1);
      expect(remote.stateCountAfterStart, 21);
      expect(observedDelays, hasLength(20));
      expect(observedDelays, everyElement(const Duration(milliseconds: 500)));
    });

    test('mirror preserves excluded Remote runtime files', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      _write(remote.folder.path, 'server.properties', 'old');
      _write(remote.folder.path, 'logs/latest.log', 'log');
      _write(remote.folder.path, 'crash-reports/crash.txt', 'crash');
      _write(remote.folder.path, 'world/session.lock', 'lock');
      _write(remote.folder.path, '.multiplexor-transfer/recovery.tmp', 'temp');
      _write(
        remote.folder.path,
        'world/.multiplexor-transfer/recovery.tmp',
        'nested temp',
      );
      _write(
        remote.folder.path,
        'world/.level.dat.multiplexor-a1-stage.part',
        'partial write',
      );
      _write(remote.folder.path, '.multiplexor-remote.json', 'metadata');

      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        mode: PterodactylTransferMode.mirror,
      );
      await service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        mode: PterodactylTransferMode.mirror,
        expectedPlanToken: plan.confirmationToken,
      );

      for (final String path in <String>[
        'logs/latest.log',
        'crash-reports/crash.txt',
        'world/session.lock',
        '.multiplexor-transfer/recovery.tmp',
        'world/.multiplexor-transfer/recovery.tmp',
        'world/.level.dat.multiplexor-a1-stage.part',
        '.multiplexor-remote.json',
      ]) {
        expect(File(p.join(remote.folder.path, path)).existsSync(), isTrue);
      }
    });

    test(
      'Push waits for synchronous apply and verification before restart',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.currentState = PterodactylTransferRemoteState.running;
        remote.applyGate = Completer<void>();
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );

        bool completed = false;
        final Future<PterodactylTransferResult> push = service
            .push(
              localInstanceName: 'local',
              profileId: 'panel',
              serverIdentifier: 'abc123',
              expectedPlanToken: plan.confirmationToken,
            )
            .whenComplete(() => completed = true);
        await _waitFor(() => remote.applyCount == 1);
        expect(completed, isFalse);
        expect(remote.startCount, 0);

        remote.applyGate!.complete();
        final PterodactylTransferResult result = await push;
        expect(result.remoteRestarted, isTrue);
        expect(remote.startCount, 1);
      },
    );

    test(
      'failed post-upload verification rolls back and stays stopped',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.corruptAfterApply = true;
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );

        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsStateError,
        );

        expect(remote.restoreCount, 1);
        expect(remote.startCount, 0);
        expect(remote.currentState, PterodactylTransferRemoteState.offline);
        expect(
          File(
            p.join(remote.folder.path, 'server.properties'),
          ).readAsStringSync(),
          'old',
        );
        expect(_latestRecoveryStatus(temporary.path), 'rolled_back');
      },
    );

    test(
      'Remote start after final verification aborts commit and rolls back',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.onSnapshot = (int count) async {
          if (count == 5) {
            remote.currentState = PterodactylTransferRemoteState.running;
          }
        };
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );

        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsStateError,
        );

        expect(remote.stopCount, 1);
        expect(remote.restoreCount, 1);
        expect(remote.currentState, PterodactylTransferRemoteState.offline);
        expect(
          File(
            p.join(remote.folder.path, 'server.properties'),
          ).readAsStringSync(),
          'old',
        );
        expect(_latestRecoveryStatus(temporary.path), 'rolled_back');
      },
    );

    test('Remote UUID change after verification is never committed', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      _write(remote.folder.path, 'server.properties', 'old');
      remote.onSnapshot = (int count) async {
        if (count == 5) remote.target = _target(uuid: 'replacement-uuid');
      };
      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );

      await expectLater(
        service.push(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
          expectedPlanToken: plan.confirmationToken,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => '$error',
            'message',
            contains('rollback verification also failed'),
          ),
        ),
      );

      expect(remote.restoreCount, 0);
      expect(_latestRecoveryStatus(temporary.path), 'rollback_failed');
    });

    test(
      'rollback stops a target that starts during verification and recaptures',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.failApplyAfterMutation = true;
        remote.onSnapshot = (int count) async {
          if (count == 5) {
            remote.currentState = PterodactylTransferRemoteState.running;
          }
        };
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );

        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsStateError,
        );

        expect(remote.stopCount, 1);
        expect(remote.restoreCount, 1);
        expect(remote.snapshotCount, 6);
        expect(remote.currentState, PterodactylTransferRemoteState.offline);
        expect(_latestRecoveryStatus(temporary.path), 'rolled_back');
      },
    );

    test(
      'failed rollback verification leaves Remote stopped and recoverable',
      () async {
        final PterodactylLocalInstance instance = local.seed('local');
        _write(instance.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        remote.corruptAfterApply = true;
        remote.failRollbackVerification = true;
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );

        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsA(
            isA<StateError>().having(
              (StateError error) => '$error',
              'message',
              contains('rollback verification also failed'),
            ),
          ),
        );

        expect(remote.startCount, 0);
        expect(remote.currentState, PterodactylTransferRemoteState.offline);
        expect(_latestRecoveryStatus(temporary.path), 'rollback_failed');
      },
    );

    test('concurrent Push is rejected before a second mutation', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      _write(remote.folder.path, 'server.properties', 'old');
      remote.applyGate = Completer<void>();
      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );
      final Future<PterodactylTransferResult> first = service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        expectedPlanToken: plan.confirmationToken,
      );
      await _waitFor(() => remote.applyCount == 1);

      await expectLater(
        service.push(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
          expectedPlanToken: plan.confirmationToken,
        ),
        throwsA(isA<StateError>()),
      );
      expect(remote.applyCount, 1);

      remote.applyGate!.complete();
      await first;
    });

    test('Remote state change after snapshot aborts before apply', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      _write(remote.folder.path, 'server.properties', 'old');
      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );
      remote.onSnapshot = (int count) async {
        if (count == 4) {
          remote.currentState = PterodactylTransferRemoteState.running;
        }
      };

      await expectLater(
        service.push(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
          expectedPlanToken: plan.confirmationToken,
        ),
        throwsStateError,
      );

      expect(remote.applyCount, 0);
      expect(
        File(
          p.join(remote.folder.path, 'server.properties'),
        ).readAsStringSync(),
        'old',
      );
    });

    test(
      'confirmation is bound to the exact Local consumer and path',
      () async {
        final PterodactylLocalInstance plugin = local.seed('local');
        final PterodactylLocalInstance fabric = local.seed(
          'local',
          consumer: 'fabric',
        );
        _write(plugin.path, 'server.properties', 'new');
        _write(fabric.path, 'server.properties', 'new');
        _write(remote.folder.path, 'server.properties', 'old');
        final PterodactylTransferPlan plan = await service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        );
        local.activeConsumer = 'fabric';

        await expectLater(
          service.push(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
            expectedPlanToken: plan.confirmationToken,
          ),
          throwsStateError,
        );
        expect(remote.applyCount, 0);
        expect(plan.localConsumer, 'plugin');
        expect(
          plan.localInstancePath,
          Directory(plugin.path).resolveSymbolicLinksSync(),
        );
      },
    );

    test('implicit linked Push enforces the saved immutable UUID', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      const PterodactylTransferLinkStore store = PterodactylTransferLinkStore();
      final DateTime linkedAt = DateTime.utc(2025);
      store.save(
        instance.path,
        PterodactylRemoteLink(
          profileId: 'panel',
          serverIdentifier: 'abc123',
          serverUuid: 'replaced-server-uuid',
          serverName: 'Old Survival',
          localInstanceName: 'local',
          localConsumer: 'plugin',
          linkedAt: linkedAt,
          lastTransferredAt: linkedAt,
        ),
      );

      await expectLater(
        service.planPush(localInstanceName: 'local'),
        throwsA(
          isA<StateError>().having(
            (StateError error) => '$error',
            'message',
            contains('saved Remote UUID'),
          ),
        ),
      );
      expect(remote.snapshotCount, 0);
    });

    test('unstable install and maintenance targets are rejected', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      remote.target = _target(installStatus: 'restoring_backup');
      await expectLater(
        service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        ),
        throwsStateError,
      );
      remote.target = _target(nodeUnderMaintenance: true);
      await expectLater(
        service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        ),
        throwsStateError,
      );
      expect(remote.snapshotCount, 0);
    });

    test('external protected metadata launch links are rejected', () async {
      if (Platform.isWindows) return;
      final File secret = File(
        p.join(
          temporary.path,
          '.multiplexor',
          'pterodactyl-smb',
          'keys',
          'stolen.jar',
        ),
      );
      secret.parent.createSync(recursive: true);
      secret.writeAsStringSync('private key material');
      final PterodactylLocalInstance instance = local.seed('local');
      Link(p.join(instance.path, 'server.jar')).createSync(secret.path);

      await expectLater(
        service.planPush(
          localInstanceName: 'local',
          profileId: 'panel',
          serverIdentifier: 'abc123',
        ),
        throwsStateError,
      );
      expect(remote.snapshotCount, 0);
    });

    test(
      'external launch links through a harmless-looking parent are rejected',
      () async {
        if (Platform.isWindows) return;
        final File secret = File(
          p.join(
            temporary.path,
            '.multiplexor',
            'pterodactyl-smb',
            'keys',
            'stolen.jar',
          ),
        );
        secret.parent.createSync(recursive: true);
        secret.writeAsStringSync('private key material');
        final Link disguisedParent = Link(
          p.join(temporary.path, 'apparently-safe-jars'),
        )..createSync(secret.parent.path);
        final String disguisedTarget = p.join(
          disguisedParent.path,
          'stolen.jar',
        );
        final PterodactylLocalInstance instance = local.seed('local');
        Link(p.join(instance.path, 'server.jar')).createSync(disguisedTarget);

        await expectLater(
          service.planPush(
            localInstanceName: 'local',
            profileId: 'panel',
            serverIdentifier: 'abc123',
          ),
          throwsStateError,
        );
        expect(remote.snapshotCount, 0);
      },
    );

    test('post-commit link failure does not roll Remote back', () async {
      final PterodactylLocalInstance instance = local.seed('local');
      _write(instance.path, 'server.properties', 'new');
      _write(remote.folder.path, 'server.properties', 'old');
      remote.onSnapshot = (int count) async {
        if (count == 5) {
          Directory(
            p.join(instance.path, PterodactylTransferLinkStore.fileName),
          ).createSync();
        }
      };
      final PterodactylTransferPlan plan = await service.planPush(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
      );

      final PterodactylTransferResult result = await service.push(
        localInstanceName: 'local',
        profileId: 'panel',
        serverIdentifier: 'abc123',
        expectedPlanToken: plan.confirmationToken,
        relink: true,
      );

      expect(result.linkPersisted, isFalse);
      expect(result.warnings.join(' '), contains('link could not be saved'));
      expect(remote.restoreCount, 0);
      expect(
        File(
          p.join(remote.folder.path, 'server.properties'),
        ).readAsStringSync(),
        'new',
      );
    });
  });
}

void _write(String root, String relative, String contents) {
  final File file = File(p.joinAll(<String>[root, ...p.posix.split(relative)]));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

Map<String, Object?> _json(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  return decoded! as Map<String, Object?>;
}

String _latestRecoveryStatus(String temporaryPath) {
  final List<File> manifests =
      Directory(
            p.join(
              temporaryPath,
              '.multiplexor',
              'pterodactyl-transfers',
              'backups',
            ),
          )
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) {
            return p.basename(file.path) == 'recovery.json';
          })
          .toList(growable: false);
  expect(manifests, hasLength(1));
  return _json(manifests.single.path)['status']! as String;
}

Future<void> _waitFor(bool Function() condition) async {
  for (int attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for asynchronous transfer state.');
}

PterodactylTransferRemoteTarget _target({
  String uuid = 'uuid-abc123',
  String? launchJar,
  String? launchArgsFile,
  String? installStatus,
  bool nodeUnderMaintenance = false,
}) => PterodactylTransferRemoteTarget(
  profileId: 'panel',
  identifier: 'abc123',
  uuid: uuid,
  name: 'Survival',
  launchJar: launchJar,
  launchArgsFile: launchArgsFile,
  installStatus: installStatus,
  nodeUnderMaintenance: nodeUnderMaintenance,
);

final class _FakeLocalGateway implements PterodactylLocalInstanceGateway {
  _FakeLocalGateway(this.rootPath) {
    Directory(rootPath).createSync(recursive: true);
  }

  final String rootPath;
  final Map<String, PterodactylLocalInstance> instances =
      <String, PterodactylLocalInstance>{};
  final Set<String> running = <String>{};
  String activeConsumer = 'plugin';

  PterodactylLocalInstance seed(String name, {String consumer = 'plugin'}) {
    final Directory directory = Directory(p.join(rootPath, consumer, name))
      ..createSync(recursive: true);
    final PterodactylLocalInstance instance = PterodactylLocalInstance(
      name: name,
      consumer: consumer,
      path: directory.path,
    );
    instances['$consumer:$name'] = instance;
    return instance;
  }

  @override
  Future<String> currentConsumer() async => activeConsumer;

  @override
  Future<PterodactylLocalInstance> createStopped(
    String name, {
    String? consumer,
  }) async {
    final String selectedConsumer = consumer ?? activeConsumer;
    if (instances.containsKey('$selectedConsumer:$name')) {
      throw StateError('Local instance already exists: $name');
    }
    final PterodactylLocalInstance instance = seed(
      name,
      consumer: selectedConsumer,
    );
    Directory(p.join(instance.path, 'plugins')).createSync();
    Directory(p.join(instance.path, 'logs')).createSync();
    _write(instance.path, 'eula.txt', 'eula=true');
    _write(instance.path, '.server-source', 'isolated=true\n');
    return instance;
  }

  @override
  Future<void> delete(PterodactylLocalInstance instance) async {
    Directory(instance.path).deleteSync(recursive: true);
    instances.remove('${instance.consumer}:${instance.name}');
    running.remove(instance.name);
  }

  @override
  Future<bool> isRunning(PterodactylLocalInstance instance) async =>
      running.contains(instance.name);

  @override
  Future<PterodactylLocalInstance> resolve(
    String name, {
    String? consumer,
  }) async {
    final String selectedConsumer = consumer ?? activeConsumer;
    final PterodactylLocalInstance? instance =
        instances['$selectedConsumer:$name'];
    if (instance == null) throw StateError('Local instance not found: $name');
    return instance;
  }

  @override
  Future<void> start(PterodactylLocalInstance instance) async {
    running.add(instance.name);
  }

  @override
  Future<void> stop(PterodactylLocalInstance instance) async {
    running.remove(instance.name);
  }
}

final class _FakeRemoteGateway implements PterodactylTransferRemoteGateway {
  _FakeRemoteGateway(String path) : folder = Directory(path)..createSync();

  final Directory folder;
  PterodactylTransferRemoteTarget target = _target();
  PterodactylTransferRemoteState currentState =
      PterodactylTransferRemoteState.offline;
  final List<String?> installStatuses = <String?>[];
  int resolveTargetCount = 0;
  int stopCount = 0;
  int startCount = 0;
  int snapshotCount = 0;
  int applyCount = 0;
  int restoreCount = 0;
  int stateCountAfterStart = 0;
  final List<PterodactylTransferRemoteState> statesAfterStart =
      <PterodactylTransferRemoteState>[];
  void Function()? onStop;
  void Function(int count)? onResolveTarget;
  Future<void> Function(int count)? onSnapshot;
  Completer<void>? applyGate;
  bool failApplyAfterMutation = false;
  bool corruptAfterApply = false;
  bool failRollbackVerification = false;

  @override
  Future<PterodactylTransferBackendSession> openBackend(
    PterodactylTransferRemoteTarget target,
  ) async => _FakeBackendSession(this);

  @override
  Future<PterodactylTransferRemoteTarget> resolveTarget({
    required String profileId,
    required String serverIdentifier,
  }) async {
    resolveTargetCount++;
    onResolveTarget?.call(resolveTargetCount);
    final String? installStatus = installStatuses.isEmpty
        ? target.installStatus
        : installStatuses.removeAt(0);
    return PterodactylTransferRemoteTarget(
      profileId: target.profileId,
      identifier: target.identifier,
      uuid: target.uuid,
      name: target.name,
      installStatus: installStatus,
      launchJar: target.launchJar,
      launchArgsFile: target.launchArgsFile,
      nodeUnderMaintenance: target.nodeUnderMaintenance,
    );
  }

  @override
  Future<void> start(PterodactylTransferRemoteTarget target) async {
    startCount++;
    if (statesAfterStart.isEmpty) {
      currentState = PterodactylTransferRemoteState.running;
    }
  }

  @override
  Future<PterodactylTransferRemoteState> state(
    PterodactylTransferRemoteTarget target,
  ) async {
    if (startCount > 0) {
      stateCountAfterStart++;
      if (statesAfterStart.isNotEmpty) {
        currentState = statesAfterStart.removeAt(0);
      }
    }
    return currentState;
  }

  @override
  Future<void> stop(PterodactylTransferRemoteTarget target) async {
    stopCount++;
    onStop?.call();
    currentState = PterodactylTransferRemoteState.offline;
  }
}

final class _FakeBackendSession implements PterodactylTransferBackendSession {
  _FakeBackendSession(this.remote);

  final _FakeRemoteGateway remote;
  bool closed = false;

  @override
  Future<void> snapshotTo(String destinationPath) async {
    _requireOpen();
    remote.snapshotCount++;
    await remote.onSnapshot?.call(remote.snapshotCount);
    await _copyManifest(
      sourcePath: remote.folder.path,
      targetPath: destinationPath,
      mode: PterodactylTransferMode.mirror,
    );
  }

  @override
  Future<void> applyFrom({
    required String sourcePath,
    required PterodactylTransferMode mode,
  }) async {
    _requireOpen();
    remote.applyCount++;
    final Completer<void>? gate = remote.applyGate;
    if (gate != null) await gate.future;
    await _copyManifest(
      sourcePath: sourcePath,
      targetPath: remote.folder.path,
      mode: mode,
      excludeTarget: _fakeTransferExcluded,
    );
    if (remote.corruptAfterApply) {
      _write(remote.folder.path, 'server.properties', 'corrupt');
    }
    if (remote.failApplyAfterMutation) {
      throw StateError('simulated synchronous upload failure');
    }
  }

  @override
  Future<void> restoreFrom(String backupPath) async {
    _requireOpen();
    remote.restoreCount++;
    await _copyManifest(
      sourcePath: backupPath,
      targetPath: remote.folder.path,
      mode: PterodactylTransferMode.mirror,
    );
    if (remote.failRollbackVerification) {
      _write(remote.folder.path, 'rollback-corruption.txt', 'corrupt');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  void _requireOpen() {
    if (closed) throw StateError('fake backend is closed');
  }
}

Future<void> _copyManifest({
  required String sourcePath,
  required String targetPath,
  required PterodactylTransferMode mode,
  bool Function(String path)? excludeTarget,
}) async {
  const PterodactylTransferFileEngine engine = PterodactylTransferFileEngine();
  final PterodactylTransferFileManifest source = await engine.scan(
    sourcePath,
    allowSymlinks: false,
  );
  final PterodactylTransferFileManifest target = await engine.scan(
    targetPath,
    exclude: excludeTarget,
    allowSymlinks: false,
  );
  await engine.apply(
    source: source,
    targetRootPath: targetPath,
    changes: engine.diff(source: source, target: target, mode: mode),
    mode: mode,
    operationId: 'fake-${DateTime.now().microsecondsSinceEpoch}',
  );
}

bool _fakeTransferExcluded(String relativePath) {
  return PterodactylTransferPathPolicy.excludes(relativePath);
}
