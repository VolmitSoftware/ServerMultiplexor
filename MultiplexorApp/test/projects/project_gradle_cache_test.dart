import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_files.dart';
import 'package:multiplexor/services/projects/project_gradle_cache.dart';
import 'package:multiplexor/services/projects/project_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late ProjectStore store;
  late ProjectGradleCache cache;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('project-cache-test-');
    store = ProjectStore(fixture.path);
    store.workDirectory.createSync(recursive: true);
    cache = ProjectGradleCache(store, 'next');
  });
  tearDown(() {
    if (store.workDirectory.existsSync()) {
      store.workDirectory.deleteSync(recursive: true);
    }
    fixture.deleteSync(recursive: true);
  });

  Directory donor(
    String key, {
    String status = 'succeeded',
    bool ownership = false,
    String? runStatus,
  }) {
    String project = key.split(':').first;
    String target = key.split(':').last;
    String id = '$project-$target';
    String log = p.join(store.runWork(id).path, 'logs', project, '$target.log');
    projectAtomicJson(store.runFile(id), <String, Object?>{
      'id': id,
      'createdAt': '2026-01-01',
      'status': runStatus ?? status,
      'jobs': <Object?>[
        <String, Object?>{
          'key': key,
          'project': project,
          'target': target,
          'status': status,
          'logPath': log,
        },
      ],
    });
    if (ownership) {
      File state = File('$log.process.json');
      state.parent.createSync(recursive: true);
      state.writeAsStringSync('{}');
    }
    Directory home = cache.home(key)..createSync(recursive: true);
    File dependency = File(
      p.join(
        home.path,
        'caches/modules-2/files-2.1/sample/library/1/hash/library.jar',
      ),
    );
    dependency.parent.createSync(recursive: true);
    dependency.writeAsStringSync('dependency $key');
    File(
      p.join(home.path, 'caches/modules-2/modules-2.lock'),
    ).writeAsStringSync('lock');
    File(
      p.join(home.path, 'caches/modules-2/gc.properties'),
    ).writeAsStringSync('gc');
    File metadata = File(
      p.join(home.path, 'caches/modules-2/metadata-2.107/module.bin'),
    );
    metadata.parent.createSync(recursive: true);
    metadata.writeAsStringSync('metadata $key');
    Directory distribution = Directory(
      p.join(home.path, 'wrapper/dists/gradle-9.5.1-bin/hash'),
    )..createSync(recursive: true);
    File executable = File(
      p.join(distribution.path, 'gradle-9.5.1/bin/gradle'),
    );
    executable.parent.createSync(recursive: true);
    executable.writeAsStringSync('gradle executable');
    File library = File(
      p.join(distribution.path, 'gradle-9.5.1/lib/gradle-launcher-9.5.1.jar'),
    );
    library.parent.createSync(recursive: true);
    library.writeAsStringSync('gradle launcher');
    File(
      p.join(distribution.path, 'gradle-9.5.1-bin.zip.ok'),
    ).writeAsStringSync('');
    File(
      p.join(distribution.path, 'gradle-9.5.1-bin.zip.lck'),
    ).writeAsStringSync('lock');
    return home;
  }

  test(
    'completed caches produce independent pinned dependencies and wrapper copies',
    () async {
      Directory source = donor('library:jar');
      await cache.prepare();
      Directory dependencies = cache.dependencyCache!;
      File snapshot = File(
        p.join(
          dependencies.path,
          'modules-2/files-2.1/sample/library/1/hash/library.jar',
        ),
      );
      expect(snapshot.readAsStringSync(), 'dependency library:jar');
      expect(
        File(
          p.join(dependencies.path, 'modules-2/modules-2.lock'),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(dependencies.path, 'modules-2/gc.properties')).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(dependencies.path, 'modules-2/metadata-2.107/module.bin'),
        ).readAsStringSync(),
        'metadata library:jar',
      );
      File(
        p.join(
          source.path,
          'caches/modules-2/files-2.1/sample/library/1/hash/library.jar',
        ),
      ).writeAsStringSync('changed donor');
      expect(snapshot.readAsStringSync(), 'dependency library:jar');
      await cache.withHome('app:one', (Directory home) async {
        File wrapper = File(
          p.join(
            home.path,
            'wrapper/dists/gradle-9.5.1-bin/hash/gradle-9.5.1/bin/gradle',
          ),
        );
        expect(wrapper.readAsStringSync(), 'gradle executable');
        expect(
          File(
            p.join(
              home.path,
              'wrapper/dists/gradle-9.5.1-bin/hash/gradle-9.5.1-bin.zip.lck',
            ),
          ).existsSync(),
          isFalse,
        );
        wrapper.writeAsStringSync('private change');
      });
      await cache.withHome('app:two', (Directory home) async {
        expect(
          File(
            p.join(
              home.path,
              'wrapper/dists/gradle-9.5.1-bin/hash/gradle-9.5.1/bin/gradle',
            ),
          ).readAsStringSync(),
          'gradle executable',
        );
      });
      expect(
        File(
          p.join(
            source.path,
            'wrapper/dists/gradle-9.5.1-bin/hash/gradle-9.5.1/bin/gradle',
          ),
        ).readAsStringSync(),
        'gradle executable',
      );
    },
  );

  test('completed idle lanes in an active matrix can seed caches', () async {
    donor('library:jar', runStatus: 'running');
    await cache.prepare();
    expect(cache.dependencyCache, isNotNull);
  });

  test(
    'partial private wrappers are never marked complete by seeding',
    () async {
      donor('library:jar');
      await cache.prepare();
      Directory destination = Directory(
        p.join(
          cache.home('app:jar').path,
          'wrapper/dists/gradle-9.5.1-bin/hash',
        ),
      )..createSync(recursive: true);
      File partial = File(p.join(destination.path, 'gradle-9.5.1/bin/gradle'));
      partial.parent.createSync(recursive: true);
      partial.writeAsStringSync('partial');
      await cache.withHome('app:jar', (Directory home) async {
        expect(partial.readAsStringSync(), 'partial');
        expect(
          File(
            p.join(destination.path, 'gradle-9.5.1-bin.zip.ok'),
          ).existsSync(),
          isFalse,
        );
      });
    },
  );

  test('active and process-owned lanes are not read as cache seeds', () async {
    donor('active:jar', status: 'running');
    donor('owned:jar', ownership: true);
    await cache.prepare();
    expect(cache.dependencyCache, isNull);
    await cache.withHome('new:jar', (Directory home) async {
      expect(Directory(p.join(home.path, 'wrapper')).existsSync(), isFalse);
    });
  });

  test(
    'a prior completed lane reserved by another run is excluded',
    () async {
      donor('library:jar');
      projectAtomicJson(store.runFile('active'), <String, Object?>{
        'id': 'active',
        'createdAt': '2026-01-02',
        'status': 'running',
        'jobs': <Object?>[
          <String, Object?>{'key': 'library:jar', 'status': 'queued'},
        ],
      });
      await cache.prepare();
      expect(cache.dependencyCache, isNull);
    },
  );

  test('foreign cache symlinks cannot become dependency snapshots', () async {
    Directory home = donor('library:jar');
    Directory modules = Directory(p.join(home.path, 'caches/modules-2'));
    modules.deleteSync(recursive: true);
    Directory outside = Directory(
      p.join(fixture.path, 'foreign/modules-2/files-2.1'),
    )..createSync(recursive: true);
    Link(modules.path).createSync(outside.parent.path);
    await cache.prepare();
    expect(cache.dependencyCache, isNull);
  }, skip: Platform.isWindows);

  test('incomplete wrapper installations are omitted', () async {
    Directory source = donor('library:jar');
    File(
      p.join(
        source.path,
        'wrapper/dists/gradle-9.5.1-bin/hash/gradle-9.5.1-bin.zip.ok',
      ),
    ).deleteSync();
    await cache.prepare();
    await cache.withHome('app:jar', (Directory home) async {
      expect(Directory(p.join(home.path, 'wrapper')).existsSync(), isFalse);
    });
  });

  test(
    'task cache seeding preserves existing entries and skips incomplete files',
    () async {
      Directory home = donor('library:jar');
      Directory source = Directory(p.join(home.path, 'caches/build-cache-1'))
        ..createSync(recursive: true);
      String first = 'a' * 32;
      String second = 'b' * 32;
      String invalid = 'c' * 32;
      File(
        p.join(source.path, first),
      ).writeAsBytesSync(gzip.encode(utf8.encode('first')));
      File(
        p.join(source.path, second),
      ).writeAsBytesSync(gzip.encode(utf8.encode('second')));
      File(p.join(source.path, invalid)).writeAsStringSync('incomplete');
      File(
        p.join(source.path, 'build-cache-1.lock'),
      ).writeAsStringSync('locked');
      cache.taskCache.createSync(recursive: true);
      File existing = File(p.join(cache.taskCache.path, first))
        ..writeAsStringSync('existing');
      await cache.prepare();
      expect(existing.readAsStringSync(), 'existing');
      expect(
        utf8.decode(
          gzip.decode(
            File(p.join(cache.taskCache.path, second)).readAsBytesSync(),
          ),
        ),
        'second',
      );
      expect(File(p.join(cache.taskCache.path, invalid)).existsSync(), isFalse);
      expect(
        File(p.join(cache.taskCache.path, 'build-cache-1.lock')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'cancellation during dependency capture discards unpublished snapshot',
    () async {
      Directory home = donor('library:jar');
      Directory files = Directory(
        p.join(home.path, 'caches/modules-2/files-2.1/many'),
      )..createSync(recursive: true);
      for (int index = 0; index < 300; index++) {
        File(p.join(files.path, '$index.jar')).writeAsStringSync('dependency');
      }
      bool cancel = false;
      cache = ProjectGradleCache(store, 'next', cancelled: () => cancel);
      Future<void> preparation = cache.prepare();
      await Future<void>.delayed(Duration.zero);
      cancel = true;
      await preparation;
      expect(cache.dependencyCache, isNull);
      expect(
        Directory(
          p.join(store.runWork('next').path, 'cache-seed/dependencies.pending'),
        ).existsSync(),
        isFalse,
      );
      RandomAccessFile lock = File(
        p.join(home.path, 'multiplexor.lock'),
      ).openSync(mode: FileMode.append);
      try {
        lock.lockSync(FileLock.exclusive);
      } finally {
        lock.closeSync();
      }
    },
  );

  test('held donor locks are skipped without waiting', () async {
    Directory source = donor('library:jar');
    Process holder = await Process.start('python3', <String>[
      '-c',
      'import fcntl,sys,time\nf=open(sys.argv[1],"a")\nfcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\ntime.sleep(30)',
      p.join(source.path, 'multiplexor.lock'),
    ]);
    try {
      expect(
        await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      await cache.prepare();
      expect(cache.dependencyCache, isNull);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  }, skip: Platform.isWindows);
}
