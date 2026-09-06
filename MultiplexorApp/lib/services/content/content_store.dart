import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../utils/async_work_pool.dart';
import '../addons/addon_catalog.dart';
import '../addons/addon_resolver.dart';

/// Downloads stay outside the watched directory until the complete selection
/// and its lockfile are ready. A failed commit restores every replaced path.
final class ContentStore {
  ContentStore({
    required this.dropinsPath,
    required this.manifestPath,
    required this.consumer,
    required this.resolver,
    void Function(File, String)? moveFile,
  }) : _moveFile = moveFile ?? _renameFile;

  final String dropinsPath;
  final String manifestPath;
  final String consumer;
  final AddonResolver resolver;
  final void Function(File, String) _moveFile;
  static final Map<String, AsyncGate> _gates = <String, AsyncGate>{};

  String get kind => consumer == 'plugin' ? 'plugin' : 'mod';

  List<Map<String, Object?>> read() {
    _regularFileOrMissing(manifestPath);
    final File manifest = File(manifestPath);
    if (!manifest.existsSync()) return <Map<String, Object?>>[];
    final Object? value = loadYaml(manifest.readAsStringSync());
    if (value is! Map ||
        value['version'] != 1 ||
        value['consumer'] != consumer ||
        value['entries'] is! List) {
      throw const FormatException('Invalid content lockfile');
    }
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
    final Set<String> names = <String>{};
    final Set<String> files = <String>{};
    for (final Object? raw in value['entries'] as List) {
      if (raw is! Map) throw const FormatException('Invalid content entry');
      final Map<String, Object?> entry = Map<String, Object?>.from(raw);
      final String name = addonString(entry, 'name');
      final String file = addonString(entry, 'file');
      if (!names.add(name) || !files.add(file.toLowerCase())) {
        throw const FormatException('Duplicate content name or file');
      }
      _validateFileName(file);
      final String source = addonString(entry, 'source');
      if (source == 'modrinth') {
        addonString(entry, 'slug');
        addonString(entry, 'mc');
        _validateLoader(addonString(entry, 'loader'));
      } else if (source != 'url') {
        throw FormatException('Unknown content source: $source');
      }
      addonString(entry, 'url');
      entries.add(entry);
    }
    return entries;
  }

  Future<void> installUrl({
    required String url,
    required String name,
    required String fileName,
  }) => _mutate((List<Map<String, Object?>> entries, Directory stage) async {
    _validateUrl(url);
    _validateFileName(fileName);
    final _PreparedContent prepared = await _download(
      ResolvedAddon(location: url, version: 'direct'),
      <String, Object?>{
        'name': name,
        'source': 'url',
        'url': url,
        'file': fileName,
      },
      stage,
    );
    return _replace(entries, prepared);
  });

  Future<void> installModrinth({
    required String slug,
    required String name,
    required String minecraft,
    required String loader,
  }) => _mutate((List<Map<String, Object?>> entries, Directory stage) async {
    final _PreparedContent prepared = await _modrinth(
      slug: slug,
      name: name,
      minecraft: minecraft,
      loader: loader,
      stage: stage,
    );
    return _replace(entries, prepared);
  });

  Future<void> update(String? target) =>
      _mutate((List<Map<String, Object?>> entries, Directory stage) async {
        final List<Map<String, Object?>> next = <Map<String, Object?>>[];
        final List<_PreparedContent> downloads = <_PreparedContent>[];
        for (final Map<String, Object?> entry in entries) {
          if (target != null &&
              entry['name'] != target &&
              entry['slug'] != target) {
            next.add(entry);
            continue;
          }
          final _PreparedContent prepared;
          if (entry['source'] == 'modrinth') {
            prepared = await _modrinth(
              slug: addonString(entry, 'slug'),
              name: addonString(entry, 'name'),
              minecraft: addonString(entry, 'mc'),
              loader: addonString(entry, 'loader'),
              stage: stage,
            );
          } else {
            final String url = addonString(entry, 'url');
            _validateUrl(url);
            prepared = await _download(
              ResolvedAddon(location: url, version: 'direct'),
              Map<String, Object?>.from(entry),
              stage,
            );
          }
          next.add(prepared.entry);
          downloads.add(prepared);
        }
        if (target != null && downloads.isEmpty) {
          throw StateError('Content entry not found: $target');
        }
        return _ContentPlan(next, downloads);
      });

  Future<void> remove(String target) =>
      _mutate((List<Map<String, Object?>> entries, Directory stage) async {
        final List<Map<String, Object?>> next = entries
            .where(
              (Map<String, Object?> entry) =>
                  entry['name'] != target && entry['slug'] != target,
            )
            .toList();
        if (entries.length == next.length) {
          throw StateError('Content entry not found: $target');
        }
        return _ContentPlan(next, const <_PreparedContent>[]);
      });

  _ContentPlan _replace(
    List<Map<String, Object?>> entries,
    _PreparedContent prepared,
  ) {
    final Map<String, Object?> entry = prepared.entry;
    final String identity = entry['source'] == 'modrinth' ? 'slug' : 'url';
    return _ContentPlan(
      <Map<String, Object?>>[
        for (final Map<String, Object?> existing in entries)
          if (existing['name'] != entry['name'] &&
              !(existing['source'] == entry['source'] &&
                  existing[identity] == entry[identity]))
            existing,
        entry,
      ],
      <_PreparedContent>[prepared],
    );
  }

  Future<_PreparedContent> _modrinth({
    required String slug,
    required String name,
    required String minecraft,
    required String loader,
    required Directory stage,
  }) async {
    if (minecraft.trim().isEmpty) {
      throw const FormatException(
        'Use --mc <version> to select content compatibility',
      );
    }
    _validateLoader(loader);
    final Map<String, Object?> project = await resolver.modrinthProject(slug);
    if (project['project_type'] != kind) {
      throw StateError('$slug is not $kind content for $consumer');
    }
    final String projectId = addonString(project, 'id');
    final ResolvedAddon resolved = await resolver.resolveModrinth(
      project: projectId,
      kind: kind,
      serverType: loader,
      minecraft: minecraft,
    );
    final String? fileName = resolved.fileName;
    if (fileName == null) {
      throw StateError('Missing content filename for $slug');
    }
    _validateFileName(fileName);
    _validateUrl(resolved.location);
    return _download(resolved, <String, Object?>{
      'name': name,
      'source': 'modrinth',
      'slug': slug,
      'project_id': projectId,
      'title': addonString(project, 'title'),
      'mc': minecraft,
      'loader': loader,
      'version_id': resolved.versionId,
      'version_number': resolved.version,
      'file': fileName,
      'url': resolved.location,
      'upstream_sha512': resolved.hash,
    }, stage);
  }

  Future<_PreparedContent> _download(
    ResolvedAddon resolved,
    Map<String, Object?> entry,
    Directory stage,
  ) async {
    final Directory download = stage.createTempSync('download-');
    final File file = File(p.join(download.path, 'artifact.jar'));
    await resolver.download(resolved, file);
    entry['sha256'] = (await sha256.bind(file.openRead()).first).toString();
    entry['installed_at'] = DateTime.now().toUtc().toIso8601String();
    return _PreparedContent(entry, file);
  }

  Future<void> _mutate(
    Future<_ContentPlan> Function(List<Map<String, Object?>>, Directory)
    prepare,
  ) =>
      _gates.putIfAbsent(p.absolute(manifestPath), AsyncGate.new).run(() async {
        final Directory state = Directory(p.dirname(manifestPath));
        state.createSync(recursive: true);
        Directory(dropinsPath).createSync(recursive: true);
        _regularDirectory(state.path);
        _regularDirectory(dropinsPath);
        final String lockPath = '$manifestPath.lock';
        _regularFileOrMissing(lockPath);
        final RandomAccessFile lock = File(
          lockPath,
        ).openSync(mode: FileMode.append);
        Directory? stage;
        bool locked = false;
        bool preserveStage = false;
        try {
          await lock.lock(FileLock.blockingExclusive);
          locked = true;
          final List<Map<String, Object?>> previous = read();
          stage = state.createTempSync('.content-stage-');
          final _ContentPlan plan = await prepare(previous, stage);
          try {
            _commit(previous, plan, stage);
          } on _ContentRecoveryFailure {
            preserveStage = true;
            rethrow;
          }
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

  void _commit(
    List<Map<String, Object?>> previous,
    _ContentPlan plan,
    Directory stage,
  ) {
    final Set<String> names = <String>{};
    final Set<String> nextFiles = <String>{};
    for (final Map<String, Object?> entry in plan.entries) {
      final String file = addonString(entry, 'file');
      _validateFileName(file);
      if (!names.add(addonString(entry, 'name')) ||
          !nextFiles.add(file.toLowerCase())) {
        throw const FormatException(
          'Content entries must have distinct names and files',
        );
      }
    }
    final Set<String> replacing = <String>{
      for (final Map<String, Object?> entry in previous)
        if (!nextFiles.contains(addonString(entry, 'file').toLowerCase()))
          addonString(entry, 'file'),
      for (final _PreparedContent download in plan.downloads)
        addonString(download.entry, 'file'),
    };
    final Set<String> managed = previous
        .map(
          (Map<String, Object?> entry) =>
              addonString(entry, 'file').toLowerCase(),
        )
        .toSet();
    for (final String file in replacing) {
      final String path = p.join(dropinsPath, file);
      _regularFileOrMissing(path);
      if (File(path).existsSync() && !managed.contains(file.toLowerCase())) {
        throw StateError('Content would overwrite an unmanaged file: $path');
      }
    }
    _regularFileOrMissing(manifestPath);
    plan.entries.sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          addonString(a, 'name').compareTo(addonString(b, 'name')),
    );
    final File pending = File(p.join(stage.path, 'content-lock.yaml'));
    pending.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'version': 1, 'consumer': consumer, 'updated_at': DateTime.now().toUtc().toIso8601String(), 'entries': plan.entries})}\n',
      flush: true,
    );
    final Map<String, String> backups = <String, String>{};
    final Set<String> installed = <String>{};
    try {
      for (final String path in <String>[
        for (final String file in replacing) p.join(dropinsPath, file),
        manifestPath,
      ]) {
        if (File(path).existsSync()) {
          final String backup = p.join(stage.path, 'backup-${backups.length}');
          _moveFile(File(path), backup);
          backups[path] = backup;
        }
      }
      for (final _PreparedContent download in plan.downloads) {
        final String path = p.join(
          dropinsPath,
          addonString(download.entry, 'file'),
        );
        _moveFile(download.file, path);
        installed.add(path);
      }
      _moveFile(pending, manifestPath);
      installed.add(manifestPath);
    } catch (error) {
      try {
        for (final String path in installed) {
          File(path).deleteSync();
        }
        for (final MapEntry<String, String> backup in backups.entries) {
          _moveFile(File(backup.value), backup.key);
        }
      } catch (recoveryError) {
        throw _ContentRecoveryFailure(
          'Content commit failed: $error. Recovery failed: $recoveryError. Backups: ${stage.path}',
        );
      }
      rethrow;
    }
  }

  void _validateLoader(String loader) {
    final Set<String> allowed = consumer == 'plugin'
        ? const <String>{
            'paper',
            'purpur',
            'leaf',
            'spigot',
            'bukkit',
            'folia',
            'canvas',
          }
        : <String>{consumer};
    if (!allowed.contains(loader)) {
      throw FormatException(
        'Loader $loader is incompatible with $consumer content',
      );
    }
  }
}

void _renameFile(File source, String target) => source.renameSync(target);

void _validateFileName(String file) {
  if (!isAddonJarFileName(file)) {
    throw FormatException('Invalid content filename: $file');
  }
}

void _validateUrl(String value) {
  final Uri uri = Uri.parse(value);
  if (!const <String>{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw FormatException('Invalid content URL: $value');
  }
}

void _regularFileOrMissing(String path) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw FileSystemException('Content path must be a regular file', path);
  }
}

void _regularDirectory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw FileSystemException('Content path must be a regular directory', path);
  }
}

final class _PreparedContent {
  const _PreparedContent(this.entry, this.file);
  final Map<String, Object?> entry;
  final File file;
}

final class _ContentPlan {
  const _ContentPlan(this.entries, this.downloads);
  final List<Map<String, Object?>> entries;
  final List<_PreparedContent> downloads;
}

final class _ContentRecoveryFailure implements Exception {
  const _ContentRecoveryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
