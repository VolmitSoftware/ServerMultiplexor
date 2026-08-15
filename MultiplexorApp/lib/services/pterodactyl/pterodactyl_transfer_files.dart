import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pterodactyl_transfer_models.dart';

final class PterodactylTransferFileEntry {
  const PterodactylTransferFileEntry({
    required this.path,
    required this.sourcePath,
    required this.size,
    required this.sha256,
  });

  final String path;
  final String sourcePath;
  final int size;
  final String sha256;
}

final class PterodactylTransferFileManifest {
  PterodactylTransferFileManifest({
    required this.rootPath,
    required Map<String, PterodactylTransferFileEntry> files,
    required Set<String> directories,
    required Set<String> excludedContentDirectories,
  }) : files = Map<String, PterodactylTransferFileEntry>.unmodifiable(files),
       directories = Set<String>.unmodifiable(directories),
       excludedContentDirectories = Set<String>.unmodifiable(
         excludedContentDirectories,
       );

  final String rootPath;
  final Map<String, PterodactylTransferFileEntry> files;
  final Set<String> directories;

  /// Included directories that contain at least one excluded descendant.
  ///
  /// Mirror keeps these directories when their excluded content is the only
  /// thing preventing removal. Directory deltas below them remain independent.
  final Set<String> excludedContentDirectories;

  String get fingerprint {
    final StringBuffer buffer = StringBuffer();
    final List<String> directoryPaths = directories.toList()..sort();
    for (final String path in directoryPaths) {
      buffer
        ..write('d\u0000')
        ..write(path)
        ..write('\n');
    }
    final List<String> protectedDirectoryPaths =
        excludedContentDirectories.toList()..sort();
    for (final String path in protectedDirectoryPaths) {
      buffer
        ..write('x\u0000')
        ..write(path)
        ..write('\n');
    }
    final List<String> filePaths = files.keys.toList()..sort();
    for (final String path in filePaths) {
      final PterodactylTransferFileEntry entry = files[path]!;
      buffer
        ..write('f\u0000')
        ..write(path)
        ..write('\u0000')
        ..write(entry.size)
        ..write('\u0000')
        ..write(entry.sha256)
        ..write('\n');
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }
}

typedef PterodactylTransferPathExclusion = bool Function(String relativePath);

/// Deterministic file manifest and staged-copy implementation.
final class PterodactylTransferFileEngine {
  const PterodactylTransferFileEngine();

  Future<PterodactylTransferFileManifest> scan(
    String rootPath, {
    PterodactylTransferPathExclusion? exclude,
    bool allowSymlinks = false,
    String? allowedSymlinkRoot,
    Iterable<String> allowedSymlinkRoots = const <String>[],
  }) async {
    final Directory root = Directory(p.normalize(p.absolute(rootPath)));
    if (!root.existsSync()) {
      throw StateError('Transfer root does not exist: ${root.path}');
    }
    final String canonicalRoot = root.resolveSymbolicLinksSync();
    final List<String> canonicalAllowedRoots = <String>[
      if (allowedSymlinkRoot != null)
        Directory(allowedSymlinkRoot).resolveSymbolicLinksSync(),
      for (final String path in allowedSymlinkRoots)
        Directory(path).resolveSymbolicLinksSync(),
    ];
    final Map<String, PterodactylTransferFileEntry> files =
        <String, PterodactylTransferFileEntry>{};
    final Set<String> directories = <String>{};
    final Set<String> excludedContentDirectories = <String>{};
    await _walk(
      physicalDirectory: canonicalRoot,
      logicalDirectory: '',
      sourceRoot: canonicalRoot,
      allowedRoots: canonicalAllowedRoots,
      allowSymlinks: allowSymlinks,
      exclude: exclude,
      ancestorDirectories: <String>{canonicalRoot},
      files: files,
      directories: directories,
      excludedContentDirectories: excludedContentDirectories,
    );
    return PterodactylTransferFileManifest(
      rootPath: root.path,
      files: files,
      directories: directories,
      excludedContentDirectories: excludedContentDirectories,
    );
  }

  List<PterodactylTransferChange> diff({
    required PterodactylTransferFileManifest source,
    required PterodactylTransferFileManifest target,
    required PterodactylTransferMode mode,
  }) {
    for (final String path in source.files.keys) {
      if (target.directories.contains(path)) {
        throw StateError(
          'Transfer cannot replace target directory with file: $path',
        );
      }
    }
    for (final String path in source.directories) {
      if (target.files.containsKey(path)) {
        throw StateError(
          'Transfer cannot replace target file with directory: $path',
        );
      }
    }
    final List<PterodactylTransferChange> changes =
        <PterodactylTransferChange>[];
    final List<String> sourcePaths = source.files.keys.toList()..sort();
    for (final String path in sourcePaths) {
      final PterodactylTransferFileEntry sourceEntry = source.files[path]!;
      final PterodactylTransferFileEntry? targetEntry = target.files[path];
      if (targetEntry == null) {
        changes.add(
          PterodactylTransferChange(
            path: path,
            kind: PterodactylTransferChangeKind.add,
            sourceSize: sourceEntry.size,
          ),
        );
      } else if (targetEntry.sha256 != sourceEntry.sha256) {
        changes.add(
          PterodactylTransferChange(
            path: path,
            kind: PterodactylTransferChangeKind.update,
            sourceSize: sourceEntry.size,
            targetSize: targetEntry.size,
          ),
        );
      }
    }
    final List<String> sourceDirectories = source.directories.toList()..sort();
    for (final String path in sourceDirectories) {
      if (!source.excludedContentDirectories.contains(path) &&
          !target.directories.contains(path) &&
          !_hasFileDescendant(source, path)) {
        changes.add(
          PterodactylTransferChange(
            path: path,
            kind: PterodactylTransferChangeKind.add,
            entryKind: PterodactylTransferEntryKind.directory,
          ),
        );
      }
    }
    if (mode == PterodactylTransferMode.mirror) {
      final List<String> targetPaths = target.files.keys.toList()..sort();
      for (final String path in targetPaths) {
        if (!source.files.containsKey(path)) {
          changes.add(
            PterodactylTransferChange(
              path: path,
              kind: PterodactylTransferChangeKind.delete,
              targetSize: target.files[path]!.size,
            ),
          );
        }
      }
      final List<String> targetDirectories = target.directories.toList()
        ..sort();
      for (final String path in targetDirectories) {
        if (!source.directories.contains(path) &&
            !target.excludedContentDirectories.contains(path)) {
          changes.add(
            PterodactylTransferChange(
              path: path,
              kind: PterodactylTransferChangeKind.delete,
              entryKind: PterodactylTransferEntryKind.directory,
            ),
          );
        }
      }
    }
    changes.sort(_compareChanges);
    return List<PterodactylTransferChange>.unmodifiable(changes);
  }

  Future<void> apply({
    required PterodactylTransferFileManifest source,
    required String targetRootPath,
    required List<PterodactylTransferChange> changes,
    required PterodactylTransferMode mode,
    required String operationId,
    bool replaceDestinationLinks = false,
  }) async {
    final String targetRoot = p.normalize(p.absolute(targetRootPath));
    _requireDirectoryRoot(targetRoot);
    final List<PterodactylTransferChange> directoryAdds =
        changes
            .where(
              (PterodactylTransferChange change) =>
                  change.entryKind == PterodactylTransferEntryKind.directory &&
                  change.kind == PterodactylTransferChangeKind.add,
            )
            .toList(growable: false)
          ..sort(_compareShallowestFirst);
    for (final PterodactylTransferChange change in directoryAdds) {
      _ensureSafeDirectory(
        targetRoot,
        change.path,
        replaceLinks: replaceDestinationLinks,
      );
    }

    for (final PterodactylTransferChange change in changes) {
      if (change.entryKind == PterodactylTransferEntryKind.directory ||
          change.kind == PterodactylTransferChangeKind.delete) {
        continue;
      }
      final PterodactylTransferFileEntry sourceEntry =
          source.files[change.path]!;
      final String destination = _safeDestination(targetRoot, change.path);
      _ensureSafeDirectory(
        targetRoot,
        p.posix.dirname(change.path),
        replaceLinks: replaceDestinationLinks,
      );
      final FileSystemEntityType existing = FileSystemEntity.typeSync(
        destination,
        followLinks: false,
      );
      if (existing == FileSystemEntityType.directory ||
          existing == FileSystemEntityType.link && !replaceDestinationLinks) {
        throw StateError(
          'Refusing to replace a non-file transfer target: ${change.path}',
        );
      }
      final String temporary = p.join(
        p.dirname(destination),
        '.${p.basename(destination)}.multiplexor-$operationId.part',
      );
      final File temporaryFile = File(temporary);
      if (temporaryFile.existsSync()) temporaryFile.deleteSync();
      try {
        await File(sourceEntry.sourcePath).copy(temporary);
        final String copiedHash = await _hashFile(temporaryFile);
        if (copiedHash != sourceEntry.sha256) {
          throw StateError(
            'Staged transfer verification failed: ${change.path}',
          );
        }
        _replaceStagedFile(
          staged: temporaryFile,
          destination: destination,
          operationId: operationId,
        );
      } finally {
        if (temporaryFile.existsSync()) temporaryFile.deleteSync();
      }
    }

    if (mode == PterodactylTransferMode.mirror) {
      final List<PterodactylTransferChange> deletions =
          changes
              .where(
                (PterodactylTransferChange change) =>
                    change.kind == PterodactylTransferChangeKind.delete,
              )
              .toList(growable: false)
            ..sort(
              (
                PterodactylTransferChange left,
                PterodactylTransferChange right,
              ) => right.path.compareTo(left.path),
            );
      for (final PterodactylTransferChange change in deletions) {
        if (change.entryKind != PterodactylTransferEntryKind.file) continue;
        final String destination = _safeDestination(targetRoot, change.path);
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          destination,
          followLinks: false,
        );
        if (type == FileSystemEntityType.file) {
          File(destination).deleteSync();
        } else if (type != FileSystemEntityType.notFound) {
          throw StateError(
            'Refusing to delete a non-file transfer target: ${change.path}',
          );
        }
      }
      final List<PterodactylTransferChange> directoryDeletions =
          changes
              .where(
                (PterodactylTransferChange change) =>
                    change.entryKind ==
                        PterodactylTransferEntryKind.directory &&
                    change.kind == PterodactylTransferChangeKind.delete,
              )
              .toList(growable: false)
            ..sort(_compareDeepestFirst);
      for (final PterodactylTransferChange change in directoryDeletions) {
        final String destination = _safeDestination(targetRoot, change.path);
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          destination,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          Directory(destination).deleteSync();
        } else if (type != FileSystemEntityType.notFound) {
          throw StateError(
            'Refusing to delete a non-directory transfer target: '
            '${change.path}',
          );
        }
      }
    }
  }

  bool _hasFileDescendant(
    PterodactylTransferFileManifest manifest,
    String directory,
  ) {
    final String prefix = '$directory/';
    return manifest.files.keys.any((String path) => path.startsWith(prefix));
  }

  int _compareChanges(
    PterodactylTransferChange left,
    PterodactylTransferChange right,
  ) {
    final int pathOrder = left.path.compareTo(right.path);
    if (pathOrder != 0) return pathOrder;
    final int entryOrder = left.entryKind.index.compareTo(
      right.entryKind.index,
    );
    return entryOrder != 0
        ? entryOrder
        : left.kind.index.compareTo(right.kind.index);
  }

  int _compareShallowestFirst(
    PterodactylTransferChange left,
    PterodactylTransferChange right,
  ) {
    final int depth = p.posix
        .split(left.path)
        .length
        .compareTo(p.posix.split(right.path).length);
    return depth != 0 ? depth : left.path.compareTo(right.path);
  }

  int _compareDeepestFirst(
    PterodactylTransferChange left,
    PterodactylTransferChange right,
  ) => -_compareShallowestFirst(left, right);

  Future<void> replaceWithBackup({
    required String backupRootPath,
    required String targetRootPath,
    required String operationId,
  }) async {
    final PterodactylTransferFileManifest backup = await scan(
      backupRootPath,
      allowSymlinks: false,
    );
    final PterodactylTransferFileManifest current = await scan(
      targetRootPath,
      allowSymlinks: false,
    );
    final List<PterodactylTransferChange> changes = diff(
      source: backup,
      target: current,
      mode: PterodactylTransferMode.mirror,
    );
    await apply(
      source: backup,
      targetRootPath: targetRootPath,
      changes: changes,
      mode: PterodactylTransferMode.mirror,
      operationId: operationId,
    );
  }

  Future<String> _hashFile(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<bool> _walk({
    required String physicalDirectory,
    required String logicalDirectory,
    required String sourceRoot,
    required List<String> allowedRoots,
    required bool allowSymlinks,
    required PterodactylTransferPathExclusion? exclude,
    required Set<String> ancestorDirectories,
    required Map<String, PterodactylTransferFileEntry> files,
    required Set<String> directories,
    required Set<String> excludedContentDirectories,
  }) async {
    bool containsExcludedContent = false;
    final List<FileSystemEntity> entities =
        Directory(physicalDirectory).listSync(followLinks: false)..sort(
          (FileSystemEntity left, FileSystemEntity right) =>
              p.basename(left.path).compareTo(p.basename(right.path)),
        );
    for (final FileSystemEntity entity in entities) {
      final String name = p.basename(entity.path);
      _validateComponent(name);
      final String relative = logicalDirectory.isEmpty
          ? name
          : p.posix.join(logicalDirectory, name);
      if (exclude?.call(relative) ?? false) {
        containsExcludedContent = true;
        continue;
      }
      final FileSystemEntityType directType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      String physicalPath = entity.path;
      FileSystemEntityType effectiveType = directType;
      if (directType == FileSystemEntityType.link) {
        if (!allowSymlinks) {
          throw StateError('Transfer source contains a symlink: $relative');
        }
        physicalPath = entity.resolveSymbolicLinksSync();
        if (!_insideOrEqual(sourceRoot, physicalPath) &&
            !allowedRoots.any(
              (String root) => _insideOrEqual(root, physicalPath),
            )) {
          throw StateError(
            'Transfer symlink escapes its allowed root: $relative',
          );
        }
        effectiveType = FileSystemEntity.typeSync(physicalPath);
      }
      if (effectiveType == FileSystemEntityType.directory) {
        final String canonical = Directory(
          physicalPath,
        ).resolveSymbolicLinksSync();
        if (ancestorDirectories.contains(canonical)) {
          throw StateError(
            'Transfer symlink creates a directory cycle: $relative',
          );
        }
        directories.add(relative);
        final bool childContainsExcludedContent = await _walk(
          physicalDirectory: canonical,
          logicalDirectory: relative,
          sourceRoot: sourceRoot,
          allowedRoots: allowedRoots,
          allowSymlinks: allowSymlinks,
          exclude: exclude,
          ancestorDirectories: <String>{...ancestorDirectories, canonical},
          files: files,
          directories: directories,
          excludedContentDirectories: excludedContentDirectories,
        );
        if (childContainsExcludedContent) {
          excludedContentDirectories.add(relative);
          containsExcludedContent = true;
        }
      } else if (effectiveType == FileSystemEntityType.file) {
        final File file = File(physicalPath);
        files[relative] = PterodactylTransferFileEntry(
          path: relative,
          sourcePath: file.path,
          size: file.lengthSync(),
          sha256: await _hashFile(file),
        );
      } else {
        throw StateError('Unsupported transfer entry: $relative');
      }
    }
    return containsExcludedContent;
  }

  void _requireDirectoryRoot(String path) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      throw StateError('Transfer destination is not a real directory: $path');
    }
  }

  void _ensureSafeDirectory(
    String root,
    String relative, {
    bool replaceLinks = false,
  }) {
    if (relative == '.' || relative.isEmpty) return;
    final List<String> parts = _validatedParts(relative);
    String current = root;
    for (final String part in parts) {
      current = p.join(current, part);
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        current,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
      } else if (type == FileSystemEntityType.link && replaceLinks) {
        Link(current).deleteSync();
        Directory(current).createSync();
      } else if (type != FileSystemEntityType.directory) {
        throw StateError(
          'Transfer destination path is not a directory: $relative',
        );
      }
    }
  }

  String _safeDestination(String root, String relative) {
    final List<String> parts = _validatedParts(relative);
    final String destination = p.normalize(p.joinAll(<String>[root, ...parts]));
    if (!p.isWithin(root, destination)) {
      throw StateError('Transfer path escaped its destination: $relative');
    }
    return destination;
  }

  List<String> _validatedParts(String relative) {
    if (relative.isEmpty ||
        p.posix.isAbsolute(relative) ||
        p.windows.isAbsolute(relative)) {
      throw StateError('Invalid transfer path: $relative');
    }
    final List<String> parts = p.posix.split(relative);
    for (final String part in parts) {
      _validateComponent(part);
    }
    return parts;
  }

  void _validateComponent(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      throw StateError('Unsafe transfer path component.');
    }
  }

  bool _insideOrEqual(String root, String candidate) =>
      p.equals(root, candidate) || p.isWithin(root, candidate);

  void _replaceStagedFile({
    required File staged,
    required String destination,
    required String operationId,
  }) {
    final FileSystemEntityType existing = FileSystemEntity.typeSync(
      destination,
      followLinks: false,
    );
    final String previousPath =
        '$destination.multiplexor-$operationId.previous';
    if (FileSystemEntity.typeSync(previousPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Transfer recovery path already exists.');
    }
    bool movedPrevious = false;
    bool installedNew = false;
    try {
      if (existing == FileSystemEntityType.file) {
        File(destination).renameSync(previousPath);
        movedPrevious = true;
      } else if (existing == FileSystemEntityType.link) {
        Link(destination).renameSync(previousPath);
        movedPrevious = true;
      }
      staged.renameSync(destination);
      installedNew = true;
      if (movedPrevious) _deleteFileOrLink(previousPath);
    } catch (_) {
      final FileSystemEntityType installed = FileSystemEntity.typeSync(
        destination,
        followLinks: false,
      );
      if (installedNew &&
          (installed == FileSystemEntityType.file ||
              installed == FileSystemEntityType.link)) {
        _deleteFileOrLink(destination);
      }
      if (movedPrevious &&
          FileSystemEntity.typeSync(previousPath, followLinks: false) !=
              FileSystemEntityType.notFound) {
        if (FileSystemEntity.typeSync(previousPath, followLinks: false) ==
            FileSystemEntityType.link) {
          Link(previousPath).renameSync(destination);
        } else {
          File(previousPath).renameSync(destination);
        }
      }
      rethrow;
    }
  }

  void _deleteFileOrLink(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else {
      File(path).deleteSync();
    }
  }
}
