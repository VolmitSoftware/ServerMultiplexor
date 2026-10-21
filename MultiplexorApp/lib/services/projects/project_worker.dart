import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'project_files.dart';
import 'project_gradle_cache.dart';
import 'project_java_homes.dart';
import 'project_model.dart';
import 'project_process.dart';
import 'project_store.dart';

const Set<String> projectActiveStates = <String>{
  'queued',
  'preparing',
  'running',
};

class ProjectWorker {
  ProjectWorker(this.store, this.run);

  final ProjectStore store;
  final Map<String, Object?> run;
  final Map<String, Future<void>> _running = <String, Future<void>>{};
  final Map<String, String> _inputHashes = <String, String>{};
  late final ProjectGradleCache cache;
  final Map<String, String> _sourceHashes = <String, String>{};
  final Map<String, String> _toolchain = <String, String>{};
  late final ProjectJavaHomes _javaHomes;
  late final ProjectPlan plan;
  late final List<Map<String, Object?>> jobs;
  late final Directory work;
  late final File budgetInit;
  String get id => run['id'] as String;
  bool get cancelled => store.cancelFile(id).existsSync();

  Future<int> execute() async {
    work = store.runWork(id)..createSync(recursive: true);
    RandomAccessFile ownership = File(
      p.join(store.directory.path, 'worker.lock'),
    ).openSync(mode: FileMode.append);
    Timer? heartbeat;
    bool ownsRun = false;
    try {
      ownership.lockSync(FileLock.exclusive);
      if (store.runFile(id).existsSync() &&
          projectReadJson(store.runFile(id))['status'] != 'queued') {
        return 1;
      }
      ownsRun = true;
      Map<String, BuildProject> projects = <String, BuildProject>{
        for (Object? item in run['projects'] as List<Object?>)
          BuildProject.fromJson(projectObject(item)).id: BuildProject.fromJson(
            projectObject(item),
          ),
      };
      plan = ProjectPlan(projects, projectStrings(run['targets']));
      jobs = (run['jobs'] as List<Object?>).map(projectObject).toList();
      run['status'] = 'preparing';
      run['startedAt'] = DateTime.now().toUtc().toIso8601String();
      run['workerPid'] = pid;
      _save();
      heartbeat = Timer.periodic(const Duration(seconds: 2), (_) => _save());
      await _capture();
      await _inspectTools();
      cache = ProjectGradleCache(store, id, cancelled: () => cancelled);
      if (!cancelled) await cache.prepare();
      if (cache.dependencyCache != null) {
        run['dependencyCache'] = cache.dependencyCache!.path;
      }
      if (cancelled) {
        for (Map<String, Object?> job in jobs) {
          job['status'] = 'cancelled';
        }
      } else {
        run['status'] = 'running';
        budgetInit = File(p.join(work.path, 'budget.init.gradle'))
          ..writeAsStringSync(projectBudgetInit);
        await _schedule();
      }
      run['status'] = cancelled
          ? 'cancelled'
          : jobs.every(
              (Map<String, Object?> job) => job['status'] == 'succeeded',
            )
          ? 'succeeded'
          : 'failed';
      return run['status'] == 'succeeded' ? 0 : 1;
    } catch (error, trace) {
      if (!ownsRun) return 1;
      run['status'] = cancelled ? 'cancelled' : 'failed';
      run['error'] = '$error';
      File(
        p.join(work.path, 'worker.log'),
      ).writeAsStringSync('$error\n$trace\n', mode: FileMode.append);
      for (Object? item in run['jobs'] as List<Object?>) {
        Map<String, Object?> job = projectObject(item);
        if (projectActiveStates.contains(job['status'])) {
          job['status'] = cancelled ? 'cancelled' : 'blocked';
          job['error'] = '$error';
        }
      }
      return 1;
    } finally {
      heartbeat?.cancel();
      if (ownsRun) {
        run['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        _save();
      }
      ownership.closeSync();
    }
  }

  void _save() {
    run['heartbeatAt'] = DateTime.now().toUtc().toIso8601String();
    projectAtomicJson(store.runFile(id), run);
  }

  Future<void> _capture() async {
    Set<String> sources = <String>{
      for (String key in plan.keys) ...plan.sourcesFor(plan.projectFor(key).id),
    };
    for (String sourceId in sources) {
      if (cancelled) return;
      BuildProject source = plan.projects[sourceId]!;
      Directory output = Directory(p.join(work.path, 'snapshot', sourceId));
      if (output.existsSync()) {
        throw StateError('Source snapshot already exists: $sourceId');
      }
      String? retryOf = run['retryOf'] as String?;
      Directory input = retryOf == null
          ? Directory(source.directory)
          : Directory(
              p.join(store.runWork(retryOf).path, 'snapshot', sourceId),
            );
      _sourceHashes[sourceId] = await copyProjectSources(
        input,
        output,
        boundary: retryOf == null ? source.sourceRoot : input.path,
      );
      if (source.definitionHash.isNotEmpty &&
          source.definitionHash != await projectDefinitionHash(output)) {
        throw StateError(
          'Build definitions changed for $sourceId; run projects scan again',
        );
      }
      if (retryOf != null &&
          projectObject(run['sourceHashes'])[sourceId] !=
              _sourceHashes[sourceId]) {
        throw StateError('Saved source snapshot changed: $sourceId');
      }
    }
    Map<String, ProjectSourceInput> inputs = <String, ProjectSourceInput>{
      for (String key in plan.keys)
        for (ProjectSourceInput input in plan.inputsFor(
          plan.projectFor(key).id,
        ))
          input.key: input,
    };
    for (ProjectSourceInput input in inputs.values) {
      if (cancelled) return;
      String snapshot = projectDigest(input.key);
      String? retryOf = run['retryOf'] as String?;
      String origin = retryOf == null
          ? input.key
          : p.join(store.runWork(retryOf).path, 'input-snapshot', snapshot);
      _inputHashes[input.key] = await copyProjectSourceInput(
        origin,
        p.join(work.path, 'input-snapshot', snapshot),
        boundary: retryOf == null
            ? input.sourceRoot
            : p.join(store.runWork(retryOf).path, 'input-snapshot'),
      );
      if (retryOf != null &&
          projectObject(run['inputHashes'])[input.key] !=
              _inputHashes[input.key]) {
        throw StateError('Saved source input changed: ${input.relativePath}');
      }
    }
    run['inputHashes'] = _inputHashes;
    run['sourceHashes'] = _sourceHashes;
    run['platform'] = '${Platform.operatingSystem}/${Platform.version}';
    _save();
  }

  Future<void> _inspectTools() async {
    for (String tool in <String>['java', 'rustc', 'cargo']) {
      try {
        ProcessResult result = await Process.run(tool, <String>[
          tool == 'java' ? '-version' : '--version',
        ]).timeout(const Duration(seconds: 15));
        _toolchain[tool] =
            '${result.exitCode}:${result.stdout}${result.stderr}';
      } on ProcessException {
        _toolchain[tool] = 'unavailable';
      }
    }
    _toolchain['platform'] = '${Platform.operatingSystem}/${Platform.version}';
    List<String> javaPaths = <String>[];
    if (Platform.isMacOS) {
      ProcessResult result = await Process.run(
        '/usr/libexec/java_home',
        <String>['-V'],
      );
      javaPaths.addAll(projectMacJavaHomes('${result.stdout}${result.stderr}'));
    } else if (Platform.isLinux && Directory('/usr/lib/jvm').existsSync()) {
      for (FileSystemEntity entry in Directory('/usr/lib/jvm').listSync()) {
        if (Directory(entry.path).existsSync()) {
          javaPaths.add(entry.path);
        }
      }
    }
    _javaHomes = await ProjectJavaHomes.capture(
      discoveredHomes: javaPaths,
      environment: Platform.environment,
    );
    _toolchain['javaInstallations'] = _javaHomes.fingerprint;
    List<String> environmentKeys =
        Platform.environment.keys
            .where(
              (String key) =>
                  <String>{
                    'JAVA_HOME',
                    'JAVA_EXECUTABLE',
                    'GRADLE_OPTS',
                    'JAVA_TOOL_OPTIONS',
                    'JDK_JAVA_OPTIONS',
                    '_JAVA_OPTIONS',
                    'PATH',
                    'RUSTFLAGS',
                    'RUSTDOCFLAGS',
                    'RUSTUP_TOOLCHAIN',
                    'CC',
                    'CXX',
                    'CFLAGS',
                    'CXXFLAGS',
                  }.contains(key) ||
                  key.startsWith('JAVA_HOME_') ||
                  key.startsWith('ORG_GRADLE_PROJECT_') ||
                  key.startsWith('CARGO_'),
            )
            .toList()
          ..sort();
    _toolchain['environment'] = projectDigest(<String, String?>{
      for (String key in environmentKeys) key: Platform.environment[key],
    });
    run['toolchain'] = _toolchain;
  }

  Future<void> _schedule() async {
    int limit = run['jobsLimit'] as int;
    int memory = run['memoryMiB'] as int;
    int workers = run['workers'] as int;
    Map<String, Map<String, Object?>> byKey = <String, Map<String, Object?>>{
      for (Map<String, Object?> job in jobs) job['key'] as String: job,
    };
    while (jobs.any(
      (Map<String, Object?> job) => projectActiveStates.contains(job['status']),
    )) {
      if (cancelled) {
        for (Map<String, Object?> job in jobs.where(
          (Map<String, Object?> job) => job['status'] == 'queued',
        )) {
          job['status'] = 'cancelled';
        }
      }
      int reservedMemory = 0;
      int reservedWorkers = 0;
      Set<String> activeProjects = <String>{};
      for (String key in _running.keys) {
        reservedMemory += plan.targetFor(key).memoryMiB;
        reservedWorkers += min(plan.targetFor(key).workers, workers);
        activeProjects.add(plan.projectFor(key).id);
      }
      for (Map<String, Object?> job in jobs) {
        if (job['status'] != 'queued' || cancelled) continue;
        String key = job['key'] as String;
        BuildProject project = plan.projectFor(key);
        ProjectTarget target = plan.targetFor(key);
        Set<String> dependencies = <String>{
          ...target.dependsOn,
          ...target.artifactProperties.values,
        };
        if (dependencies.any(
          (String key) => <String>{
            'failed',
            'blocked',
            'cancelled',
          }.contains(byKey[key]!['status']),
        )) {
          job['status'] = 'blocked';
          job['error'] = 'A required build did not succeed';
          continue;
        }
        if (dependencies.any(
          (String key) => byKey[key]!['status'] != 'succeeded',
        )) {
          continue;
        }
        if (target.memoryMiB > memory) {
          job['status'] = 'failed';
          job['error'] =
              'Target reserves ${target.memoryMiB} MiB; run budget is $memory MiB';
          continue;
        }
        int requestedWorkers = min(target.workers, workers);
        if (_running.length >= limit ||
            reservedMemory + target.memoryMiB > memory ||
            reservedWorkers + requestedWorkers > workers ||
            ((project.sandbox != 'per-target' || !project.parallelTargets) &&
                activeProjects.contains(project.id))) {
          continue;
        }
        job['status'] = 'preparing';
        reservedMemory += target.memoryMiB;
        reservedWorkers += requestedWorkers;
        activeProjects.add(project.id);
        _running[key] = _build(job, project, target, requestedWorkers, byKey);
      }
      _save();
      if (_running.isEmpty) {
        if (jobs.any((Map<String, Object?> job) => job['status'] == 'queued')) {
          throw StateError('No build can run within the selected resources');
        }
        break;
      }
      await Future.any(_running.values);
      _running.removeWhere(
        (String key, Future<void> value) =>
            !projectActiveStates.contains(byKey[key]!['status']),
      );
    }
  }

  Future<void> _build(
    Map<String, Object?> job,
    BuildProject project,
    ProjectTarget target,
    int workers,
    Map<String, Map<String, Object?>> byKey,
  ) async {
    String key = job['key'] as String;
    Directory sandbox = Directory(
      p.join(work.path, 'sandboxes', project.id, target.id),
    );
    File log = File(p.join(work.path, 'logs', project.id, '${target.id}.log'));
    job['logPath'] = log.path;
    job['startedAt'] = DateTime.now().toUtc().toIso8601String();
    try {
      List<String> sources = plan.sourcesFor(project.id);
      sources.sort();
      String packaging = run['packaging'] as String? ?? 'local';
      if (!<String>{'local', 'compact'}.contains(packaging)) {
        throw const FormatException('Packaging must be local or compact');
      }
      List<ProjectSourceInput> inputs = plan.inputsFor(project.id);
      String fingerprint = projectDigest(<String, Object?>{
        'packaging': packaging,
        'inputs': <String, String>{
          for (ProjectSourceInput input in inputs)
            input.relativePath: _inputHashes[input.key]!,
        },
        'sources': <String, Object?>{
          for (String source in sources)
            source: <String, Object?>{
              'hash': _sourceHashes[source]!,
              'path': plan.projects[source]!.relativePath,
            },
        },
        'target': target.toJson(),
        'testBudget': projectBudgetInit,
        'toolchain': _toolchain,
        'dependencies': <String, Object?>{
          for (String dependency in <String>{
            ...target.dependsOn,
            ...target.artifactProperties.values,
          })
            dependency: <Object?>[
              for (Map<String, Object?> artifact
                  in (byKey[dependency]!['artifacts'] as List<Object?>).map(
                    projectObject,
                  ))
                <String, Object?>{
                  'sha256': artifact['sha256'],
                  'role': artifact['role'],
                  'platforms': artifact['platforms'],
                },
            ],
        },
      });
      job['fingerprint'] = fingerprint;
      if ((run['changed'] == true || run['retryOf'] != null) &&
          await _reuse(job, fingerprint)) {
        return;
      }
      for (String sourceId in sources) {
        BuildProject source = plan.projects[sourceId]!;
        await materializeProjectSnapshot(
          p.join(work.path, 'snapshot', sourceId),
          p.join(sandbox.path, source.relativePath),
          boundary: p.join(work.path, 'snapshot'),
        );
      }
      for (ProjectSourceInput input in inputs) {
        await materializeProjectSnapshot(
          p.join(work.path, 'input-snapshot', projectDigest(input.key)),
          p.join(sandbox.path, input.relativePath),
          boundary: p.join(work.path, 'input-snapshot'),
        );
      }
      String directory = p.join(sandbox.path, project.relativePath);
      List<String> args = <String>[
        ...target.tasks,
        ...target.arguments,
        '--no-daemon',
        '--build-cache',
        '-PcompactRelease=${packaging == 'compact'}',
        '--console=plain',
        '--max-workers=$workers',
        '--init-script',
        budgetInit.path,
        ...localSourceArguments(sandbox.path),
        '-PmultiplexorSandbox=true',
      ];
      for (MapEntry<String, String> property
          in target.artifactProperties.entries) {
        List<Object?> artifacts =
            byKey[property.value]!['artifacts'] as List<Object?>;
        List<Map<String, Object?>> api = artifacts
            .map(projectObject)
            .where((Map<String, Object?> artifact) => artifact['role'] == 'api')
            .toList();
        if (api.length != 1) {
          throw StateError(
            '${property.value} must produce exactly one API artifact',
          );
        }
        args.add('-P${property.key}=${api.single['file']}');
      }
      if (cancelled) {
        job['status'] = 'cancelled';
        return;
      }
      job['status'] = 'running';
      _save();
      ProjectProcessResult result = await cache.withHome(
        key,
        (Directory gradleHome) => runProjectProcess(
          executable: p.join(
            directory,
            Platform.isWindows ? 'gradlew.bat' : 'gradlew',
          ),
          arguments: args,
          directory: directory,
          log: log,
          cancelled: () => cancelled,
          environment: <String, String>{
            ..._javaHomes.environment,
            'MULTIPLEXOR_TEST_FORKS': '$workers',
            'MULTIPLEXOR_TASK_CACHE': cache.taskCache.path,
            if (cache.dependencyCache != null)
              'GRADLE_RO_DEP_CACHE': cache.dependencyCache!.path,
            'MULTIPLEXOR_SOURCE_HASHES': jsonEncode(<String, String>{
              for (String source in sources)
                Directory(
                  p.join(sandbox.path, plan.projects[source]!.relativePath),
                ).resolveSymbolicLinksSync(): _sourceHashes[source]!,
            }),
            'GRADLE_USER_HOME': gradleHome.path,
          },
          removeEnvironment: const <String>{'GRADLE_RO_DEP_CACHE'},
          onLine: (String line) {
            if (line.startsWith('> Task ')) {
              job['currentTask'] = line.substring(7);
            }
          },
        ),
      );
      job['exitCode'] = result.exitCode;
      if (cancelled || result.exitCode == 130) {
        job['status'] = 'cancelled';
        return;
      }
      if (result.exitCode != 0) {
        throw StateError('Gradle exited ${result.exitCode}; see ${log.path}');
      }
      List<Map<String, Object?>> artifacts = <Map<String, Object?>>[];
      for (ProjectArtifact artifact in target.artifacts) {
        File source = File(p.join(directory, artifact.path));
        if (!source.existsSync() ||
            source.lengthSync() == 0 ||
            !p.isWithin(sandbox.path, source.resolveSymbolicLinksSync())) {
          throw StateError(
            'Missing or invalid declared artifact: ${artifact.path}',
          );
        }
        Directory destination = Directory(
          p.join(work.path, 'artifacts', project.id, target.id),
        )..createSync(recursive: true);
        File output = File(p.join(destination.path, p.basename(source.path)));
        if (output.existsSync()) {
          throw StateError('Artifact filename collision: ${output.path}');
        }
        await source.copy(output.path);
        artifacts.add(<String, Object?>{
          ...artifact.toJson(),
          'file': output.path,
          'sha256': await projectFileHash(output),
          'size': output.lengthSync(),
          'project': project.id,
          'target': target.id,
        });
      }
      job['artifacts'] = artifacts;
      job['status'] = 'succeeded';
    } catch (error, trace) {
      job['status'] = cancelled ? 'cancelled' : 'failed';
      job['error'] = '$error';
      log.parent.createSync(recursive: true);
      log.writeAsStringSync('$error\n$trace\n', mode: FileMode.append);
    } finally {
      job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
      _save();
    }
  }

  Future<bool> _reuse(Map<String, Object?> job, String fingerprint) async {
    String? retryOf = run['retryOf'] as String?;
    for (Map<String, Object?> previous in store.runs()) {
      if (previous['id'] == id ||
          (retryOf != null && previous['id'] != retryOf)) {
        continue;
      }
      for (Map<String, Object?> candidate
          in (previous['jobs'] as List<Object?>).map(projectObject)) {
        if (candidate['key'] != job['key'] ||
            candidate['status'] != 'succeeded' ||
            candidate['fingerprint'] != fingerprint) {
          continue;
        }
        List<Map<String, Object?>> artifacts =
            (candidate['artifacts'] as List<Object?>)
                .map(projectObject)
                .toList();
        Directory previousArtifacts = Directory(
          p.join(store.runWork(previous['id'] as String).path, 'artifacts'),
        );
        bool valid = true;
        for (Map<String, Object?> artifact in artifacts) {
          File file = File(artifact['file'] as String);
          if (!file.existsSync() ||
              !p.isWithin(
                previousArtifacts.path,
                file.resolveSymbolicLinksSync(),
              ) ||
              file.lengthSync() != artifact['size'] ||
              await projectFileHash(file) != artifact['sha256']) {
            valid = false;
            break;
          }
        }
        if (!valid) continue;
        Directory destination = Directory(
          p.join(
            work.path,
            'artifacts',
            job['project'] as String,
            job['target'] as String,
          ),
        )..createSync(recursive: true);
        List<Map<String, Object?>> copied = <Map<String, Object?>>[];
        for (Map<String, Object?> artifact in artifacts) {
          File source = File(artifact['file'] as String);
          File output = File(p.join(destination.path, p.basename(source.path)));
          if (output.existsSync()) {
            throw StateError('Artifact filename collision: ${output.path}');
          }
          await source.copy(output.path);
          if (output.lengthSync() != artifact['size'] ||
              await projectFileHash(output) != artifact['sha256']) {
            throw StateError(
              'Cached artifact changed during copy: ${source.path}',
            );
          }
          copied.add(<String, Object?>{...artifact, 'file': output.path});
        }
        job['status'] = 'succeeded';
        job['artifacts'] = copied;
        job['reusedFrom'] = previous['id'];
        File log = File(job['logPath'] as String);
        log.parent.createSync(recursive: true);
        log.writeAsStringSync(
          'Reused verified artifacts from ${previous['id']}\n',
        );
        return true;
      }
    }
    return false;
  }
}
