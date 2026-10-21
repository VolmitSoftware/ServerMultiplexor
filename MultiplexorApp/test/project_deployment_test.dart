import 'dart:io';

import 'package:multiplexor/services/projects/project_deployment.dart';
import 'package:multiplexor/services/projects/project_files.dart';
import 'package:multiplexor/services/projects/project_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProjectStore store;
  late ProjectDeployment deployment;
  late Directory destination;

  setUp(() {
    Directory temporary = Directory.systemTemp.createTempSync(
      'project-deployment-',
    );
    root = Directory(temporary.resolveSymbolicLinksSync());
    store = _TestStore(root.path);
    deployment = ProjectDeployment(store);
    destination = Directory(p.join(root.path, 'output'));
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> artifact(
    String run,
    String project,
    String target, {
    String? filename,
    String contents = 'jar',
    String platform = 'plugin',
    List<String> versions = const <String>['26.1.2-26.3'],
    String role = 'runtime',
  }) async {
    File file = File(
      p.join(
        store.runWork(run).path,
        'artifacts',
        '$project-$target',
        filename ?? '$project-$target.jar',
      ),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return <String, Object?>{
      'file': file.path,
      'sha256': await projectFileHash(file),
      'size': file.lengthSync(),
      'role': role,
      'project': project,
      'target': target,
      'platforms': <String>[platform],
      'minecraftVersions': versions,
    };
  }

  void saveRun(
    String id,
    List<Map<String, Object?>> artifacts, {
    Set<String> failed = const <String>{},
  }) {
    projectAtomicJson(store.runFile(id), <String, Object?>{
      'id': id,
      'status': failed.isEmpty ? 'succeeded' : 'failed',
      'jobs': <Map<String, Object?>>[
        for (Map<String, Object?> item in artifacts)
          <String, Object?>{
            'key': '${item['project']}:${item['target']}',
            'status': failed.contains(item['target']) ? 'failed' : 'succeeded',
            'artifacts': <Map<String, Object?>>[item],
          },
      ],
    });
  }

  Future<void> configure({String? platform, String? minecraft}) =>
      deployment.configure(
        'exports',
        path: destination.path,
        platform: platform,
        minecraft: minecraft,
      );

  test('listing an empty catalog creates no directories or output', () {
    expect(deployment.destinations(), isEmpty);
    expect(store.directory.existsSync(), isFalse);
    expect(destination.existsSync(), isFalse);
  });

  test(
    'listing returns saved locations without touching their directories',
    () async {
      await deployment.configure(
        'z-export',
        path: destination.path,
        platform: 'fabric',
        minecraft: '26.3',
      );
      await deployment.configure('a-export', path: p.join(root.path, 'other'));
      String saved = store.destinationsFile.readAsStringSync();
      List<Map<String, Object?>> locations = deployment.destinations();
      expect(
        locations.map((Map<String, Object?> item) => item['name']),
        <String>['a-export', 'z-export'],
      );
      expect(locations.last['path'], destination.path);
      expect(locations.last['platform'], 'fabric');
      expect(locations.last['minecraft'], '26.3');
      expect(store.destinationsFile.readAsStringSync(), saved);
      expect(destination.existsSync(), isFalse);
      expect(Directory(p.join(root.path, 'other')).existsSync(), isFalse);
    },
  );

  test(
    'removing configuration leaves deployed jars and ownership unchanged',
    () async {
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit'),
      ]);
      await configure();
      await deployment.configure('other', path: p.join(root.path, 'other'));
      await deployment.deploy('one', 'exports');
      Map<String, List<int>> before = <String, List<int>>{
        for (File file in destination.listSync().whereType<File>())
          p.basename(file.path): file.readAsBytesSync(),
      };
      Map<String, Object?> removed = await deployment.remove('exports');
      expect(removed['name'], 'exports');
      expect(
        deployment.destinations().map(
          (Map<String, Object?> item) => item['name'],
        ),
        <String>['other'],
      );
      expect(<String, List<int>>{
        for (File file in destination.listSync().whereType<File>())
          p.basename(file.path): file.readAsBytesSync(),
      }, before);
    },
  );

  test(
    'removing a location does not resolve its changed output path',
    () async {
      await configure();
      File destinationFile = File(destination.path)
        ..writeAsStringSync('unrelated');
      await deployment.remove('exports');
      expect(destinationFile.readAsStringSync(), 'unrelated');
      expect(deployment.destinations(), isEmpty);
    },
  );

  test(
    'unknown removals and invalid edits preserve saved configuration',
    () async {
      await configure(platform: 'plugin', minecraft: '26.3');
      String saved = store.destinationsFile.readAsStringSync();
      await expectLater(deployment.remove('missing'), throwsFormatException);
      await expectLater(
        deployment.configure(
          'exports',
          path: destination.path,
          platform: 'invalid',
        ),
        throwsFormatException,
      );
      await expectLater(
        deployment.configure('exports', dropins: true, platform: 'fabric'),
        throwsFormatException,
      );
      File invalid = File(p.join(root.path, 'file'))
        ..writeAsStringSync('untouched');
      await expectLater(
        deployment.configure('exports', path: invalid.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.destinationsFile.readAsStringSync(), saved);
      expect(invalid.readAsStringSync(), 'untouched');
      expect(destination.existsSync(), isFalse);
    },
  );

  test(
    'concurrent remove and configure preserve unrelated destination updates',
    () async {
      await configure();
      await Future.wait(<Future<Map<String, Object?>>>[
        deployment.remove('exports'),
        ProjectDeployment(
          store,
        ).configure('other', path: p.join(root.path, 'other')),
      ]);
      expect(
        deployment.destinations().map(
          (Map<String, Object?> item) => item['name'],
        ),
        <String>['other'],
      );
    },
  );

  test(
    'preview verifies selection without creating destination files',
    () async {
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit'),
      ]);
      await configure();
      Map<String, Object?> result = await deployment.deploy(
        'one',
        'exports',
        preview: true,
      );
      expect(result['preview'], isTrue);
      expect((result['actions'] as List<Object?>).length, 1);
      expect(destination.existsSync(), isFalse);
    },
  );

  test(
    'only successful runtime artifacts deploy and unmanaged jars remain',
    () async {
      saveRun(
        'one',
        <Map<String, Object?>>[
          await artifact('one', 'iris', 'bukkit'),
          await artifact('one', 'iris', 'api', role: 'api'),
          await artifact('one', 'bad', 'failed'),
        ],
        failed: <String>{'failed'},
      );
      destination.createSync();
      File unrelated = File(p.join(destination.path, 'unrelated.jar'))
        ..writeAsStringSync('untouched');
      await configure();
      await deployment.deploy('one', 'exports');
      expect(
        File(p.join(destination.path, 'iris-bukkit.jar')).readAsStringSync(),
        'jar',
      );
      expect(
        File(p.join(destination.path, 'iris-api.jar')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(destination.path, 'bad-failed.jar')).existsSync(),
        isFalse,
      );
      expect(unrelated.readAsStringSync(), 'untouched');
    },
  );

  test('artifact source hash changes fail before output writes', () async {
    Map<String, Object?> entry = await artifact('one', 'iris', 'bukkit');
    saveRun('one', <Map<String, Object?>>[entry]);
    File(entry['file'] as String).writeAsStringSync('changed');
    await configure();
    await expectLater(deployment.deploy('one', 'exports'), throwsStateError);
    expect(
      File(p.join(destination.path, 'iris-bukkit.jar')).existsSync(),
      isFalse,
    );
  });

  test(
    'replacement removes only matching managed target and preserves others',
    () async {
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit', filename: 'iris-old.jar'),
        await artifact('one', 'gloss', 'bukkit'),
      ]);
      await configure();
      await deployment.deploy('one', 'exports');
      saveRun('two', <Map<String, Object?>>[
        await artifact(
          'two',
          'iris',
          'bukkit',
          filename: 'iris-new.jar',
          contents: 'new',
        ),
      ]);
      await deployment.deploy('two', 'exports');
      expect(
        File(p.join(destination.path, 'iris-old.jar')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(destination.path, 'iris-new.jar')).readAsStringSync(),
        'new',
      );
      expect(
        File(p.join(destination.path, 'gloss-bukkit.jar')).readAsStringSync(),
        'jar',
      );
    },
  );

  test('edited managed artifact is preserved and blocks replacement', () async {
    saveRun('one', <Map<String, Object?>>[
      await artifact('one', 'iris', 'bukkit'),
    ]);
    await configure();
    await deployment.deploy('one', 'exports');
    File output = File(p.join(destination.path, 'iris-bukkit.jar'))
      ..writeAsStringSync('user edit');
    saveRun('two', <Map<String, Object?>>[
      await artifact('two', 'iris', 'bukkit', filename: 'iris-new.jar'),
    ]);
    await expectLater(deployment.deploy('two', 'exports'), throwsStateError);
    expect(output.readAsStringSync(), 'user edit');
    expect(
      File(p.join(destination.path, 'iris-new.jar')).existsSync(),
      isFalse,
    );
  });

  test('unmanaged filename collision is never overwritten', () async {
    saveRun('one', <Map<String, Object?>>[
      await artifact('one', 'iris', 'bukkit'),
    ]);
    destination.createSync();
    File output = File(p.join(destination.path, 'iris-bukkit.jar'))
      ..writeAsStringSync('unmanaged');
    await configure();
    await expectLater(deployment.deploy('one', 'exports'), throwsStateError);
    expect(output.readAsStringSync(), 'unmanaged');
  });

  test('failed manifest commit restores jars and previous manifest', () async {
    saveRun('one', <Map<String, Object?>>[
      await artifact('one', 'iris', 'bukkit', contents: 'old'),
    ]);
    await configure();
    await deployment.deploy('one', 'exports');
    File manifest = File(
      p.join(destination.path, '.multiplexor-project-artifacts.json'),
    );
    String oldManifest = manifest.readAsStringSync();
    saveRun('two', <Map<String, Object?>>[
      await artifact('two', 'iris', 'bukkit', contents: 'new'),
    ]);
    bool failed = false;
    ProjectDeployment failing = ProjectDeployment(
      store,
      moveFile: (File source, String target) {
        if (!failed && source.path.endsWith('manifest.json')) {
          failed = true;
          throw const FileSystemException('Injected manifest failure');
        }
        source.renameSync(target);
      },
    );
    await expectLater(
      failing.deploy('two', 'exports'),
      throwsA(isA<FileSystemException>()),
    );
    expect(failed, isTrue);
    expect(
      File(p.join(destination.path, 'iris-bukkit.jar')).readAsStringSync(),
      'old',
    );
    expect(manifest.readAsStringSync(), oldManifest);
    expect(destination.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'compatibility uses numeric inclusive ranges and exact platforms',
    () async {
      saveRun('one', <Map<String, Object?>>[
        await artifact(
          'one',
          'iris',
          'plugin',
          versions: <String>['26.2-26.10'],
        ),
        await artifact(
          'one',
          'iris',
          'fabric',
          platform: 'fabric',
          versions: <String>['26.3'],
        ),
      ]);
      await configure(platform: 'plugin', minecraft: '26.10');
      Map<String, Object?> result = await deployment.deploy('one', 'exports');
      expect((result['skipped'] as List<Object?>).length, 1);
      expect(
        File(p.join(destination.path, 'iris-plugin.jar')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(destination.path, 'iris-fabric.jar')).existsSync(),
        isFalse,
      );
      await configure(platform: 'plugin', minecraft: '26.11');
      await expectLater(
        deployment.deploy('one', 'exports', target: 'iris:plugin'),
        throwsStateError,
      );
    },
  );

  test(
    'dropins require exact compatibility and reject duplicate project variants',
    () async {
      await expectLater(
        deployment.configure('shared', dropins: true, platform: 'plugin'),
        throwsFormatException,
      );
      await deployment.configure(
        'shared',
        dropins: true,
        platform: 'plugin',
        minecraft: '26.3',
      );
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'first'),
        await artifact('one', 'iris', 'second'),
      ]);
      await expectLater(deployment.deploy('one', 'shared'), throwsStateError);
      Map<String, Object?> result = await deployment.deploy(
        'one',
        'shared',
        target: 'iris:first',
      );
      expect((result['actions'] as List<Object?>).length, 1);
    },
  );

  test('source links and paths outside the run are rejected', () async {
    Map<String, Object?> entry = await artifact('one', 'iris', 'bukkit');
    File source = File(entry['file'] as String);
    File outside = File(p.join(root.path, 'outside.jar'))
      ..writeAsStringSync('jar');
    source.deleteSync();
    Link(source.path).createSync(outside.path);
    saveRun('one', <Map<String, Object?>>[entry]);
    await configure();
    await expectLater(
      deployment.deploy('one', 'exports'),
      throwsA(isA<FileSystemException>()),
    );
    entry['file'] = outside.path;
    saveRun('one', <Map<String, Object?>>[entry]);
    await expectLater(
      deployment.deploy('one', 'exports'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('destination links and ownership traversal are rejected', () async {
    Directory real = Directory(p.join(root.path, 'real'))..createSync();
    Link(destination.path).createSync(real.path);
    await expectLater(configure(), throwsA(isA<FileSystemException>()));
    Link(destination.path).deleteSync();
    destination.createSync();
    await configure();
    saveRun('one', <Map<String, Object?>>[
      await artifact('one', 'iris', 'bukkit'),
    ]);
    projectAtomicJson(
      File(p.join(destination.path, '.multiplexor-project-artifacts.json')),
      <String, Object?>{
        'schema': 1,
        'artifacts': <Map<String, Object?>>[
          <String, Object?>{
            'file': '../escape.jar',
            'project': 'iris',
            'target': 'bukkit',
            'sha256': '0' * 64,
          },
        ],
      },
    );
    await expectLater(
      deployment.deploy('one', 'exports'),
      throwsFormatException,
    );
  });

  test(
    'stopped instance accepts matching jars and running instance refuses them',
    () async {
      Directory instance = Directory(
        p.join(root.path, 'consumers', 'plugin-consumers', 'instances', 'demo'),
      )..createSync(recursive: true);
      File(
        p.join(instance.path, '.server-source'),
      ).writeAsStringSync('type=paper\nmc=26.3\n');
      await deployment.configure(
        'server',
        instance: 'demo',
        platform: 'plugin',
      );
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit'),
      ]);
      await deployment.deploy('one', 'server');
      expect(
        File(p.join(instance.path, 'plugins', 'iris-bukkit.jar')).existsSync(),
        isTrue,
      );
      File runtimePid = File(
        p.join(
          root.path,
          'consumers',
          'plugin-consumers',
          'state',
          'runtime',
          'demo.console.pid',
        ),
      );
      runtimePid.parent.createSync(recursive: true);
      runtimePid.writeAsStringSync('$pid\n');
      await expectLater(deployment.deploy('one', 'server'), throwsStateError);
    },
  );

  test(
    'identical filenames from different projects fail before deployment',
    () async {
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit', filename: 'distribution.jar'),
        await artifact('one', 'gloss', 'bukkit', filename: 'distribution.jar'),
      ]);
      await configure();
      await expectLater(deployment.deploy('one', 'exports'), throwsStateError);
      expect(
        File(p.join(destination.path, 'distribution.jar')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'instance destination resolves its platform and refuses locked instances',
    () async {
      Directory instance = Directory(
        p.join(root.path, 'consumers', 'plugin-consumers', 'instances', 'demo'),
      )..createSync(recursive: true);
      File source = File(p.join(instance.path, '.server-source'))
        ..writeAsStringSync('type=paper\nmc=26.3\nlocked=true\n');
      Map<String, Object?> configured = await deployment.configure(
        'server',
        instance: 'demo',
        platform: 'plugin',
      );
      expect(configured['path'], p.join(instance.path, 'plugins'));
      saveRun('one', <Map<String, Object?>>[
        await artifact('one', 'iris', 'bukkit'),
      ]);
      await expectLater(deployment.deploy('one', 'server'), throwsStateError);
      source.writeAsStringSync('type=paper\nmc=26.2\n');
      await expectLater(deployment.deploy('one', 'server'), throwsStateError);
    },
  );
}

class _TestStore extends ProjectStore {
  _TestStore(super.workspace);

  @override
  Directory runWork(String id) => Directory(p.join(workspace, 'work', id));
}
