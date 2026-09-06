import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pterodactyl_transfer_files.dart';

/// Common file versions for one Local instance and immutable Remote identity.
/// Missing snapshots use the existing two-way transfer workflow.
final class PterodactylTransferBaselineStore {
  const PterodactylTransferBaselineStore({required this.metadataDirectoryPath});

  final String metadataDirectoryPath;

  PterodactylTransferFileManifest? read({
    required String localConsumer,
    required String localInstancePath,
    required String profileId,
    required String serverUuid,
  }) {
    final Map<String, String> identity = _identity(
      localConsumer,
      localInstancePath,
      profileId,
      serverUuid,
    );
    final Directory? directory = _directory(create: false);
    if (directory == null) return null;
    final File file = File(p.join(directory.path, _filename(identity)));
    if (_fileType(file.path) == FileSystemEntityType.notFound) return null;
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?> ||
        decoded['schema_version'] != 1 ||
        decoded['identity'] is! Map<String, Object?> ||
        decoded['files'] is! List<Object?> ||
        decoded['directories'] is! List<Object?>) {
      throw const FormatException('Invalid transfer baseline');
    }
    final Map<String, Object?> storedIdentity =
        decoded['identity']! as Map<String, Object?>;
    if (identity.entries.any(
      (MapEntry<String, String> entry) =>
          storedIdentity[entry.key] != entry.value,
    )) {
      throw const FormatException('Transfer baseline identity does not match');
    }
    final Map<String, PterodactylTransferFileEntry> files =
        <String, PterodactylTransferFileEntry>{};
    final Set<String> directories = <String>{};
    for (final Object? raw in decoded['directories']! as List<Object?>) {
      final String path = _path(raw);
      if (!directories.add(path)) {
        throw const FormatException('Duplicate baseline directory');
      }
    }
    for (final Object? raw in decoded['files']! as List<Object?>) {
      if (raw is! Map<String, Object?>) {
        throw const FormatException('Invalid baseline file');
      }
      final String path = _path(raw['path']);
      final Object? size = raw['size'];
      final Object? hash = raw['sha256'];
      if (size is! int ||
          size < 0 ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          files.containsKey(path) ||
          directories.contains(path)) {
        throw const FormatException('Invalid baseline file');
      }
      files[path] = PterodactylTransferFileEntry(
        path: path,
        sourcePath: '',
        size: size,
        sha256: hash,
      );
    }
    for (final String path in <String>[...files.keys, ...directories]) {
      String ancestor = p.posix.dirname(path);
      while (ancestor != '.') {
        if (!directories.contains(ancestor) || files.containsKey(ancestor)) {
          throw const FormatException('Invalid baseline directory tree');
        }
        ancestor = p.posix.dirname(ancestor);
      }
    }
    return PterodactylTransferFileManifest(
      rootPath: identity['local_path']!,
      files: files,
      directories: directories,
      excludedContentDirectories: const <String>{},
    );
  }

  void write({
    required String localConsumer,
    required String localInstancePath,
    required String profileId,
    required String serverUuid,
    required PterodactylTransferFileManifest manifest,
  }) {
    final Map<String, String> identity = _identity(
      localConsumer,
      localInstancePath,
      profileId,
      serverUuid,
    );
    final Directory directory = _directory(create: true)!;
    final File destination = File(p.join(directory.path, _filename(identity)));
    _fileType(destination.path);
    final Directory stage = directory.createTempSync('.baseline-');
    final File previous = File(p.join(stage.path, 'previous.json'));
    bool movedPrevious = false;
    bool preserveStage = false;
    try {
      final File pending = File(p.join(stage.path, 'next.json'));
      final List<String> filePaths = manifest.files.keys.toList()..sort();
      final List<String> directories = manifest.transferableDirectories.toList()
        ..sort();
      pending.writeAsStringSync(
        '${jsonEncode(<String, Object?>{
          'schema_version': 1,
          'identity': identity,
          'files': <Map<String, Object?>>[
            for (final String path in filePaths) <String, Object?>{'path': _path(path), 'size': manifest.files[path]!.size, 'sha256': manifest.files[path]!.sha256},
          ],
          'directories': directories.map(_path).toList(),
        })}\n',
        flush: true,
      );
      if (_fileType(destination.path) == FileSystemEntityType.file) {
        destination.renameSync(previous.path);
        movedPrevious = true;
      }
      try {
        pending.renameSync(destination.path);
      } catch (error) {
        if (movedPrevious) {
          try {
            previous.renameSync(destination.path);
          } catch (recoveryError) {
            preserveStage = true;
            throw StateError(
              'Baseline write failed: $error. Recovery failed: $recoveryError. Previous baseline: ${previous.path}',
            );
          }
        }
        rethrow;
      }
    } finally {
      if (!preserveStage) {
        try {
          stage.deleteSync(recursive: true);
        } on FileSystemException {
          // The installed baseline is authoritative; leftover staging files
          // must not turn a committed write into an apparent failure.
        }
      }
    }
  }

  Directory? _directory({required bool create}) {
    final Directory metadata = Directory(
      p.normalize(p.absolute(metadataDirectoryPath)),
    );
    for (final Directory directory in <Directory>[
      metadata,
      Directory(p.join(metadata.path, 'pterodactyl-transfer-baselines')),
    ]) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        directory.createSync(recursive: true);
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('Transfer baseline folder must be a real directory');
      }
    }
    return Directory(p.join(metadata.path, 'pterodactyl-transfer-baselines'));
  }

  Map<String, String> _identity(
    String consumer,
    String localPath,
    String profile,
    String uuid,
  ) {
    if (consumer.isEmpty || profile.isEmpty || uuid.isEmpty) {
      throw const FormatException('Invalid transfer baseline identity');
    }
    final Directory local = Directory(p.normalize(p.absolute(localPath)));
    if (FileSystemEntity.typeSync(local.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Local baseline instance must be a real directory');
    }
    return <String, String>{
      'consumer': consumer,
      'local_path': local.resolveSymbolicLinksSync(),
      'profile_id': profile,
      'server_uuid': uuid,
    };
  }

  String _filename(Map<String, String> identity) =>
      '${sha256.convert(utf8.encode(jsonEncode(identity)))}.json';

  FileSystemEntityType _fileType(String path) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw StateError('Transfer baseline must be a real file');
    }
    return type;
  }

  String _path(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        p.posix.isAbsolute(value) ||
        p.windows.isAbsolute(value) ||
        value.contains('\\') ||
        value.contains('\u0000') ||
        value
            .split('/')
            .any(
              (String part) => part.isEmpty || part == '.' || part == '..',
            )) {
      throw const FormatException('Invalid transfer baseline path');
    }
    return value;
  }
}
