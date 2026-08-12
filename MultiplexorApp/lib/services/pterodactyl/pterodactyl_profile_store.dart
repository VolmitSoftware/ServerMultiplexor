import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'pterodactyl_profile.dart';

/// Stores only non-secret panel metadata.
final class PterodactylProfileStore {
  PterodactylProfileStore(String metadataDirectoryPath)
    : file = File(p.join(metadataDirectoryPath, 'pterodactyl-profiles.yaml'));

  PterodactylProfileStore.atFile(this.file);

  static const int schemaVersion = 1;
  static const Set<String> _rootKeys = <String>{'schema_version', 'profiles'};
  static const Set<String> _profileKeys = <String>{
    'id',
    'name',
    'panel_url',
    'trusted_certificate_path',
  };

  final File file;

  List<PterodactylProfile> loadAll() {
    if (!file.existsSync()) return <PterodactylProfile>[];
    final Object? root;
    try {
      root = loadYaml(file.readAsStringSync());
    } on YamlException {
      throw const FormatException('Invalid Pterodactyl profile YAML.');
    }
    if (root is! YamlMap) {
      throw const FormatException('Pterodactyl profiles must be a mapping.');
    }
    _checkKeys(root, _rootKeys);
    if (root['schema_version'] != schemaVersion ||
        root['profiles'] is! YamlList) {
      throw const FormatException('Unsupported Pterodactyl profile schema.');
    }

    final List<PterodactylProfile> result = <PterodactylProfile>[];
    final Set<String> ids = <String>{};
    for (final Object? raw in root['profiles'] as YamlList) {
      if (raw is! YamlMap) {
        throw const FormatException('A Pterodactyl profile is invalid.');
      }
      _checkKeys(raw, _profileKeys);
      final PterodactylProfile profile = PterodactylProfile(
        id: _string(raw, 'id'),
        name: _string(raw, 'name'),
        panelUri: Uri.parse(_string(raw, 'panel_url')),
        trustedCertificatePath: _optionalString(
          raw,
          'trusted_certificate_path',
        ),
      );
      if (!ids.add(profile.id)) {
        throw const FormatException('Duplicate Pterodactyl profile ID.');
      }
      result.add(profile);
    }
    result.sort(
      (PterodactylProfile a, PterodactylProfile b) => a.id.compareTo(b.id),
    );
    return List<PterodactylProfile>.unmodifiable(result);
  }

  PterodactylProfile? load(String id) {
    final String normalized = PterodactylProfile.normalizeId(id);
    for (final PterodactylProfile profile in loadAll()) {
      if (profile.id == normalized) return profile;
    }
    return null;
  }

  void save(PterodactylProfile profile) {
    final Map<String, PterodactylProfile> profiles =
        <String, PterodactylProfile>{
          for (final PterodactylProfile item in loadAll()) item.id: item,
          profile.id: profile,
        };
    _write(profiles.values);
  }

  bool remove(String id) {
    final String normalized = PterodactylProfile.normalizeId(id);
    final List<PterodactylProfile> profiles = loadAll().toList();
    final int before = profiles.length;
    profiles.removeWhere(
      (PterodactylProfile profile) => profile.id == normalized,
    );
    if (profiles.length == before) return false;
    _write(profiles);
    return true;
  }

  void _write(Iterable<PterodactylProfile> profiles) {
    final List<PterodactylProfile> ordered = profiles.toList()
      ..sort(
        (PterodactylProfile a, PterodactylProfile b) => a.id.compareTo(b.id),
      );
    file.parent.createSync(recursive: true);
    final File temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(_encode(ordered), flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  static void _checkKeys(YamlMap map, Set<String> allowed) {
    for (final Object? key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw const FormatException(
          'Pterodactyl profile data contains an unsupported field.',
        );
      }
    }
  }

  static String _string(YamlMap map, String key) {
    final Object? value = map[key];
    if (value is! String) {
      throw FormatException('Pterodactyl profile field $key is invalid.');
    }
    return value;
  }

  static String? _optionalString(YamlMap map, String key) {
    final Object? value = map[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Pterodactyl profile field $key is invalid.');
    }
    return value;
  }

  static String _encode(List<PterodactylProfile> profiles) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('schema_version: $schemaVersion');
    if (profiles.isEmpty) return '${buffer}profiles: []\n';
    buffer.writeln('profiles:');
    for (final PterodactylProfile profile in profiles) {
      buffer
        ..writeln('  - id: ${jsonEncode(profile.id)}')
        ..writeln('    name: ${jsonEncode(profile.name)}')
        ..writeln('    panel_url: ${jsonEncode(profile.origin)}');
      if (profile.trustedCertificatePath case final String path) {
        buffer.writeln('    trusted_certificate_path: ${jsonEncode(path)}');
      }
    }
    return buffer.toString();
  }
}
