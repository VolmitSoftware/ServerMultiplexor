import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'addon_catalog.dart';
import 'addon_resolver.dart';

final class InstalledAddon {
  InstalledAddon(this.json)
    : id = addonString(json, 'id'),
      file = addonString(json, 'file'),
      hash = addonString(json, 'sha256') {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id) ||
        !<String>{
          'plugins/multiplexor-$id.jar',
          'mods/multiplexor-$id.jar',
        }.contains(file) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid installed addon');
    }
    addonStrings(json, 'filePrefixes', optional: true);
  }

  final Map<String, Object?> json;
  final String id;
  final String file;
  final String hash;

  bool protects(String path) {
    if (path.toLowerCase() == file.toLowerCase()) return true;
    if (p.posix.dirname(path) != p.posix.dirname(file)) return false;
    final String name = p.posix.basename(path).toLowerCase();
    return name.endsWith('.jar') &&
        addonStrings(
          json,
          'filePrefixes',
          optional: true,
        ).any((String prefix) => name.startsWith(prefix.toLowerCase()));
  }
}

final class AddonState {
  const AddonState(this.entries);
  static const String filename = '.multiplexor-addons.json';
  final Map<String, InstalledAddon> entries;

  static AddonState read(String instancePath) {
    final String path = p.join(instancePath, filename);
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return const AddonState(<String, InstalledAddon>{});
    }
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Addon state must be a regular file', path);
    }
    final Map<String, Object?> json = addonObject(
      jsonDecode(File(path).readAsStringSync()),
    );
    if (json['schema'] != 1 || json['entries'] is! List<Object?>) {
      throw const FormatException('Invalid addon state');
    }
    final Map<String, InstalledAddon> entries = <String, InstalledAddon>{};
    for (final Object? raw in json['entries']! as List<Object?>) {
      final InstalledAddon entry = InstalledAddon(addonObject(raw));
      if (entries.containsKey(entry.id)) {
        throw const FormatException('Duplicate installed addon');
      }
      entries[entry.id] = entry;
    }
    return AddonState(entries);
  }

  bool protects(String path) =>
      entries.values.any((InstalledAddon addon) => addon.protects(path));

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'entries': entries.values
        .map((InstalledAddon addon) => addon.json)
        .toList(),
  };
}

final class AddonInstaller {
  AddonInstaller({
    required this.workspace,
    required this.instancePath,
    required this.serverType,
    required this.minecraft,
    required this.catalog,
  });

  final String workspace;
  final String instancePath;
  final String serverType;
  final String minecraft;
  final AddonCatalog catalog;

  Map<String, Object?> list(String instance) {
    final AddonState state = AddonState.read(instancePath);
    return <String, Object?>{
      'instance': instance,
      'type': serverType,
      'minecraft': minecraft,
      'entries': <Map<String, Object?>>[
        for (final AddonDefinition addon in catalog.entries.values)
          <String, Object?>{
            ...addon.toJson(),
            if (addon.sources.any(
              (AddonSource source) =>
                  source.supports(serverType, minecraft) &&
                  source.json['label'] == 'development',
            ))
              'name': '${addon.name} (development)',
            'selected': state.entries.containsKey(addon.id),
            'available':
                addon.unavailableReason(serverType, minecraft: minecraft) ==
                null,
            'reason': addon.unavailableReason(serverType, minecraft: minecraft),
          },
        for (final InstalledAddon installed in state.entries.values)
          if (!catalog.entries.containsKey(installed.id))
            <String, Object?>{
              'id': installed.id,
              'name': installed.id,
              'description': 'Installed addon removed from the catalog.',
              'selected': true,
              'available': false,
              'reason': 'Restore its catalog entry or uncheck to remove.',
            },
      ],
    };
  }

  /// Resolve and validate the complete selection before committing any jar.
  /// The caller shares the existing drop-in lock during the short commit.
  Future<Set<String>> apply(
    Set<String> selection, {
    required void Function(String) report,
    required Future<void> Function() beforeCommit,
    required void Function(void Function()) commit,
    bool update = false,
  }) async {
    final Set<String> selected = catalog.expand(selection);
    for (final String id in selected) {
      final String? reason = catalog.entries[id]!.unavailableReason(
        serverType,
        minecraft: minecraft,
      );
      if (reason != null) throw StateError('$id: $reason');
    }
    _regularDirectory(instancePath);
    final String lockPath = p.join(instancePath, '.multiplexor-addons.lock');
    _regularFileOrMissing(lockPath);
    final RandomAccessFile lock = File(
      lockPath,
    ).openSync(mode: FileMode.append);
    bool locked = false;
    Directory? stage;
    bool preserveStage = false;
    final AddonResolver resolver = AddonResolver(workspace);
    try {
      lock.lockSync(FileLock.exclusive);
      locked = true;
      final AddonState previous = AddonState.read(instancePath);
      _checkExisting(previous);
      final Set<String> refreshRoots = <String>{
        for (final String id in selected)
          if (update ||
              previous.entries[id] == null ||
              previous.entries[id]!.json['minecraft'] != minecraft ||
              previous.entries[id]!.json['serverType'] != serverType ||
              !File(
                p.join(instancePath, previous.entries[id]!.file),
              ).existsSync())
            id,
      };
      // A newly resolved dependent may require a newer dependency than the
      // installed one. Resolve its whole declared closure in the same batch.
      final Set<String> refresh = catalog.expand(refreshRoots);
      stage = Directory(
        instancePath,
      ).createTempSync('.multiplexor-addons-stage-');
      final Map<String, InstalledAddon> next = <String, InstalledAddon>{};
      final Map<String, File> downloads = <String, File>{};
      for (final String id in selected) {
        final AddonDefinition definition = catalog.entries[id]!;
        final InstalledAddon? old = previous.entries[id];
        if (!refresh.contains(id) &&
            old != null &&
            old.json['minecraft'] == minecraft &&
            old.json['serverType'] == serverType &&
            File(p.join(instancePath, old.file)).existsSync()) {
          next[id] = old;
          continue;
        }
        report(
          '[INFO] Resolving ${definition.name} for $serverType Minecraft $minecraft',
        );
        final ResolvedAddon resolved = await resolver.resolve(
          definition,
          serverType,
          minecraft,
        );
        for (final String project in resolved.requiredProjects) {
          final bool included = next.values.any(
            (InstalledAddon dependency) =>
                dependency.json['projectId'] == project,
          );
          if (!included) {
            throw StateError(
              '${definition.name} requires Modrinth project $project. Add it to the catalog and dependencies.',
            );
          }
          final String? requiredVersion = resolved.requiredVersions[project];
          if (requiredVersion != null &&
              !next.values.any(
                (InstalledAddon dependency) =>
                    dependency.json['projectId'] == project &&
                    dependency.json['versionId'] == requiredVersion,
              )) {
            throw StateError(
              '${definition.name} requires Modrinth project $project version $requiredVersion. Set that dependency source\'s versionId to $requiredVersion.',
            );
          }
        }
        final File download = File(p.join(stage.path, '$id.jar'));
        await resolver.download(resolved, download);
        next[id] = InstalledAddon(<String, Object?>{
          'id': id,
          'file': definition.file,
          'sha256': _hash(download),
          'version': resolved.version,
          'source': resolved.location,
          if (resolved.projectId != null) 'projectId': resolved.projectId,
          if (resolved.versionId != null) 'versionId': resolved.versionId,
          'minecraft': minecraft,
          'serverType': serverType,
          'filePrefixes': definition.filePrefixes,
        });
        downloads[id] = download;
        report('[INFO] Ready: ${definition.name} ${resolved.version}');
      }
      await beforeCommit();
      final Directory transaction = stage;
      commit(() {
        _regularDirectory(instancePath);
        _checkExisting(previous);
        if (jsonEncode(AddonState.read(instancePath).toJson()) !=
            jsonEncode(previous.toJson())) {
          throw StateError('Addon selection changed during download. Retry.');
        }
        _checkConflicts(previous, next);
        final Map<String, String> backups = <String, String>{};
        final Set<String> installedPaths = <String>{};
        final String statePath = p.join(instancePath, AddonState.filename);
        final File stateFile = File(statePath);
        final String? previousState = stateFile.existsSync()
            ? stateFile.readAsStringSync()
            : null;
        bool stateWritten = false;
        try {
          for (final InstalledAddon old in previous.entries.values) {
            if (next.containsKey(old.id) && !downloads.containsKey(old.id)) {
              continue;
            }
            final String path = p.join(instancePath, old.file);
            if (!File(path).existsSync()) continue;
            final String backup = p.join(transaction.path, 'old-${old.id}.jar');
            File(path).renameSync(backup);
            backups[path] = backup;
          }
          for (final MapEntry<String, File> download in downloads.entries) {
            final String path = p.join(instancePath, next[download.key]!.file);
            final String directory = p.dirname(path);
            if (!Directory(directory).existsSync()) {
              Directory(directory).createSync();
            }
            _regularDirectory(directory);
            download.value.renameSync(path);
            installedPaths.add(path);
          }
          final File pending = File(p.join(transaction.path, 'state.json'));
          pending.writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(AddonState(next).toJson())}\n',
            flush: true,
          );
          pending.renameSync(statePath);
          stateWritten = true;
        } catch (error) {
          try {
            for (final String path in installedPaths) {
              File(path).deleteSync();
            }
            for (final MapEntry<String, String> backup in backups.entries) {
              File(backup.value).renameSync(backup.key);
            }
            if (stateWritten) {
              if (previousState == null) {
                stateFile.deleteSync();
              } else {
                stateFile.writeAsStringSync(previousState, flush: true);
              }
            }
          } catch (recoveryError) {
            preserveStage = true;
            throw StateError(
              'Addon commit failed: $error. Recovery failed: $recoveryError. Backups: ${transaction.path}',
            );
          }
          rethrow;
        }
      });
      return selected;
    } finally {
      resolver.close();
      try {
        if (stage != null && !preserveStage && stage.existsSync()) {
          stage.deleteSync(recursive: true);
        }
      } finally {
        try {
          if (locked) lock.unlockSync();
        } finally {
          lock.closeSync();
        }
      }
    }
  }

  void _checkExisting(AddonState state) {
    for (final InstalledAddon addon in state.entries.values) {
      final String path = p.join(instancePath, addon.file);
      final String directory = p.dirname(path);
      if (FileSystemEntity.typeSync(directory, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _regularDirectory(directory);
      }
      _regularFileOrMissing(path);
      final File file = File(path);
      if (file.existsSync() && _hash(file) != addon.hash) {
        throw StateError(
          'Managed addon was modified locally: $path. Move it aside before changing addons.',
        );
      }
    }
  }

  void _checkConflicts(AddonState previous, Map<String, InstalledAddon> next) {
    for (final InstalledAddon addon in next.values) {
      final String directory = p.join(
        instancePath,
        p.posix.dirname(addon.file),
      );
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        directory,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) continue;
      _regularDirectory(directory);
      for (final FileSystemEntity entity in Directory(
        directory,
      ).listSync(followLinks: false)) {
        final String relative =
            '${p.basename(directory)}/${p.basename(entity.path)}';
        if (previous.entries.values.any(
          (InstalledAddon old) => old.file == relative,
        )) {
          continue;
        }
        if (addon.protects(relative)) {
          throw StateError(
            'Existing unmanaged addon conflicts with ${addon.id}: ${entity.path}. Move it aside first.',
          );
        }
      }
    }
  }
}

String _hash(File file) => sha256.convert(file.readAsBytesSync()).toString();

void _regularDirectory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw FileSystemException(
      'Addon target must be a real directory, not a symlink',
      path,
    );
  }
}

void _regularFileOrMissing(String path) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Addon path must be a regular file, not a symlink',
      path,
    );
  }
}
