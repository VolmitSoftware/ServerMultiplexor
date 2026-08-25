import 'package:path/path.dart' as p;

/// One exclusion contract shared by manifests and direct rclone writes.
final class PterodactylTransferPathPolicy {
  const PterodactylTransferPathPolicy._();

  static const String linkMetadataFileName = '.multiplexor-remote.json';

  static final RegExp _generatedPart = RegExp(
    r'^\..+\.multiplexor-[a-z0-9][a-z0-9._-]*\.part$',
  );

  static bool excludes(String relativePath) {
    final List<String> parts = p.posix.split(relativePath);
    if (parts.isEmpty) return false;
    final String first = parts.first;
    final String base = parts.last;
    return first == 'logs' ||
        first == 'crash-reports' ||
        parts.contains('.multiplexor-transfer') ||
        base == 'session.lock' ||
        base == linkMetadataFileName ||
        base == '.server-source' ||
        base == 'multiplexor-restart.sh' ||
        base == 'multiplexor-restart.cmd' ||
        _generatedPart.hasMatch(base);
  }

  /// rclone filter rules equivalent to [excludes]. Restore deliberately does
  /// not use these rules because recovery snapshots contain the full tree.
  static const List<String> rcloneExclusions = <String>[
    '--exclude=/logs',
    '--exclude=/logs/**',
    '--exclude=/crash-reports',
    '--exclude=/crash-reports/**',
    '--exclude=/session.lock',
    '--exclude=/**/session.lock',
    '--exclude=/.multiplexor-remote.json',
    '--exclude=/**/.multiplexor-remote.json',
    '--exclude=/.server-source',
    '--exclude=/**/.server-source',
    '--exclude=/multiplexor-restart.sh',
    '--exclude=/**/multiplexor-restart.sh',
    '--exclude=/multiplexor-restart.cmd',
    '--exclude=/**/multiplexor-restart.cmd',
    '--exclude=/.multiplexor-transfer',
    '--exclude=/.multiplexor-transfer/**',
    '--exclude=/**/.multiplexor-transfer',
    '--exclude=/**/.multiplexor-transfer/**',
    '--exclude=/.*.multiplexor-*.part',
    '--exclude=/**/.*.multiplexor-*.part',
  ];
}
