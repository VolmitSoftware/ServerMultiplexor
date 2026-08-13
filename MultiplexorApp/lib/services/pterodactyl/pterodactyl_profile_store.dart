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

  static const int schemaVersion = 2;
  static const int _legacySchemaVersion = 1;
  static const Set<String> _rootKeys = <String>{
    'schema_version',
    'active_profile',
    'profiles',
  };
  static const Set<String> _profileKeys = <String>{
    'id',
    'name',
    'panel_url',
    'trusted_certificate_path',
  };

  final File file;

  List<PterodactylProfile> loadAll() => _loadDocument().profiles;

  /// The account selected for commands that omit `--profile`.
  ///
  /// Schema v1 did not persist a selection. Its first sorted profile becomes
  /// active deterministically so existing installations gain the account
  /// workflow without a migration prompt.
  String? loadActiveId() => _loadDocument().activeId;

  void setActive(String id) {
    final String normalized = PterodactylProfile.normalizeId(id);
    final _ProfileDocument document = _loadDocument();
    if (!document.profiles.any(
      (PterodactylProfile profile) => profile.id == normalized,
    )) {
      throw StateError('Unknown Pterodactyl profile: $normalized');
    }
    _write(document.profiles, activeId: normalized);
  }

  _ProfileDocument _loadDocument() {
    if (!file.existsSync()) {
      return const _ProfileDocument(
        profiles: <PterodactylProfile>[],
        activeId: null,
      );
    }
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
    final Object? rawSchema = root['schema_version'];
    if ((rawSchema != schemaVersion && rawSchema != _legacySchemaVersion) ||
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
    final List<PterodactylProfile> profiles =
        List<PterodactylProfile>.unmodifiable(result);
    final String? requestedActive = rawSchema == schemaVersion
        ? _optionalString(root, 'active_profile')
        : null;
    final String? activeId;
    if (requestedActive == null) {
      activeId = profiles.isEmpty ? null : profiles.first.id;
    } else {
      final String normalized = PterodactylProfile.normalizeId(requestedActive);
      if (!profiles.any(
        (PterodactylProfile profile) => profile.id == normalized,
      )) {
        throw const FormatException(
          'The active Pterodactyl profile does not exist.',
        );
      }
      activeId = normalized;
    }
    return _ProfileDocument(profiles: profiles, activeId: activeId);
  }

  PterodactylProfile? load(String id) {
    final String normalized = PterodactylProfile.normalizeId(id);
    for (final PterodactylProfile profile in loadAll()) {
      if (profile.id == normalized) return profile;
    }
    return null;
  }

  void save(PterodactylProfile profile) {
    final _ProfileDocument document = _loadDocument();
    final Map<String, PterodactylProfile> profiles =
        <String, PterodactylProfile>{
          for (final PterodactylProfile item in document.profiles)
            item.id: item,
          profile.id: profile,
        };
    _write(profiles.values, activeId: document.activeId ?? profile.id);
  }

  bool remove(String id) {
    final String normalized = PterodactylProfile.normalizeId(id);
    final _ProfileDocument document = _loadDocument();
    final List<PterodactylProfile> profiles = document.profiles.toList();
    final int before = profiles.length;
    profiles.removeWhere(
      (PterodactylProfile profile) => profile.id == normalized,
    );
    if (profiles.length == before) return false;
    final String? activeId = document.activeId == normalized
        ? (profiles.isEmpty ? null : profiles.first.id)
        : document.activeId;
    _write(profiles, activeId: activeId);
    return true;
  }

  void _write(
    Iterable<PterodactylProfile> profiles, {
    required String? activeId,
  }) {
    final List<PterodactylProfile> ordered = profiles.toList()
      ..sort(
        (PterodactylProfile a, PterodactylProfile b) => a.id.compareTo(b.id),
      );
    file.parent.createSync(recursive: true);
    final File temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(
        _encode(ordered, activeId: activeId),
        flush: true,
      );
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

  static String _encode(
    List<PterodactylProfile> profiles, {
    required String? activeId,
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('schema_version: $schemaVersion');
    if (activeId != null) {
      buffer.writeln('active_profile: ${jsonEncode(activeId)}');
    }
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

final class _ProfileDocument {
  const _ProfileDocument({required this.profiles, required this.activeId});

  final List<PterodactylProfile> profiles;
  final String? activeId;
}
