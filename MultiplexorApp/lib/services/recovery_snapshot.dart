import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Recovery trees contain regular files and directories only. External links
/// are captured by value so cache pruning and shared-data edits cannot alter a
/// saved recovery point.
class RecoverySnapshot {
  static const int version = 2;

  static void copy(
    Directory source,
    Directory destination, {
    bool includeLogs = true,
  }) {
    void visit(String from, String to, Set<String> ancestors) {
      final String resolved =
          FileSystemEntity.typeSync(from) == FileSystemEntityType.directory
          ? Directory(from).resolveSymbolicLinksSync()
          : File(from).resolveSymbolicLinksSync();
      final FileSystemEntityType type = FileSystemEntity.typeSync(resolved);
      if (type == FileSystemEntityType.directory) {
        if (ancestors.contains(resolved)) {
          throw FileSystemException(
            'Recovery snapshot contains a link cycle',
            from,
          );
        }
        Directory(to).createSync(recursive: true);
        final Set<String> next = <String>{...ancestors, resolved};
        for (final FileSystemEntity entry in Directory(
          resolved,
        ).listSync(followLinks: false)) {
          if (!includeLogs && p.basename(entry.path) == 'logs') continue;
          visit(entry.path, p.join(to, p.basename(entry.path)), next);
        }
      } else if (type == FileSystemEntityType.file) {
        File(resolved).copySync(to);
      } else {
        throw FileSystemException(
          'Recovery snapshot requires a readable regular file or directory',
          from,
        );
      }
    }

    visit(source.path, destination.path, <String>{});
  }

  static List<Map<String, Object>> entries(Directory root) {
    final List<Map<String, Object>> result = <Map<String, Object>>[];
    for (final FileSystemEntity entry in root.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final String relative = p.relative(entry.path, from: root.path);
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        entry.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.file) {
        final File file = File(entry.path);
        result.add(<String, Object>{
          'path': relative,
          'type': 'file',
          'size': file.lengthSync(),
          'sha256': sha256.convert(file.readAsBytesSync()).toString(),
        });
      } else if (type == FileSystemEntityType.directory) {
        result.add(<String, Object>{'path': relative, 'type': 'directory'});
      } else {
        throw FileSystemException(
          'Recovery snapshot contains a non-regular entry',
          entry.path,
        );
      }
    }
    result.sort(
      (Map<String, Object> a, Map<String, Object> b) =>
          (a['path']! as String).compareTo(b['path']! as String),
    );
    return result;
  }

  static void verify(Directory root, Object? expected) {
    if (!root.existsSync() || expected is! List) {
      throw const FormatException('Invalid recovery snapshot manifest');
    }
    final List<Map<String, Object>> normalized = <Map<String, Object>>[];
    final Set<String> paths = <String>{};
    for (final Object? item in expected) {
      if (item is! Map || item['path'] is! String) {
        throw const FormatException('Invalid recovery snapshot entry');
      }
      final String path = item['path'] as String;
      if (path.isEmpty ||
          p.isAbsolute(path) ||
          p.normalize(path) != path ||
          path == '..' ||
          p.split(path).contains('..') ||
          !paths.add(path)) {
        throw const FormatException('Invalid recovery snapshot path');
      }
      if (item['type'] == 'directory') {
        normalized.add(<String, Object>{'path': path, 'type': 'directory'});
      } else if (item['type'] == 'file' &&
          item['size'] is int &&
          item['sha256'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(item['sha256'] as String)) {
        normalized.add(<String, Object>{
          'path': path,
          'type': 'file',
          'size': item['size'] as int,
          'sha256': item['sha256'] as String,
        });
      } else {
        throw const FormatException('Invalid recovery snapshot entry');
      }
    }
    normalized.sort(
      (Map<String, Object> a, Map<String, Object> b) =>
          (a['path']! as String).compareTo(b['path']! as String),
    );
    if (jsonEncode(entries(root)) != jsonEncode(normalized)) {
      throw const FormatException('Recovery snapshot integrity mismatch');
    }
  }

  /// Both directories must be on the same filesystem. The old tree remains
  /// available until installation and post-install bookkeeping succeed.
  static void replace(
    Directory prepared,
    Directory target, {
    void Function()? afterInstall,
  }) {
    final Directory previous = Directory('${prepared.path}.previous');
    final bool existed = target.existsSync();
    if (existed) target.renameSync(previous.path);
    bool installed = false;
    try {
      prepared.renameSync(target.path);
      installed = true;
      afterInstall?.call();
    } catch (_) {
      if (installed) Directory(target.path).deleteSync(recursive: true);
      if (existed) previous.renameSync(target.path);
      rethrow;
    }
    if (existed) {
      try {
        previous.deleteSync(recursive: true);
      } on FileSystemException {
        // The committed target is valid; retaining the previous tree is safe.
      }
    }
  }
}
