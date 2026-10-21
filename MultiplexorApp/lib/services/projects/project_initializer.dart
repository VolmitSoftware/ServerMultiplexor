import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_files.dart';
import 'project_model.dart';

class ProjectInitializer {
  Map<String, Object?> initialize(
    String path, {
    String? id,
    String? name,
    int? java,
    bool apply = false,
  }) {
    Directory requested = Directory(path);
    if (!requested.existsSync()) {
      throw FileSystemException('Source directory does not exist', path);
    }
    String root = requested.resolveSymbolicLinksSync();
    List<File> builds = <File>[
      File(p.join(root, 'build.gradle')),
      File(p.join(root, 'build.gradle.kts')),
    ].where((File file) => file.existsSync()).toList();
    if (builds.length != 1) {
      throw const FormatException(
        'Choose a Gradle root with exactly one build.gradle or build.gradle.kts',
      );
    }
    if (!<String>[
          'gradlew',
          'gradlew.bat',
        ].any((String file) => File(p.join(root, file)).existsSync()) ||
        !File(
          p.join(root, 'gradle', 'wrapper', 'gradle-wrapper.properties'),
        ).existsSync()) {
      throw const FormatException('The project needs a Gradle wrapper');
    }
    File build = builds.single;
    File definition = File(p.join(root, 'gradle', 'multiplexor.gradle'));
    if (FileSystemEntity.typeSync(definition.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException(
        'gradle/multiplexor.gradle already exists; edit it or scan this project',
      );
    }
    if (FileSystemEntity.isLinkSync(build.path) ||
        FileSystemEntity.isLinkSync(definition.parent.path)) {
      throw const FormatException(
        'The build file and gradle directory must be inside the project',
      );
    }
    String original = build.readAsStringSync();
    if (original.contains('multiplexor.gradle') ||
        RegExp(r'\bext\.multiplexor\b').hasMatch(original)) {
      throw const FormatException(
        'The build already declares Multiplexor metadata',
      );
    }
    String projectId = projectIdentifier(id ?? _identifier(p.basename(root)));
    String projectName = name ?? p.basename(root);
    if (projectName.trim().isEmpty ||
        projectName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('The project name must be non-empty text');
    }
    if (java != null && java < 1) {
      throw const FormatException('Java must be a positive major version');
    }
    List<Map<String, Object?>> targets = _targets(root, java);
    if (targets.isEmpty) {
      throw const FormatException(
        'No Java, plugin, or mod source modules found; declare custom targets in gradle/multiplexor.gradle',
      );
    }
    String hook = build.path.endsWith('.kts')
        ? 'apply(from = "gradle/multiplexor.gradle")'
        : "apply from: 'gradle/multiplexor.gradle'";
    String metadata = _metadata(projectId, projectName, targets);
    Map<String, Object?> result = <String, Object?>{
      'path': root,
      'id': projectId,
      'name': projectName,
      'applied': apply,
      'files': <Map<String, Object?>>[
        <String, Object?>{
          'path': 'gradle/multiplexor.gradle',
          'action': 'create',
          'content': metadata,
        },
        <String, Object?>{
          'path': p.basename(build.path),
          'action': 'append',
          'content': '$hook\n',
        },
      ],
      'targets': targets,
      'warnings': <String>[
        'Scan verifies candidate module membership; source folders outside this Gradle build are omitted.',
        'Gradle resolves archive tasks, artifact paths, and Java requirements during scan.',
        if (targets.any(
          (Map<String, Object?> target) =>
              target['platform'] != null &&
              (target['minecraftVersions'] as List<String>).isEmpty,
        ))
          'Some targets have unknown Minecraft compatibility; review their minecraftVersions before delivery.',
        'Review custom packaging, build-task delivery actions, and local composite dependencies before building.',
      ],
    };
    if (apply) _apply(build, definition, original, hook, metadata);
    return result;
  }

  List<Map<String, Object?>> _targets(String root, int? java) {
    List<Map<String, Object?>> targets = <Map<String, Object?>>[];
    void visit(Directory directory) {
      String relative = p.posix.joinAll(
        p.split(p.relative(directory.path, from: root)),
      );
      List<String> descriptors = <String>[];
      for (MapEntry<String, String> descriptor in _descriptors.entries) {
        if (File(p.join(directory.path, descriptor.key)).existsSync()) {
          descriptors.add(descriptor.value);
        }
      }
      Set<String> platforms = descriptors.toSet();
      if (platforms.length > 1) {
        throw FormatException(
          '$relative has multiple runtime platforms; declare its targets explicitly in gradle/multiplexor.gradle',
        );
      }
      bool sources = <String>['java', 'kotlin', 'scala', 'groovy'].any(
        (String language) => Directory(
          p.join(directory.path, 'src', 'main', language),
        ).existsSync(),
      );
      if (platforms.isNotEmpty || sources) {
        String? platform = platforms.firstOrNull;
        String targetId = relative == '.'
            ? platform == 'plugin'
                  ? 'bukkit'
                  : platform ?? 'library'
            : _identifier(relative.replaceAll('/', '-'));
        targets.add(<String, Object?>{
          'id': targetId,
          'projectDirectory': relative,
          'platform': platform,
          'java': java,
          'minecraftVersions': _minecraftVersions(directory, platform),
          'artifact': 'resolved by Gradle',
        });
      }
      List<Directory> children =
          directory
              .listSync(followLinks: false)
              .whereType<Directory>()
              .where(
                (Directory child) =>
                    projectSourceEntry(p.basename(child.path)) &&
                    !<String>{
                      'src',
                      'gradle',
                      'buildSrc',
                      'build-logic',
                    }.contains(p.basename(child.path)) &&
                    !File(p.join(child.path, 'gradlew')).existsSync() &&
                    !File(p.join(child.path, 'gradlew.bat')).existsSync(),
              )
              .toList()
            ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
      for (Directory child in children) {
        visit(child);
      }
    }

    visit(Directory(root));
    Set<String> ids = <String>{};
    for (Map<String, Object?> target in targets) {
      if (!ids.add(target['id'] as String)) {
        throw const FormatException(
          'Module names produce duplicate target IDs; declare targets explicitly',
        );
      }
    }
    return targets;
  }

  List<String> _minecraftVersions(Directory directory, String? platform) {
    if (platform != 'fabric') return <String>[];
    File descriptor = File(
      p.join(directory.path, 'src/main/resources/fabric.mod.json'),
    );
    Map<String, Object?> json = projectObject(
      jsonDecode(descriptor.readAsStringSync()),
    );
    Object? depends = json['depends'];
    Object? minecraft = depends is Map<String, Object?>
        ? depends['minecraft']
        : null;
    List<Object?> values = minecraft is List<Object?>
        ? minecraft
        : <Object?>[minecraft];
    if (values.any(
      (Object? value) =>
          value is! String || !RegExp(r'^\d+(?:\.\d+)+$').hasMatch(value),
    )) {
      return <String>[];
    }
    return values.cast<String>();
  }

  void _apply(
    File build,
    File definition,
    String original,
    String hook,
    String metadata,
  ) {
    if (build.readAsStringSync() != original) {
      throw const FileSystemException(
        'The build file changed during initialization',
      );
    }
    definition.parent.createSync(recursive: true);
    definition.createSync(exclusive: true);
    Directory? staging;
    try {
      staging = build.parent.createTempSync('.multiplexor-init-');
      File temporary = File(p.join(staging.path, p.basename(build.path)));
      definition.writeAsStringSync(metadata, flush: true);
      build.copySync(temporary.path);
      temporary.writeAsStringSync(
        '$original${original.endsWith('\n') ? '' : '\n'}\n$hook\n',
        flush: true,
      );
      if (build.readAsStringSync() != original) {
        throw const FileSystemException(
          'The build file changed during initialization',
        );
      }
      temporary.renameSync(build.path);
    } catch (_) {
      definition.deleteSync();
      rethrow;
    } finally {
      staging?.deleteSync(recursive: true);
    }
  }

  String _metadata(String id, String name, List<Map<String, Object?>> targets) {
    String declaration = _groovy(
      jsonEncode(<String, Object?>{'id': id, 'name': name, 'targets': targets}),
    );
    return 'import groovy.json.JsonSlurper\n'
        'import org.gradle.api.plugins.JavaPluginExtension\n'
        'import org.gradle.api.tasks.bundling.AbstractArchiveTask\n\n'
        'Map declaration = (Map) new JsonSlurper().parseText($declaration)\n'
        r'''
gradle.projectsEvaluated {
    Map<File, Project> modules = rootProject.allprojects.collectEntries { Project module ->
        [(module.projectDir.canonicalFile): module]
    }
    List<Map> targets = declaration.targets.findResults { Map target ->
        File directory = rootProject.file(target.projectDirectory).canonicalFile
        Project module = modules[directory]
        if (module == null) {
            return null
        }
        List<String> candidates = target.platform == 'fabric' ? ['remapJar'] : ['shadowJar', 'jar']
        if (target.platform == 'forge' && module.tasks.findByName('reobfJar') != null && module.tasks.findByName('reobfShadowJar') == null) {
            candidates = ['jar']
        }
        AbstractArchiveTask archive = candidates.collect { String name -> module.tasks.findByName(name) }
                .find { Task task -> task instanceof AbstractArchiveTask && task.enabled } as AbstractArchiveTask
        if (archive == null) {
            throw new GradleException("No supported archive task for ${module.path}; configure this target's tasks and artifacts explicitly")
        }
        JavaPluginExtension java = module.extensions.findByType(JavaPluginExtension)
        Integer requiredJava = target.java == null
                ? java?.toolchain?.languageVersion?.orNull?.asInt() ?: (java == null ? null : Integer.valueOf(java.sourceCompatibility.majorVersion))
                : ((Number) target.java).intValue()
        if (requiredJava == null) {
            throw new GradleException("Cannot resolve Java requirement for ${module.path}; set this target's java value")
        }
        List<String> tasks = []
        Task check = module.tasks.findByName('check')
        if (check != null && check.enabled) tasks.add(check.path)
        tasks.add(archive.path)
        String reobfuscationTask = 'reobf' + archive.name.capitalize()
        Task reobfuscate = module.tasks.findByName(reobfuscationTask)
        if (target.platform == 'forge' && reobfuscate != null && reobfuscate.enabled) tasks.add(reobfuscate.path)
        File output = archive.archiveFile.get().asFile
        String artifact = rootProject.relativePath(output).replace(File.separatorChar, '/' as char)
        if (artifact.startsWith('../') || output.canonicalFile.toPath().startsWith(rootProject.projectDir.canonicalFile.toPath()) == false) {
            throw new GradleException("Archive for ${module.path} is outside the project")
        }
        return [
            id: target.id, tasks: tasks, arguments: [], java: requiredJava,
            memoryMiB: 4096, workers: 2, dependsOn: [],
            artifacts: [[path: artifact, role: target.platform == null ? 'library' : 'runtime',
                platforms: target.platform == null ? [] : [target.platform], minecraftVersions: target.minecraftVersions]]
        ]
    }
    if (targets.isEmpty()) {
        throw new GradleException('No detected source modules belong to this Gradle build; include the modules in settings.gradle or configure targets explicitly')
    }
    rootProject.ext.multiplexor = [
        schema: 1, id: declaration.id, name: declaration.name,
        sandbox: 'per-target', parallelTargets: true,
        sourceDependencies: [], sourceInputs: [], targets: targets
    ]
}
''';
  }

  String _identifier(String name) {
    String result = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^[^a-z0-9]+'), '');
    if (result.isEmpty) {
      throw const FormatException('Specify a project ID with --id');
    }
    return result;
  }

  String _groovy(String value) =>
      "'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";

  static const Map<String, String> _descriptors = <String, String>{
    'src/main/resources/plugin.yml': 'plugin',
    'src/main/resources/paper-plugin.yml': 'plugin',
    'src/main/resources/fabric.mod.json': 'fabric',
    'src/main/resources/META-INF/mods.toml': 'forge',
    'src/main/resources/META-INF/neoforge.mods.toml': 'neoforge',
    'src/main/resources/bungee.yml': 'bungee',
    'src/main/resources/velocity-plugin.json': 'velocity',
  };
}
