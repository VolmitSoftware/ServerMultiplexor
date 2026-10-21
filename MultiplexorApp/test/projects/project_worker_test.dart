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
          "${wrapper.readAsStringSync()}\nprintf '%s\\n' \"\$MULTIPLEXOR_SOURCE_HASHES\" > build/source-hashes.json\n",
        );
      }
      Map<String, Object?> first = run('first-stamps', projects, <String>[
        'library:one',
        'app:one',
        'other:one',
      ]);
      expect(await ProjectWorker(store, first).execute(), 0);
      Map<String, Object?> stamps(String runId, BuildProject project) {
        Directory sandbox = Directory(
          p.join(store.runWork(runId).path, 'sandboxes', project.id, 'one'),
        );
        Map<String, Object?> result = projectReadJson(
          File(
            p.join(
              sandbox.path,
              project.relativePath,
              'build/source-hashes.json',
            ),
          ),
        );
        expect(result.keys.toSet(), <String>{
          for (String source in <String>[
            project.id,
            ...project.sourceDependencies,
          ])
            Directory(p.join(sandbox.path, source)).resolveSymbolicLinksSync(),
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
        '\ncat ../docs/app/reference.txt > build/result.jar\n',
        mode: FileMode.append,
      );
      Map<String, Object?> first = run(
        'inputs-first',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, first).execute(), 0);
      String sandbox = p.join(
        store.runWork('inputs-first').path,
        'sandboxes/app/one',
      );
      expect(
        File(p.join(sandbox, 'docs/app/reference.txt')).readAsStringSync(),
        'first documentation',
      );
      expect(Directory(p.join(sandbox, 'docs/other')).existsSync(), isFalse);
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
      Map<String, Object?> state = run(
        'file-input',
        <BuildProject>[app],
        <String>['app:one'],
      );
      expect(await ProjectWorker(store, state).execute(), 0);
      expect(
        File(
          p.join(
            store.runWork('file-input').path,
            'sandboxes/app/one/docs/version.txt',
          ),
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
    'packaging participates in reuse and cache settings reach isolated Gradle homes',
    () async {
      BuildProject app = project('app', <Map<String, Object?>>[
        target('one'),
        target('two'),
      ]);
      File wrapper = File(p.join(app.directory, 'gradlew'));
      wrapper.writeAsStringSync(r'''
printf 'cache=%s home=%s\n' "$MULTIPLEXOR_TASK_CACHE" "$GRADLE_USER_HOME"
''', mode: FileMode.append);
      Map<String, Object?> first = run(
        'pack-local',
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
        expect(log, contains('-PcompactRelease=false'));
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
      expect(
        environments.map((String line) => line.split(' home=').last).toSet(),
        hasLength(2),
      );
      expect(
        File(
          p.join(store.runWork('pack-local').path, 'budget.init.gradle'),
        ).readAsStringSync(),
        contains('settings.buildCache'),
      );
      Map<String, Object?> compact = run(
        'pack-compact',
        <BuildProject>[app],
        <String>['app:one'],
        changed: true,
      );
      compact['packaging'] = 'compact';
      expect(await ProjectWorker(store, compact).execute(), 0);
      Map<String, Object?> job = projectObject(
        (compact['jobs'] as List<Object?>).single,
      );
      expect(job['reusedFrom'], isNull);
      expect(
        File(job['logPath'] as String).readAsStringSync(),
        contains('-PcompactRelease=true'),
      );
    },
    skip: Platform.isWindows,
  );

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
}
