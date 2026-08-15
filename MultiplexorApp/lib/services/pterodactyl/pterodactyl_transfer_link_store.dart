import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'pterodactyl_transfer_models.dart';

/// Durable, non-secret Remote identity attached to a local instance.
final class PterodactylTransferLinkStore {
  const PterodactylTransferLinkStore();

  static const String fileName = '.multiplexor-remote.json';

  PterodactylRemoteLink? load(String localInstancePath) {
    final Directory directory = _realInstanceDirectory(localInstancePath);
    final File file = File(p.join(directory.path, fileName));
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw StateError('Remote link metadata must be a real file.');
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Remote link must be a JSON object.');
    }
    if (decoded['schema_version'] != 1) {
      throw const FormatException('Unsupported Remote link schema.');
    }
    return PterodactylRemoteLink(
      profileId: _requiredString(decoded, 'profile_id'),
      serverIdentifier: _requiredString(decoded, 'server_identifier'),
      serverUuid: _requiredString(decoded, 'server_uuid'),
      serverName: _requiredString(decoded, 'server_name'),
      localInstanceName: _requiredString(decoded, 'local_instance_name'),
      localConsumer: _requiredString(decoded, 'local_consumer'),
      linkedAt: _requiredDate(decoded, 'linked_at'),
      lastTransferredAt: _requiredDate(decoded, 'last_transferred_at'),
    );
  }

  void save(String localInstancePath, PterodactylRemoteLink link) {
    final Directory directory = _realInstanceDirectory(localInstancePath);
    final File file = File(p.join(directory.path, fileName));
    final FileSystemEntityType destinationType = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.notFound &&
        destinationType != FileSystemEntityType.file) {
      throw StateError('Remote link metadata must be a real file.');
    }
    final File temporary = _createUniqueAdjacentFile(file.path, 'tmp');
    final String encoded = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'schema_version': 1,
        'profile_id': link.profileId,
        'server_identifier': link.serverIdentifier,
        'server_uuid': link.serverUuid,
        'server_name': link.serverName,
        'local_instance_name': link.localInstanceName,
        'local_consumer': link.localConsumer,
        'linked_at': link.linkedAt.toUtc().toIso8601String(),
        'last_transferred_at': link.lastTransferredAt.toUtc().toIso8601String(),
      },
    );
    final RandomAccessFile output = temporary.openSync(
      mode: FileMode.writeOnly,
    );
    try {
      output.writeStringSync('$encoded\n');
      output.flushSync();
    } finally {
      output.closeSync();
    }
    _replaceAtomically(temporary, file);
  }

  Directory _realInstanceDirectory(String path) {
    final String normalized = p.normalize(p.absolute(path));
    final String parent = p.dirname(normalized);
    if (FileSystemEntity.typeSync(parent, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Local instance parent must be a real directory.');
    }
    if (FileSystemEntity.typeSync(normalized, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Local instance folder must be a real directory.');
    }
    return Directory(Directory(normalized).resolveSymbolicLinksSync());
  }

  String _uniqueAdjacentPath(String destination, String role) {
    final Random random = Random.secure();
    for (int attempt = 0; attempt < 64; attempt++) {
      final String suffix = List<int>.generate(
        16,
        (_) => random.nextInt(256),
      ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final String candidate = '$destination.$role.$suffix';
      if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw StateError('Could not allocate safe Remote link metadata storage.');
  }

  File _createUniqueAdjacentFile(String destination, String role) {
    for (int attempt = 0; attempt < 64; attempt++) {
      final File file = File(_uniqueAdjacentPath(destination, role));
      try {
        file.createSync(exclusive: true);
        return file;
      } on FileSystemException {
        if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    throw StateError('Could not create safe Remote link metadata storage.');
  }

  String _requiredString(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Remote link field "$key" is invalid.');
    }
    return value;
  }

  DateTime _requiredDate(Map<String, Object?> json, String key) {
    final String value = _requiredString(json, key);
    final DateTime? parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('Remote link field "$key" is not a timestamp.');
    }
    return parsed.toUtc();
  }

  void _replaceAtomically(File temporary, File destination) {
    final File previous = File(
      _uniqueAdjacentPath(destination.path, 'previous'),
    );
    bool movedPrevious = false;
    bool installedNew = false;
    try {
      final FileSystemEntityType destinationType = FileSystemEntity.typeSync(
        destination.path,
        followLinks: false,
      );
      if (destinationType == FileSystemEntityType.file) {
        destination.renameSync(previous.path);
        movedPrevious = true;
      } else if (destinationType != FileSystemEntityType.notFound) {
        throw StateError('Remote link metadata must be a real file.');
      }
      temporary.renameSync(destination.path);
      installedNew = true;
      if (movedPrevious) previous.deleteSync();
    } catch (_) {
      if (installedNew &&
          FileSystemEntity.typeSync(destination.path, followLinks: false) ==
              FileSystemEntityType.file) {
        destination.deleteSync();
      }
      if (movedPrevious &&
          FileSystemEntity.typeSync(previous.path, followLinks: false) ==
              FileSystemEntityType.file &&
          FileSystemEntity.typeSync(destination.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        previous.renameSync(destination.path);
      }
      rethrow;
    } finally {
      if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        temporary.deleteSync();
      }
    }
  }
}
