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
    String artifactPath = 'build/result.jar',
    String role = 'runtime',
    List<String> platforms = const <String>['plugin'],
    List<String> minecraftVersions = const <String>[],
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
        'path': artifactPath,
        'role': role,
        'platforms': platforms,
        'minecraftVersions': minecraftVersions,
      },
    ],
  };

  BuildProject project(
    String id,
    List<Map<String, Object?>> targets, {
    List<String> sources = const <String>[],
    List<String> inputs = const <String>[],
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
      'sourceInputs': inputs,
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
    bool cache = true,
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
      'cache': cache,
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
    'source stamps identify each copied project independently of its consumer',
    () async {
      BuildProject library = project('library', <Map<String, Object?>>[
        target('one'),
      ]);
      BuildProject app = project(
        'app',
        <Map<String, Object?>>[target('one')],
        sources: <String>['library'],
        inputs: <String>['docs/app'],
      );
      BuildProject other = project(
        'other',
        <Map<String, Object?>>[target('one')],
        sources: <String>['library'],
      );
      File docs = File(p.join(fixture.path, 'sources/docs/app/reference.md'));
      docs.parent.createSync(recursive: true);
      docs.writeAsStringSync('first documentation');
      List<BuildProject> projects = <BuildProject>[library, app, other];
      for (BuildProject project in projects) {
        File wrapper = File(p.join(project.directory, 'gradlew'));
        wrapper.writeAsStringSync(
          "${wrapper.readAsStringSync()}\nprintf 'source-hashes=%s\\n' \"\$MULTIPLEXOR_SOURCE_HASHES\"\n",
        );
      }
      Map<String, Object?> first = run('first-stamps', projects, <String>[
        'library:one',
        'app:one',
        'other:one',
      ]);
      expect(await ProjectWorker(store, first).execute(), 0);
      Map<String, Object?> stamps(String runId, BuildProject project) {
        String sandbox = p.join(
          store.runWork(runId).resolveSymbolicLinksSync(),
          'sandboxes',
          project.id,
          'one',
        );
        String line =
            File(
              p.join(store.runWork(runId).path, 'logs', project.id, 'one.log'),
            ).readAsLinesSync().singleWhere(
              (String line) => line.startsWith('source-hashes='),
            );
        Map<String, Object?> result = projectObject(
          jsonDecode(line.substring('source-hashes='.length)),
        );
        expect(result.keys.toSet(), <String>{
          for (String source in <String>[
            project.id,
            ...project.sourceDependencies,
          ])
            p.join(sandbox, source),
        });
        return <String, Object?>{
          for (MapEntry<String, Object?> entry in result.entries)
            p.basename(entry.key): entry.value,
        };
      }

      String libraryHash =
          projectObject(first['sourceHashes'])['library'] as String;
      for (BuildProject project in projects) {
        expect(stamps('first-stamps', project)['library'], libraryHash);
      }
      File(
        p.join(app.directory, 'input.txt'),
      ).writeAsStringSync('edited consumer');
      docs.writeAsStringSync('edited documentation');
      Map<String, Object?> second = run('second-stamps', projects, <String>[
        'library:one',
        'app:one',
        'other:one',
      ]);
      expect(await ProjectWorker(store, second).execute(), 0);
      for (BuildProject project in projects) {
        expect(stamps('second-stamps', project)['library'], libraryHash);
      }
      expect(
        stamps('second-stamps', app)['app'],
        isNot(stamps('first-stamps', app)['app']),
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

  test(
    'fresh and reused builds deliver to exports and dropins while instances stay manual',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
      ProjectDeployment deployment = ProjectDeployment(store);
      Directory export = Directory(p.join(fixture.path, 'export'));
      await deployment.configure('export', path: export.path);
      Map<String, Object?> dropins = await deployment.configure(
        'shared',
        dropins: true,
        platform: 'plugin',
        minecraft: '26.3',
      );
      Directory instance = Directory(
        p.join(store.workspace, 'consumers/plugin-consumers/instances/demo'),
      )..createSync(recursive: true);
      File(
        p.join(instance.path, '.server-source'),
      ).writeAsStringSync('type=paper\nmc=26.3\n');
      await deployment.configure(
        'server',
        instance: 'demo',
        platform: 'plugin',
      );
      Map<Directory, String> outputs = <Directory, String>{
        export: 'result.jar',
        Directory(dropins['path'] as String): 'app.jar',
      };
      for (String id in <String>['delivery-first', 'delivery-reused']) {
        Map<String, Object?> state = run(
          id,
          <BuildProject>[app],
          <String>['app:one'],
          changed: id == 'delivery-reused',
        );
        expect(await ProjectWorker(store, state).execute(), 0);
        expect(state['status'], 'succeeded');
        Map<String, Object?> job = projectObject(
          (state['jobs'] as List<Object?>).single,
        );
        if (id == 'delivery-reused') {
          expect(job['reusedFrom'], 'delivery-first');
        }
        List<Map<String, Object?>> deliveries =
            (job['deliveries'] as List<Object?>).map(projectObject).toList();
        expect(
          deliveries.map((Map<String, Object?> item) => item['destination']),
          unorderedEquals(<String>['export', 'shared']),
        );
        expect(
          deliveries.map((Map<String, Object?> item) => item['status']),
          everyElement('succeeded'),
        );
        for (MapEntry<Directory, String> output in outputs.entries) {
          File jar = File(p.join(output.key.path, output.value));
          expect(jar.readAsStringSync(), 'captured input');
          Map<String, Object?> manifest = projectReadJson(
            File(
              p.join(output.key.path, '.multiplexor-project-artifacts.json'),
            ),
          );
          expect(
            projectObject(
              (manifest['artifacts'] as List<Object?>).single,
            )['runId'],
            id,
          );
          jar.deleteSync();
        }
        expect(
          Directory(p.join(instance.path, 'plugins')).existsSync(),
          isFalse,
        );
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'non-runtime and incompatible artifacts leave saved destinations untouched',
    () async {
      ProjectDeployment deployment = ProjectDeployment(store);
      Directory export = Directory(p.join(fixture.path, 'export'));
      await deployment.configure(
        'export',
        path: export.path,
        platform: 'plugin',
        minecraft: '26.3',
      );
      Map<String, Object?> dropins = await deployment.configure(
        'shared',
        dropins: true,
        platform: 'plugin',
        minecraft: '26.3',
      );
      List<Map<String, Object?>> targets = <Map<String, Object?>>[
        target('api', role: 'api'),
        target('library', role: 'library'),
        target('fabric', platforms: <String>['fabric']),
        target('version', minecraftVersions: <String>['1.21.11']),
      ];
      BuildProject app = project('app', targets);
      Map<String, Object?> state = run(
        'delivery-skipped',
        <BuildProject>[app],
        targets
            .map((Map<String, Object?> item) => 'app:${item['id']}')
            .toList(),
      );
      expect(await ProjectWorker(store, state).execute(), 0);
      expect(state['status'], 'succeeded');
      expect(
        (state['jobs'] as List<Object?>)
            .map(projectObject)
            .map((Map<String, Object?> job) => job['status']),
        everyElement('succeeded'),
      );
      expect(export.existsSync(), isFalse);
      Directory shared = Directory(dropins['path'] as String);
      expect(shared.listSync(), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test(
    'delivery failure preserves built artifacts and continues destinations and dependencies',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('one', artifactPath: 'build/one.jar'),
        target(
          'two',
          artifactPath: 'build/two.jar',
          dependencies: <String>['app:one'],
        ),
      ]);
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(
        '\ncp build/result.jar build/one.jar\ncp build/result.jar build/two.jar\n',
        mode: FileMode.append,
      );
      ProjectDeployment deployment = ProjectDeployment(store);
      Directory blocked = Directory(p.join(fixture.path, 'blocked'))
        ..createSync();
      File unmanaged = File(p.join(blocked.path, 'one.jar'))
        ..writeAsStringSync('unmanaged');
      Directory export = Directory(p.join(fixture.path, 'export'));
      await deployment.configure('a-blocked', path: blocked.path);
      await deployment.configure('z-export', path: export.path);
      Map<String, Object?> state = run(
        'delivery-failed',
        <BuildProject>[app],
        <String>['app:two'],
      );
      expect(await ProjectWorker(store, state).execute(), 1);
      expect(state['status'], 'failed');
      List<Map<String, Object?>> jobs = (state['jobs'] as List<Object?>)
          .map(projectObject)
          .toList();
      expect(
        jobs.map((Map<String, Object?> job) => job['status']),
        everyElement('succeeded'),
      );
      expect(unmanaged.readAsStringSync(), 'unmanaged');
      for (String filename in <String>['one.jar', 'two.jar']) {
        expect(
          File(p.join(export.path, filename)).readAsStringSync(),
          'captured input',
        );
      }
      List<Map<String, Object?>> deliveries =
          (jobs.first['deliveries'] as List<Object?>)
              .map(projectObject)
              .toList();
      Map<String, Object?> failed = deliveries.singleWhere(
        (Map<String, Object?> item) => item['destination'] == 'a-blocked',
      );
      expect(failed['status'], 'failed');
      expect(failed['error'], contains('unmanaged'));
      expect(
        deliveries.singleWhere(
          (Map<String, Object?> item) => item['destination'] == 'z-export',
        )['status'],
        'succeeded',
      );
      for (Map<String, Object?> job in jobs) {
        Map<String, Object?> artifact = projectObject(
          (job['artifacts'] as List<Object?>).single,
        );
        expect(
          File(artifact['file'] as String).readAsStringSync(),
          'captured input',
        );
      }
    },
    skip: Platform.isWindows,
  );

  test('concurrent builds finish all deliveries before returning', () async {
    List<Map<String, Object?>> targets = <Map<String, Object?>>[
      for (String id in <String>['one', 'two', 'three'])
        target(id, artifactPath: 'build/$id.jar'),
    ];
    BuildProject app = project('app', targets);
    File(p.join(app.directory, 'gradlew')).writeAsStringSync(
      '\ncp build/result.jar build/one.jar\n'
      'cp build/result.jar build/two.jar\n'
      'cp build/result.jar build/three.jar\n',
      mode: FileMode.append,
    );
    Directory export = Directory(p.join(fixture.path, 'export'));
    await ProjectDeployment(store).configure('export', path: export.path);
    Map<String, Object?> state = run(
      'delivery-parallel',
      <BuildProject>[app],
      targets.map((Map<String, Object?> item) => 'app:${item['id']}').toList(),
    );
    expect(await ProjectWorker(store, state).execute(), 0);
    Map<String, Object?> persisted = projectReadJson(
      store.runFile('delivery-parallel'),
    );
    DateTime finished = DateTime.parse(persisted['finishedAt'] as String);
    for (Map<String, Object?> job in (persisted['jobs'] as List<Object?>).map(
      projectObject,
    )) {
      expect(job['status'], 'succeeded');
      expect(
        projectObject((job['deliveries'] as List<Object?>).single)['status'],
        'succeeded',
      );
      expect(
        DateTime.parse(job['finishedAt'] as String).isAfter(finished),
        isFalse,
      );
      expect(
        File(p.join(export.path, '${job['target']}.jar')).readAsStringSync(),
        'captured input',
      );
    }
    Map<String, Object?> manifest = projectReadJson(
      File(p.join(export.path, '.multiplexor-project-artifacts.json')),
    );
    expect(manifest['artifacts'], hasLength(3));
  }, skip: Platform.isWindows);

  test(
    'ambiguous dropins leave exports usable and exact target builds deliver reused artifacts',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('one', artifactPath: 'build/one.jar'),
        target('two', artifactPath: 'build/two.jar'),
      ]);
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(
        '\ncp build/result.jar build/one.jar\ncp build/result.jar build/two.jar\n',
        mode: FileMode.append,
      );
      ProjectDeployment deployment = ProjectDeployment(store);
      Directory export = Directory(p.join(fixture.path, 'export'));
      await deployment.configure('export', path: export.path);
      Map<String, Object?> configured = await deployment.configure(
        'shared',
        dropins: true,
        platform: 'plugin',
        minecraft: '26.3',
      );
      Directory shared = Directory(configured['path'] as String);
      Map<String, Object?> ambiguous = run(
        'delivery-ambiguous',
        <BuildProject>[app],
        <String>['app:one', 'app:two'],
      );
      expect(await ProjectWorker(store, ambiguous).execute(), 1);
      expect(shared.listSync(), isEmpty);
      for (Map<String, Object?> job in (ambiguous['jobs'] as List<Object?>).map(
        projectObject,
      )) {
        expect(job['status'], 'succeeded');
        expect(
          File(p.join(export.path, '${job['target']}.jar')).readAsStringSync(),
          'captured input',
        );
        Map<String, Object?> failed = (job['deliveries'] as List<Object?>)
            .map(projectObject)
            .singleWhere(
              (Map<String, Object?> item) => item['destination'] == 'shared',
            );
        expect(failed['status'], 'failed');
        expect(failed['error'], contains('Multiple compatible targets'));
      }
      Map<String, Object?> selected = run(
        'delivery-selected',
        <BuildProject>[app],
        <String>['app:two'],
        changed: true,
      );
      expect(await ProjectWorker(store, selected).execute(), 0);
      Map<String, Object?> job = projectObject(
        (selected['jobs'] as List<Object?>).single,
      );
      expect(job['reusedFrom'], 'delivery-ambiguous');
      expect(
        (job['deliveries'] as List<Object?>)
            .map(projectObject)
            .map((Map<String, Object?> item) => item['status']),
        everyElement('succeeded'),
      );
      expect(File(p.join(shared.path, 'one.jar')).existsSync(), isFalse);
      expect(File(p.join(shared.path, 'two.jar')).existsSync(), isFalse);
      expect(
        File(p.join(shared.path, 'app.jar')).readAsStringSync(),
        'captured input',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'auxiliary inputs are isolated, invalidate reuse, and remain frozen on retry',
    () async {
      BuildProject app = project(
        'app',
        <Map<String, Object?>>[target('one')],
        inputs: <String>['docs/app'],
      );
      File docs = File(p.join(fixture.path, 'sources/docs/app/reference.txt'));
      docs.parent.createSync(recursive: true);
      docs.writeAsStringSync('first documentation');
      File unrelated = File(
        p.join(fixture.path, 'sources/docs/other/reference.txt'),
      );
      unrelated.parent.createSync(recursive: true);
      unrelated.writeAsStringSync('not an input');
      File wrapper = File(p.join(app.directory, 'gradlew'));
      wrapper.writeAsStringSync(
        '\ncat ../docs/app/reference.txt > build/result.jar\nprintf \'docs=%s\\n\' "\$(ls ../docs)"\n',
        mode: FileMode.append,
      );
      Map<String, Object?> first = run(
        'inputs-first',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, first).execute(), 0);
      Map<String, Object?> captured = projectObject(
        (first['jobs'] as List<Object?>).single,
      );
      expect(
        File(
          projectObject((captured['artifacts'] as List<Object?>).single)['file']
              as String,
        ).readAsStringSync(),
        'first documentation',
      );
      expect(
        File(captured['logPath'] as String).readAsStringSync(),
        contains('docs=app\n'),
      );
      docs.writeAsStringSync('edited documentation');
      Map<String, Object?> second = run(
        'inputs-second',
        <BuildProject>[app],
        <String>['app:one'],
        changed: true,
      );
      expect(await ProjectWorker(store, second).execute(), 0);
      Map<String, Object?> secondJob = projectObject(
        (second['jobs'] as List<Object?>).single,
      );
      expect(secondJob['reusedFrom'], isNull);
      expect(
        File(
          projectObject(
                (secondJob['artifacts'] as List<Object?>).single,
              )['file']
              as String,
        ).readAsStringSync(),
        'edited documentation',
      );
      Map<String, Object?> firstJob = projectObject(
        (first['jobs'] as List<Object?>).single,
      );
      File(
        projectObject((firstJob['artifacts'] as List<Object?>).single)['file']
            as String,
      ).writeAsStringSync('invalid artifact');
      Map<String, Object?> retry = run(
        'inputs-retry',
        <BuildProject>[app],
        <String>['app:one'],
      );
      retry['retryOf'] = 'inputs-first';
      retry['sourceHashes'] = first['sourceHashes'];
      retry['inputHashes'] = first['inputHashes'];
      expect(await ProjectWorker(store, retry).execute(), 0);
      Map<String, Object?> retryJob = projectObject(
        (retry['jobs'] as List<Object?>).single,
      );
      expect(retryJob['reusedFrom'], isNull);
      expect(
        File(
          projectObject((retryJob['artifacts'] as List<Object?>).single)['file']
              as String,
        ).readAsStringSync(),
        'first documentation',
      );
      expect(retry['inputHashes'], first['inputHashes']);
    },
    skip: Platform.isWindows,
  );

  test(
    'file inputs preserve exact content outside project source filters',
    () async {
      BuildProject app = project(
        'app',
        <Map<String, Object?>>[target('one')],
        inputs: <String>['docs/version.txt'],
      );
      File docs = File(p.join(fixture.path, 'sources/docs/version.txt'));
      docs.parent.createSync(recursive: true);
      docs.writeAsStringSync('document version');
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(
        '\ncat ../docs/version.txt > build/result.jar\n',
        mode: FileMode.append,
      );
      Map<String, Object?> state = run(
        'file-input',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, state).execute(), 0);
      expect(
        File(
          projectObject(
                (projectObject(
                          (state['jobs'] as List<Object?>).single,
                        )['artifacts']
                        as List<Object?>)
                    .single,
              )['file']
              as String,
        ).readAsStringSync(),
        'document version',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'missing and escaping auxiliary inputs fail before target launch',
    () async {
      for (bool escape in <bool>[false, true]) {
        BuildProject app = project(
          'app',
          <Map<String, Object?>>[target('one')],
          inputs: <String>['docs/app'],
        );
        Directory docs = Directory(p.join(fixture.path, 'sources/docs'))
          ..createSync(recursive: true);
        if (escape) {
          Link(p.join(docs.path, 'app')).createSync(fixture.parent.path);
        }
        Map<String, Object?> state = run(
          escape ? 'escape-input' : 'missing-input',
          <BuildProject>[app],
          <String>['app:one'],
        );
        expect(await ProjectWorker(store, state).execute(), 1);
        expect(state['error'], isNotNull);
        expect(
          projectObject((state['jobs'] as List<Object?>).single)['logPath'],
          isNull,
        );
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'wrapper defaults allow target property overrides without reusing old artifacts',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(r'''
property=missing
property_arguments=
for argument do
    case "$argument" in
        -Ppaperweight.experimental.genSources=*)
            property="${argument#*=}"
            property_arguments="${property_arguments}${property_arguments:+,}${property}"
            ;;
    esac
done
printf '%s\n' "$property" > build/result.jar
printf 'property-arguments=%s\n' "$property_arguments"
''', mode: FileMode.append);
      String output(Map<String, Object?> state) {
        Map<String, Object?> job = projectObject(
          (state['jobs'] as List<Object?>).single,
        );
        Map<String, Object?> artifact = projectObject(
          (job['artifacts'] as List<Object?>).single,
        );
        return File(artifact['file'] as String).readAsStringSync();
      }

      Map<String, Object?> first = run(
        'default-property',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, first).execute(), 0);
      expect(output(first), 'false\n');

      Map<String, Object?> unchanged = run(
        'unchanged-property',
        <BuildProject>[app],
        <String>['app:one'],
        changed: true,
      );
      expect(await ProjectWorker(store, unchanged).execute(), 0);
      expect(
        projectObject(
          (unchanged['jobs'] as List<Object?>).single,
        )['reusedFrom'],
        'default-property',
      );
      expect(output(unchanged), 'false\n');

      BuildProject configured = BuildProject.fromJson(<String, Object?>{
        ...app.toJson(),
        'targets': <Object?>[
          <String, Object?>{
            ...app.targets.single.toJson(),
            'arguments': <String>['-Ppaperweight.experimental.genSources=true'],
          },
        ],
      });
      Map<String, Object?> overridden = run(
        'overridden-property',
        <BuildProject>[configured],
        <String>['app:one'],
        changed: true,
      );
      expect(await ProjectWorker(store, overridden).execute(), 0);
      expect(overridden['sourceHashes'], first['sourceHashes']);
      Map<String, Object?> overriddenJob = projectObject(
        (overridden['jobs'] as List<Object?>).single,
      );
      expect(overriddenJob['reusedFrom'], isNull);
      expect(output(overridden), 'true\n');
      expect(
        File(overriddenJob['logPath'] as String).readAsStringSync(),
        contains('property-arguments=false,true\n'),
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'packaging participates in reuse and cache settings reach the shared Gradle home',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('one'),
        target('two'),
      ]);
      File wrapper = File(p.join(app.directory, 'gradlew'));
      wrapper.writeAsStringSync(r'''
printf 'cache=%s home=%s\n' "$MULTIPLEXOR_TASK_CACHE" "$GRADLE_USER_HOME"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--init-script' ]; then cat "$2"; fi
  shift
done
''', mode: FileMode.append);
      Map<String, Object?> first = run(
        'pack-compact',
        <BuildProject>[app],
        <String>['app:one', 'app:two'],
      );
      expect(await ProjectWorker(store, first).execute(), 0);
      List<Map<String, Object?>> jobs = (first['jobs'] as List<Object?>)
          .map(projectObject)
          .toList();
      List<String> environments = <String>[];
      for (Map<String, Object?> job in jobs) {
        String log = File(job['logPath'] as String).readAsStringSync();
        expect(log, contains('--build-cache'));
        expect(log, contains('-PcompactRelease=true'));
        expect(log, contains('settings.buildCache'));
        environments.add(
          log
              .split('\n')
              .singleWhere((String line) => line.startsWith('cache=')),
        );
      }
      expect(
        environments.map((String line) => line.split(' home=').first).toSet(),
        hasLength(1),
      );
      String home = p.join(store.workDirectory.path, 'gradle-home');
      expect(
        environments.map((String line) => line.split(' home=').last).toSet(),
        <String>{home},
      );
      expect(
        File(
          p.join(home, 'init.d', 'multiplexor-cache-retention.gradle'),
        ).existsSync(),
        isTrue,
      );
      Map<String, Object?> local = run(
        'pack-local',
        <BuildProject>[app],
        <String>['app:one'],
        changed: true,
      );
      local['packaging'] = 'local';
      expect(await ProjectWorker(store, local).execute(), 0);
      Map<String, Object?> job = projectObject(
        (local['jobs'] as List<Object?>).single,
      );
      expect(job['reusedFrom'], isNull);
      expect(
        File(job['logPath'] as String).readAsStringSync(),
        contains('-PcompactRelease=false'),
      );
    },
    skip: Platform.isWindows,
  );

  test('without the build cache a finished run keeps only its logs', () async {
    BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
    File(p.join(app.directory, 'gradlew')).writeAsStringSync(r'''
printf 'cache=%s home=%s\n' "$MULTIPLEXOR_TASK_CACHE" "$GRADLE_USER_HOME"
''', mode: FileMode.append);
    Map<String, Object?> state = run(
      'uncached',
      <BuildProject>[app],
      <String>['app:one'],
      cache: false,
    );
    expect(await ProjectWorker(store, state).execute(), 0);
    String work = store.runWork('uncached').path;
    Map<String, Object?> job = projectObject(
      (state['jobs'] as List<Object?>).single,
    );
    expect(
      File(job['logPath'] as String).readAsStringSync(),
      contains(
        'cache=${p.join(work, 'task-cache')} home=${p.join(work, 'gradle-home')}',
      ),
    );
    List<String> files = <String>[
      for (FileSystemEntity entry in store.workDirectory.listSync(
        recursive: true,
        followLinks: false,
      ))
        if (entry is! Directory)
          p.relative(entry.path, from: store.workDirectory.path),
    ];
    expect(files, <String>['runs/uncached/logs/app/one.log']);
  }, skip: Platform.isWindows);

  test('source inputs reject traversal and overlapping materializations', () {
    BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
    for (List<String> inputs in <List<String>>[
      <String>['../docs'],
      <String>['/docs'],
      <String>['.'],
      <String>['docs/app', 'docs/app'],
      <String>['app'],
      <String>['app/config'],
      <String>['docs', 'docs/app'],
    ]) {
      expect(() {
        BuildProject configured = BuildProject.fromJson(<String, Object?>{
          ...app.toJson(),
          'sourceInputs': inputs,
        });
        ProjectPlan(
          <String, BuildProject>{'app': configured},
          <String>['app:one'],
        );
      }, throwsFormatException);
    }
    BuildProject lib = project(
      'lib',
      <Map<String, Object?>>[target('one')],
      inputs: <String>['docs/shared'],
    );
    BuildProject consumer = BuildProject.fromJson(<String, Object?>{
      ...app.toJson(),
      'sourceDependencies': <String>['lib'],
      'sourceInputs': <String>['docs/shared'],
    });
    ProjectPlan plan = ProjectPlan(
      <String, BuildProject>{'app': consumer, 'lib': lib},
      <String>['app:one'],
    );
    expect(plan.inputsFor('app').single.relativePath, 'docs/shared');
  });

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

  test('recorded durations start the longest target first', () async {
    BuildProject app = project('app', <Map<String, Object?>>[
      target('quick'),
      target('slow'),
    ]);
    DateTime start = DateTime.utc(2026, 10, 1);
    projectAtomicJson(store.runFile('history'), <String, Object?>{
      'schema': 1,
      'id': 'history',
      'status': 'succeeded',
      'createdAt': start.toIso8601String(),
      'jobs': <Object?>[
        for (MapEntry<String, int> recorded in <String, int>{
          'app:quick': 1,
          'app:slow': 9,
        }.entries)
          <String, Object?>{
            'key': recorded.key,
            'project': 'app',
            'target': recorded.key.split(':').last,
            'status': 'succeeded',
            'startedAt': start.toIso8601String(),
            'finishedAt': start
                .add(Duration(minutes: recorded.value))
                .toIso8601String(),
            'artifacts': <Object?>[],
          },
      ],
    });
    Map<String, Object?> state = run(
      'ordered',
      <BuildProject>[app],
      <String>['app:quick', 'app:slow'],
    );
    state['jobsLimit'] = 1;
    expect(await ProjectWorker(store, state).execute(), 0);
    Map<String, Map<String, Object?>> jobs = <String, Map<String, Object?>>{
      for (Object? item in state['jobs'] as List<Object?>)
        projectObject(item)['key'] as String: projectObject(item),
    };
    expect(
      DateTime.parse(
        jobs['app:slow']!['startedAt'] as String,
      ).isBefore(DateTime.parse(jobs['app:quick']!['startedAt'] as String)),
      isTrue,
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

  void recordRun(
    String id,
    String createdAt, {
    String status = 'succeeded',
    String? retryOf,
    List<Object?> jobs = const <Object?>[],
  }) {
    projectAtomicJson(store.runFile(id), <String, Object?>{
      'schema': 1,
      'id': id,
      'status': status,
      'createdAt': createdAt,
      'retryOf': ?retryOf,
      'jobs': jobs,
    });
    for (String entry in <String>['snapshot', 'artifacts', 'sandboxes']) {
      Directory(
        p.join(store.runWork(id).path, entry),
      ).createSync(recursive: true);
    }
  }

  test('finished runs keep only retry inputs, logs, and artifacts', () async {
    for (int index = 0; index < 10; index++) {
      recordRun('older-$index', '2026-01-01T00:00:0$index.000Z');
    }
    File(p.join(store.runWork('older-9').path, 'leftover', 'output.bin'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stale output');
    BuildProject app = project(
      'app',
      <Map<String, Object?>>[
        target('built'),
        target('broken', command: 'fail'),
      ],
      inputs: <String>['docs/app'],
    );
    File docs = File(p.join(fixture.path, 'sources/docs/app/reference.txt'));
    docs.parent.createSync(recursive: true);
    docs.writeAsStringSync('documentation');
    Map<String, Object?> state = run(
      'finished',
      <BuildProject>[app],
      <String>['app:built', 'app:broken'],
    );
    expect(await ProjectWorker(store, state).execute(), 1);
    expect(state['status'], 'failed');
    expect(
      store
          .runWork('finished')
          .listSync()
          .map((FileSystemEntity entry) => p.basename(entry.path))
          .toSet(),
      <String>{'artifacts', 'input-snapshot', 'logs', 'snapshot'},
    );
    expect(
      store
          .runWork('older-9')
          .listSync()
          .map((FileSystemEntity entry) => p.basename(entry.path))
          .toSet(),
      <String>{'artifacts', 'snapshot'},
    );
    expect(store.runFile('older-0').existsSync(), isFalse);
    expect(store.runWork('older-0').existsSync(), isFalse);
    expect(store.runs(), hasLength(10));
    expect(
      Directory(p.join(store.workDirectory.path, 'trash')).listSync(),
      isEmpty,
    );
    Map<String, Object?> retry = run(
      'finished-retry',
      <BuildProject>[app],
      <String>['app:built'],
    );
    retry['retryOf'] = 'finished';
    retry['sourceHashes'] = state['sourceHashes'];
    retry['inputHashes'] = state['inputHashes'];
    expect(await ProjectWorker(store, retry).execute(), 0);
    expect(
      projectObject((retry['jobs'] as List<Object?>).single)['reusedFrom'],
      'finished',
    );
  }, skip: Platform.isWindows);

  test('clearing the build cache leaves only run logs', () async {
    recordRun('kept', '2026-01-01T00:00:00.000Z');
    recordRun('active', '2026-01-01T00:00:01.000Z', status: 'running');
    for (String path in <String>[
      'runs/kept/logs/app/one.log',
      'runs/kept/declarations/abc.log',
      'runs/kept/declarations/sources/app/build.gradle',
      'runs/kept/snapshot/app/build.gradle',
      'runs/active/snapshot/app/build.gradle',
      'gradle-home/caches/module.jar',
      'task-cache/entry.bin',
      'discovery-abc/sources/app/build.gradle',
    ]) {
      File(p.join(store.workDirectory.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync(path);
    }
    store.clearCache();
    await store.emptyTrash();
    List<String> files = <String>[
      for (FileSystemEntity entry in store.workDirectory.listSync(
        recursive: true,
        followLinks: false,
      ))
        if (entry is! Directory)
          p.relative(entry.path, from: store.workDirectory.path),
    ]..sort();
    expect(files, <String>[
      'runs/active/snapshot/app/build.gradle',
      'runs/kept/declarations/abc.log',
      'runs/kept/logs/app/one.log',
    ]);
    expect(
      Directory(p.join(store.runWork('active').path, 'sandboxes')).existsSync(),
      isTrue,
    );
    expect(
      store.runs().map((Map<String, Object?> run) => run['id']).toSet(),
      <String>{'kept', 'active'},
    );
  }, skip: Platform.isWindows);

  test(
    'run retention keeps the newest runs and every run still in use',
    () async {
      String at(int index) =>
          '2026-01-01T00:00:${index.toString().padLeft(2, '0')}.000Z';
      for (int index = 5; index < 15; index++) {
        recordRun('run-$index', at(index));
      }
      recordRun('run-0', at(0));
      recordRun('run-1', at(1), status: 'running', retryOf: 'run-4');
      recordRun('run-2', at(2));
      recordRun('run-3', at(3));
      recordRun('run-4', at(4));
      String referenced = p.join(
        store.runWork('run-2').path,
        'artifacts',
        'app',
        'one',
        'app.jar',
      );
      recordRun(
        'run-12',
        at(12),
        jobs: <Object?>[
          <String, Object?>{
            'key': 'app:one',
            'status': 'succeeded',
            'artifacts': <Object?>[
              <String, Object?>{'file': referenced},
            ],
          },
        ],
      );
      recordRun(
        'run-11',
        at(11),
        jobs: <Object?>[
          <String, Object?>{
            'key': 'app:one',
            'status': 'succeeded',
            'reusedFrom': 'run-3',
            'artifacts': <Object?>[],
          },
        ],
      );
      store.retainRuns(cache: true);
      expect(
        store.runs().map((Map<String, Object?> run) => run['id']).toSet(),
        <String>{
          for (int index = 5; index < 15; index++) 'run-$index',
          'run-1',
          'run-2',
          'run-4',
        },
      );
      for (String removed in <String>['run-0', 'run-3']) {
        expect(store.runFile(removed).parent.existsSync(), isFalse);
        expect(store.runWork(removed).existsSync(), isFalse);
      }
      expect(
        Directory(
          p.join(store.runWork('run-1').path, 'sandboxes'),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(
          p.join(store.runWork('run-2').path, 'sandboxes'),
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(store.workDirectory.path, 'trash')).listSync(),
        isNotEmpty,
      );
      await store.emptyTrash();
      expect(
        Directory(p.join(store.workDirectory.path, 'trash')).listSync(),
        isEmpty,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'metadata scan runs against copies and atomically registers targets',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
      Directory(p.join(app.directory, 'gradle')).createSync();
      File(
        p.join(app.directory, 'gradle/multiplexor.gradle'),
      ).writeAsStringSync('ext.multiplexor = [:]');
      String metadata = jsonEncode(app.toJson());
      File observed = File(p.join(fixture.path, 'scan-source-hashes.json'));
      File(p.join(app.directory, 'gradlew')).writeAsStringSync(
        '#!/bin/sh\nmkdir -p build\nprintf \'%s\\n\' "\$MULTIPLEXOR_SOURCE_HASHES" > \'${observed.path}\'\nprintf \'%s\\n\' \'MULTIPLEXOR_PROJECT=$metadata\'\n',
      );
      List<BuildProject> results = await store.scan(
        p.join(fixture.path, 'sources'),
        (_) {},
      );
      Map<String, Object?> sourceHashes = projectReadJson(observed);
      expect(
        sourceHashes.keys.single,
        startsWith(store.workDirectory.resolveSymbolicLinksSync()),
      );
      expect(sourceHashes.keys.single, endsWith('/sources/app'));
      expect(sourceHashes.values.single, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(results.single.id, 'app');
      expect(store.projects().single.targets.single.id, 'one');
      expect(Directory(p.join(app.directory, 'build')).existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  Map<String, Object?> declaration(
    String id,
    List<Map<String, Object?>> targets, {
    List<String> sources = const <String>[],
  }) => <String, Object?>{
    'schema': 1,
    'id': id,
    'name': id,
    'sandbox': 'per-target',
    'parallelTargets': true,
    'sourceDependencies': sources,
    'sourceInputs': <String>[],
    'targets': targets,
  };

  BuildProject declare(
    BuildProject registered,
    Map<String, Object?> declared, {
    int exitCode = 0,
  }) {
    List<String> artifacts = <String>[
      for (Object? item in declared['targets'] as List<Object?>? ?? <Object?>[])
        for (Object? artifact
            in projectObject(item)['artifacts'] as List<Object?>)
          projectObject(artifact)['path'] as String,
    ];
    File(p.join(registered.directory, 'gradlew')).writeAsStringSync('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "multiplexorMetadata" ]; then
    printf '%s\\n' 'MULTIPLEXOR_PROJECT=${jsonEncode(declared)}'
    exit $exitCode
  fi
done
for artifact in ${artifacts.join(' ')}; do
  mkdir -p "\$(dirname "\$artifact")"
  cat input.txt > "\$artifact"
done
''');
    return BuildProject.fromJson(<String, Object?>{
      ...registered.toJson(),
      'definitionHash': 'outdated',
    });
  }

  Map<String, Map<String, Object?>> jobsByKey(Map<String, Object?> state) =>
      <String, Map<String, Object?>>{
        for (Object? item in state['jobs'] as List<Object?>)
          projectObject(item)['key'] as String: projectObject(item),
      };

  test(
    'changed declarations are re-read from the captured snapshot and saved',
    () async {
      BuildProject app = declare(
        project('app', <Map<String, Object?>>[
          target('one', artifactPath: 'build/app-1.jar'),
        ]),
        declaration('app', <Map<String, Object?>>[
          target('one', artifactPath: 'build/app-2.jar'),
        ]),
      );
      projectAtomicJson(store.catalogFile, <String, Object?>{
        'schema': 1,
        'projects': <Object?>[app.toJson()],
      });
      Map<String, Object?> state = run(
        'declared',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, state).execute(), 0);
      Map<String, Object?> artifact = projectObject(
        (jobsByKey(state)['app:one']!['artifacts'] as List<Object?>).single,
      );
      expect(p.basename(artifact['file'] as String), 'app-2.jar');
      String snapshotHash = await projectDefinitionHash(
        Directory(p.join(store.runWork('declared').path, 'snapshot', 'app')),
      );
      BuildProject saved = store.projects().single;
      expect(saved.targets.single.artifacts.single.path, 'build/app-2.jar');
      expect(saved.definitionHash, snapshotHash);
      BuildProject recorded = BuildProject.fromJson(
        projectObject((state['projects'] as List<Object?>).single),
      );
      expect(recorded.targets.single.artifacts.single.path, 'build/app-2.jar');
      expect(
        Directory(
          p.join(store.runWork('declared').path, 'declarations', 'sources'),
        ).existsSync(),
        isFalse,
      );
    },
    skip: Platform.isWindows,
  );

  test('unreadable declarations fail only their own targets', () async {
    BuildProject broken = declare(
      project('broken', <Map<String, Object?>>[target('one')]),
      <String, Object?>{},
      exitCode: 3,
    );
    BuildProject consumer = project('consumer', <Map<String, Object?>>[
      target('one', dependencies: <String>['broken:one']),
    ]);
    BuildProject app = project('app', <Map<String, Object?>>[target('one')]);
    Map<String, Object?> state = run(
      'partial',
      <BuildProject>[broken, consumer, app],
      <String>['consumer:one', 'app:one'],
    );
    expect(await ProjectWorker(store, state).execute(), 1);
    Map<String, Map<String, Object?>> jobs = jobsByKey(state);
    expect(jobs['broken:one']!['status'], 'failed');
    expect(
      jobs['broken:one']!['error'],
      contains('Cannot read broken targets'),
    );
    expect(File(jobs['broken:one']!['logPath'] as String).existsSync(), isTrue);
    expect(jobs['consumer:one']!['status'], 'blocked');
    expect(jobs['app:one']!['status'], 'succeeded');
  }, skip: Platform.isWindows);

  test('declarations drop removed targets and add new requirements', () async {
    BuildProject lib = project('lib', <Map<String, Object?>>[
      target('api', role: 'api'),
    ]);
    BuildProject shared = project('shared', <Map<String, Object?>>[
      target('library', role: 'library'),
    ]);
    BuildProject app = declare(
      project('app', <Map<String, Object?>>[target('one'), target('two')]),
      declaration(
        'app',
        <Map<String, Object?>>[
          target('one', dependencies: <String>['lib:api']),
        ],
        sources: <String>['shared'],
      ),
    );
    File(p.join(app.directory, 'gradlew')).writeAsStringSync(
      "if [ -d ../shared ]; then printf 'shared=present\\n'; fi\n",
      mode: FileMode.append,
    );
    Map<String, Object?> state = run(
      'reshaped',
      <BuildProject>[lib, shared, app],
      <String>['app:one', 'app:two'],
    );
    expect(await ProjectWorker(store, state).execute(), 1);
    Map<String, Map<String, Object?>> jobs = jobsByKey(state);
    expect(jobs['app:two']!['status'], 'failed');
    expect(jobs['app:two']!['error'], 'app no longer declares target two');
    expect(jobs['lib:api']!['status'], 'succeeded');
    expect(jobs['app:one']!['status'], 'succeeded');
    expect(state['targets'], <String>['lib:api', 'app:one']);
    expect(
      projectObject(state['sourceHashes']).keys,
      containsAll(<String>['app', 'lib', 'shared']),
    );
    expect(
      File(jobs['app:one']!['logPath'] as String).readAsStringSync(),
      contains('shared=present\n'),
    );
  }, skip: Platform.isWindows);

  test('version catalogs participate in declaration hashes', () async {
    Directory source = Directory(p.join(fixture.path, 'catalog'))..createSync();
    File catalog = File(p.join(source.path, 'gradle', 'libs.versions.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[versions]\nminecraft = "26.2"\n');
    String before = await projectDefinitionHash(source);
    catalog.writeAsStringSync('[versions]\nminecraft = "26.3"\n');
    expect(await projectDefinitionHash(source), isNot(before));
  });
}
