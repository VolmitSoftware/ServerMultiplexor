import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_files.dart';
import 'package:multiplexor/services/projects/project_deployment.dart';
import 'package:multiplexor/services/projects/project_model.dart';
import 'package:multiplexor/services/projects/project_store.dart';
import 'package:multiplexor/services/projects/project_worker.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late ProjectStore store;
  setUp(() {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('multiplexor-project-test-')
          .resolveSymbolicLinksSync(),
    );
    store = ProjectStore(p.join(fixture.path, 'workspace'));
    store.directory.createSync(recursive: true);
  });
  tearDown(() {
    if (store.workDirectory.existsSync()) {
      store.workDirectory.deleteSync(recursive: true);
    }
    fixture.deleteSync(recursive: true);
  });

  Map<String, Object?> target(
    String id, {
    List<String> dependencies = const <String>[],
    String command = 'pass',
  }) => <String, Object?>{
    'id': id,
    'tasks': <String>[command],
    'arguments': <String>[],
    'java': 25,
    'memoryMiB': 512,
    'workers': 1,
    'dependsOn': dependencies,
    'artifacts': <Object?>[
      <String, Object?>{
        'path': 'build/result.jar',
        'role': 'runtime',
        'platforms': <String>['plugin'],
      },
    ],
  };

  BuildProject project(
    String id,
    List<Map<String, Object?>> targets, {
    List<String> sources = const <String>[],
    bool parallel = true,
  }) {
    Directory directory = Directory(p.join(fixture.path, 'sources', id))
      ..createSync(recursive: true);
    File(
      p.join(directory.path, 'input.txt'),
    ).writeAsStringSync('captured input');
    File wrapper = File(p.join(directory.path, 'gradlew'))
      ..writeAsStringSync('''#!/bin/sh
if [ "\$1" = "fail" ]; then exit 7; fi
if [ "\$1" = "slow" ]; then sleep 20; else sleep 0.15; fi
mkdir -p build
cat input.txt > build/result.jar
printf '> Task :assemble\\n'
''');
    if (!Platform.isWindows) {
      Process.runSync('chmod', <String>['755', wrapper.path]);
    }
    return BuildProject.fromJson(<String, Object?>{
      'schema': 1,
      'id': id,
      'name': id,
      'sandbox': 'per-target',
      'parallelTargets': parallel,
      'sourceDependencies': sources,
      'sourceRoot': p.join(fixture.path, 'sources'),
      'relativePath': id,
      'targets': targets,
    });
  }

  Map<String, Object?> run(
    String id,
    List<BuildProject> projects,
    List<String> keys, {
    bool changed = false,
  }) {
    ProjectPlan plan = ProjectPlan(<String, BuildProject>{
      for (BuildProject project in projects) project.id: project,
    }, keys);
    return <String, Object?>{
      'schema': 1,
      'id': id,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'status': 'queued',
      'projects': projects
          .map((BuildProject project) => project.toJson())
          .toList(),
      'targets': plan.keys,
      'jobsLimit': 4,
      'memoryMiB': 2048,
      'workers': 4,
      'changed': changed,
      'jobs': <Object?>[
        for (String key in plan.keys)
          <String, Object?>{
            'key': key,
            'project': key.split(':').first,
            'target': key.split(':').last,
            'status': 'queued',
            'artifacts': <Object?>[],
          },
      ],
    };
  }

  test(
    'dependency planning includes artifact prerequisites and rejects cycles',
    () {
      BuildProject lib = project('lib', <Map<String, Object?>>[target('api')]);
      BuildProject app = project('app', <Map<String, Object?>>[
        target('jar', dependencies: <String>['lib:api']),
      ]);
      expect(
        ProjectPlan(
          <String, BuildProject>{'lib': lib, 'app': app},
          <String>['app:jar'],
        ).keys,
        <String>['lib:api', 'app:jar'],
      );
      BuildProject cyclic = project('cycle', <Map<String, Object?>>[
        target('a', dependencies: <String>['cycle:b']),
        target('b', dependencies: <String>['cycle:a']),
      ]);
      expect(
        () => ProjectPlan(
          <String, BuildProject>{'cycle': cyclic},
          <String>['cycle:a'],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'copies uncommitted source and isolates simultaneous target output',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('one'),
        target('two'),
      ]);
      File(
        p.join(app.directory, 'untracked.txt'),
      ).writeAsStringSync('new source');
      Map<String, Object?> state = run(
        'parallel',
        <BuildProject>[app],
        <String>['app:one', 'app:two'],
      );
      expect(await ProjectWorker(store, state).execute(), 0);
      List<Map<String, Object?>> jobs = (state['jobs'] as List<Object?>)
          .map(projectObject)
          .toList();
      expect(
        DateTime.parse(
          jobs[1]['startedAt'] as String,
        ).isBefore(DateTime.parse(jobs[0]['finishedAt'] as String)),
        isTrue,
      );
      expect(
        File(p.join(app.directory, 'build/result.jar')).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(store.runWork('parallel').path, 'snapshot/app/untracked.txt'),
        ).readAsStringSync(),
        'new source',
      );
      List<String> paths = jobs
          .map(
            (Map<String, Object?> job) =>
                projectObject(
                      (job['artifacts'] as List<Object?>).single,
                    )['file']
                    as String,
          )
          .toList();
      expect(paths.toSet(), hasLength(2));
      expect(
        paths.map((String path) => File(path).readAsStringSync()),
        everyElement('captured input'),
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'failed prerequisites block dependents while independent targets finish',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('broken', command: 'fail'),
        target('dependent', dependencies: <String>['app:broken']),
        target('independent'),
      ]);
      Map<String, Object?> state = run(
        'failure',
        <BuildProject>[app],
        <String>['app:dependent', 'app:independent'],
      );
      expect(await ProjectWorker(store, state).execute(), 1);
      expect(
        (state['jobs'] as List<Object?>)
            .map(projectObject)
            .map((Map<String, Object?> job) => job['status']),
        <String>['failed', 'blocked', 'succeeded'],
      );
    },
    skip: Platform.isWindows,
  );

  test('project policy serializes siblings even with spare capacity', () async {
    BuildProject app = project('app', <Map<String, Object?>>[
      target('one'),
      target('two'),
    ], parallel: false);
    Map<String, Object?> state = run(
      'serial',
      <BuildProject>[app],
      <String>['app:one', 'app:two'],
    );
    expect(await ProjectWorker(store, state).execute(), 0);
    List<Map<String, Object?>> jobs = (state['jobs'] as List<Object?>)
        .map(projectObject)
        .toList();
    expect(
      DateTime.parse(
        jobs[1]['startedAt'] as String,
      ).isBefore(DateTime.parse(jobs[0]['finishedAt'] as String)),
      isFalse,
    );
  }, skip: Platform.isWindows);

  test('changed builds reuse only existing verified artifacts', () async {
    BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
    Map<String, Object?> first = run(
      'first',
      <BuildProject>[app],
      <String>['app:one'],
    );
    expect(await ProjectWorker(store, first).execute(), 0);
    Map<String, Object?> second = run(
      'second',
      <BuildProject>[app],
      <String>['app:one'],
      changed: true,
    );
    expect(await ProjectWorker(store, second).execute(), 0);
    expect(
      projectObject((second['jobs'] as List<Object?>).single)['reusedFrom'],
      'first',
    );
    Map<String, Object?> secondArtifact = projectObject(
      (projectObject((second['jobs'] as List<Object?>).single)['artifacts']
              as List<Object?>)
          .single,
    );
    expect(
      p.isWithin(
        store.runWork('second').path,
        secondArtifact['file'] as String,
      ),
      isTrue,
    );
    ProjectDeployment deployment = ProjectDeployment(store);
    await deployment.configure(
      'export',
      path: p.join(fixture.path, 'export'),
      platform: 'plugin',
    );
    await deployment.deploy('second', 'export');
    expect(
      File(p.join(fixture.path, 'export/result.jar')).readAsStringSync(),
      'captured input',
    );
    File(secondArtifact['file'] as String).writeAsStringSync('changed output');
    Map<String, Object?> artifact = projectObject(
      (projectObject((first['jobs'] as List<Object?>).single)['artifacts']
              as List<Object?>)
          .single,
    );
    File(artifact['file'] as String).writeAsStringSync('changed output');
    Map<String, Object?> third = run(
      'third',
      <BuildProject>[app],
      <String>['app:one'],
      changed: true,
    );
    expect(await ProjectWorker(store, third).execute(), 0);
    expect(
      projectObject((third['jobs'] as List<Object?>).single)['reusedFrom'],
      isNull,
    );
  }, skip: Platform.isWindows);

  test('hyphenated keys have distinct work and artifact paths', () async {
    BuildProject first = project('one-two', <Map<String, Object?>>[
      target('three'),
    ]);
    BuildProject second = project('one', <Map<String, Object?>>[
      target('two-three'),
    ]);
    Map<String, Object?> state = run(
      'keys',
      <BuildProject>[first, second],
      <String>['one-two:three', 'one:two-three'],
    );
    expect(await ProjectWorker(store, state).execute(), 0);
    List<Map<String, Object?>> jobs = (state['jobs'] as List<Object?>)
        .map(projectObject)
        .toList();
    expect(
      jobs.map((Map<String, Object?> job) => job['logPath']).toSet(),
      hasLength(2),
    );
    expect(
      jobs
          .map(
            (Map<String, Object?> job) => projectObject(
              (job['artifacts'] as List<Object?>).single,
            )['file'],
          )
          .toSet(),
      hasLength(2),
    );
  }, skip: Platform.isWindows);

  test('memory budget serializes targets with spare job slots', () async {
    BuildProject app = project('app', <Map<String, Object?>>[
      target('one'),
      target('two'),
    ]);
    Map<String, Object?> state = run(
      'memory',
      <BuildProject>[app],
      <String>['app:one', 'app:two'],
    );
    state['memoryMiB'] = 512;
    expect(await ProjectWorker(store, state).execute(), 0);
    List<Map<String, Object?>> jobs = (state['jobs'] as List<Object?>)
        .map(projectObject)
        .toList();
    expect(
      DateTime.parse(
        jobs[1]['startedAt'] as String,
      ).isBefore(DateTime.parse(jobs[0]['finishedAt'] as String)),
      isFalse,
    );
  }, skip: Platform.isWindows);

  test(
    'Git ignores generated runtimes while retaining tracked and untracked sources',
    () async {
      Directory source = Directory(p.join(fixture.path, 'git-source'))
        ..createSync();
      Map<String, String> environment = <String, String>{
        ...Platform.environment,
      }..remove('GIT_CONFIG_COUNT');
      Future<void> git(List<String> arguments) async {
        ProcessResult result = await Process.run(
          'git',
          arguments,
          workingDirectory: source.path,
          environment: environment,
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await git(<String>['init', '-q']);
      File(p.join(source.path, '.gitignore')).writeAsStringSync('run/\n');
      Directory(p.join(source.path, 'run')).createSync();
      File(
        p.join(source.path, 'run/kept.txt'),
      ).writeAsStringSync('tracked source');
      await git(<String>['add', '-f', 'run/kept.txt']);
      File(
        p.join(source.path, 'untracked.txt'),
      ).writeAsStringSync('new source');
      Link(p.join(source.path, 'run/runtime')).createSync(fixture.parent.path);
      Directory output = Directory(p.join(fixture.path, 'git-copy'));
      await copyProjectSources(source, output);
      expect(
        File(p.join(output.path, 'run/kept.txt')).readAsStringSync(),
        'tracked source',
      );
      expect(
        File(p.join(output.path, 'untracked.txt')).readAsStringSync(),
        'new source',
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(output.path, 'run/runtime'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    },
    skip: Platform.isWindows,
  );

  test('source symlinks cannot escape the registered source root', () async {
    Directory source = Directory(p.join(fixture.path, 'source'))..createSync();
    File outside = File(p.join(fixture.path, 'outside'))
      ..writeAsStringSync('outside');
    Link(p.join(source.path, 'link')).createSync(outside.path);
    await expectLater(
      copyProjectSources(source, Directory(p.join(fixture.path, 'copy'))),
      throwsA(isA<FileSystemException>()),
    );
  }, skip: Platform.isWindows);

  test('retry uses the captured source after the checkout changes', () async {
    BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
    Map<String, Object?> first = run(
      'original',
      <BuildProject>[app],
      <String>['app:one'],
    );
    expect(await ProjectWorker(store, first).execute(), 0);
    File(p.join(app.directory, 'input.txt')).writeAsStringSync('edited later');
    Map<String, Object?> retry = run(
      'retry',
      <BuildProject>[app],
      <String>['app:one'],
    );
    retry['retryOf'] = 'original';
    retry['sourceHashes'] = first['sourceHashes'];
    expect(await ProjectWorker(store, retry).execute(), 0);
    Map<String, Object?> artifact = projectObject(
      (projectObject((retry['jobs'] as List<Object?>).single)['artifacts']
              as List<Object?>)
          .single,
    );
    expect(
      File(artifact['file'] as String).readAsStringSync(),
      'captured input',
    );
    expect(
      projectObject((retry['jobs'] as List<Object?>).single)['reusedFrom'],
      'original',
    );
  }, skip: Platform.isWindows);

  test(
    'metadata scan runs against copies and atomically registers targets',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
      Directory(p.join(app.directory, 'gradle')).createSync();
      File(
        p.join(app.directory, 'gradle/multiplexor.gradle'),
      ).writeAsStringSync('ext.multiplexor = [:]');
      String metadata = jsonEncode(app.toJson());
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(
        '#!/bin/sh\nmkdir -p build\nprintf \'%s\\n\' \'MULTIPLEXOR_PROJECT=$metadata\'\n',
      );
      List<BuildProject> results = await store.scan(
        p.join(fixture.path, 'sources'),
        (_) {},
      );
      expect(results.single.id, 'app');
      expect(store.projects().single.targets.single.id, 'one');
      expect(Directory(p.join(app.directory, 'build')).existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );
}
