import 'package:path/path.dart' as p;

/// One exclusion contract shared by manifests and direct rclone writes.
final class PterodactylTransferPathPolicy {
  const PterodactylTransferPathPolicy._();

  static const String linkMetadataFileName = '.multiplexor-remote.json';

  static const Set<String> _localMetadataFiles = <String>{
    linkMetadataFileName,
    '.multiplexor-runtime.env',
    '.multiplexor-log4j2.xml',
    '.multiplexor-dropins.json',
    '.multiplexor-dropins.lock',
    '.multiplexor-addons.json',
    '.multiplexor-addons.lock',
    '.multiplexor-create-owner',
  };

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
        parts.any(
          (String part) => part.startsWith('.multiplexor-addons-stage-'),
        ) ||
        base == 'session.lock' ||
        _localMetadataFiles.contains(base) ||
        base == '.server-source' ||
        base == 'multiplexor-restart.sh' ||
        base == 'multiplexor-restart.cmd' ||
        _generatedPart.hasMatch(base);
  }

  /// rclone filter rules equivalent to [excludes]. Restore deliberately does
  /// not use these rules because recovery snapshots contain the full tree.
  static final List<String> rcloneExclusions = List<String>.unmodifiable(
    <String>[
      '--exclude=/logs',
      '--exclude=/logs/**',
      '--exclude=/crash-reports',
      '--exclude=/crash-reports/**',
      '--exclude=/session.lock',
      '--exclude=/**/session.lock',
      for (final String name in _localMetadataFiles) ...<String>[
        '--exclude=/$name',
        '--exclude=/**/$name',
      ],
      '--exclude=/.multiplexor-addons-stage-*',
      '--exclude=/.multiplexor-addons-stage-*/**',
      '--exclude=/**/.multiplexor-addons-stage-*',
      '--exclude=/**/.multiplexor-addons-stage-*/**',
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
    ],
  );
}
