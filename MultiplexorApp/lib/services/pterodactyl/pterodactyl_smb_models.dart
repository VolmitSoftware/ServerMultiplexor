import 'dart:collection';

import 'package:path/path.dart' as p;

import 'pterodactyl_models.dart';

enum PterodactylSmbOperatingSystem { macos, linux, windows, unsupported }

enum PterodactylSmbCheckLevel { ready, warning, error }

final class PterodactylSftpAccount {
  PterodactylSftpAccount({
    required String profileId,
    required String panelUsername,
    this.enabled = true,
    this.useManagedKey = true,
  }) : profileId = _profileId(profileId),
       panelUsername = _panelUsername(panelUsername);

  static final RegExp _profilePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static final RegExp _usernamePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$',
  );

  final String profileId;
  final String panelUsername;
  final bool enabled;
  final bool useManagedKey;

  String usernameFor(String serverIdentifier) {
    if (!RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(serverIdentifier)) {
      throw const FormatException(
        'Pterodactyl SFTP server identifiers must contain 8 letters or digits.',
      );
    }
    return '$panelUsername.$serverIdentifier';
  }

  PterodactylSftpAccount copyWith({
    String? panelUsername,
    bool? enabled,
    bool? useManagedKey,
  }) => PterodactylSftpAccount(
    profileId: profileId,
    panelUsername: panelUsername ?? this.panelUsername,
    enabled: enabled ?? this.enabled,
    useManagedKey: useManagedKey ?? this.useManagedKey,
  );

  static String _profileId(String value) {
    final String normalized = value.trim().toLowerCase();
    if (!_profilePattern.hasMatch(normalized)) {
      throw const FormatException('Invalid Pterodactyl profile ID.');
    }
    return normalized;
  }

  static String _panelUsername(String value) {
    final String normalized = value.trim();
    if (!_usernamePattern.hasMatch(normalized)) {
      throw const FormatException(
        'Pterodactyl usernames must use letters, digits, dots, underscores, '
        'or hyphens.',
      );
    }
    return normalized;
  }
}

/// Non-secret settings for the aggregate remote-files share.
///
/// Panel passwords and private keys deliberately do not belong in this model.
final class PterodactylSmbSettings {
  PterodactylSmbSettings({
    required String shareName,
    required String mountRoot,
    required String knownHostsFile,
    required Iterable<PterodactylSftpAccount> accounts,
    this.requireSmbEncryption = true,
  }) : shareName = _shareName(shareName),
       mountRoot = _absoluteNonRootPath(mountRoot, 'mount root'),
       knownHostsFile = _absoluteNonRootPath(
         knownHostsFile,
         'known-hosts file',
       ),
       accounts = UnmodifiableMapView<String, PterodactylSftpAccount>(
         _accountMap(accounts),
       );

  static final RegExp _shareNamePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$',
  );

  final String shareName;
  final String mountRoot;
  final String knownHostsFile;
  final bool requireSmbEncryption;
  final Map<String, PterodactylSftpAccount> accounts;

  Iterable<PterodactylSftpAccount> get enabledAccounts => accounts.values.where(
    (PterodactylSftpAccount account) => account.enabled,
  );

  PterodactylSmbSettings copyWith({
    String? shareName,
    String? mountRoot,
    String? knownHostsFile,
    bool? requireSmbEncryption,
    Iterable<PterodactylSftpAccount>? accounts,
  }) => PterodactylSmbSettings(
    shareName: shareName ?? this.shareName,
    mountRoot: mountRoot ?? this.mountRoot,
    knownHostsFile: knownHostsFile ?? this.knownHostsFile,
    requireSmbEncryption: requireSmbEncryption ?? this.requireSmbEncryption,
    accounts: accounts ?? this.accounts.values,
  );

  PterodactylSmbSettings withAccount(PterodactylSftpAccount account) {
    final Map<String, PterodactylSftpAccount> updated =
        Map<String, PterodactylSftpAccount>.from(accounts)
          ..[account.profileId] = account;
    return copyWith(accounts: updated.values);
  }

  PterodactylSmbSettings withoutAccount(String profileId) {
    final Map<String, PterodactylSftpAccount> updated =
        Map<String, PterodactylSftpAccount>.from(accounts)
          ..remove(profileId.trim().toLowerCase());
    return copyWith(accounts: updated.values);
  }

  static String _shareName(String value) {
    final String normalized = value.trim();
    if (!_shareNamePattern.hasMatch(normalized)) {
      throw const FormatException(
        'SMB share names must contain 1-64 safe, printable characters.',
      );
    }
    return normalized;
  }

  static String _absoluteNonRootPath(String value, String label) {
    final String normalized = p.normalize(value.trim());
    if (!p.isAbsolute(normalized) || p.dirname(normalized) == normalized) {
      throw FormatException('The $label must be an absolute non-root path.');
    }
    return normalized;
  }

  static Map<String, PterodactylSftpAccount> _accountMap(
    Iterable<PterodactylSftpAccount> accounts,
  ) {
    final Map<String, PterodactylSftpAccount> result =
        <String, PterodactylSftpAccount>{};
    for (final PterodactylSftpAccount account in accounts) {
      if (result.containsKey(account.profileId)) {
        throw const FormatException('Duplicate Pterodactyl SMB profile ID.');
      }
      result[account.profileId] = account;
    }
    return result;
  }
}

final class PterodactylSmbMountTarget {
  const PterodactylSmbMountTarget({
    required this.profileId,
    required this.serverIdentifier,
    required this.serverName,
    required this.host,
    required this.port,
    required this.sftpUsername,
    required this.relativeDirectory,
    required this.remoteName,
  });

  factory PterodactylSmbMountTarget.fromServer({
    required PterodactylSftpAccount account,
    required PterodactylClientServer server,
  }) {
    final String slug = safePathSegment(server.name, fallback: 'server');
    final String profileDirectory = safePathSegment(
      account.profileId,
      fallback: 'remote',
    );
    return PterodactylSmbMountTarget(
      profileId: account.profileId,
      serverIdentifier: server.identifier,
      serverName: server.name,
      host: server.sftpHost,
      port: server.sftpPort,
      sftpUsername: account.usernameFor(server.identifier),
      relativeDirectory: p.join(
        profileDirectory,
        '$slug--${server.identifier.toLowerCase()}',
      ),
      remoteName:
          'mx_${_environmentSegment(account.profileId)}_'
          '${_environmentSegment(server.identifier)}',
    );
  }

  final String profileId;
  final String serverIdentifier;
  final String serverName;
  final String host;
  final int port;
  final String sftpUsername;
  final String relativeDirectory;
  final String remoteName;

  String mountPath(PterodactylSmbSettings settings) =>
      p.join(settings.mountRoot, relativeDirectory);

  String get environmentPrefix => 'RCLONE_CONFIG_${remoteName.toUpperCase()}_';

  String get connectionSignature => '$host\n$port\n$sftpUsername';

  static String safePathSegment(String value, {required String fallback}) {
    String normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[ ._-]+|[ ._-]+$'), '');
    if (normalized.isEmpty) normalized = fallback;
    if (normalized.length > 64) normalized = normalized.substring(0, 64);
    return normalized;
  }

  static String _environmentSegment(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
}

final class PterodactylSmbCheck {
  const PterodactylSmbCheck({
    required this.name,
    required this.level,
    required this.message,
  });

  final String name;
  final PterodactylSmbCheckLevel level;
  final String message;
}

final class PterodactylSshHostKeyCandidate {
  const PterodactylSshHostKeyCandidate({
    required this.host,
    required this.port,
    required this.keyType,
    required this.knownHostsLine,
    required this.fingerprint,
  });

  final String host;
  final int port;
  final String keyType;
  final String knownHostsLine;
  final String fingerprint;

  String get endpoint => port == 22 ? host : '[$host]:$port';

  @override
  bool operator ==(Object other) =>
      other is PterodactylSshHostKeyCandidate &&
      other.host == host &&
      other.port == port &&
      other.keyType == keyType &&
      other.knownHostsLine == knownHostsLine &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode =>
      Object.hash(host, port, keyType, knownHostsLine, fingerprint);
}

final class PterodactylSmbDoctorReport {
  PterodactylSmbDoctorReport(Iterable<PterodactylSmbCheck> checks)
    : checks = List<PterodactylSmbCheck>.unmodifiable(checks);

  final List<PterodactylSmbCheck> checks;

  bool get isReady => checks.every(
    (PterodactylSmbCheck check) =>
        check.level != PterodactylSmbCheckLevel.error,
  );
}

final class PterodactylSmbMountStatus {
  const PterodactylSmbMountStatus({
    required this.profileId,
    required this.serverIdentifier,
    required this.serverName,
    required this.mountPath,
    required this.pid,
    required this.running,
  });

  final String profileId;
  final String serverIdentifier;
  final String serverName;
  final String mountPath;
  final int pid;
  final bool running;
}

final class PterodactylSmbStatus {
  PterodactylSmbStatus({
    required this.configured,
    required this.shareName,
    required this.mountRoot,
    required this.shareRegistered,
    required this.startedAt,
    required Iterable<PterodactylSmbMountStatus> mounts,
  }) : mounts = List<PterodactylSmbMountStatus>.unmodifiable(mounts);

  final bool configured;
  final String? shareName;
  final String? mountRoot;
  final bool shareRegistered;
  final DateTime? startedAt;
  final List<PterodactylSmbMountStatus> mounts;

  /// Whether the user-visible local Drive is fully mounted.
  ///
  /// Native SMB publication is optional and deliberately does not affect the
  /// health of the local Drive.
  bool get running => localDriveRunning;

  bool get localDriveRunning =>
      mounts.isNotEmpty &&
      mounts.every((PterodactylSmbMountStatus mount) => mount.running);

  bool get smbShared => shareRegistered;

  int get runningMounts =>
      mounts.where((PterodactylSmbMountStatus mount) => mount.running).length;
}
