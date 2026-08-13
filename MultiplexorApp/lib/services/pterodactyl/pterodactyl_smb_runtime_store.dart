import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class PterodactylSmbRuntimeMount {
  const PterodactylSmbRuntimeMount({
    required this.profileId,
    required this.serverIdentifier,
    required this.serverName,
    required this.mountPath,
    required this.remoteName,
    required this.pid,
    this.connectionSignature,
  });

  final String profileId;
  final String serverIdentifier;
  final String serverName;
  final String mountPath;
  final String remoteName;
  final int pid;
  final String? connectionSignature;
}

final class PterodactylSmbRuntimeState {
  PterodactylSmbRuntimeState({
    required this.shareName,
    required this.mountRoot,
    required this.startedAt,
    required this.shareRegistered,
    required Iterable<PterodactylSmbRuntimeMount> mounts,
  }) : mounts = List<PterodactylSmbRuntimeMount>.unmodifiable(mounts);

  final String shareName;
  final String mountRoot;
  final DateTime startedAt;
  final bool shareRegistered;
  final List<PterodactylSmbRuntimeMount> mounts;
}

/// Crash-recovery state. This file contains process IDs and paths, never keys.
final class PterodactylSmbRuntimeStore {
  PterodactylSmbRuntimeStore(String metadataDirectoryPath)
    : file = File(
        p.join(metadataDirectoryPath, 'pterodactyl-smb', 'runtime.json'),
      );

  PterodactylSmbRuntimeStore.atFile(this.file);

  static const int schemaVersion = 2;

  final File file;

  PterodactylSmbRuntimeState? load() {
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw const FormatException('Invalid Pterodactyl SMB runtime state.');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['schema_version'] is! int ||
        (decoded['schema_version'] != 1 &&
            decoded['schema_version'] != schemaVersion) ||
        decoded['share_name'] is! String ||
        decoded['mount_root'] is! String ||
        decoded['started_at'] is! String ||
        decoded['share_registered'] is! bool ||
        decoded['mounts'] is! List<Object?>) {
      throw const FormatException('Invalid Pterodactyl SMB runtime state.');
    }
    final DateTime? startedAt = DateTime.tryParse(
      decoded['started_at']! as String,
    );
    if (startedAt == null) {
      throw const FormatException('Invalid Pterodactyl SMB start time.');
    }
    final int storedSchema = decoded['schema_version']! as int;
    final List<PterodactylSmbRuntimeMount> mounts =
        <PterodactylSmbRuntimeMount>[];
    for (final Object? rawMount in decoded['mounts']! as List<Object?>) {
      if (rawMount is! Map<String, Object?> ||
          rawMount['profile_id'] is! String ||
          rawMount['server_identifier'] is! String ||
          rawMount['server_name'] is! String ||
          rawMount['mount_path'] is! String ||
          rawMount['remote_name'] is! String ||
          rawMount['pid'] is! int ||
          (storedSchema >= 2 && rawMount['connection_signature'] is! String)) {
        throw const FormatException('Invalid Pterodactyl SMB mount state.');
      }
      mounts.add(
        PterodactylSmbRuntimeMount(
          profileId: rawMount['profile_id']! as String,
          serverIdentifier: rawMount['server_identifier']! as String,
          serverName: rawMount['server_name']! as String,
          mountPath: rawMount['mount_path']! as String,
          remoteName: rawMount['remote_name']! as String,
          pid: rawMount['pid']! as int,
          connectionSignature: storedSchema >= 2
              ? rawMount['connection_signature']! as String
              : null,
        ),
      );
    }
    return PterodactylSmbRuntimeState(
      shareName: decoded['share_name']! as String,
      mountRoot: decoded['mount_root']! as String,
      startedAt: startedAt.toUtc(),
      shareRegistered: decoded['share_registered']! as bool,
      mounts: mounts,
    );
  }

  void save(PterodactylSmbRuntimeState state) {
    file.parent.createSync(recursive: true);
    final File temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    final Map<String, Object?> encoded = <String, Object?>{
      'schema_version': schemaVersion,
      'share_name': state.shareName,
      'mount_root': state.mountRoot,
      'started_at': state.startedAt.toUtc().toIso8601String(),
      'share_registered': state.shareRegistered,
      'mounts': <Object?>[
        for (final PterodactylSmbRuntimeMount mount in state.mounts)
          <String, Object?>{
            'profile_id': mount.profileId,
            'server_identifier': mount.serverIdentifier,
            'server_name': mount.serverName,
            'mount_path': mount.mountPath,
            'remote_name': mount.remoteName,
            'pid': mount.pid,
            'connection_signature': mount.connectionSignature ?? '',
          },
      ],
    };
    try {
      temporary.writeAsStringSync('${jsonEncode(encoded)}\n', flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void remove() {
    if (file.existsSync()) file.deleteSync();
  }
}
