import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'builtin_addons.dart';

final class AddonDefinition {
  AddonDefinition(Map<String, Object?> json)
    : id = addonString(json, 'id'),
      name = addonString(json, 'name'),
      description = json['description'] as String? ?? '',
      kind = addonString(json, 'kind'),
      fileName = json.containsKey('fileName')
          ? addonString(json, 'fileName')
          : '${addonString(json, 'id')}.jar',
      serverTypes = addonStrings(json, 'serverTypes'),
      dependencies = addonStrings(json, 'dependencies', optional: true),
      filePrefixes = addonStrings(json, 'filePrefixes', optional: true),
      sources = json['sources'] is List<Object?>
          ? (json['sources']! as List<Object?>)
                .map((Object? value) => AddonSource(addonObject(value)))
                .toList()
          : <AddonSource>[AddonSource(addonObject(json['source']))] {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id) ||
        !const <String>{'plugin', 'mod'}.contains(kind) ||
        !isAddonJarFileName(fileName) ||
        serverTypes.isEmpty ||
        sources.isEmpty) {
      throw FormatException('Invalid addon definition: $id');
    }
  }

  final String id;
  final String name;
  final String description;
  final String kind;
  final String fileName;
  final List<String> serverTypes;
  final List<String> dependencies;
  final List<String> filePrefixes;
  final List<AddonSource> sources;

  String get directory => kind == 'plugin' ? 'plugins' : 'mods';
  String get file => '$directory/$fileName';

  String displayName(String serverType, String minecraft) {
    final List<AddonSource> candidates = sources
        .where((AddonSource source) => source.supports(serverType, minecraft))
        .toList();
    final int development = candidates.indexWhere(
      (AddonSource source) => source.json['label'] == 'development',
    );
    return development < 0
        ? name
        : '$name (development${development == 0 ? '' : ' fallback'})';
  }

  bool requiresMinecraftVersion(String serverType) {
    if (!serverTypes.contains(serverType)) return false;
    final List<AddonSource> platformSources = sources
        .where((AddonSource source) => source.supportsServer(serverType))
        .toList();
    return platformSources.isNotEmpty &&
        platformSources.every(
          (AddonSource source) =>
              source.type == 'modrinth' ||
              addonStrings(
                source.json,
                'minecraftVersions',
                optional: true,
              ).isNotEmpty,
        );
  }

  String? unavailableReason(String serverType, {String? minecraft}) {
    if (!serverTypes.contains(serverType)) {
      return 'Requires ${serverTypes.join(', ')}; this server uses $serverType.';
    }
    if (minecraft != null) {
      if (minecraft.isEmpty && requiresMinecraftVersion(serverType)) {
        return 'Minecraft version is unknown. Supply --mc <version>.';
      }
      final List<AddonSource> candidates = sources
          .where((AddonSource source) => source.supports(serverType, minecraft))
          .toList();
      if (candidates.isEmpty) {
        return 'No verified source for $serverType Minecraft $minecraft.';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'description': description,
    'kind': kind,
    'fileName': fileName,
    'serverTypes': serverTypes,
    'dependencies': dependencies,
  };
}

final class AddonSource {
  AddonSource(this.json) : type = addonString(json, 'type') {
    switch (type) {
      case 'modrinth':
        addonString(json, 'project');
      case 'github':
        if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(addonString(json, 'repo'))) {
          throw const FormatException('Invalid GitHub addon repository');
        }
        addonString(json, 'asset');
      case 'url':
        addonString(json, 'url');
      case 'jenkins':
        addonString(json, 'url');
        RegExp(addonString(json, 'artifactPattern'));
      case 'file':
        addonString(json, 'path');
      default:
        throw FormatException('Unknown addon source: $type');
    }
    addonStrings(json, 'serverTypes', optional: true);
    addonStrings(json, 'minecraftVersions', optional: true);
  }

  final Map<String, Object?> json;
  final String type;

  bool supportsServer(String serverType) {
    final List<String> types = addonStrings(
      json,
      'serverTypes',
      optional: true,
    );
    return types.isEmpty || types.contains(serverType);
  }

  bool supports(String serverType, String minecraft) {
    final List<String> versions = addonStrings(
      json,
      'minecraftVersions',
      optional: true,
    );
    return supportsServer(serverType) &&
        (versions.isEmpty || versions.contains(minecraft));
  }
}

final class AddonCatalog {
  AddonCatalog(Iterable<AddonDefinition> definitions) {
    final Set<String> files = <String>{};
    for (final AddonDefinition definition in definitions) {
      if (entries.containsKey(definition.id)) {
        throw FormatException('Duplicate addon ID: ${definition.id}');
      }
      if (!files.add(definition.file.toLowerCase())) {
        throw FormatException('Duplicate addon filename: ${definition.file}');
      }
      entries[definition.id] = definition;
    }
    // Validate every dependency, including entries not currently selected.
    expand(entries.keys.toSet());
  }

  factory AddonCatalog.load(String workspace) {
    final List<AddonDefinition> definitions = builtinAddons
        .map(AddonDefinition.new)
        .toList();
    final File registry = File(
      p.join(workspace, '.multiplexor', 'addons.json'),
    );
    if (registry.existsSync()) {
      final Map<String, Object?> json = addonObject(
        jsonDecode(registry.readAsStringSync()),
      );
      final Object? raw = json['addons'];
      if (raw is! List<Object?>) {
        throw const FormatException('addons must be an array');
      }
      definitions.addAll(
        raw.map((Object? value) => AddonDefinition(addonObject(value))),
      );
    }
    return AddonCatalog(definitions);
  }

  final Map<String, AddonDefinition> entries = <String, AddonDefinition>{};

  Set<String> expand(Set<String> selected) {
    final Set<String> result = <String>{};
    final Set<String> visiting = <String>{};
    void visit(String id) {
      if (result.contains(id)) return;
      final AddonDefinition? definition = entries[id];
      if (definition == null) throw FormatException('Unknown addon: $id');
      if (!visiting.add(id)) {
        throw FormatException('Cyclic addon dependency: $id');
      }
      for (final String dependency in definition.dependencies) {
        visit(dependency);
      }
      visiting.remove(id);
      result.add(id);
    }

    for (final String id in selected) {
      visit(id);
    }
    return result;
  }
}

bool isAddonJarFileName(String value) => RegExp(
  r'^[a-z0-9][a-z0-9._ +()-]*\.jar$',
  caseSensitive: false,
).hasMatch(value);

/// Match the declared jar or a version/platform variant, not another plugin
/// whose name happens to begin with the same letters (e.g. WorldEditCUI).
bool matchesAddonJar(String path, String file, List<String> prefixes) {
  if (path.toLowerCase() == file.toLowerCase()) return true;
  if (p.posix.dirname(path) != p.posix.dirname(file)) return false;
  final String name = p.posix.basename(path).toLowerCase();
  if (!name.endsWith('.jar')) return false;
  final String stem = name.substring(0, name.length - 4);
  for (final String value in prefixes) {
    final String prefix = value.toLowerCase();
    if (prefix.endsWith('.jar')) {
      if (name == prefix) return true;
      continue;
    }
    final String base = prefix.replaceFirst(RegExp(r'[-_. ]+$'), '');
    if (base.isEmpty) continue;
    if (stem == base ||
        stem.startsWith(base) &&
            stem.length > base.length &&
            '-_. '.contains(stem[base.length])) {
      return true;
    }
  }
  return false;
}

Map<String, Object?> addonObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected addon object');
  }
  return value;
}

String addonString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing or invalid addon field: $key');
  }
  return value;
}

List<String> addonStrings(
  Map<String, Object?> json,
  String key, {
  bool optional = false,
}) {
  final Object? value = json[key];
  if (optional && value == null) return const <String>[];
  if (value is! List<Object?> ||
      value.any((Object? item) => item is! String || item.isEmpty)) {
    throw FormatException('Invalid addon list: $key');
  }
  return value.cast<String>();
}
