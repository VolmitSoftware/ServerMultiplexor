import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'project_model.dart';

const Set<String> projectExcludedDirectories = <String>{
  '.git',
  '.gradle',
  '.codegraph',
  '.idea',
  '.worktrees',
  '.build-work',
  '.buildlogs',
  '.dart_tool',
  '.manager-state',
  '.multiplexor',
  'build',
  'node_modules',
  '__pycache__',
  'target',
  '.qa',
  '.local-notes',
};

bool projectSourceEntry(String name) =>
    !projectExcludedDirectories.contains(name) &&
    !<String>{'.DS_Store', 'AGENTS.md', 'CLAUDE.md'}.contains(name) &&
    !name.startsWith('.env') &&
    !name.endsWith('.hprof') &&
    !name.endsWith('.log');

Future<String> projectFileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

String projectDigest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

void projectAtomicJson(File file, Object? value) {
  file.parent.createSync(recursive: true);
  File temporary = File('${file.path}.$pid.tmp');
  temporary.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    flush: true,
  );
  temporary.renameSync(file.path);
}

Map<String, Object?> projectReadJson(File file) =>
    projectObject(jsonDecode(file.readAsStringSync()));

Future<String> copyProjectSources(
  Directory source,
  Directory destination, {
  String? boundary,
}) async {
  String allowed = Directory(
    boundary ?? source.path,
  ).resolveSymbolicLinksSync();
  Set<String> ignored = await _ignoredSourcePaths(source);
  Map<String, String> hashes = <String, String>{};
  List<String> executableFiles = <String>[];
  Future<void> visit(
    String origin,
    String relative,
    Set<String> ancestors,
  ) async {
    if (ignored.contains(p.normalize(p.absolute(origin)))) return;
    FileSystemEntityType type = FileSystemEntity.typeSync(
      origin,
      followLinks: false,
    );
    String resolved = type == FileSystemEntityType.link
        ? Link(origin).resolveSymbolicLinksSync()
        : origin;
    if (resolved != allowed && !p.isWithin(allowed, resolved)) {
      throw FileSystemException(
        'Source link leaves the registered source root',
        origin,
      );
    }
    FileStat before = FileStat.statSync(resolved);
    if (before.type == FileSystemEntityType.directory) {
      if (ancestors.contains(resolved)) {
        throw FileSystemException('Cyclic source directory', origin);
      }
      Directory(p.join(destination.path, relative)).createSync(recursive: true);
      List<FileSystemEntity> entries =
          Directory(resolved).listSync(followLinks: false)..sort(
            (FileSystemEntity a, FileSystemEntity b) =>
                a.path.compareTo(b.path),
          );
      for (FileSystemEntity entry in entries) {
        if (projectSourceEntry(p.basename(entry.path))) {
          await visit(
            entry.path,
            p.join(relative, p.basename(entry.path)),
            <String>{...ancestors, resolved},
          );
        }
      }
      return;
    }
    if (before.type != FileSystemEntityType.file) {
      throw FileSystemException('Unsupported source entry', origin);
    }
    File output = File(p.join(destination.path, relative));
    output.parent.createSync(recursive: true);
    await File(resolved).copy(output.path);
    String hash = await projectFileHash(output);
    FileStat after = FileStat.statSync(resolved);
    if (after.size != before.size ||
        after.modified != before.modified ||
        hash != await projectFileHash(File(resolved))) {
      throw FileSystemException(
        'Source changed during capture; retry the build',
        origin,
      );
    }
    hashes[relative] = '${before.mode & 0x49 == 0 ? 0 : 1}:$hash';
    if (!Platform.isWindows && before.mode & 0x49 != 0) {
      executableFiles.add(output.path);
    }
  }

  await visit(source.resolveSymbolicLinksSync(), '.', <String>{});
  for (int index = 0; index < executableFiles.length; index += 100) {
    ProcessResult result = await Process.run('chmod', <String>[
      '755',
      ...executableFiles.skip(index).take(100),
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not preserve executable source files',
        source.path,
      );
    }
  }
  return projectDigest(hashes);
}

Future<Set<String>> _ignoredSourcePaths(Directory source) async {
  Directory current = source.absolute;
  while (FileSystemEntity.typeSync(p.join(current.path, '.git')) ==
      FileSystemEntityType.notFound) {
    if (current.parent.path == current.path) return <String>{};
    current = current.parent;
  }
  ProcessResult result = await Process.run(
    'git',
    <String>[
      'ls-files',
      '--others',
      '--ignored',
      '--exclude-standard',
      '--directory',
      '-z',
    ],
    workingDirectory: source.path,
    environment: <String, String>{...Platform.environment}
      ..remove('GIT_CONFIG_COUNT'),
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not read ignored source paths: ${result.stderr}',
      source.path,
    );
  }
  return <String>{
    for (String relative in (result.stdout as String).split('\u0000'))
      if (relative.isNotEmpty)
        p.normalize(p.absolute(p.join(source.path, relative))),
  };
}

Future<String> projectDefinitionHash(Directory directory) async {
  Map<String, String> hashes = <String, String>{};
  Future<void> visit(Directory current) async {
    List<FileSystemEntity> entries = current.listSync(followLinks: false)
      ..sort(
        (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
      );
    for (FileSystemEntity entry in entries) {
      if (!projectSourceEntry(p.basename(entry.path))) continue;
      if (entry is Directory) {
        await visit(entry);
      } else if (entry is File &&
          (entry.path.endsWith('.gradle') ||
              entry.path.endsWith('.gradle.kts') ||
              entry.path.endsWith('.properties') ||
              entry.path.endsWith('.json') ||
              p
                  .split(p.relative(entry.path, from: directory.path))
                  .contains('buildSrc'))) {
        hashes[p.relative(entry.path, from: directory.path)] =
            await projectFileHash(entry);
      }
    }
  }

  await visit(directory);
  return projectDigest(hashes);
}

String projectWorkRoot(String workspace) {
  String? override = Platform.environment['MULTIPLEXOR_BUILD_HOME'];
  String home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return p.join(
    override ?? p.join(home, '.multiplexor', 'project-builds'),
    projectDigest(p.normalize(p.absolute(workspace))).substring(0, 16),
  );
}

const String projectMetadataInit = r'''
import groovy.json.JsonOutput
gradle.projectsEvaluated {
    rootProject.tasks.register('multiplexorMetadata') {
        doLast {
            if (!rootProject.ext.has('multiplexor')) {
                throw new GradleException('Project does not declare multiplexor build metadata')
            }
            println('MULTIPLEXOR_PROJECT=' + JsonOutput.toJson(rootProject.ext.multiplexor))
        }
    }
}
''';

const String projectBudgetInit = r'''
import org.gradle.api.tasks.testing.Test
gradle.projectsEvaluated {
    allprojects {
        tasks.withType(Test).configureEach {
            maxParallelForks = Math.min(maxParallelForks, Math.max(1, Integer.parseInt(System.getenv('MULTIPLEXOR_TEST_FORKS') ?: '1')))
        }
    }
}
''';
