import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/consumer_profile.dart';
import '../../utils/async_work_pool.dart';
import '../../utils/process_runner.dart';
import '../consumer_service.dart';
import '../manager_context.dart';
import '../native_command_service.dart';
import 'project_files.dart';
import 'project_model.dart';
import 'project_store.dart';

class ProjectDeployment {
  ProjectDeployment(this.store, {void Function(File, String)? moveFile})
    : _moveFile = moveFile ?? moveProjectFile;

  final ProjectStore store;
  final void Function(File, String) _moveFile;
  static final Map<String, AsyncGate> _gates = <String, AsyncGate>{};
  static const String _manifestName = '.multiplexor-project-artifacts.json';
  static const Set<String> _platforms = <String>{
    'plugin',
    'fabric',
    'forge',
    'neoforge',
    'velocity',
    'bungee',
  };

  Future<Map<String, Object?>> configure(
    String name, {
    String? path,
    String? platform,
    String? minecraft,
    String? instance,
    bool dropins = false,
  }) async {
    projectIdentifier(name);
    if ((path != null ? 1 : 0) +
            (instance != null ? 1 : 0) +
            (dropins ? 1 : 0) !=
        1) {
      throw const FormatException(
        'Choose one destination path, instance or dropins',
      );
    }
    if (platform != null && !_platforms.contains(platform)) {
      throw FormatException('Unknown destination platform: $platform');
    }
    if (minecraft != null) _version(minecraft);
    Map<String, Object?> destination = <String, Object?>{
      'name': name,
      'kind': instance != null
          ? 'instance'
          : dropins
          ? 'dropins'
          : 'directory',
      if (path != null) 'path': _safePath(path),
      'platform': ?platform,
      'minecraft': ?minecraft,
      'instance': ?instance,
    };
    destination = await _resolve(destination, checkRuntime: false);
    return store.locked(() async {
      List<Map<String, Object?>> configured = destinations()
        ..removeWhere((Map<String, Object?> item) => item['name'] == name)
        ..add(destination)
        ..sort(
          (Map<String, Object?> a, Map<String, Object?> b) =>
              (a['name'] as String).compareTo(b['name'] as String),
        );
      _safePath(store.destinationsFile.path);
      projectAtomicJson(store.destinationsFile, <String, Object?>{
        'schema': 1,
        'destinations': configured,
      });
      return destination;
    });
  }

  Future<Map<String, Object?>> remove(String name) async {
    projectIdentifier(name);
    return store.locked(() async {
      List<Map<String, Object?>> configured = destinations();
      int index = configured.indexWhere(
        (Map<String, Object?> item) => item['name'] == name,
      );
      if (index < 0) throw FormatException('Unknown destination: $name');
      Map<String, Object?> removed = configured.removeAt(index);
      _safePath(store.destinationsFile.path);
      projectAtomicJson(store.destinationsFile, <String, Object?>{
        'schema': 1,
        'destinations': configured,
      });
      return removed;
    });
  }

  Future<Map<String, Object?>> deploy(
    String runId,
    String destination, {
    String? target,
    bool preview = false,
    bool automatic = false,
  }) async {
    projectIdentifier(runId);
    Map<String, Object?> configured = destinations().firstWhere(
      (Map<String, Object?> item) => item['name'] == destination,
      orElse: () => throw FormatException('Unknown destination: $destination'),
    );
    if (automatic && !_selectAutomatic(runId, configured, target)) {
      return <String, Object?>{
        'runId': runId,
        'destination': destination,
        'status': 'skipped',
        'reason': 'No compatible runtime artifacts',
        'actions': <Object?>[],
      };
    }
    Map<String, Object?> resolved = await _resolve(
      configured,
      checkRuntime: true,
    );
    String directory = resolved['path'] as String;
    return _gates.putIfAbsent(directory, AsyncGate.new).run(() async {
      _safePath(directory);
      if (preview) {
        return _prepare(runId, resolved, target, null, preview: true);
      }
      Directory(directory).createSync(recursive: true);
      String lockPath = p.join(directory, '$_manifestName.lock');
      _regularFileOrMissing(lockPath);
      RandomAccessFile lock = File(lockPath).openSync(mode: FileMode.append);
      Directory? stage;
      bool locked = false;
      bool preserveStage = false;
      try {
        await lock.lock(FileLock.exclusive);
        locked = true;
        resolved = await _resolve(configured, checkRuntime: true);
        if (resolved['path'] != directory) {
          throw StateError('Destination changed while deployment was starting');
        }
        stage = Directory.systemTemp.createTempSync('multiplexor-stage-');
        return await _prepare(runId, resolved, target, stage, preview: false);
      } on _DeploymentRecoveryFailure {
        preserveStage = true;
        rethrow;
      } finally {
        try {
          if (stage != null && !preserveStage) {
            stage.deleteSync(recursive: true);
          }
        } finally {
          if (locked) lock.unlockSync();
          lock.closeSync();
        }
      }
    });
  }

  List<Map<String, Object?>> destinations() {
    _regularFileOrMissing(store.destinationsFile.path);
    if (!store.destinationsFile.existsSync()) return <Map<String, Object?>>[];
    Map<String, Object?> saved = projectReadJson(store.destinationsFile);
    if (saved['schema'] != 1 || saved['destinations'] is! List<Object?>) {
      throw const FormatException('Invalid project destinations');
    }
    return (saved['destinations'] as List<Object?>).map(projectObject).toList();
  }

  bool _selectAutomatic(
    String runId,
    Map<String, Object?> destination,
    String? target,
  ) {
    if (destination['kind'] != 'directory' &&
        destination['kind'] != 'dropins') {
      throw StateError(
        'Automatic delivery requires an export directory or dropins',
      );
    }
    if (target == null) {
      throw const FormatException('Automatic delivery requires one target');
    }
    File runFile = store.runFile(runId);
    _regularFileOrMissing(runFile.path);
    Map<String, Object?> run = projectReadJson(runFile);
    Map<String, Object?> job = (run['jobs'] as List<Object?>)
        .map(projectObject)
        .firstWhere((Map<String, Object?> item) => item['key'] == target);
    if (job['status'] != 'succeeded' ||
        !(job['artifacts'] as List<Object?>)
            .map(projectObject)
            .any(
              (Map<String, Object?> artifact) =>
                  _matches(destination, artifact),
            )) {
      return false;
    }
    if (destination['kind'] == 'dropins') {
      Set<String> selected = projectStrings(run['targets']).toSet();
      for (Object? raw in run['projects'] as List<Object?>) {
        BuildProject project = BuildProject.fromJson(projectObject(raw));
        if (!target.startsWith('${project.id}:')) continue;
        for (ProjectTarget candidate in project.targets) {
          String key = '${project.id}:${candidate.id}';
          if (key != target &&
              selected.contains(key) &&
              candidate.artifacts.any(
                (ProjectArtifact artifact) =>
                    _matches(destination, artifact.toJson()),
              )) {
            throw StateError(
              'Multiple compatible targets for ${project.id}; deliver one project:target manually',
            );
          }
        }
      }
    }
    return true;
  }

  bool _matches(
    Map<String, Object?> destination,
    Map<String, Object?> artifact,
  ) {
    String? platform = destination['platform'] as String?;
    String? minecraft = destination['minecraft'] as String?;
    return artifact['role'] == 'runtime' &&
        (platform == null ||
            projectStrings(artifact['platforms']).contains(platform)) &&
        (minecraft == null ||
            _compatible(
              minecraft,
              projectStrings(artifact['minecraftVersions']),
            ));
  }

  Future<Map<String, Object?>> _resolve(
    Map<String, Object?> configured, {
    required bool checkRuntime,
  }) async {
    Map<String, Object?> result = Map<String, Object?>.from(configured);
    String kind = result['kind'] as String;
    if (kind == 'directory') {
      String path = _safePath(result['path'] as String);
      FileSystemEntityType type = FileSystemEntity.typeSync(
        path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw FileSystemException('Expected a deployment directory', path);
      }
      result['path'] = path;
      return result;
    }
    if (kind != 'instance' && kind != 'dropins') {
      throw FormatException('Unknown destination kind: $kind');
    }
    String? platform = result['platform'] as String?;
    ConsumerProfile? consumer = ConsumerProfile.parse(
      result['consumer'] as String? ?? platform,
    );
    if (kind == 'instance' &&
        (platform == null || platform == 'velocity' || platform == 'bungee')) {
      consumer ??= ConsumerProfile.plugin;
    }
    if (consumer == null ||
        (kind == 'dropins' && !ConsumerProfile.names.contains(platform))) {
      throw const FormatException(
        'Dropins require a plugin, Fabric, Forge or NeoForge platform',
      );
    }
    ManagerContext context = ManagerContext(
      rootDir: store.workspace,
      verbose: false,
    );
    NativeCommandService commands = NativeCommandService(
      context: context,
      consumerService: ConsumerService(context),
    )..setConsumerOverride(consumer);
    try {
      if (kind == 'dropins') {
        String? minecraft = result['minecraft'] as String?;
        if (minecraft == null) {
          throw const FormatException(
            'Dropins require an exact Minecraft version',
          );
        }
        _version(minecraft);
        String directory = await _command(commands, <String>[
          consumer == ConsumerProfile.plugin ? 'plugins' : 'mods',
          'show-source',
        ]);
        result['path'] = _safePath(directory);
        result['consumer'] = consumer.shortName;
        return result;
      }
      String instance = result['instance'] as String;
      String directory = _safePath(
        await _command(commands, <String>['instance', 'path', instance]),
      );
      File source = File(p.join(directory, '.server-source'));
      _regularFileOrMissing(source.path);
      if (!source.existsSync()) {
        throw StateError('Instance has no server metadata: $instance');
      }
      Map<String, String> metadata = <String, String>{};
      for (String line in source.readAsLinesSync()) {
        int separator = line.indexOf('=');
        if (separator > 0) {
          metadata[line.substring(0, separator).trim()] = line
              .substring(separator + 1)
              .trim();
        }
      }
      String actualPlatform = switch (metadata['type']) {
        'paper' ||
        'purpur' ||
        'folia' ||
        'canvas' ||
        'leaf' ||
        'spigot' => 'plugin',
        'forge' || 'mohist' => 'forge',
        'fabric' => 'fabric',
        'neoforge' => 'neoforge',
        'velocity' => 'velocity',
        'bungee' => 'bungee',
        _ => throw StateError(
          'Instance has no supported server type: $instance',
        ),
      };
      if (platform != null && platform != actualPlatform) {
        throw StateError(
          'Instance $instance uses $actualPlatform, not $platform',
        );
      }
      String? actualMinecraft = metadata['mc'];
      if (actualPlatform != 'velocity' && actualPlatform != 'bungee') {
        if (actualMinecraft == null) {
          throw StateError('Instance has no Minecraft version: $instance');
        }
        _version(actualMinecraft);
      }
      String? requestedMinecraft = result['minecraft'] as String?;
      if (requestedMinecraft != null && requestedMinecraft != actualMinecraft) {
        throw StateError('Instance Minecraft version changed: $instance');
      }
      if (checkRuntime) {
        if (metadata['locked']?.toLowerCase() == 'true') {
          throw StateError('Instance is locked: $instance');
        }
        String states = await _command(commands, <String>['runtime', 'states']);
        List<List<String>> rows = states
            .split('\n')
            .map((String line) => line.split('\t'))
            .where((List<String> row) => row.first == instance)
            .toList();
        if (rows.length != 1 ||
            rows.first.length < 5 ||
            rows.first[1] != 'stopped' ||
            rows.first[4] == 'locked') {
          throw StateError('Instance must be stopped and unlocked: $instance');
        }
      }
      result['path'] = _safePath(
        p.join(
          directory,
          <String>{'plugin', 'velocity', 'bungee'}.contains(actualPlatform)
              ? 'plugins'
              : 'mods',
        ),
      );
      result['consumer'] = consumer.shortName;
      result['platform'] = actualPlatform;
      if (actualMinecraft != null) result['minecraft'] = actualMinecraft;
      return result;
    } finally {
      commands.disposeRcon();
    }
  }

  Future<Map<String, Object?>> _prepare(
    String runId,
    Map<String, Object?> destination,
    String? selectedTarget,
    Directory? stage, {
    required bool preview,
  }) async {
    File runFile = store.runFile(runId);
    _regularFileOrMissing(runFile.path);
    if (!runFile.existsSync()) {
      throw FormatException('Unknown build run: $runId');
    }
    Map<String, Object?> run = projectReadJson(runFile);
    String directory = destination['path'] as String;
    bool runtime = destination['kind'] != 'directory';
    File manifest = File(p.join(directory, _manifestName));
    _regularFileOrMissing(manifest.path);
    String? originalManifest = manifest.existsSync()
        ? manifest.readAsStringSync()
        : null;
    List<Map<String, Object?>> previous = _readManifest(manifest);
    List<Map<String, Object?>> selected = <Map<String, Object?>>[];
    List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
    Set<String> projects = <String>{};
    Set<String> filenames = <String>{};
    for (Object? rawJob in run['jobs'] as List<Object?>) {
      Map<String, Object?> job = projectObject(rawJob);
      if (selectedTarget != null && selectedTarget != job['key']) continue;
      if (job['status'] != 'succeeded') continue;
      for (Object? raw in job['artifacts'] as List<Object?>? ?? <Object?>[]) {
        Map<String, Object?> artifact = projectObject(raw);
        if (artifact['role'] != 'runtime') continue;
        if (!_matches(destination, artifact)) {
          skipped.add(<String, Object?>{
            'target': job['key'],
            'file': artifact['file'],
            'reason': 'incompatible',
          });
          continue;
        }
        String project = projectIdentifier(artifact['project']);
        projectIdentifier(artifact['target']);
        String source = _safePath(artifact['file'] as String);
        if (!p.isWithin(
          p.normalize(p.absolute(store.runWork(runId).path)),
          source,
        )) {
          throw FileSystemException('Artifact leaves its build run', source);
        }
        _regularFileOrMissing(source);
        File file = File(source);
        if (!file.existsSync() ||
            file.lengthSync() != artifact['size'] ||
            await projectFileHash(file) != _hash(artifact['sha256'])) {
          throw StateError('Build artifact changed: $source');
        }
        String filename = p.basename(source);
        if (destination['kind'] == 'dropins') {
          filename =
              previous
                      .where(
                        (Map<String, Object?> entry) =>
                            entry['project'] == project,
                      )
                      .firstOrNull?['file']
                  as String? ??
              '$project.jar';
        }
        filename = _filename(filename);
        if (!filenames.add(filename.toLowerCase())) {
          throw StateError('Deployment filename collision: $filename');
        }
        if (runtime && !projects.add(project)) {
          throw StateError(
            'Multiple compatible targets for $project; choose one project:target',
          );
        }
        selected.add(<String, Object?>{
          ...artifact,
          'file': filename,
          'source': source,
        });
      }
    }
    if (selected.isEmpty) {
      throw StateError('No successful compatible runtime artifacts selected');
    }
    Map<String, Map<String, Object?>> owned = <String, Map<String, Object?>>{
      for (Map<String, Object?> entry in previous)
        (entry['file'] as String).toLowerCase(): entry,
    };
    Set<String> replacing = selected
        .map((Map<String, Object?> entry) => _identity(entry, runtime))
        .toSet();
    List<Map<String, Object?>> retained = previous
        .where(
          (Map<String, Object?> entry) =>
              !replacing.contains(_identity(entry, runtime)),
        )
        .toList();
    List<Map<String, Object?>> affected = previous
        .where(
          (Map<String, Object?> entry) =>
              replacing.contains(_identity(entry, runtime)),
        )
        .toList();
    for (Map<String, Object?> entry in affected) {
      await _verifyOwned(directory, entry);
    }
    for (Map<String, Object?> artifact in selected) {
      String filename = artifact['file'] as String;
      String path = p.join(directory, filename);
      _regularFileOrMissing(path);
      Map<String, Object?>? prior = owned[filename.toLowerCase()];
      if (prior != null && !replacing.contains(_identity(prior, runtime))) {
        throw StateError(
          'Artifact belongs to another managed target: $filename',
        );
      }
      if (File(path).existsSync() && prior == null) {
        throw StateError(
          'Deployment would overwrite an unmanaged file: $filename',
        );
      }
    }
    List<Map<String, Object?>> actions = <Map<String, Object?>>[
      for (Map<String, Object?> entry in affected)
        if (!filenames.contains((entry['file'] as String).toLowerCase()) &&
            File(p.join(directory, entry['file'] as String)).existsSync())
          <String, Object?>{'action': 'remove', 'file': entry['file']},
      for (Map<String, Object?> entry in selected)
        <String, Object?>{
          'action':
              File(p.join(directory, entry['file'] as String)).existsSync()
              ? 'replace'
              : 'install',
          'file': entry['file'],
          'project': entry['project'],
          'target': entry['target'],
          'sha256': entry['sha256'],
        },
    ];
    if (!preview) {
      List<Map<String, Object?>> next = <Map<String, Object?>>[...retained];
      Map<File, String> prepared = <File, String>{};
      for (Map<String, Object?> artifact in selected) {
        File staged = File(p.join(stage!.path, 'new-${prepared.length}'));
        await File(artifact['source'] as String).copy(staged.path);
        if (await projectFileHash(staged) != artifact['sha256']) {
          throw StateError(
            'Build artifact changed while staging: ${artifact['source']}',
          );
        }
        prepared[staged] = p.join(directory, artifact['file'] as String);
        next.add(<String, Object?>{
          for (String key in <String>[
            'file',
            'sha256',
            'size',
            'project',
            'target',
          ])
            key: artifact[key],
          'runId': runId,
        });
      }
      File pending = File(p.join(stage!.path, 'manifest.json'));
      pending.writeAsStringSync(
        jsonEncode(<String, Object?>{'schema': 1, 'artifacts': next}),
        flush: true,
      );
      Map<String, Object?> currentDestination = await _resolve(
        destination,
        checkRuntime: true,
      );
      if (currentDestination['path'] != directory) {
        throw StateError('Destination changed while artifacts were staged');
      }
      for (Map<String, Object?> entry in affected) {
        await _verifyOwned(directory, entry);
      }
      _regularFileOrMissing(manifest.path);
      if ((manifest.existsSync() ? manifest.readAsStringSync() : null) !=
          originalManifest) {
        throw StateError(
          'Deployment ownership changed while artifacts were staged',
        );
      }
      for (String path in prepared.values) {
        _regularFileOrMissing(path);
        if (File(path).existsSync() &&
            !owned.containsKey(p.basename(path).toLowerCase())) {
          throw StateError(
            'Deployment would overwrite an unmanaged file: $path',
          );
        }
      }
      _commit(manifest, pending, prepared, affected, stage);
    }
    return <String, Object?>{
      'runId': runId,
      'destination': destination['name'],
      'preview': preview,
      'path': directory,
      'actions': actions,
      'skipped': skipped,
    };
  }

  List<Map<String, Object?>> _readManifest(File manifest) {
    if (!manifest.existsSync()) return <Map<String, Object?>>[];
    Map<String, Object?> saved = projectReadJson(manifest);
    if (saved['schema'] != 1 || saved['artifacts'] is! List<Object?>) {
      throw const FormatException('Invalid deployment ownership manifest');
    }
    Set<String> names = <String>{};
    List<Map<String, Object?>> entries = (saved['artifacts'] as List<Object?>)
        .map(projectObject)
        .toList();
    for (Map<String, Object?> entry in entries) {
      if (!names.add(_filename(entry['file'] as String).toLowerCase())) {
        throw const FormatException('Duplicate deployment ownership filename');
      }
      projectIdentifier(entry['project']);
      projectIdentifier(entry['target']);
      _hash(entry['sha256']);
    }
    return entries;
  }

  Future<void> _verifyOwned(
    String directory,
    Map<String, Object?> entry,
  ) async {
    String path = p.join(directory, entry['file'] as String);
    _regularFileOrMissing(path);
    File file = File(path);
    if (file.existsSync() && await projectFileHash(file) != entry['sha256']) {
      throw StateError('Managed artifact changed outside Multiplexor: $path');
    }
  }

  void _commit(
    File manifest,
    File pending,
    Map<File, String> prepared,
    List<Map<String, Object?>> affected,
    Directory stage,
  ) {
    Map<String, String> backups = <String, String>{};
    Set<String> installed = <String>{};
    try {
      Set<String> replacing = <String>{
        for (Map<String, Object?> entry in affected)
          p.join(manifest.parent.path, entry['file'] as String),
        ...prepared.values,
        manifest.path,
      };
      for (String path in replacing) {
        _regularFileOrMissing(path);
        if (File(path).existsSync()) {
          String backup = p.join(stage.path, 'backup-${backups.length}');
          _moveFile(File(path), backup);
          backups[path] = backup;
        }
      }
      for (MapEntry<File, String> artifact in prepared.entries) {
        _moveFile(artifact.key, artifact.value);
        installed.add(artifact.value);
      }
      _moveFile(pending, manifest.path);
      installed.add(manifest.path);
    } catch (error) {
      try {
        for (String path in installed) {
          File(path).deleteSync();
        }
        for (MapEntry<String, String> backup in backups.entries) {
          _moveFile(File(backup.value), backup.key);
        }
      } catch (recoveryError) {
        throw _DeploymentRecoveryFailure(
          'Deployment failed: $error. Recovery failed: $recoveryError. Backups: ${stage.path}',
        );
      }
      rethrow;
    }
  }

  static Future<String> _command(
    NativeCommandService commands,
    List<String> arguments,
  ) async {
    CapturedResult result = await commands.execute(arguments, stream: false);
    if (!result.success) throw StateError(result.stderr.trim());
    return result.stdout.trim();
  }

  static String _identity(Map<String, Object?> entry, bool runtime) => runtime
      ? entry['project'] as String
      : '${entry['project']}:${entry['target']}';

  static String _filename(String name) {
    if (name.isEmpty ||
        p.basename(name) != name ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        !name.toLowerCase().endsWith('.jar')) {
      throw FormatException('Invalid deployment jar filename: $name');
    }
    return name;
  }

  static String _hash(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid artifact SHA-256');
    }
    return value;
  }

  static String _safePath(String path) {
    if (path.trim().isEmpty || path.contains('\u0000')) {
      throw const FormatException('Deployment path must not be empty');
    }
    String absolute = p.normalize(p.absolute(path));
    String current = absolute;
    while (true) {
      FileSystemEntityType type = FileSystemEntity.typeSync(
        current,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        throw FileSystemException(
          'Deployment paths cannot contain symbolic links',
          current,
        );
      }
      if (current != absolute &&
          type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Deployment path parent is not a directory',
          current,
        );
      }
      String parent = p.dirname(current);
      if (parent == current) return absolute;
      current = parent;
    }
  }

  static void _regularFileOrMissing(String path) {
    _safePath(path);
    FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException('Expected a regular deployment file', path);
    }
  }

  static List<int> _version(String value) {
    if (!RegExp(r'^\d+(?:\.\d+)*$').hasMatch(value)) {
      throw FormatException('Expected an exact Minecraft version: $value');
    }
    return value.split('.').map(int.parse).toList();
  }

  static int _compareVersion(String left, String right) {
    List<int> a = _version(left);
    List<int> b = _version(right);
    int length = a.length > b.length ? a.length : b.length;
    for (int index = 0; index < length; index++) {
      int comparison = (index < a.length ? a[index] : 0).compareTo(
        index < b.length ? b[index] : 0,
      );
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static bool _compatible(String minecraft, List<String> supported) {
    _version(minecraft);
    if (supported.isEmpty) return true;
    for (String candidate in supported) {
      List<String> range = candidate.split('-');
      if (range.length == 1 && _compareVersion(minecraft, candidate) == 0) {
        return true;
      }
      if (range.length == 2 &&
          _compareVersion(minecraft, range.first) >= 0 &&
          _compareVersion(minecraft, range.last) <= 0) {
        return true;
      }
    }
    return false;
  }
}

class _DeploymentRecoveryFailure implements Exception {
  _DeploymentRecoveryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
