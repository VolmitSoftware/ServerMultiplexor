import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../pterodactyl/pterodactyl_profile.dart';

final class RemoteProfilerHostConfig {
  RemoteProfilerHostConfig({
    required String profileId,
    required this.nodeId,
    required this.sshTarget,
    this.sshPort = 22,
    this.identityFile,
    this.knownHostsFile,
    this.sudoDocker = false,
  }) : profileId = PterodactylProfile.normalizeId(profileId) {
    if (nodeId < 1 || sshPort < 1 || sshPort > 65535) {
      throw const FormatException('Node ID and SSH port must be positive.');
    }
    if (!RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.@:\[\]-]*$').hasMatch(sshTarget)) {
      throw const FormatException(
        'SSH target must be a host alias or user@host.',
      );
    }
    for (final String? path in <String?>[identityFile, knownHostsFile]) {
      if (path != null &&
          (!p.isAbsolute(path) || RegExp(r'[\x00-\x1f\x7f]').hasMatch(path))) {
        throw const FormatException(
          'SSH file paths must be absolute local paths.',
        );
      }
    }
  }

  final String profileId;
  final int nodeId;
  final String sshTarget;
  final int sshPort;
  final String? identityFile;
  final String? knownHostsFile;
  final bool sudoDocker;

  Map<String, Object?> toJson() => <String, Object?>{
    'profile_id': profileId,
    'node_id': nodeId,
    'ssh_target': sshTarget,
    'ssh_port': sshPort,
    'identity_file': identityFile,
    'known_hosts_file': knownHostsFile,
    'sudo_docker': sudoDocker,
  };

  factory RemoteProfilerHostConfig.fromJson(Map<String, Object?> json) {
    if (json['profile_id'] is! String ||
        json['node_id'] is! int ||
        json['ssh_target'] is! String ||
        json['ssh_port'] is! int ||
        json['sudo_docker'] is! bool ||
        (json['identity_file'] != null && json['identity_file'] is! String) ||
        (json['known_hosts_file'] != null &&
            json['known_hosts_file'] is! String)) {
      throw const FormatException('Invalid remote profiler host settings.');
    }
    return RemoteProfilerHostConfig(
      profileId: json['profile_id'] as String,
      nodeId: json['node_id'] as int,
      sshTarget: json['ssh_target'] as String,
      sshPort: json['ssh_port'] as int,
      identityFile: json['identity_file'] as String?,
      knownHostsFile: json['known_hosts_file'] as String?,
      sudoDocker: json['sudo_docker'] as bool,
    );
  }
}

final class RemoteProfilerHostStore {
  RemoteProfilerHostStore(String metadataDirectory)
    : file = File(p.join(metadataDirectory, 'remote-profiler-hosts.json'));

  final File file;

  List<RemoteProfilerHostConfig> list() {
    if (!file.existsSync()) return <RemoteProfilerHostConfig>[];
    final Object? data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, Object?> ||
        data['schema_version'] != 1 ||
        data['hosts'] is! List<Object?>) {
      throw const FormatException('Invalid remote profiler host store.');
    }
    final List<RemoteProfilerHostConfig> hosts = <RemoteProfilerHostConfig>[];
    final Set<String> keys = <String>{};
    for (final Object? item in data['hosts'] as List<Object?>) {
      if (item is! Map<String, Object?>) {
        throw const FormatException('Invalid profiler host.');
      }
      final RemoteProfilerHostConfig host = RemoteProfilerHostConfig.fromJson(
        item,
      );
      if (!keys.add('${host.profileId}/${host.nodeId}')) {
        throw const FormatException('Duplicate profiler host mapping.');
      }
      hosts.add(host);
    }
    return hosts;
  }

  RemoteProfilerHostConfig? load(String profileId, int nodeId) => list()
      .where(
        (RemoteProfilerHostConfig host) =>
            host.profileId == PterodactylProfile.normalizeId(profileId) &&
            host.nodeId == nodeId,
      )
      .firstOrNull;

  void save(RemoteProfilerHostConfig config) {
    final List<RemoteProfilerHostConfig> hosts = list()
      ..removeWhere(
        (RemoteProfilerHostConfig host) =>
            host.profileId == config.profileId && host.nodeId == config.nodeId,
      )
      ..add(config);
    file.parent.createSync(recursive: true);
    final File pending = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      pending.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'schema_version': 1, 'hosts': hosts.map((RemoteProfilerHostConfig host) => host.toJson()).toList()})}\n',
        flush: true,
      );
      pending.renameSync(file.path);
    } finally {
      if (pending.existsSync()) pending.deleteSync();
    }
  }
}
