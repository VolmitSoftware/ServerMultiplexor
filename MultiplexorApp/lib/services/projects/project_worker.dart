import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'project_build_limits.dart';
import 'project_deployment.dart';
import 'project_files.dart';
import 'project_gradle_cache.dart';
import 'project_java_homes.dart';
import 'project_model.dart';
import 'project_process.dart';
import 'project_schedule.dart';
import 'project_store.dart';

class ProjectWorker {
  ProjectWorker(this.store, this.run);

  final ProjectStore store;
  final Map<String, Object?> run;
  final Map<String, Future<void>> _running = <String, Future<void>>{};
  final Map<String, String> _inputHashes = <String, String>{};
  late final ProjectGradleCache cache;
  final Map<String, String> _sourceHashes = <String, String>{};
  final Map<String, String> _toolchain = <String, String>{};
  final Map<String, Object> _declarationFailures = <String, Object>{};
  late final ProjectJavaHomes _javaHomes;
  late ProjectPlan plan;
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
      run['jobs'] = jobs;
      run['status'] = 'preparing';
      run['startedAt'] = DateTime.now().toUtc().toIso8601String();
      run['workerPid'] = pid;
      _save();
      heartbeat = Timer.periodic(const Duration(seconds: 2), (_) => _save());
      await _capture();
      await _inspectTools();
      cache = ProjectGradleCache(store)..prepare();
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
              (Map<String, Object?> job) =>
                  job['status'] == 'succeeded' && job['deliveryError'] == null,
            )
          ? 'succeeded'
          : 'failed';
      List<String> deliveryFailures = <String>[
        for (Map<String, Object?> job in jobs)
          if (job['deliveryError'] != null) job['key'] as String,
      ];
      if (deliveryFailures.isNotEmpty) {
        run['error'] =
            'Artifact delivery failed for ${deliveryFailures.join(', ')}; see target logs';
      }
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
        await _cleanStorage(store.retainRuns);
      }
      ownership.closeSync();
      if (ownsRun) await _cleanStorage(store.emptyTrash);
    }
  }

  Future<void> _cleanStorage(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, trace) {
      File(p.join(work.path, 'worker.log')).writeAsStringSync(
        'Build storage cleanup failed: $error\n$trace\n',
        mode: FileMode.append,
      );
    }
  }

  void _save() {
    run['heartbeatAt'] = DateTime.now().toUtc().toIso8601String();
    projectAtomicJson(store.runFile(id), run);
  }

  Future<void> _capture() async {
    List<String> requested = plan.keys.toList();
    Map<String, BuildProject> projects = <String, BuildProject>{
      ...plan.projects,
    };
    Map<String, String> previousHashes = <String, String>{};
    Directory declarations = Directory(
      p.join(work.path, 'declarations', 'sources'),
    );
    try {
      while (true) {
        plan = _replan(projects, requested);
        List<String> pending = <String>{
          for (String key in plan.keys)
            ...plan.sourcesFor(plan.projectFor(key).id),
        }.where((String id) => !_sourceHashes.containsKey(id)).toList();
        if (pending.isEmpty) break;
        List<String> stale = <String>[];
        for (String sourceId in pending) {
          if (cancelled) return;
          if (await _snapshot(projects[sourceId]!)) stale.add(sourceId);
        }
        for (String sourceId in stale) {
          if (cancelled) return;
          try {
            BuildProject declared = await _declare(
              projects[sourceId]!,
              projects,
            );
            previousHashes[sourceId] = projects[sourceId]!.definitionHash;
            projects[sourceId] = declared;
          } catch (error, trace) {
            _declarationFailures[sourceId] = error;
            File log = _declarationLog(sourceId);
            log.parent.createSync(recursive: true);
            log.writeAsStringSync('$error\n$trace\n', mode: FileMode.append);
          }
        }
      }
    } finally {
      if (declarations.existsSync()) await declarations.delete(recursive: true);
    }
    if (previousHashes.isNotEmpty) {
      run['projects'] = <Object?>[
        for (BuildProject project in projects.values) project.toJson(),
      ];
      await _registerDeclarations(previousHashes, <BuildProject>[
        for (String id in previousHashes.keys) projects[id]!,
      ]);
    }
    run['targets'] = plan.keys;
    for (String key in plan.keys) {
      if (jobs.any((Map<String, Object?> job) => job['key'] == key)) continue;
      jobs.add(<String, Object?>{
        'key': key,
        'project': plan.projectFor(key).id,
        'target': plan.targetFor(key).id,
        'status': 'queued',
        'artifacts': <Object?>[],
      });
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

  Future<bool> _snapshot(BuildProject source) async {
    Directory output = Directory(p.join(work.path, 'snapshot', source.id));
    if (output.existsSync()) {
      throw StateError('Source snapshot already exists: ${source.id}');
    }
    String? retryOf = run['retryOf'] as String?;
    Directory input = retryOf == null
        ? Directory(source.directory)
        : Directory(p.join(store.runWork(retryOf).path, 'snapshot', source.id));
    _sourceHashes[source.id] = await copyProjectSources(
      input,
      output,
      boundary: retryOf == null ? source.sourceRoot : input.path,
    );
    if (retryOf != null &&
        projectObject(run['sourceHashes'])[source.id] !=
            _sourceHashes[source.id]) {
      throw StateError('Saved source snapshot changed: ${source.id}');
    }
    return source.definitionHash.isNotEmpty &&
        source.definitionHash != await projectDefinitionHash(output);
  }

  Future<BuildProject> _declare(
    BuildProject source,
    Map<String, BuildProject> projects,
  ) async {
    Directory declarations = Directory(p.join(work.path, 'declarations'))
      ..createSync(recursive: true);
    String sources = p.join(declarations.path, 'sources');
    for (String id in _sourceHashes.keys) {
      String destination = p.join(sources, projects[id]!.relativePath);
      if (Directory(destination).existsSync()) continue;
      await materializeProjectSnapshot(
        p.join(work.path, 'snapshot', id),
        destination,
        boundary: p.join(work.path, 'snapshot'),
      );
    }
    File init = File(p.join(declarations.path, 'metadata.init.gradle'));
    if (!init.existsSync()) init.writeAsStringSync(projectMetadataInit);
    BuildProject declared = await readProjectDeclaration(
      sources: sources,
      relativePath: source.relativePath,
      sourceRoot: source.sourceRoot,
      init: init,
      log: _declarationLog(source.id),
      sourceHashes: <String, String>{
        for (String id in _sourceHashes.keys)
          Directory(
            p.join(sources, projects[id]!.relativePath),
          ).resolveSymbolicLinksSync(): _sourceHashes[id]!,
      },
      cancelled: () => cancelled,
    );
    if (declared.id != source.id) {
      throw StateError(
        '${source.relativePath} now declares project ${declared.id}; run projects scan to register it',
      );
    }
    return declared;
  }

  File _declarationLog(String id) =>
      File(p.join(work.path, 'declarations', '$id.log'));

  ProjectPlan _replan(
    Map<String, BuildProject> projects,
    List<String> requested,
  ) {
    List<String> declared = <String>[];
    for (String key in requested) {
      String projectId = key.split(':').first;
      String targetId = key.split(':').last;
      Object? failure = _declarationFailures[projectId];
      if (failure != null) {
        _reject(key, '$failure', _declarationLog(projectId));
      } else if (!projects[projectId]!.targets.any(
        (ProjectTarget target) => target.id == targetId,
      )) {
        _reject(key, '$projectId no longer declares target $targetId');
      } else {
        try {
          ProjectPlan(projects, <String>[key]);
          declared.add(key);
        } on FormatException catch (error) {
          _reject(key, 'Cannot plan $key: ${error.message}');
        }
      }
    }
    return ProjectPlan(projects, declared);
  }

  void _reject(String key, String error, [File? log]) {
    Map<String, Object?> job = jobs.firstWhere(
      (Map<String, Object?> job) => job['key'] == key,
    );
    if (job['status'] == 'failed') return;
    job['status'] = 'failed';
    job['error'] = error;
    if (log != null) job['logPath'] = log.path;
    job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
  }

  Future<void> _registerDeclarations(
    Map<String, String> previousHashes,
    List<BuildProject> declared,
  ) async {
    for (int attempt = 1; ; attempt++) {
      try {
        await store.registerDeclarations(previousHashes, declared);
        return;
      } on FileSystemException catch (error, trace) {
        if (attempt < 40) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        File(p.join(work.path, 'worker.log')).writeAsStringSync(
          'Catalog declarations were not updated: $error\n$trace\n',
          mode: FileMode.append,
        );
        return;
      }
    }
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
    ProjectBuildLimits budget = ProjectBuildLimits(
      jobs: run['jobsLimit'] as int,
      memoryMiB: run['memoryMiB'] as int,
      workers: run['workers'] as int,
    );
    int memory = budget.memoryMiB;
    Map<String, Map<String, Object?>> byKey = <String, Map<String, Object?>>{
      for (Map<String, Object?> job in jobs) job['key'] as String: job,
    };
    Map<String, Duration> estimates = projectDurationEstimates(
      store.runs(),
      plan.keys,
    );
    Map<String, Duration> priorities = projectCriticalPaths(plan, estimates);
    Map<String, DateTime> started = <String, DateTime>{};
    while (_running.isNotEmpty ||
        jobs.any(
          (Map<String, Object?> job) =>
              projectActiveStates.contains(job['status']),
        )) {
      if (cancelled) {
        for (Map<String, Object?> job in jobs.where(
          (Map<String, Object?> job) => job['status'] == 'queued',
        )) {
          job['status'] = 'cancelled';
        }
      }
      DateTime now = DateTime.now();
      List<ProjectScheduleEntry> ready = <ProjectScheduleEntry>[];
      for (Map<String, Object?> job in jobs) {
        if (job['status'] != 'queued' || cancelled) continue;
        String key = job['key'] as String;
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
        ready.add(_scheduleEntry(key, estimates[key]!, priorities[key]!));
      }
      List<ProjectScheduleEntry> running = <ProjectScheduleEntry>[
        for (String key in _running.keys)
          _scheduleEntry(
            key,
            _remaining(estimates[key]!, now.difference(started[key]!)),
            Duration.zero,
          ),
      ];
      for (String key in projectScheduleStarts(
        budget: budget,
        running: running,
        ready: ready,
      )) {
        Map<String, Object?> job = byKey[key]!;
        ProjectTarget target = plan.targetFor(key);
        job['status'] = 'preparing';
        started[key] = now;
        _running[key] =
            _build(
              job,
              plan.projectFor(key),
              target,
              min(target.workers, budget.workers),
              byKey,
            ).whenComplete(() {
              _running.remove(key);
            });
      }
      _save();
      if (_running.isEmpty) {
        if (jobs.any((Map<String, Object?> job) => job['status'] == 'queued')) {
          throw StateError('No build can run within the selected resources');
        }
        break;
      }
      await Future.any(_running.values);
    }
  }

  ProjectScheduleEntry _scheduleEntry(
    String key,
    Duration duration,
    Duration priority,
  ) {
    BuildProject project = plan.projectFor(key);
    ProjectTarget target = plan.targetFor(key);
    return ProjectScheduleEntry(
      key: key,
      project: project.id,
      memoryMiB: target.memoryMiB,
      workers: min(target.workers, run['workers'] as int),
      exclusive: project.sandbox != 'per-target' || !project.parallelTargets,
      duration: duration,
      priority: priority,
    );
  }

  Duration _remaining(Duration estimate, Duration elapsed) =>
      elapsed >= estimate ? Duration.zero : estimate - elapsed;

  Future<void> _build(
    Map<String, Object?> job,
    BuildProject project,
    ProjectTarget target,
    int workers,
    Map<String, Map<String, Object?>> byKey,
  ) async {
    Directory sandbox = Directory(
      p.join(work.path, 'sandboxes', project.id, target.id),
    );
    File log = File(p.join(work.path, 'logs', project.id, '${target.id}.log'));
    job['logPath'] = log.path;
    job['startedAt'] = DateTime.now().toUtc().toIso8601String();
    try {
      List<String> sources = plan.sourcesFor(project.id);
      sources.sort();
      String packaging = run['packaging'] as String? ?? 'compact';
      if (!<String>{'local', 'compact'}.contains(packaging)) {
        throw const FormatException('Packaging must be local or compact');
      }
      List<ProjectSourceInput> inputs = plan.inputsFor(project.id);
      String fingerprint = projectDigest(<String, Object?>{
        'packaging': packaging,
        'buildProperties': projectBuildProperties,
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
        for (MapEntry<String, String> property
            in projectBuildProperties.entries)
          '-P${property.key}=${property.value}',
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
      ProjectProcessResult result = await runProjectProcess(
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
          'MULTIPLEXOR_SOURCE_HASHES': jsonEncode(<String, String>{
            for (String source in sources)
              Directory(
                p.join(sandbox.path, plan.projects[source]!.relativePath),
              ).resolveSymbolicLinksSync(): _sourceHashes[source]!,
          }),
          'GRADLE_USER_HOME': cache.home.path,
        },
        onLine: (String line) {
          if (line.startsWith('> Task ')) {
            job['currentTask'] = line.substring(7);
          }
        },
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
      if (job['status'] == 'succeeded' && !cancelled) {
        _save();
        await _deliver(job, log);
      }
      job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
      _save();
    }
  }

  Future<void> _deliver(Map<String, Object?> job, File log) async {
    List<Map<String, Object?>> deliveries = <Map<String, Object?>>[];
    job['deliveries'] = deliveries;
    job['deliveryStatus'] = 'running';
    ProjectDeployment deployment = ProjectDeployment(store);
    try {
      for (Map<String, Object?> destination in deployment.destinations()) {
        if (cancelled) break;
        if (destination['kind'] != 'directory' &&
            destination['kind'] != 'dropins') {
          continue;
        }
        String name = destination['name'] as String;
        job['currentTask'] = 'Delivering to $name';
        try {
          Map<String, Object?> result = await deployment.deploy(
            id,
            name,
            target: job['key'] as String,
            automatic: true,
          );
          deliveries.add(<String, Object?>{'status': 'succeeded', ...result});
          log.writeAsStringSync(
            'Delivery to $name: ${result['status'] ?? 'succeeded'}\n',
            mode: FileMode.append,
          );
        } catch (error, trace) {
          deliveries.add(<String, Object?>{
            'destination': name,
            'status': 'failed',
            'error': '$error',
          });
          job['deliveryError'] = 'Delivery to $name failed: $error';
          log.writeAsStringSync(
            '${job['deliveryError']}\n$trace\n',
            mode: FileMode.append,
          );
        }
        _save();
      }
    } catch (error, trace) {
      job['deliveryError'] = 'Automatic delivery failed: $error';
      log.parent.createSync(recursive: true);
      log.writeAsStringSync(
        '${job['deliveryError']}\n$trace\n',
        mode: FileMode.append,
      );
    }
    job['deliveryStatus'] = job['deliveryError'] != null
        ? 'failed'
        : deliveries.any(
            (Map<String, Object?> item) => item['status'] == 'succeeded',
          )
        ? 'succeeded'
        : 'skipped';
    job['currentTask'] = switch (job['deliveryStatus']) {
      'failed' => 'Delivery failed',
      'succeeded' => 'Build and delivery complete',
      _ => 'Build complete',
    };
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
