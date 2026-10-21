import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'project_build_limits.dart';
import 'project_deployment.dart';
import 'project_files.dart';
import 'project_initializer.dart';
import 'project_model.dart';
import 'project_process.dart';
import 'project_store.dart';
import 'project_worker.dart';

class ProjectBuildService {
  ProjectBuildService({required String rootDirectory})
    : store = ProjectStore(rootDirectory);

  final ProjectStore store;

  ProjectBuildLimits limits() => store.limitsFile.existsSync()
      ? ProjectBuildLimits.fromJson(projectReadJson(store.limitsFile))
      : ProjectBuildLimits.defaults();

  List<Map<String, Object?>> catalog() =>
      store.projects().map((BuildProject project) => project.toJson()).toList();

  List<Map<String, Object?>> destinations() =>
      ProjectDeployment(store).destinations();

  Map<String, Object?> status([String? id]) {
    List<Map<String, Object?>> runs = id == null
        ? store.runs()
        : <Map<String, Object?>>[projectReadJson(store.runFile(id))];
    for (Map<String, Object?> run in runs) {
      if (!projectActiveStates.contains(run['status'])) continue;
      DateTime last = DateTime.parse(
        (run['heartbeatAt'] ?? run['createdAt']) as String,
      );
      if (DateTime.now().difference(last) > const Duration(seconds: 45)) {
        run['status'] = 'interrupted';
        run['error'] = 'Build worker heartbeat expired';
      }
    }
    return <String, Object?>{
      'runs': runs,
      'activeRunId': runs
          .where(
            (Map<String, Object?> run) =>
                projectActiveStates.contains(run['status']),
          )
          .firstOrNull?['id'],
    };
  }

  Future<int> command(
    List<String> arguments, {
    required void Function(String) output,
    required void Function(String) error,
  }) async {
    try {
      ProjectArguments args = ProjectArguments(arguments);
      switch (args.command) {
        case 'init':
          Map<String, Object?> initialized = ProjectInitializer().initialize(
            args.requiredPosition(0),
            id: args.option('id'),
            name: args.option('name'),
            java: args.option('java') == null ? null : args.integer('java', 25),
            apply: args.flag('apply'),
          );
          _emit(initialized, args, output);
          return 0;
        case 'limits':
          ProjectBuildLimits configured = await _configureLimits(args);
          _emit(configured.toJson(), args, output);
          return 0;
        case 'scan':
          List<BuildProject> projects = await store.locked(
            () => store.scan(
              args.requiredPosition(0),
              args.flag('json') ? error : output,
            ),
          );
          _emit(
            <String, Object?>{
              'projects': projects
                  .map((BuildProject project) => project.toJson())
                  .toList(),
            },
            args,
            output,
          );
          return 0;
        case 'list':
          _emit(<String, Object?>{'projects': catalog()}, args, output);
          return 0;
        case 'plan':
          ProjectPlan plan = _plan(args);
          _emit(
            <String, Object?>{
              'targets': plan.keys,
              'projects': plan.projects.values
                  .map((BuildProject project) => project.toJson())
                  .toList(),
            },
            args,
            output,
          );
          return 0;
        case 'build':
          ProjectPlan plan = _plan(args);
          String id = await _start(plan, args);
          _emit(<String, Object?>{'id': id, 'status': 'queued'}, args, output);
          return args.flag('wait') ? await _wait(id) : 0;
        case 'retry':
          String previous = args.requiredPosition(0);
          Map<String, Object?> old = projectReadJson(store.runFile(previous));
          if (projectActiveStates.contains(
            (status(previous)['runs'] as List<Object?>)
                .map(projectObject)
                .single['status'],
          )) {
            throw StateError('This build is still active');
          }
          Map<String, BuildProject> projects = <String, BuildProject>{
            for (Object? item in old['projects'] as List<Object?>)
              BuildProject.fromJson(projectObject(item)).id:
                  BuildProject.fromJson(projectObject(item)),
          };
          String id = await _start(
            ProjectPlan(projects, projectStrings(old['targets'])),
            args,
            previous: old,
          );
          _emit(<String, Object?>{'id': id, 'retryOf': previous}, args, output);
          return args.flag('wait') ? await _wait(id) : 0;
        case 'worker':
          String id = args.requiredPosition(0);
          return await ProjectWorker(
            store,
            projectReadJson(store.runFile(id)),
          ).execute();
        case 'status':
          _emit(status(args.positions.firstOrNull), args, output);
          return 0;
        case 'cancel':
          String id = args.requiredPosition(0);
          if (!store.runFile(id).existsSync()) {
            throw FormatException('Unknown run: $id');
          }
          Map<String, Object?> selected = (status(id)['runs'] as List<Object?>)
              .map(projectObject)
              .single;
          if (selected['status'] == 'interrupted') {
            await store.locked(() => _recoverInterrupted(cancelId: id));
          } else {
            if (!projectActiveStates.contains(selected['status'])) {
              throw StateError('This build is not active');
            }
            store.cancelFile(id).writeAsStringSync('cancel\n', flush: true);
          }
          output('Cancellation requested for $id');
          return 0;
        case 'logs':
          return await _logs(args, output);
        case 'destinations':
          _emit(
            <String, Object?>{'destinations': destinations()},
            args,
            output,
          );
          return 0;
        case 'destination':
          if (args.flag('remove')) {
            if (args.flag('dropins') ||
                <String>[
                  'path',
                  'platform',
                  'mc',
                  'instance',
                ].any((String name) => args.option(name) != null)) {
              throw const FormatException(
                'Choose --remove or destination settings',
              );
            }
            Map<String, Object?> removed = await ProjectDeployment(
              store,
            ).remove(args.requiredPosition(0));
            _emit(<String, Object?>{'removed': removed}, args, output);
            return 0;
          }
          Map<String, Object?> result = await ProjectDeployment(store)
              .configure(
                args.requiredPosition(0),
                path: args.option('path'),
                platform: args.option('platform'),
                minecraft: args.option('mc'),
                instance: args.option('instance'),
                dropins: args.flag('dropins'),
              );
          _emit(result, args, output);
          return 0;
        case 'deploy':
          Map<String, Object?> result = await ProjectDeployment(store).deploy(
            args.requiredPosition(0),
            args.option('to') ??
                (throw const FormatException('Missing --to destination')),
            target: args.option('target'),
            preview: args.flag('preview'),
          );
          _emit(result, args, output);
          return 0;
        default:
          throw FormatException('Unknown projects command: ${args.command}');
      }
    } on FormatException catch (failure) {
      error(failure.message);
      return 2;
    } catch (failure, trace) {
      error('$failure');
      if (arguments.firstOrNull == 'worker') error('$trace');
      return 1;
    }
  }

  Future<ProjectBuildLimits> _configureLimits(ProjectArguments args) async {
    if (<String>[
      'jobs',
      'memory',
      'workers',
    ].every((String name) => args.option(name) == null)) {
      return limits();
    }
    return store.locked(() async {
      ProjectBuildLimits current = limits();
      ProjectBuildLimits configured = ProjectBuildLimits(
        jobs: args.integer('jobs', current.jobs),
        memoryMiB: args.integer('memory', current.memoryMiB),
        workers: args.integer('workers', current.workers),
      );
      projectAtomicJson(store.limitsFile, configured.toJson());
      return configured;
    });
  }

  ProjectPlan _plan(ProjectArguments args) {
    List<BuildProject> projects = store.projects();
    if (projects.isEmpty) {
      throw const FormatException(
        'Register projects with projects scan <source-directory>',
      );
    }
    Map<String, BuildProject> catalog = <String, BuildProject>{
      for (BuildProject project in projects) project.id: project,
    };
    String? explicitTargets = args.option('targets');
    if (explicitTargets != null) {
      if (args.positions.isNotEmpty ||
          args.flag('all') ||
          args.option('target') != null ||
          args.flag('all-targets')) {
        throw const FormatException(
          'Choose --targets or a project, --all, --target, or --all-targets',
        );
      }
      List<String> keys = _targetSelection('targets', explicitTargets);
      for (String key in keys) {
        List<String> parts = key.split(':');
        if (parts.length != 2 || parts.any((String part) => part.isEmpty)) {
          throw const FormatException('--targets requires project:target IDs');
        }
        for (String part in parts) {
          projectIdentifier(part);
        }
      }
      return ProjectPlan(catalog, keys);
    }
    String? selection = args.positions.firstOrNull?.toLowerCase();
    if (args.flag('all') && selection != null) {
      throw const FormatException('Choose a project or --all');
    }
    if (selection == null && !args.flag('all')) {
      throw const FormatException('Choose a project or --all');
    }
    List<BuildProject> selected = projects
        .where(
          (BuildProject project) =>
              args.flag('all') ||
              project.id == selection ||
              project.name.toLowerCase() == selection,
        )
        .toList();
    if (selected.isEmpty) throw FormatException('Unknown project: $selection');
    String? target = args.option('target');
    if (target != null && args.flag('all-targets')) {
      throw const FormatException('Choose --target or --all-targets');
    }
    List<String>? targets = target == null
        ? null
        : _targetSelection('target', target);
    return ProjectPlan(catalog, <String>[
      for (BuildProject project in selected)
        if (targets != null)
          for (String id in targets) '${project.id}:${project.target(id).id}'
        else
          for (ProjectTarget target in project.targets)
            '${project.id}:${target.id}',
    ]);
  }

  List<String> _targetSelection(String option, String value) {
    List<String> targets = value
        .split(',')
        .map((String id) => id.trim())
        .toList();
    if (targets.any((String id) => id.isEmpty)) {
      throw FormatException(
        '--$option requires non-empty target IDs separated by commas',
      );
    }
    if (targets.toSet().length != targets.length) {
      throw FormatException('--$option contains duplicate target IDs');
    }
    return targets;
  }

  Future<String> _start(
    ProjectPlan plan,
    ProjectArguments args, {
    Map<String, Object?>? previous,
  }) => store.locked(() async {
    if (status()['activeRunId'] != null) {
      throw StateError(
        'A project build is active; use its status or cancel it first',
      );
    }
    await _recoverInterrupted();
    ProjectBuildLimits configured = previous == null
        ? limits()
        : ProjectBuildLimits(
            jobs: previous['jobsLimit'] as int,
            memoryMiB: previous['memoryMiB'] as int,
            workers: previous['workers'] as int,
          );
    int jobs = args.integer('jobs', configured.jobs);
    int memory = args.integer('memory', configured.memoryMiB);
    int workers = args.integer('workers', configured.workers);
    String packaging =
        args.option('packaging') ??
        previous?['packaging'] as String? ??
        'local';
    if (!<String>{'local', 'compact'}.contains(packaging)) {
      throw const FormatException('Packaging must be local or compact');
    }
    for (String key in plan.keys) {
      if (plan.targetFor(key).memoryMiB > memory) {
        throw FormatException(
          '$key needs ${plan.targetFor(key).memoryMiB} MiB; increase --memory',
        );
      }
    }
    String id = 'run-${DateTime.now().toUtc().microsecondsSinceEpoch}-$pid';
    List<Map<String, Object?>> jobsState = <Map<String, Object?>>[
      for (String key in plan.keys)
        <String, Object?>{
          'key': key,
          'project': plan.projectFor(key).id,
          'target': plan.targetFor(key).id,
          'status': 'queued',
          'artifacts': <Object?>[],
        },
    ];
    Map<String, Object?> run = <String, Object?>{
      'schema': 1,
      'id': id,
      'status': 'queued',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'projects': plan.projects.values
          .map((BuildProject project) => project.toJson())
          .toList(),
      'targets': plan.keys,
      'jobs': jobsState,
      'jobsLimit': jobs,
      'memoryMiB': memory,
      'workers': workers,
      'packaging': packaging,
      'changed': args.flag('changed'),
      if (previous != null) 'retryOf': previous['id'],
      if (previous != null) 'sourceHashes': previous['sourceHashes'],
      if (previous != null) 'inputHashes': previous['inputHashes'],
    };
    projectAtomicJson(store.runFile(id), run);
    try {
      await Process.start(
        Platform.resolvedExecutable,
        projectExecutableArguments(<String>[
          '--root',
          store.workspace,
          'projects',
          'worker',
          id,
        ]),
        workingDirectory: store.workspace,
        mode: ProcessStartMode.detached,
        environment: <String, String>{...Platform.environment}
          ..remove('GIT_CONFIG_COUNT'),
        includeParentEnvironment: false,
      );
    } catch (failure) {
      run['status'] = 'failed';
      run['error'] = '$failure';
      projectAtomicJson(store.runFile(id), run);
      rethrow;
    }
    return id;
  });

  Future<void> _recoverInterrupted({String? cancelId}) async {
    RandomAccessFile ownership = File(
      p.join(store.directory.path, 'worker.lock'),
    ).openSync(mode: FileMode.append);
    try {
      try {
        ownership.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw StateError('A build worker still owns this workspace');
      }
      for (Map<String, Object?> previous in store.runs()) {
        if (!projectActiveStates.contains(previous['status'])) continue;
        String previousId = previous['id'] as String;
        DateTime last = DateTime.parse(
          (previous['heartbeatAt'] ?? previous['createdAt']) as String,
        );
        if (DateTime.now().difference(last) <= const Duration(seconds: 45)) {
          throw StateError('A project build is starting; try again shortly');
        }
        for (Map<String, Object?> job
            in (previous['jobs'] as List<Object?>).map(projectObject)) {
          String? log = job['logPath'] as String?;
          if (log != null) await stopRecordedProjectProcess(File(log));
          if (projectActiveStates.contains(job['status'])) {
            job['status'] = previousId == cancelId
                ? 'cancelled'
                : 'interrupted';
          }
        }
        previous['status'] = previousId == cancelId
            ? 'cancelled'
            : 'interrupted';
        previous['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        previous['error'] = 'Build worker heartbeat expired';
        projectAtomicJson(store.runFile(previousId), previous);
      }
    } finally {
      ownership.closeSync();
    }
  }

  Future<int> _wait(String id) async {
    while (true) {
      Map<String, Object?> run = (status(id)['runs'] as List<Object?>)
          .map(projectObject)
          .single;
      if (!projectActiveStates.contains(run['status'])) {
        return run['status'] == 'succeeded' ? 0 : 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<int> _logs(ProjectArguments args, void Function(String) output) async {
    String id = args.requiredPosition(0);
    Map<String, int> offsets = <String, int>{};
    do {
      Map<String, Object?> run = (status(id)['runs'] as List<Object?>)
          .map(projectObject)
          .single;
      for (Map<String, Object?> job in (run['jobs'] as List<Object?>).map(
        projectObject,
      )) {
        if (args.option('target') != null &&
            args.option('target') != job['target'] &&
            args.option('target') != job['key']) {
          continue;
        }
        String? path = job['logPath'] as String?;
        if (path == null || !File(path).existsSync()) continue;
        RandomAccessFile file = File(path).openSync();
        try {
          file.setPositionSync(offsets[path] ?? 0);
          int remaining = file.lengthSync() - file.positionSync();
          while (remaining > 0) {
            List<int> bytes = file.readSync(min(65536, remaining));
            if (bytes.isEmpty) break;
            output(
              '[${job['key']}] ${utf8.decode(bytes, allowMalformed: true)}',
            );
            remaining -= bytes.length;
          }
          offsets[path] = file.positionSync();
        } finally {
          file.closeSync();
        }
      }
      if (!args.flag('follow') ||
          !projectActiveStates.contains(run['status'])) {
        return 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } while (true);
  }

  void _emit(
    Map<String, Object?> value,
    ProjectArguments args,
    void Function(String) output,
  ) {
    output(
      args.flag('json')
          ? jsonEncode(value)
          : const JsonEncoder.withIndent('  ').convert(value),
    );
  }
}

List<String> projectExecutableArguments(List<String> args) => <String>[
  if (Platform.script.scheme == 'file' &&
      Platform.script.path.endsWith('.dart'))
    Platform.script.toFilePath(),
  ...args,
];

class ProjectArguments {
  ProjectArguments(List<String> arguments)
    : command = arguments.firstOrNull ?? 'list' {
    for (int index = 1; index < arguments.length; index++) {
      String item = arguments[index];
      if (!item.startsWith('--')) {
        positions.add(item);
        continue;
      }
      String key = item.substring(2);
      int equals = key.indexOf('=');
      if (equals >= 0) {
        values[key.substring(0, equals)] = key.substring(equals + 1);
        continue;
      }
      if (<String>{
        'all',
        'all-targets',
        'wait',
        'json',
        'follow',
        'preview',
        'dropins',
        'changed',
        'remove',
        'apply',
      }.contains(key)) {
        values[key] = 'true';
      } else {
        if (++index >= arguments.length || arguments[index].startsWith('--')) {
          throw FormatException('Missing value for --$key');
        }
        values[key] = arguments[index];
      }
    }
  }
  final String command;
  final List<String> positions = <String>[];
  final Map<String, String> values = <String, String>{};
  String requiredPosition(int index) => positions.length > index
      ? positions[index]
      : throw FormatException('Missing argument for projects $command');
  String? option(String key) => values[key];
  bool flag(String key) => values[key] == 'true';
  int integer(String key, int fallback) {
    if (values[key] == null) return fallback;
    int? value = int.tryParse(values[key]!);
    if (value == null || value < 1) {
      throw FormatException('--$key expects a positive integer');
    }
    return value;
  }
}
