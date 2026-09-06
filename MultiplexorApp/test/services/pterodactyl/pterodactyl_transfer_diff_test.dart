import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_baseline_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_files.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const PterodactylTransferFileEngine engine = PterodactylTransferFileEngine();
  late Directory root;
  late Directory local;
  late Directory remote;
  late PterodactylTransferFileManifest baseline;

  File put(Directory tree, String name, String value) =>
      File(p.join(tree.path, name))
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
  Future<PterodactylTransferFileManifest> scan(Directory tree) =>
      engine.scan(tree.path);
  Future<List<PterodactylTransferChange>> diff() async => engine.diff(
    source: await scan(local),
    target: await scan(remote),
    mode: PterodactylTransferMode.update,
    baseline: baseline,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-diff-test-',
    );
    local = Directory(p.join(root.path, 'local'))..createSync();
    remote = Directory(p.join(root.path, 'remote'))..createSync();
    put(local, 'config.yml', 'base');
    put(remote, 'config.yml', 'base');
    baseline = await scan(local);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'local edit uploads only that path while preserving remote drift and additions',
    () async {
      put(remote, 'config.yml', 'remote changed');
      put(remote, 'remote-only.txt', 'keep');
      put(local, 'plugins/NewPlugin.jar', 'new local plugin');
      final PterodactylTransferFileManifest source = await scan(local);
      final List<PterodactylTransferChange> changes = await diff();
      expect(
        changes.map((PterodactylTransferChange change) => change.path),
        <String>['plugins/NewPlugin.jar'],
      );
      final PterodactylTransferFileManifest selected = engine.selectSource(
        source: source,
        changes: changes,
      );
      expect(selected.files.keys, <String>['plugins/NewPlugin.jar']);
      expect(selected.directories, <String>{'plugins'});
      await engine.apply(
        source: selected,
        targetRootPath: remote.path,
        changes: changes,
        mode: PterodactylTransferMode.update,
        operationId: 'selective',
      );
      expect(
        File(p.join(remote.path, 'config.yml')).readAsStringSync(),
        'remote changed',
      );
      expect(
        File(p.join(remote.path, 'remote-only.txt')).readAsStringSync(),
        'keep',
      );
      expect(
        File(p.join(remote.path, 'plugins/NewPlugin.jar')).readAsStringSync(),
        'new local plugin',
      );
    },
  );

  test('independent conflicting edits report paths before transfer', () async {
    put(local, 'config.yml', 'local edit');
    put(remote, 'config.yml', 'remote edit');
    await expectLater(
      diff(),
      throwsA(
        isA<PterodactylTransferConflict>().having(
          (PterodactylTransferConflict error) => error.paths,
          'paths',
          <String>['config.yml'],
        ),
      ),
    );
  });

  test(
    'local-only edit updates while remote-only edit and deletion are preserved',
    () async {
      put(local, 'config.yml', 'local edit');
      expect((await diff()).single.kind, PterodactylTransferChangeKind.update);
      put(local, 'config.yml', 'base');
      put(remote, 'config.yml', 'remote edit');
      expect(await diff(), isEmpty);
      File(p.join(remote.path, 'config.yml')).deleteSync();
      expect(await diff(), isEmpty);
      put(local, 'config.yml', 'local edit');
      await expectLater(diff(), throwsA(isA<PterodactylTransferConflict>()));
    },
  );

  test('local deletion preserves remote and retains baseline', () async {
    File(p.join(local.path, 'config.yml')).deleteSync();
    final List<PterodactylTransferChange> changes = await diff();
    expect(changes, isEmpty);
    final PterodactylTransferFileManifest advanced = engine.advanceBaseline(
      baseline: baseline,
      source: await scan(local),
      changes: changes,
      target: await scan(remote),
    );
    expect(
      advanced.files['config.yml']!.sha256,
      baseline.files['config.yml']!.sha256,
    );
  });

  test(
    'convergence is a no-op and becomes the base for a later local-only edit',
    () async {
      put(local, 'config.yml', 'same new value');
      put(remote, 'config.yml', 'same new value');
      final List<PterodactylTransferChange> changes = await diff();
      expect(changes, isEmpty);
      baseline = engine.advanceBaseline(
        baseline: baseline,
        source: await scan(local),
        changes: changes,
        target: await scan(remote),
      );
      put(local, 'config.yml', 'later local change');
      expect((await diff()).single.kind, PterodactylTransferChangeKind.update);
    },
  );

  test(
    'shared deletion becomes a common absence for later local recreation',
    () async {
      File(p.join(local.path, 'config.yml')).deleteSync();
      File(p.join(remote.path, 'config.yml')).deleteSync();
      expect(await diff(), isEmpty);
      baseline = engine.advanceBaseline(
        baseline: baseline,
        source: await scan(local),
        changes: const <PterodactylTransferChange>[],
        target: await scan(remote),
      );
      expect(baseline.files, isEmpty);
      put(local, 'config.yml', 'recreated');
      expect((await diff()).single.kind, PterodactylTransferChangeKind.add);
    },
  );

  test(
    'advancing a different upload never accepts skipped remote drift as common',
    () async {
      put(remote, 'config.yml', 'remote edit');
      put(local, 'new.txt', 'new');
      final List<PterodactylTransferChange> changes = await diff();
      final PterodactylTransferFileManifest source = await scan(local);
      await engine.apply(
        source: source,
        targetRootPath: remote.path,
        changes: changes,
        mode: PterodactylTransferMode.update,
        operationId: 'advance',
      );
      baseline = engine.advanceBaseline(
        baseline: baseline,
        source: source,
        changes: changes,
        target: await scan(remote),
      );
      put(local, 'config.yml', 'local later edit');
      await expectLater(diff(), throwsA(isA<PterodactylTransferConflict>()));
      expect(baseline.files, contains('new.txt'));
    },
  );

  test('two independently added different files conflict', () async {
    put(local, 'new.txt', 'local');
    put(remote, 'new.txt', 'remote');
    await expectLater(diff(), throwsA(isA<PterodactylTransferConflict>()));
  });

  test('remote directory deletion conflicts with a new local child', () async {
    put(local, 'data/old.txt', 'old');
    put(remote, 'data/old.txt', 'old');
    baseline = await scan(local);
    Directory(p.join(remote.path, 'data')).deleteSync(recursive: true);
    put(local, 'data/new.txt', 'new');
    await expectLater(
      diff(),
      throwsA(
        isA<PterodactylTransferConflict>().having(
          (PterodactylTransferConflict error) => error.paths,
          'paths',
          contains('data'),
        ),
      ),
    );
  });

  test(
    'remote file-to-directory drift is preserved when local is unchanged',
    () async {
      File(p.join(remote.path, 'config.yml')).deleteSync();
      put(remote, 'config.yml/new.txt', 'remote shape');
      expect(await diff(), isEmpty);
      put(local, 'config.yml', 'local edit');
      await expectLater(diff(), throwsA(isA<PterodactylTransferConflict>()));
    },
  );

  test('unlinked update and mirror retain their two-way semantics', () async {
    put(remote, 'config.yml', 'remote drift');
    put(remote, 'extra.txt', 'extra');
    final PterodactylTransferFileManifest source = await scan(local);
    final PterodactylTransferFileManifest target = await scan(remote);
    expect(
      engine
          .diff(
            source: source,
            target: target,
            mode: PterodactylTransferMode.update,
          )
          .single
          .path,
      'config.yml',
    );
    final List<PterodactylTransferChange> mirror = engine.diff(
      source: source,
      target: target,
      mode: PterodactylTransferMode.mirror,
      baseline: baseline,
    );
    expect(
      mirror.map((PterodactylTransferChange change) => change.kind),
      <PterodactylTransferChangeKind>[
        PterodactylTransferChangeKind.update,
        PterodactylTransferChangeKind.delete,
      ],
    );
  });

  test(
    'transferable directory cache is stable and cannot mutate its manifest',
    () async {
      put(local, 'world/region/file.mca', 'region');
      final PterodactylTransferFileManifest manifest = await scan(local);
      final Set<String> cached = manifest.transferableDirectories;
      expect(identical(cached, manifest.transferableDirectories), isTrue);
      expect(() => cached.add('unexpected'), throwsUnsupportedError);
      final String fingerprint = manifest.fingerprint;
      engine.advanceBaseline(
        baseline: manifest,
        source: baseline,
        changes: const <PterodactylTransferChange>[],
        target: baseline,
      );
      expect(manifest.fingerprint, fingerprint);
    },
  );

  test(
    'excluded descendants do not change a materialized transfer fingerprint',
    () async {
      put(local, 'world/region/r.0.0.mca', 'world');
      put(local, 'world/session.lock', 'runtime');
      put(local, 'excluded-only/session.lock', 'runtime');
      put(local, 'with-empty/session.lock', 'runtime');
      Directory(p.join(local.path, 'with-empty/empty')).createSync();
      final PterodactylTransferFileManifest source = await engine.scan(
        local.path,
        exclude: (String path) => p.posix.basename(path) == 'session.lock',
      );
      final Directory stage = Directory(p.join(root.path, 'stage'))
        ..createSync();
      final PterodactylTransferFileManifest empty = await scan(stage);
      await engine.apply(
        source: source,
        targetRootPath: stage.path,
        changes: engine.diff(
          source: source,
          target: empty,
          mode: PterodactylTransferMode.update,
        ),
        mode: PterodactylTransferMode.update,
        operationId: 'excluded',
      );
      expect((await scan(stage)).fingerprint, source.fingerprint);
      expect(
        Directory(p.join(stage.path, 'excluded-only')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(stage.path, 'with-empty/empty')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(stage.path, 'world/session.lock')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'preexisting staging symlink cannot redirect a copy outside its target',
    () async {
      put(local, 'config.yml', 'new');
      final File outside = put(root, 'outside.txt', 'untouched');
      final Link staging = Link(
        p.join(remote.path, '.config.yml.multiplexor-collision.part'),
      )..createSync(outside.path);
      final PterodactylTransferFileManifest source = await scan(local);
      await expectLater(
        engine.apply(
          source: source,
          targetRootPath: remote.path,
          changes: <PterodactylTransferChange>[
            const PterodactylTransferChange(
              path: 'config.yml',
              kind: PterodactylTransferChangeKind.update,
            ),
          ],
          mode: PterodactylTransferMode.update,
          operationId: 'collision',
        ),
        throwsStateError,
      );
      expect(outside.readAsStringSync(), 'untouched');
      expect(staging.existsSync(), isTrue);
    },
  );

  test(
    'mirror deletion refuses an ancestor replaced with an outside symlink',
    () async {
      final Directory outside = Directory(p.join(root.path, 'outside'))
        ..createSync();
      final File file = put(outside, 'old.txt', 'untouched');
      Link(p.join(remote.path, 'data')).createSync(outside.path);
      await expectLater(
        engine.apply(
          source: baseline,
          targetRootPath: remote.path,
          changes: <PterodactylTransferChange>[
            const PterodactylTransferChange(
              path: 'data/old.txt',
              kind: PterodactylTransferChangeKind.delete,
            ),
          ],
          mode: PterodactylTransferMode.mirror,
          operationId: 'delete',
        ),
        throwsStateError,
      );
      expect(file.readAsStringSync(), 'untouched');
    },
  );

  group('baseline persistence', () {
    late PterodactylTransferBaselineStore store;
    setUp(() {
      store = PterodactylTransferBaselineStore(
        metadataDirectoryPath: p.join(root.path, 'metadata'),
      );
    });
    PterodactylTransferFileManifest? read({
      String profile = 'panel',
      String uuid = 'uuid',
    }) => store.read(
      localConsumer: 'plugin',
      localInstancePath: local.path,
      profileId: profile,
      serverUuid: uuid,
    );
    void write(PterodactylTransferFileManifest manifest) => store.write(
      localConsumer: 'plugin',
      localInstancePath: local.path,
      profileId: 'panel',
      serverUuid: 'uuid',
      manifest: manifest,
    );

    test(
      'missing baseline stays absent and saved content roundtrips without source paths',
      () {
        expect(read(), isNull);
        expect(Directory(p.join(root.path, 'metadata')).existsSync(), isFalse);
        write(baseline);
        final PterodactylTransferFileManifest loaded = read()!;
        expect(loaded.fingerprint, baseline.fingerprint);
        expect(loaded.files.values.single.sourcePath, isEmpty);
        expect(read(profile: 'other'), isNull);
        expect(read(uuid: 'other'), isNull);
      },
    );

    test('changing data updates the same identity atomically', () async {
      write(baseline);
      put(local, 'new.txt', 'new');
      final PterodactylTransferFileManifest changed = await scan(local);
      write(changed);
      expect(read()!.fingerprint, changed.fingerprint);
      final Directory storage = Directory(
        p.join(root.path, 'metadata/pterodactyl-transfer-baselines'),
      );
      expect(storage.listSync(), hasLength(1));
    });

    test(
      'malformed baseline and symlinked storage fail without silent two-way fallback',
      () {
        write(baseline);
        final Directory storage = Directory(
          p.join(root.path, 'metadata/pterodactyl-transfer-baselines'),
        );
        final File record = storage.listSync().whereType<File>().single;
        record.writeAsStringSync('{"schema_version":1}');
        expect(read, throwsFormatException);
        record.deleteSync();
        final File outside = put(root, 'outside.json', 'untouched');
        Link(record.path).createSync(outside.path);
        expect(read, throwsStateError);
        expect(() => write(baseline), throwsStateError);
        expect(outside.readAsStringSync(), 'untouched');
      },
    );
  });
}
