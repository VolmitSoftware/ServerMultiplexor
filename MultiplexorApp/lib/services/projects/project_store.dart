import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_files.dart';
import 'project_model.dart';
import 'project_process.dart';
import '../../utils/async_work_pool.dart';
import '../../utils/delete_path.dart';

const Set<String> projectActiveStates = <String>{
  'queued',
  'preparing',
  'running',
};
const int projectRetainedRuns = 10;
const Set<String> _runRecords = <String>{
  'artifacts',
  'declarations',
  'input-snapshot',
  'logs',
  'snapshot',
  'worker.log',
};

class ProjectStore {
  static final Map<String, AsyncGate> _gates = <String, AsyncGate>{};
  ProjectStore(String workspace)
    : workspace = p.normalize(p.absolute(workspace)),
      directory = Directory(
        p.join(workspace, '.manager-state', 'project-builds'),
      ),
      workDirectory = Directory(projectWorkRoot(workspace));

  final String workspace;
  final Directory directory;
  final Directory workDirectory;
  int _discards = 0;
  File get catalogFile => File(p.join(directory.path, 'catalog.json'));
  File get limitsFile => File(p.join(directory.path, 'limits.json'));
  File get destinationsFile =>
      File(p.join(directory.path, 'destinations.json'));
  File runFile(String id) =>
      File(p.join(directory.path, 'runs', projectIdentifier(id), 'run.json'));
  Directory runWork(String id) =>
      Directory(p.join(workDirectory.path, 'runs', projectIdentifier(id)));
  File cancelFile(String id) => File(p.join(runFile(id).parent.path, 'cancel'));
  Directory get trashDirectory =>
      Directory(p.join(workDirectory.path, 'trash'));

  List<BuildProject> projects() {
    if (!catalogFile.existsSync()) return <BuildProject>[];
    Map<String, Object?> saved = projectReadJson(catalogFile);
    return (saved['projects'] as List<Object?>)
        .map((Object? item) => BuildProject.fromJson(projectObject(item)))
        .toList();
  }

  List<Map<String, Object?>> runs() {
    Directory root = Directory(p.join(directory.path, 'runs'));
    if (!root.existsSync()) return <Map<String, Object?>>[];
    List<Map<String, Object?>> result = <Map<String, Object?>>[];
    for (Directory entry in root.listSync().whereType<Directory>()) {
      File file = File(p.join(entry.path, 'run.json'));
      if (file.existsSync()) result.add(projectReadJson(file));
    }
    result.sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          (b['createdAt'] as String).compareTo(a['createdAt'] as String),
    );
    return result;
  }

  void retainRuns() {
    List<Map<String, Object?>> history = runs();
    String root = p.join(workDirectory.path, 'runs');
    Set<String> kept = <String>{};
    for (int index = 0; index < history.length; index++) {
      Map<String, Object?> run = history[index];
      bool active = projectActiveStates.contains(run['status']);
      if (index >= projectRetainedRuns && !active) continue;
      kept.add(run['id'] as String);
      if (run['retryOf'] case String retryOf when active) {
        kept.add(retryOf);
      }
      for (Object? job in run['jobs'] as List<Object?>? ?? <Object?>[]) {
        for (Object? artifact
            in projectObject(job)['artifacts'] as List<Object?>? ??
                <Object?>[]) {
          Object? file = projectObject(artifact)['file'];
          if (file is String && p.isWithin(root, file)) {
            kept.add(p.split(p.relative(file, from: root)).first);
          }
        }
      }
    }
    for (Map<String, Object?> run in history) {
      String id = run['id'] as String;
      if (!kept.contains(id)) {
        _discard(runWork(id));
        runFile(id).parent.deleteSync(recursive: true);
      } else if (!projectActiveStates.contains(run['status'])) {
        _discardLeftovers(runWork(id));
      }
    }
  }

  Future<void> emptyTrash() async {
    if (FileSystemEntity.typeSync(trashDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    for (FileSystemEntity entry in trashDirectory.listSync(
      followLinks: false,
    )) {
      await deletePath(entry.path);
    }
  }

  void _discardLeftovers(Directory work) {
    if (!work.existsSync()) return;
    for (FileSystemEntity entry in work.listSync(followLinks: false)) {
      String name = p.basename(entry.path);
      if (name == 'declarations' && entry is Directory) {
        for (FileSystemEntity item in entry.listSync(followLinks: false)) {
          if (!item.path.endsWith('.log')) _discard(item);
        }
      } else if (!_runRecords.contains(name)) {
        _discard(entry);
      }
    }
  }

  void _discard(FileSystemEntity entry) {
    if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    trashDirectory.createSync(recursive: true);
    if (FileSystemEntity.typeSync(trashDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Invalid project build trash',
        trashDirectory.path,
      );
    }
    entry.renameSync(
      p.join(
        trashDirectory.path,
        '$pid-${DateTime.now().microsecondsSinceEpoch}-${_discards++}',
      ),
    );
  }

  Future<T> locked<T>(Future<T> Function() action) =>
      _gates.putIfAbsent(workspace, AsyncGate.new).run(() => _locked(action));

  Future<T> _locked<T>(Future<T> Function() action) async {
    directory.createSync(recursive: true);
    RandomAccessFile lock = File(
      p.join(directory.path, 'operation.lock'),
    ).openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      return await action();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 35 || error.osError?.errorCode == 11) {
        throw const FileSystemException(
          'Another project operation owns the workspace',
        );
      }
      rethrow;
    } finally {
      lock.closeSync();
    }
  }

  Future<List<BuildProject>> scan(
    String path,
    void Function(String) report,
  ) async {
    Directory requested = Directory(path);
    if (!requested.existsSync()) {
      throw FileSystemException('Source directory does not exist', path);
    }
    String root = requested.resolveSymbolicLinksSync();
    if (File(p.join(root, 'gradle', 'multiplexor.gradle')).existsSync()) {
      root = p.dirname(root);
    }
    List<String> candidates = <String>[];
    void discover(Directory dir, int depth) {
      if (File(p.join(dir.path, 'gradle', 'multiplexor.gradle')).existsSync() &&
          File(p.join(dir.path, 'gradlew')).existsSync()) {
        candidates.add(p.split(p.relative(dir.path, from: root)).join('/'));
        return;
      }
      if (depth == 0) return;
      for (FileSystemEntity entry in dir.listSync(followLinks: false)) {
        if (entry is Directory && projectSourceEntry(p.basename(entry.path))) {
          discover(entry, depth - 1);
        }
      }
    }

    discover(Directory(root), 3);
    candidates.sort();
    if (candidates.isEmpty) {
      throw const FormatException(
        'No Gradle projects declare gradle/multiplexor.gradle',
      );
    }
    workDirectory.createSync(recursive: true);
    Directory scan = workDirectory.createTempSync('discovery-');
    List<BuildProject> discovered = <BuildProject>[];
    try {
      File init = File(p.join(scan.path, 'metadata.init.gradle'))
        ..writeAsStringSync(projectMetadataInit);
      Map<String, String> sourceHashes = <String, String>{};
      for (String candidate in candidates) {
        report('Capturing $candidate');
        sourceHashes[candidate] = await copyProjectSources(
          Directory(p.join(root, candidate)),
          Directory(p.join(scan.path, 'sources', candidate)),
          boundary: root,
        );
      }
      String sourceRoot = p.join(scan.path, 'sources');
      Map<String, String> copiedHashes = <String, String>{
        for (String source in candidates)
          Directory(p.join(sourceRoot, source)).resolveSymbolicLinksSync():
              sourceHashes[source]!,
      };
      for (String candidate in candidates) {
        report('Reading $candidate targets');
        discovered.add(
          await readProjectDeclaration(
            sources: sourceRoot,
            relativePath: candidate,
            sourceRoot: root,
            init: init,
            log: File(
              p.join(
                scan.path,
                '${projectDigest(candidate).substring(0, 12)}.log',
              ),
            ),
            sourceHashes: copiedHashes,
          ),
        );
      }
      List<BuildProject> combined = <BuildProject>[
        ...projects().where((BuildProject item) => item.sourceRoot != root),
        ...discovered,
      ];
      Map<String, BuildProject> byId = <String, BuildProject>{};
      for (BuildProject project in combined) {
        if (byId.containsKey(project.id)) {
          throw FormatException('Duplicate project: ${project.id}');
        }
        byId[project.id] = project;
      }
      ProjectPlan plan = ProjectPlan(byId, <String>[
        for (BuildProject project in combined)
          for (ProjectTarget target in project.targets)
            '${project.id}:${target.id}',
      ]);
      for (BuildProject project in discovered) {
        for (ProjectSourceInput input in plan.inputsFor(project.id)) {
          String resolved = File(input.key).resolveSymbolicLinksSync();
          String boundary = Directory(
            input.sourceRoot,
          ).resolveSymbolicLinksSync();
          if (!p.isWithin(boundary, resolved)) {
            throw FileSystemException(
              'Source input leaves the registered source root',
              input.key,
            );
          }
        }
      }
      projectAtomicJson(catalogFile, <String, Object?>{
        'schema': 1,
        'scannedAt': DateTime.now().toUtc().toIso8601String(),
        'projects': combined
            .map((BuildProject project) => project.toJson())
            .toList(),
      });
      await scan.delete(recursive: true);
      return discovered;
    } catch (_) {
      report('Discovery files retained at ${scan.path}');
      rethrow;
    }
  }

  Future<void> registerDeclarations(
    Map<String, String> previousHashes,
    List<BuildProject> declared,
  ) => locked(() async {
    if (!catalogFile.existsSync()) return;
    Map<String, BuildProject> byId = <String, BuildProject>{
      for (BuildProject project in declared) project.id: project,
    };
    projectAtomicJson(catalogFile, <String, Object?>{
      ...projectReadJson(catalogFile),
      'projects': <Object?>[
        for (BuildProject saved in projects())
          if (byId[saved.id] case BuildProject current
              when saved.definitionHash == previousHashes[saved.id] &&
                  saved.directory == current.directory)
            current.toJson()
          else
            saved.toJson(),
      ],
    });
  });
}

Future<BuildProject> readProjectDeclaration({
  required String sources,
  required String relativePath,
  required String sourceRoot,
  required File init,
  required File log,
  required Map<String, String> sourceHashes,
  bool Function()? cancelled,
}) async {
  String directory = p.join(sources, relativePath);
  String definitionHash = await projectDefinitionHash(Directory(directory));
  ProjectProcessResult result = await runProjectProcess(
    executable: p.join(
      directory,
      Platform.isWindows ? 'gradlew.bat' : 'gradlew',
    ),
    arguments: <String>[
      '--no-daemon',
      '--console=plain',
      '--max-workers=2',
      '--init-script',
      init.path,
      '-q',
      'multiplexorMetadata',
      ...localSourceArguments(sources),
    ],
    directory: directory,
    log: log,
    cancelled: cancelled,
    environment: <String, String>{
      'MULTIPLEXOR_SOURCE_HASHES': jsonEncode(sourceHashes),
    },
    timeout: const Duration(minutes: 15),
  );
  String? line = result.lines
      .where((String line) => line.startsWith('MULTIPLEXOR_PROJECT='))
      .lastOrNull;
  if (result.exitCode != 0 || line == null) {
    throw StateError(
      'Cannot read $relativePath targets (${result.exitCode}). ${result.lines.take(20).join('\n')}\nLogs: ${log.path}',
    );
  }
  Map<String, Object?> metadata = projectObject(
    jsonDecode(line.substring('MULTIPLEXOR_PROJECT='.length)),
  );
  metadata['sourceRoot'] = sourceRoot;
  metadata['relativePath'] = relativePath;
  metadata['definitionHash'] = definitionHash;
  return BuildProject.fromJson(metadata);
}

List<String> localSourceArguments(String sources) => <String>[
  for (MapEntry<String, String> entry in <String, String>{
    'VolmLib': 'VolmLib',
    'Iris': 'Iris',
    'HiddenOre': 'HiddenOre',
  }.entries)
    if (Directory(p.join(sources, entry.key)).existsSync()) ...<String>[
      '-PuseLocal${entry.value}=true',
      '-Plocal${entry.value}Directory=${p.join(sources, entry.key)}',
    ],
];
