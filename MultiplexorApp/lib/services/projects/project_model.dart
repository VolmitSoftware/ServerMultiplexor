import 'package:path/path.dart' as p;

Map<String, Object?> projectObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected a project object');
  }
  return value;
}

List<String> projectStrings(Object? value) {
  if (value == null) return <String>[];
  if (value is! List<Object?> || value.any((Object? item) => item is! String)) {
    throw const FormatException('Expected a list of strings');
  }
  return value.cast<String>();
}

String projectIdentifier(Object? value) {
  if (value is! String || !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value)) {
    throw FormatException('Invalid project or target identifier: $value');
  }
  return value;
}

String projectRelativePath(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      p.isAbsolute(value) ||
      p.windows.isAbsolute(value) ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value.split('/').contains('..')) {
    throw FormatException('Expected a relative project path: $value');
  }
  return value;
}

int projectPositive(Object? value, int fallback) {
  if (value == null) return fallback;
  if (value is! int || value < 1) {
    throw FormatException('Expected a positive integer: $value');
  }
  return value;
}

class ProjectArtifact {
  ProjectArtifact.fromJson(Map<String, Object?> json)
    : path = projectRelativePath(json['path']),
      role = json['role'] as String? ?? 'runtime',
      platforms = projectStrings(json['platforms']),
      minecraftVersions = projectStrings(json['minecraftVersions']) {
    if (!<String>{'runtime', 'api', 'library'}.contains(role)) {
      throw FormatException('Unknown artifact role: $role');
    }
    if (platforms.any(
      (String platform) => !<String>{
        'plugin',
        'fabric',
        'forge',
        'neoforge',
        'velocity',
        'bungee',
      }.contains(platform),
    )) {
      throw const FormatException('Unknown artifact platform');
    }
  }

  final String path;
  final String role;
  final List<String> platforms;
  final List<String> minecraftVersions;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'role': role,
    'platforms': platforms,
    'minecraftVersions': minecraftVersions,
  };
}

class ProjectTarget {
  ProjectTarget.fromJson(Map<String, Object?> json)
    : id = projectIdentifier(json['id']),
      tasks = projectStrings(json['tasks']),
      arguments = projectStrings(json['arguments']),
      java = projectPositive(json['java'], 25),
      memoryMiB = projectPositive(json['memoryMiB'], 4096),
      workers = projectPositive(json['workers'], 2),
      dependsOn = projectStrings(json['dependsOn']),
      artifactProperties =
          (json['artifactProperties'] == null
                  ? <String, Object?>{}
                  : projectObject(json['artifactProperties']))
              .map(
                (String key, Object? value) => MapEntry(key, value as String),
              ),
      artifacts = (json['artifacts'] as List<Object?>? ?? <Object?>[])
          .map(
            (Object? value) => ProjectArtifact.fromJson(projectObject(value)),
          )
          .toList() {
    if (tasks.isEmpty || tasks.any((String task) => task.startsWith('-'))) {
      throw FormatException('Target $id needs explicit Gradle tasks');
    }
    for (String key in artifactProperties.keys) {
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_.-]*$').hasMatch(key)) {
        throw FormatException('Invalid Gradle property: $key');
      }
    }
  }

  final String id;
  final List<String> tasks;
  final List<String> arguments;
  final int java;
  final int memoryMiB;
  final int workers;
  final List<String> dependsOn;
  final Map<String, String> artifactProperties;
  final List<ProjectArtifact> artifacts;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'tasks': tasks,
    'arguments': arguments,
    'java': java,
    'memoryMiB': memoryMiB,
    'workers': workers,
    'dependsOn': dependsOn,
    'artifactProperties': artifactProperties,
    'artifacts': artifacts
        .map((ProjectArtifact item) => item.toJson())
        .toList(),
  };
}

class BuildProject {
  BuildProject.fromJson(Map<String, Object?> json)
    : id = projectIdentifier(json['id']),
      name = json['name'] as String,
      sandbox = json['sandbox'] as String,
      parallelTargets = json['parallelTargets'] as bool? ?? false,
      sourceDependencies = projectStrings(json['sourceDependencies']),
      sourceInputs = projectStrings(json['sourceInputs']).map((String value) {
        String path = p.posix.normalize(projectRelativePath(value));
        if (path == '.') {
          throw const FormatException(
            'Source inputs must name a file or directory below the source root',
          );
        }
        return path;
      }).toList(),
      sourceRoot = json['sourceRoot'] as String,
      definitionHash = json['definitionHash'] as String? ?? '',
      relativePath = projectRelativePath(json['relativePath']),
      targets = (json['targets'] as List<Object?>)
          .map((Object? item) => ProjectTarget.fromJson(projectObject(item)))
          .toList() {
    if (json['schema'] != 1 ||
        !<String>{'per-target', 'project'}.contains(sandbox)) {
      throw const FormatException('Invalid project schema or sandbox policy');
    }
    if (sourceInputs.toSet().length != sourceInputs.length) {
      throw FormatException('Project $id requires unique source inputs');
    }
    if (targets.isEmpty ||
        targets.map((ProjectTarget t) => t.id).toSet().length !=
            targets.length) {
      throw FormatException('Project $id requires unique targets');
    }
  }

  final String id;
  final String name;
  final String sandbox;
  final bool parallelTargets;
  final List<String> sourceDependencies;
  final List<String> sourceInputs;
  final String sourceRoot;
  final String definitionHash;
  final String relativePath;
  final List<ProjectTarget> targets;
  String get directory => p.join(sourceRoot, relativePath);
  ProjectTarget target(String id) => targets.firstWhere(
    (ProjectTarget target) => target.id == id,
    orElse: () => throw FormatException('Unknown target: ${this.id}:$id'),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'sandbox': sandbox,
    'parallelTargets': parallelTargets,
    'sourceDependencies': sourceDependencies,
    'sourceInputs': sourceInputs,
    'sourceRoot': sourceRoot,
    'relativePath': relativePath,
    'definitionHash': definitionHash,
    'targets': targets.map((ProjectTarget target) => target.toJson()).toList(),
  };
}

class ProjectPlan {
  ProjectPlan(this.projects, Iterable<String> requested) {
    for (String key in requested) {
      _visit(key, <String>{});
    }
    for (String key in keys) {
      List<String> sources = sourcesFor(key.split(':').first);
      inputsFor(key.split(':').first);
      for (int left = 0; left < sources.length; left++) {
        String first = p.normalize(projects[sources[left]]!.relativePath);
        for (int right = left + 1; right < sources.length; right++) {
          String second = p.normalize(projects[sources[right]]!.relativePath);
          if (p.equals(first, second) ||
              p.isWithin(first, second) ||
              p.isWithin(second, first)) {
            throw FormatException(
              'Source paths overlap: ${sources[left]} and ${sources[right]}',
            );
          }
        }
      }
    }
  }

  final Map<String, BuildProject> projects;
  final List<String> keys = <String>[];

  BuildProject projectFor(String key) =>
      projects[key.split(':').first] ??
      (throw FormatException('Unknown project: $key'));

  ProjectTarget targetFor(String key) {
    List<String> parts = key.split(':');
    if (parts.length != 2) {
      throw FormatException('Expected project:target: $key');
    }
    return projectFor(key).target(parts.last);
  }

  List<String> sourcesFor(String id, [Set<String>? visiting]) {
    Set<String> seen = visiting ?? <String>{};
    if (!seen.add(id)) return <String>[];
    BuildProject project =
        projects[id] ??
        (throw FormatException('Missing local source dependency: $id'));
    return <String>[
      id,
      for (String dependency in project.sourceDependencies)
        ...sourcesFor(dependency, seen),
    ];
  }

  List<ProjectSourceInput> inputsFor(String id) {
    List<BuildProject> sources = sourcesFor(
      id,
    ).map((String key) => projects[key]!).toList();
    Map<String, ProjectSourceInput> inputs = <String, ProjectSourceInput>{};
    for (BuildProject source in sources) {
      for (String path in source.sourceInputs) {
        ProjectSourceInput input = ProjectSourceInput(source.sourceRoot, path);
        for (BuildProject project in sources) {
          if (_overlaps(path, project.relativePath)) {
            throw FormatException(
              'Source input $path overlaps project ${project.id}',
            );
          }
        }
        for (ProjectSourceInput previous in inputs.values) {
          if (path == previous.relativePath && input.key == previous.key) {
            continue;
          }
          if (_overlaps(path, previous.relativePath)) {
            throw FormatException(
              'Source inputs overlap: $path and ${previous.relativePath}',
            );
          }
        }
        inputs[path] = input;
      }
    }
    return inputs.values.toList();
  }

  static bool _overlaps(String first, String second) =>
      p.equals(first, second) ||
      p.isWithin(first, second) ||
      p.isWithin(second, first);

  void _visit(String key, Set<String> visiting) {
    if (keys.contains(key)) return;
    if (!visiting.add(key)) {
      throw FormatException('Build dependency cycle at $key');
    }
    ProjectTarget target = targetFor(key);
    for (String dependency in <String>{
      ...target.dependsOn,
      ...target.artifactProperties.values,
    }) {
      _visit(dependency, visiting);
    }
    visiting.remove(key);
    keys.add(key);
  }
}

class ProjectSourceInput {
  const ProjectSourceInput(this.sourceRoot, this.relativePath);

  final String sourceRoot;
  final String relativePath;
  String get key => p.normalize(p.absolute(p.join(sourceRoot, relativePath)));
}
