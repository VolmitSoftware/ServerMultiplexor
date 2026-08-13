import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'pterodactyl_models.dart';
import 'pterodactyl_profile.dart';
import 'pterodactyl_sftp_key_store.dart';
import 'pterodactyl_sftp_password_store.dart';
import 'pterodactyl_smb_models.dart';
import 'pterodactyl_smb_process.dart';
import 'pterodactyl_smb_runtime_store.dart';
import 'pterodactyl_smb_settings_store.dart';
import 'pterodactyl_smb_share.dart';

typedef PterodactylSmbProfileLoader = PterodactylProfile? Function(String id);
typedef PterodactylSmbServerLoader =
    Future<List<PterodactylClientServer>> Function(String profileId);
typedef PterodactylSmbPanelUsernameLoader =
    Future<String> Function(String profileId);
typedef PterodactylSmbSshKeyRegistrar =
    Future<void> Function(
      String profileId, {
      required String name,
      required String publicKey,
    });

/// Returns the user-visible root used for fresh Multiplexor Drive installs.
///
/// Supplying the operating system and environment makes the platform policy
/// independently testable without mutating the process environment.
String defaultPterodactylDriveRoot({
  required PterodactylSmbOperatingSystem operatingSystem,
  required Map<String, String> environment,
  String? fallbackDirectory,
}) {
  if (operatingSystem == PterodactylSmbOperatingSystem.windows) {
    String home = (environment['USERPROFILE'] ?? '').trim();
    if (home.isEmpty) {
      home =
          '${environment['HOMEDRIVE'] ?? ''}'
                  '${environment['HOMEPATH'] ?? ''}'
              .trim();
    }
    if (home.isNotEmpty && p.windows.isAbsolute(home)) {
      return p.windows.join(home, 'Multiplexor Drive');
    }
    final String fallback = fallbackDirectory ?? Directory.current.path;
    return p.windows.join(fallback, 'Multiplexor Drive');
  }
  final String home = (environment['HOME'] ?? '').trim();
  if (home.isNotEmpty && p.posix.isAbsolute(home) && home != '/') {
    return p.posix.join(home, 'Multiplexor Drive');
  }
  return p.join(
    fallbackDirectory ?? Directory.current.path,
    'Multiplexor Drive',
  );
}

/// Mounts every configured Panel account through rclone/SFTP into one local,
/// user-visible Multiplexor Drive. Publishing that root through the host's
/// authenticated SMB service remains available as an optional compatibility
/// feature.
///
/// No API key or Panel password is written to settings, runtime state, argv, or
/// logs. Passwords are obscured over stdin and exist only in each rclone child
/// environment; SSH-agent authentication avoids even that runtime fallback.
final class PterodactylSmbService {
  PterodactylSmbService({
    required String metadataDirectoryPath,
    required PterodactylSmbProfileLoader loadProfile,
    required PterodactylSmbServerLoader loadServers,
    PterodactylSmbPanelUsernameLoader? loadPanelUsername,
    PterodactylSmbSshKeyRegistrar? ensureSshPublicKey,
    PterodactylSmbSettingsStore? settingsStore,
    PterodactylSmbRuntimeStore? runtimeStore,
    PterodactylSftpPasswordProvider? passwordProvider,
    PterodactylSmbProcessRunner? processRunner,
    PterodactylSmbOperatingSystem? operatingSystem,
    PterodactylSmbShareManager? shareManager,
    PterodactylSftpKeyStore? keyStore,
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.mountReadyTimeout = const Duration(seconds: 8),
    this.unmountReadyTimeout = const Duration(seconds: 5),
  }) : _metadataDirectoryPath = p.normalize(metadataDirectoryPath),
       _loadProfile = loadProfile,
       _loadServers = loadServers,
       _loadPanelUsername = loadPanelUsername,
       _ensureSshPublicKey = ensureSshPublicKey,
       _settingsStore =
           settingsStore ?? PterodactylSmbSettingsStore(metadataDirectoryPath),
       _runtimeStore =
           runtimeStore ?? PterodactylSmbRuntimeStore(metadataDirectoryPath),
       _passwordProvider = passwordProvider ?? PterodactylSftpPasswordStore(),
       _runner = processRunner ?? const DartIoPterodactylSmbProcessRunner(),
       _keyStore =
           keyStore ??
           PterodactylSftpKeyStore(
             metadataDirectoryPath: metadataDirectoryPath,
             runner: processRunner ?? const DartIoPterodactylSmbProcessRunner(),
           ),
       _operatingSystem =
           operatingSystem ?? detectPterodactylSmbOperatingSystem(),
       _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now,
       _shareManager =
           shareManager ??
           PterodactylSmbShareManager(
             runner: processRunner ?? const DartIoPterodactylSmbProcessRunner(),
             operatingSystem:
                 operatingSystem ?? detectPterodactylSmbOperatingSystem(),
             environment: environment,
           );

  static const String _rootMarkerName = '.multiplexor-drive.json';
  static const String _legacyRootMarkerName = '.multiplexor-smb-root.json';

  final String _metadataDirectoryPath;
  final PterodactylSmbProfileLoader _loadProfile;
  final PterodactylSmbServerLoader _loadServers;
  final PterodactylSmbPanelUsernameLoader? _loadPanelUsername;
  final PterodactylSmbSshKeyRegistrar? _ensureSshPublicKey;
  final PterodactylSmbSettingsStore _settingsStore;
  final PterodactylSmbRuntimeStore _runtimeStore;
  final PterodactylSftpPasswordProvider _passwordProvider;
  final PterodactylSmbProcessRunner _runner;
  final PterodactylSftpKeyStore _keyStore;
  final PterodactylSmbOperatingSystem _operatingSystem;
  final PterodactylSmbShareManager _shareManager;
  final Map<String, String> _environment;
  final DateTime Function() _clock;
  final Duration mountReadyTimeout;
  final Duration unmountReadyTimeout;
  final Set<String> _scannedHostKeys = <String>{};

  PterodactylSmbSettings? get settings => _settingsStore.load();

  String get drivePath => (settings ?? defaultSettings()).mountRoot;

  PterodactylSmbSettings defaultSettings() => PterodactylSmbSettings(
    shareName: 'Multiplexor Drive',
    mountRoot: defaultPterodactylDriveRoot(
      operatingSystem: _operatingSystem,
      environment: _environment,
      fallbackDirectory: p.dirname(_metadataDirectoryPath),
    ),
    knownHostsFile: _defaultKnownHostsFile(),
    accounts: const <PterodactylSftpAccount>[],
  );

  PterodactylSmbSettings configureShare({
    String? shareName,
    String? mountRoot,
    String? knownHostsFile,
    bool? requireSmbEncryption,
  }) {
    _requireStoppedForConfiguration();
    final PterodactylSmbSettings current = settings ?? defaultSettings();
    final PterodactylSmbSettings updated = current.copyWith(
      shareName: shareName,
      mountRoot: _driveRootForUpdate(current, mountRoot),
      knownHostsFile: knownHostsFile,
      requireSmbEncryption: requireSmbEncryption,
    );
    _validateSharePaths(updated);
    _scannedHostKeys.clear();
    _settingsStore.save(updated);
    return updated;
  }

  Future<PterodactylSmbSettings> configureAccount({
    required String profileId,
    String? panelUsername,
    bool enabled = true,
    bool provisionSshKey = true,
  }) => configureAccounts(
    profileIds: <String>[profileId],
    panelUsernames: panelUsername?.trim().isNotEmpty == true
        ? <String, String>{profileId: panelUsername!}
        : const <String, String>{},
    enabled: enabled,
    provisionSshKeys: provisionSshKey,
  );

  /// Prepares accounts and passwordless identities for a local Drive install.
  ///
  /// Host keys are intentionally not trusted here. The caller must display
  /// [scanHostKeys] results and explicitly pass approved keys to
  /// [trustHostKeys] before the Drive can start.
  Future<PterodactylSmbSettings> installDrive({
    required Iterable<String> profileIds,
    Map<String, String> panelUsernames = const <String, String>{},
    bool provisionSshKeys = true,
    String? mountRoot,
    String? knownHostsFile,
  }) async {
    if (_runtimeStore.load() != null) await stopDrive();
    return configureAccounts(
      profileIds: profileIds,
      panelUsernames: panelUsernames,
      provisionSshKeys: provisionSshKeys,
      mountRoot: mountRoot,
      knownHostsFile: knownHostsFile,
    );
  }

  /// Configures multiple SFTP accounts and optional share changes with one
  /// local settings commit.
  ///
  /// Account identity lookup, local key preparation, and idempotent remote key
  /// registration all finish before settings are saved. If any preparation
  /// fails, the prior settings file remains byte-for-byte unchanged. Keys
  /// already generated or registered remain safe to reuse on the next attempt.
  Future<PterodactylSmbSettings> configureAccounts({
    required Iterable<String> profileIds,
    Map<String, String> panelUsernames = const <String, String>{},
    bool enabled = true,
    bool provisionSshKeys = true,
    String? shareName,
    String? mountRoot,
    String? knownHostsFile,
    bool? requireSmbEncryption,
  }) async {
    _requireStoppedForConfiguration();
    final List<String> normalizedProfileIds = <String>[];
    final Set<String> seenProfileIds = <String>{};
    for (final String profileId in profileIds) {
      final String normalized = PterodactylProfile.normalizeId(profileId);
      if (!seenProfileIds.add(normalized)) {
        throw ArgumentError('Duplicate Pterodactyl profile: $normalized');
      }
      normalizedProfileIds.add(normalized);
    }
    if (normalizedProfileIds.isEmpty) {
      throw ArgumentError.value(
        profileIds,
        'profileIds',
        'At least one Pterodactyl profile is required.',
      );
    }

    final Map<String, String> normalizedUsernames = <String, String>{};
    for (final MapEntry<String, String> entry in panelUsernames.entries) {
      final String profileId = PterodactylProfile.normalizeId(entry.key);
      if (!seenProfileIds.contains(profileId)) {
        throw ArgumentError(
          'A username was supplied for unrequested profile $profileId.',
        );
      }
      if (normalizedUsernames.containsKey(profileId)) {
        throw ArgumentError('Duplicate username override for $profileId.');
      }
      final String username = entry.value.trim();
      if (username.isEmpty) {
        throw ArgumentError('The username override for $profileId is empty.');
      }
      normalizedUsernames[profileId] = username;
    }

    final PterodactylSmbSettings current = settings ?? defaultSettings();
    PterodactylSmbSettings updated = current.copyWith(
      shareName: shareName,
      mountRoot: _driveRootForUpdate(current, mountRoot),
      knownHostsFile: knownHostsFile,
      requireSmbEncryption: requireSmbEncryption,
    );
    _validateSharePaths(updated);

    for (final String profileId in normalizedProfileIds) {
      final PterodactylProfile? profile = _loadProfile(profileId);
      if (profile == null) {
        throw StateError('Unknown Pterodactyl profile: $profileId');
      }
      final String resolvedUsername =
          normalizedUsernames[profile.id] ??
          await _requirePanelUsernameLoader()(profile.id);
      final PterodactylSftpAccount account = PterodactylSftpAccount(
        profileId: profile.id,
        panelUsername: resolvedUsername,
        enabled: enabled,
        useManagedKey: provisionSshKeys,
      );
      if (provisionSshKeys) {
        await _provisionSshKey(profile);
      }
      updated = updated.withAccount(account);
    }

    _scannedHostKeys.clear();
    _settingsStore.save(updated);
    return updated;
  }

  Future<PterodactylSmbSettings> removeAccount(String profileId) async {
    _requireStoppedForConfiguration();
    final PterodactylSmbSettings current = settings ?? defaultSettings();
    final PterodactylSftpAccount? account =
        current.accounts[profileId.trim().toLowerCase()];
    if (account != null) {
      final PterodactylProfile? profile = _loadProfile(account.profileId);
      if (profile != null) {
        await _passwordProvider.remove(profile, account);
      }
    }
    final PterodactylSmbSettings updated = current.withoutAccount(profileId);
    _scannedHostKeys.clear();
    _settingsStore.save(updated);
    return updated;
  }

  Future<void> enrollPassword(String profileId) async {
    final ({PterodactylProfile profile, PterodactylSftpAccount account}) pair =
        _resolveAccount(profileId);
    await _passwordProvider.enroll(pair.profile, pair.account);
  }

  Future<void> authorizeShare() => _shareManager.authorize();

  /// Scans the currently configured Wings SFTP endpoints without trusting
  /// them. The returned fingerprints must be shown to the operator before
  /// [trustHostKeys] is called with the explicitly approved candidates.
  Future<List<PterodactylSshHostKeyCandidate>> scanHostKeys() async {
    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      throw StateError('Install Multiplexor Drive first.');
    }
    if (!await _runner.executableExists('ssh-keyscan') ||
        !await _runner.executableExists('ssh-keygen')) {
      throw StateError('OpenSSH ssh-keyscan and ssh-keygen are required.');
    }
    final List<PterodactylSmbMountTarget> targets = await _loadTargets(
      configured,
    );
    final Map<String, PterodactylSmbMountTarget> endpoints =
        <String, PterodactylSmbMountTarget>{};
    for (final PterodactylSmbMountTarget target in targets) {
      endpoints['${target.host}\n${target.port}'] = target;
    }
    _scannedHostKeys.clear();
    final List<PterodactylSshHostKeyCandidate> candidates =
        <PterodactylSshHostKeyCandidate>[];
    for (final PterodactylSmbMountTarget endpoint in endpoints.values) {
      final PterodactylSmbCommandResult scanned = await _runner.run(
        'ssh-keyscan',
        <String>[
          '-T',
          '5',
          '-p',
          '${endpoint.port}',
          '-t',
          'ed25519,ecdsa,rsa',
          '--',
          endpoint.host,
        ],
      );
      final List<String> lines = scanned.stdout
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty && !line.startsWith('#'))
          .toList(growable: false);
      if (lines.isEmpty) {
        throw StateError(
          'No SSH host key was returned by ${endpoint.host}:${endpoint.port}.',
        );
      }
      for (final String line in lines) {
        final List<String> fields = line.split(RegExp(r'\s+'));
        if (fields.length != 3 ||
            !_validKnownHostsHost(fields[0], endpoint.host, endpoint.port) ||
            !_validHostKeyType(fields[1]) ||
            !RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(fields[2])) {
          throw StateError(
            'ssh-keyscan returned a malformed key for '
            '${endpoint.host}:${endpoint.port}.',
          );
        }
        final PterodactylSmbCommandResult fingerprinted = await _runner.run(
          'ssh-keygen',
          const <String>['-lf', '-', '-E', 'sha256'],
          stdinText: '$line\n',
        );
        final RegExpMatch? match = RegExp(
          r'\b(SHA256:[A-Za-z0-9+/]+={0,2})\b',
        ).firstMatch(fingerprinted.stdout);
        if (fingerprinted.exitCode != 0 || match == null) {
          throw StateError(
            'Unable to fingerprint the SSH host key for '
            '${endpoint.host}:${endpoint.port}.',
          );
        }
        final PterodactylSshHostKeyCandidate candidate =
            PterodactylSshHostKeyCandidate(
              host: endpoint.host,
              port: endpoint.port,
              keyType: fields[1],
              knownHostsLine: line,
              fingerprint: match.group(1)!,
            );
        candidates.add(candidate);
        _scannedHostKeys.add(_hostKeyCandidateIdentity(candidate));
      }
    }
    candidates.sort((
      PterodactylSshHostKeyCandidate left,
      PterodactylSshHostKeyCandidate right,
    ) {
      final int endpoint = left.endpoint.compareTo(right.endpoint);
      return endpoint != 0 ? endpoint : left.keyType.compareTo(right.keyType);
    });
    return List<PterodactylSshHostKeyCandidate>.unmodifiable(candidates);
  }

  /// Atomically merges only candidates that were returned by [scanHostKeys].
  /// Passing an empty list is a no-op; this method never scans or auto-trusts.
  Future<void> trustHostKeys(
    Iterable<PterodactylSshHostKeyCandidate> confirmed,
  ) async {
    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      throw StateError('Install Multiplexor Drive first.');
    }
    final List<PterodactylSshHostKeyCandidate> candidates = confirmed.toList(
      growable: false,
    );
    if (candidates.isEmpty) return;
    for (final PterodactylSshHostKeyCandidate candidate in candidates) {
      final List<String> fields = candidate.knownHostsLine.split(
        RegExp(r'\s+'),
      );
      if (fields.length != 3 ||
          fields[1] != candidate.keyType ||
          !_validKnownHostsHost(fields[0], candidate.host, candidate.port) ||
          !_validHostKeyType(candidate.keyType) ||
          !RegExp(
            r'^SHA256:[A-Za-z0-9+/]+={0,2}$',
          ).hasMatch(candidate.fingerprint)) {
        throw const FormatException('Invalid SSH host-key candidate.');
      }
      if (!_scannedHostKeys.contains(_hostKeyCandidateIdentity(candidate))) {
        throw StateError(
          'SSH host keys must be scanned and fingerprint-confirmed in this '
          'session before they can be trusted.',
        );
      }
    }
    final File knownHosts = File(configured.knownHostsFile);
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      knownHosts.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw StateError('The SSH known-hosts path must be a real file.');
    }
    final Set<String> lines = <String>{};
    if (knownHosts.existsSync()) {
      lines.addAll(
        knownHosts
            .readAsLinesSync()
            .map((String line) => line.trim())
            .where((String line) => line.isNotEmpty),
      );
    }
    lines.addAll(
      candidates.map(
        (PterodactylSshHostKeyCandidate candidate) => candidate.knownHostsLine,
      ),
    );
    knownHosts.parent.createSync(recursive: true);
    final File temporary = File(
      '${knownHosts.path}.tmp-$pid-${_clock().microsecondsSinceEpoch}',
    );
    try {
      final List<String> ordered = lines.toList()..sort();
      temporary.writeAsStringSync('${ordered.join('\n')}\n', flush: true);
      if (!Platform.isWindows) {
        final PterodactylSmbCommandResult permissions = await _runner.run(
          'chmod',
          <String>['600', temporary.path],
        );
        if (permissions.exitCode != 0) {
          throw StateError('Unable to secure the SSH known-hosts file.');
        }
      }
      temporary.renameSync(knownHosts.path);
      _scannedHostKeys.clear();
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  Future<PterodactylSmbDoctorReport> doctor({
    bool includeSmbShare = false,
  }) async {
    final List<PterodactylSmbCheck> checks = <PterodactylSmbCheck>[];
    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      checks.add(
        const PterodactylSmbCheck(
          name: 'configuration',
          level: PterodactylSmbCheckLevel.error,
          message: 'Configure at least one Pterodactyl SFTP account first.',
        ),
      );
    } else if (configured.enabledAccounts.isEmpty) {
      checks.add(
        const PterodactylSmbCheck(
          name: 'configuration',
          level: PterodactylSmbCheckLevel.error,
          message: 'No Pterodactyl SFTP account is enabled.',
        ),
      );
    } else {
      checks.add(
        PterodactylSmbCheck(
          name: 'configuration',
          level: PterodactylSmbCheckLevel.ready,
          message:
              '${configured.enabledAccounts.length} account(s) will be mounted.',
        ),
      );
    }

    final bool rcloneAvailable = await _runner.executableExists('rclone');
    checks.add(
      PterodactylSmbCheck(
        name: 'rclone',
        level: rcloneAvailable
            ? PterodactylSmbCheckLevel.ready
            : PterodactylSmbCheckLevel.error,
        message: rcloneAvailable
            ? 'rclone is available.'
            : 'Install rclone to mount the remote SFTP filesystems.',
      ),
    );
    checks.add(await _fuseCheck());
    if (includeSmbShare) {
      checks.addAll(await _shareManager.doctor());
    }

    final bool sshKeygenAvailable = await _runner.executableExists(
      'ssh-keygen',
    );
    checks.add(
      PterodactylSmbCheck(
        name: 'ssh-keygen',
        level: sshKeygenAvailable
            ? PterodactylSmbCheckLevel.ready
            : PterodactylSmbCheckLevel.error,
        message: sshKeygenAvailable
            ? 'Per-profile ed25519 SFTP identities can be managed.'
            : 'Install OpenSSH ssh-keygen for passwordless SFTP onboarding.',
      ),
    );

    if (configured != null) {
      final File knownHosts = File(configured.knownHostsFile);
      bool knownHostsReady = false;
      String hostKeyMessage;
      try {
        final List<PterodactylSmbMountTarget> targets = await _loadTargets(
          configured,
        );
        final Set<String> trustedHosts = knownHosts.existsSync()
            ? knownHosts
                  .readAsLinesSync()
                  .map((String line) => line.trim())
                  .where(
                    (String line) => line.isNotEmpty && !line.startsWith('#'),
                  )
                  .map((String line) => line.split(RegExp(r'\s+')).first)
                  .toSet()
            : <String>{};
        final Set<String> missing = <String>{
          for (final PterodactylSmbMountTarget target in targets)
            if (!_knownHostsTokens(
              target.host,
              target.port,
            ).any(trustedHosts.contains))
              '${target.host}:${target.port}',
        };
        knownHostsReady = targets.isNotEmpty && missing.isEmpty;
        hostKeyMessage = knownHostsReady
            ? 'Every configured Wings SFTP endpoint has a pinned host key.'
            : missing.isEmpty
            ? 'No Wings SFTP endpoints are available to verify.'
            : 'Missing pinned SSH host keys for: ${missing.join(', ')}.';
      } catch (error) {
        hostKeyMessage = 'Unable to verify configured SFTP host keys: $error';
      }
      checks.add(
        PterodactylSmbCheck(
          name: 'ssh-host-keys',
          level: knownHostsReady
              ? PterodactylSmbCheckLevel.ready
              : PterodactylSmbCheckLevel.error,
          message: knownHostsReady
              ? hostKeyMessage
              : '$hostKeyMessage Run remote drive trust, confirm each SHA256 '
                    'fingerprint, then persist the selected Wings SFTP host '
                    'keys.',
        ),
      );
      checks.add(_mountRootCheck(configured));
      final bool agentAvailable = (_environment['SSH_AUTH_SOCK'] ?? '')
          .trim()
          .isNotEmpty;
      for (final PterodactylSftpAccount account in configured.enabledAccounts) {
        final PterodactylProfile? profile = _loadProfile(account.profileId);
        if (profile == null) {
          checks.add(
            PterodactylSmbCheck(
              name: 'account:${account.profileId}',
              level: PterodactylSmbCheckLevel.error,
              message: 'The saved Panel profile no longer exists.',
            ),
          );
          continue;
        }
        final bool hasPassword = await _passwordProvider.contains(
          profile,
          account,
        );
        final bool hasKey = _keyStore.hasPrivateKey(profile);
        final bool canProvisionKey =
            account.useManagedKey &&
            _ensureSshPublicKey != null &&
            sshKeygenAvailable;
        checks.add(
          PterodactylSmbCheck(
            name: 'account:${account.profileId}',
            level:
                (account.useManagedKey && hasKey) ||
                    canProvisionKey ||
                    hasPassword ||
                    agentAvailable
                ? PterodactylSmbCheckLevel.ready
                : PterodactylSmbCheckLevel.error,
            message: account.useManagedKey && hasKey
                ? 'A per-profile ed25519 SFTP identity is available.'
                : canProvisionKey
                ? 'An ed25519 SFTP identity will be generated and registered.'
                : hasPassword
                ? 'A secured SFTP password is available.'
                : agentAvailable
                ? 'SFTP will authenticate through the SSH agent.'
                : 'Add the account SSH key to an agent or enroll its Panel '
                      'password. API keys cannot authenticate Pterodactyl SFTP.',
          ),
        );
      }
    }
    return PterodactylSmbDoctorReport(checks);
  }

  Future<PterodactylSmbStatus> status() async {
    final PterodactylSmbSettings? configured = settings;
    final PterodactylSmbRuntimeState? runtime = _runtimeStore.load();
    if (runtime == null) {
      return PterodactylSmbStatus(
        configured: configured != null,
        shareName: configured?.shareName,
        mountRoot: configured?.mountRoot,
        shareRegistered: false,
        startedAt: null,
        mounts: const <PterodactylSmbMountStatus>[],
      );
    }
    final List<PterodactylSmbMountStatus> mounts =
        <PterodactylSmbMountStatus>[];
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts) {
      final String? description = await _runner.describeProcess(mount.pid);
      final bool visible = await _mountIsVisible(mount.mountPath);
      mounts.add(
        PterodactylSmbMountStatus(
          profileId: mount.profileId,
          serverIdentifier: mount.serverIdentifier,
          serverName: mount.serverName,
          mountPath: mount.mountPath,
          pid: mount.pid,
          running:
              visible &&
              description != null &&
              _isOwnedRclone(description, mount),
        ),
      );
    }
    final bool shareRegistered =
        runtime.shareRegistered &&
        await _shareManager.exists(runtime.shareName);
    return PterodactylSmbStatus(
      configured: configured != null,
      shareName: runtime.shareName,
      mountRoot: runtime.mountRoot,
      shareRegistered: shareRegistered,
      startedAt: runtime.startedAt,
      mounts: mounts,
    );
  }

  /// Starts or repairs the local Multiplexor Drive without registering an SMB
  /// network share or requesting administrator authorization.
  Future<PterodactylSmbStatus> startDrive() => _start(registerSmbShare: false);

  /// Legacy compatibility entry point that also publishes the Drive over SMB.
  Future<PterodactylSmbStatus> start() => startSmbShare();

  Future<PterodactylSmbStatus> startSmbShare() =>
      _start(registerSmbShare: true);

  Future<PterodactylSmbStatus> _start({required bool registerSmbShare}) async {
    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      throw StateError('Install Multiplexor Drive first.');
    }
    final PterodactylSmbRuntimeState? existing = _runtimeStore.load();
    if (existing != null) {
      final PterodactylSmbStatus current = await status();
      final List<PterodactylSmbMountTarget> expectedTargets =
          await _loadTargets(configured);
      final bool targetsMatch = _runtimeTargetsMatch(
        existing,
        configured,
        expectedTargets,
      );
      if (current.localDriveRunning && targetsMatch) {
        if (!registerSmbShare || current.shareRegistered) return current;
        if (await _shareManager.exists(configured.shareName)) {
          throw StateError(
            'An SMB share named ${configured.shareName} already exists and is '
            'not owned by this Multiplexor runtime.',
          );
        }
        final PterodactylSmbDoctorReport shareReport = await doctor(
          includeSmbShare: true,
        );
        _throwIfDoctorNotReady(shareReport, noun: 'SMB');
        await _shareManager.create(configured);
        _runtimeStore.save(
          PterodactylSmbRuntimeState(
            shareName: existing.shareName,
            mountRoot: existing.mountRoot,
            startedAt: existing.startedAt,
            shareRegistered: true,
            mounts: existing.mounts,
          ),
        );
        return status();
      }
      await stop();
    }
    if (registerSmbShare && await _shareManager.exists(configured.shareName)) {
      throw StateError(
        'An SMB share named ${configured.shareName} already exists and is not '
        'owned by this Multiplexor runtime.',
      );
    }
    final PterodactylSmbDoctorReport report = await doctor(
      includeSmbShare: registerSmbShare,
    );
    _throwIfDoctorNotReady(report, noun: registerSmbShare ? 'SMB' : 'Drive');

    final List<PterodactylSmbMountTarget> targets = await _loadTargets(
      configured,
    );
    if (targets.isEmpty) {
      throw StateError('No accessible Pterodactyl server files were found.');
    }
    _prepareOwnedRoot(configured, targets);

    final Map<String, _PterodactylSftpMountAuth> authentications =
        <String, _PterodactylSftpMountAuth>{};
    for (final PterodactylSftpAccount account in configured.enabledAccounts) {
      final PterodactylProfile profile = _requireProfile(account.profileId);
      authentications[account.profileId] = await _mountAuthentication(
        profile,
        account,
      );
    }

    PterodactylSmbRuntimeState runtime = PterodactylSmbRuntimeState(
      shareName: configured.shareName,
      mountRoot: configured.mountRoot,
      startedAt: _clock().toUtc(),
      shareRegistered: false,
      mounts: const <PterodactylSmbRuntimeMount>[],
    );
    _runtimeStore.save(runtime);
    final List<PterodactylSmbProcessHandle> handles =
        <PterodactylSmbProcessHandle>[];
    try {
      for (final PterodactylSmbMountTarget target in targets) {
        final String mountPath = target.mountPath(configured);
        final Map<String, String> mountEnvironment = _mountEnvironment(
          target,
          configured,
          authentications[target.profileId]!,
        );
        final List<String> arguments = _mountArguments(target, configured);
        final PterodactylSmbProcessHandle process = await _runner.start(
          'rclone',
          arguments,
          environment: mountEnvironment,
        );
        handles.add(process);
        final PterodactylSmbRuntimeMount runtimeMount =
            PterodactylSmbRuntimeMount(
              profileId: target.profileId,
              serverIdentifier: target.serverIdentifier,
              serverName: target.serverName,
              mountPath: mountPath,
              remoteName: target.remoteName,
              pid: process.pid,
              connectionSignature: target.connectionSignature,
            );
        runtime = PterodactylSmbRuntimeState(
          shareName: runtime.shareName,
          mountRoot: runtime.mountRoot,
          startedAt: runtime.startedAt,
          shareRegistered: false,
          mounts: <PterodactylSmbRuntimeMount>[...runtime.mounts, runtimeMount],
        );
        _runtimeStore.save(runtime);
        final int? earlyExit = await process.waitForExit(
          const Duration(milliseconds: 750),
        );
        if (earlyExit != null) {
          throw StateError(
            'SFTP mount for ${target.serverName} exited with code $earlyExit'
            '${process.diagnostic.isEmpty ? '.' : ': ${process.diagnostic}'}',
          );
        }
        if (!await _waitForMount(runtimeMount)) {
          throw StateError(
            'SFTP mount for ${target.serverName} did not become ready'
            '${process.diagnostic.isEmpty ? '.' : ': ${process.diagnostic}'}',
          );
        }
      }

      if (registerSmbShare) {
        await _shareManager.create(configured);
        runtime = PterodactylSmbRuntimeState(
          shareName: runtime.shareName,
          mountRoot: runtime.mountRoot,
          startedAt: runtime.startedAt,
          shareRegistered: true,
          mounts: runtime.mounts,
        );
        _runtimeStore.save(runtime);
      }
      return await status();
    } catch (_) {
      await _rollbackStart(runtime, handles, configured.mountRoot);
      rethrow;
    }
  }

  static void _throwIfDoctorNotReady(
    PterodactylSmbDoctorReport report, {
    required String noun,
  }) {
    if (report.isReady) return;
    final String errors = report.checks
        .where(
          (PterodactylSmbCheck check) =>
              check.level == PterodactylSmbCheckLevel.error,
        )
        .map((PterodactylSmbCheck check) => check.message)
        .join(' ');
    throw StateError('$noun prerequisites are not ready. $errors');
  }

  Future<PterodactylSmbStatus> stop() async {
    final PterodactylSmbRuntimeState? runtime = _runtimeStore.load();
    if (runtime == null) return status();

    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      throw StateError(
        'Refusing to stop Drive mounts without their saved configuration.',
      );
    }
    final String trustedRoot = p.normalize(configured.mountRoot);
    if (!p.equals(p.normalize(runtime.mountRoot), trustedRoot)) {
      throw StateError(
        'Refusing to stop Drive mounts outside the configured Drive root.',
      );
    }
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts) {
      if (!_runtimeMountIsWithinRoot(mount, trustedRoot)) {
        throw StateError(
          'Refusing to stop an invalid Drive mount path for '
          '${mount.serverIdentifier}. Runtime state was left unchanged.',
        );
      }
    }

    final List<String> conflicts = <String>[];
    final Set<int> liveOwnedPids = <int>{};
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts) {
      final String? description = await _runner.describeProcess(mount.pid);
      if (description == null) continue;
      if (!_isOwnedRclone(description, mount)) {
        conflicts.add('${mount.pid} (${mount.serverIdentifier})');
      } else {
        liveOwnedPids.add(mount.pid);
      }
    }
    if (conflicts.isNotEmpty) {
      throw StateError(
        'Refusing to stop unrelated process ID(s): ${conflicts.join(', ')}. '
        'The Drive and runtime state were left unchanged for manual '
        'recovery.',
      );
    }

    if (runtime.shareRegistered &&
        await _shareManager.exists(runtime.shareName)) {
      await _shareManager.remove(runtime.shareName);
    }
    final PterodactylSmbRuntimeState recoveryState = PterodactylSmbRuntimeState(
      shareName: runtime.shareName,
      mountRoot: runtime.mountRoot,
      startedAt: runtime.startedAt,
      shareRegistered: false,
      mounts: runtime.mounts,
    );
    _runtimeStore.save(recoveryState);
    final List<String> stopFailures = <String>[];
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts.reversed) {
      if (liveOwnedPids.contains(mount.pid)) {
        final String? description = await _runner.describeProcess(mount.pid);
        if (description != null && !_isOwnedRclone(description, mount)) {
          stopFailures.add(
            '${mount.serverIdentifier}: process ownership changed while '
            'stopping',
          );
          continue;
        }
        if (description != null) {
          _runner.killPid(mount.pid);
          await _waitForProcessExit(mount);
        }
      }
      try {
        await _unmount(mount);
      } catch (error) {
        stopFailures.add('${mount.serverIdentifier}: $error');
      }
    }
    if (stopFailures.isNotEmpty) {
      throw StateError(
        'One or more Drive mounts could not be safely released: '
        '${stopFailures.join('; ')}. Runtime recovery state was retained; '
        'retry remote drive stop.',
      );
    }
    _runtimeStore.remove();
    return status();
  }

  Future<PterodactylSmbStatus> stopDrive() => stop();

  /// Resolves a server to its stable folder inside Multiplexor Drive.
  ///
  /// This does not start a mount or open the platform file manager.
  Future<String> resolveServerFolder({
    required String profileId,
    required String serverIdentifier,
  }) async {
    final String normalizedProfile = PterodactylProfile.normalizeId(profileId);
    final String normalizedIdentifier = _serverIdentifier(serverIdentifier);
    final PterodactylSmbSettings? configured = settings;
    final PterodactylSftpAccount? account =
        configured?.accounts[normalizedProfile];
    if (configured == null || account == null || !account.enabled) {
      throw StateError(
        'Profile $normalizedProfile is not installed in Multiplexor Drive.',
      );
    }
    _requireProfile(normalizedProfile);
    final List<PterodactylClientServer> servers = await _loadServers(
      normalizedProfile,
    );
    PterodactylClientServer? selected;
    for (final PterodactylClientServer server in servers) {
      if (server.identifier.toLowerCase() == normalizedIdentifier) {
        selected = server;
        break;
      }
    }
    if (selected == null) {
      throw StateError(
        'Server $serverIdentifier is not accessible through profile '
        '$normalizedProfile.',
      );
    }
    final String resolved = p.normalize(
      PterodactylSmbMountTarget.fromServer(
        account: account,
        server: selected,
      ).mountPath(configured),
    );
    if (!p.isWithin(configured.mountRoot, resolved)) {
      throw StateError('The generated Drive folder escaped its mount root.');
    }
    return resolved;
  }

  /// Ensures the Drive is mounted, then opens its root in the native file
  /// manager. Returns the absolute local path that was opened.
  Future<String> openDrive() async {
    await _ensureDriveMounted();
    final String path = p.normalize(drivePath);
    await _openLocalFolder(path);
    return path;
  }

  /// Installs the selected profile when needed, repairs the local mounts, and
  /// opens this server's folder in Finder, Explorer, or the Linux file manager.
  ///
  /// Unknown SSH host keys are never accepted here: [startDrive] still fails
  /// its pinned-host-key doctor check until the operator explicitly trusts the
  /// scanned fingerprints.
  Future<String> openServerFolder({
    required String profileId,
    required String serverIdentifier,
  }) async {
    final String normalizedProfile = PterodactylProfile.normalizeId(profileId);
    final String normalizedIdentifier = _serverIdentifier(serverIdentifier);
    final PterodactylSftpAccount? account =
        settings?.accounts[normalizedProfile];
    if (account == null || !account.enabled) {
      if (_runtimeStore.load() != null) await stopDrive();
      await configureAccount(profileId: normalizedProfile);
    }
    final PterodactylSmbStatus current = await _ensureDriveMounted(
      profileId: normalizedProfile,
      serverIdentifier: normalizedIdentifier,
    );
    final String path = current.mounts
        .singleWhere(
          (PterodactylSmbMountStatus mount) =>
              mount.running &&
              mount.profileId == normalizedProfile &&
              mount.serverIdentifier.toLowerCase() == normalizedIdentifier,
        )
        .mountPath;
    await _openLocalFolder(path);
    return path;
  }

  Future<PterodactylSmbStatus> _ensureDriveMounted({
    String? profileId,
    String? serverIdentifier,
  }) async {
    final PterodactylSmbStatus current = await startDrive();
    if (!current.localDriveRunning) {
      throw StateError('Multiplexor Drive did not become fully ready.');
    }
    if (profileId != null &&
        !current.mounts.any(
          (PterodactylSmbMountStatus mount) =>
              mount.running &&
              mount.profileId == profileId &&
              mount.serverIdentifier.toLowerCase() == serverIdentifier,
        )) {
      throw StateError(
        'The requested server did not appear in Multiplexor Drive.',
      );
    }
    return current;
  }

  Future<void> _openLocalFolder(String path) async {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      throw StateError('The Multiplexor Drive folder is unavailable: $path');
    }
    final (
      String executable,
      List<String> arguments,
    ) = switch (_operatingSystem) {
      PterodactylSmbOperatingSystem.macos => ('/usr/bin/open', <String>[path]),
      PterodactylSmbOperatingSystem.linux => ('xdg-open', <String>[path]),
      PterodactylSmbOperatingSystem.windows => ('explorer.exe', <String>[path]),
      PterodactylSmbOperatingSystem.unsupported => throw UnsupportedError(
        'Opening Multiplexor Drive is unsupported on this platform.',
      ),
    };
    final PterodactylSmbCommandResult result = await _runner.run(
      executable,
      arguments,
    );
    final bool success =
        result.exitCode == 0 ||
        (_operatingSystem == PterodactylSmbOperatingSystem.windows &&
            result.exitCode == 1);
    if (!success) {
      throw StateError(
        'Unable to open Multiplexor Drive'
        '${result.diagnostic.isEmpty ? '.' : ': ${result.diagnostic}'}',
      );
    }
  }

  static String _serverIdentifier(String value) {
    final String normalized = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9]{8}$').hasMatch(normalized)) {
      throw const FormatException(
        'Pterodactyl server identifiers must contain 8 letters or digits.',
      );
    }
    return normalized;
  }

  String connectionUrl() {
    final PterodactylSmbSettings? configured = settings;
    if (configured == null) {
      throw StateError('Configure the Multiplexor SMB share first.');
    }
    return _shareManager.connectionUrl(configured.shareName);
  }

  void _requireStoppedForConfiguration() {
    if (_runtimeStore.load() != null) {
      throw StateError('Stop Multiplexor Drive before configuring it.');
    }
  }

  ({PterodactylProfile profile, PterodactylSftpAccount account})
  _resolveAccount(String profileId) {
    final PterodactylSmbSettings? configured = settings;
    final PterodactylSftpAccount? account =
        configured?.accounts[profileId.trim().toLowerCase()];
    if (account == null) {
      throw StateError('No Drive account is configured for $profileId.');
    }
    return (profile: _requireProfile(account.profileId), account: account);
  }

  PterodactylProfile _requireProfile(String profileId) {
    final PterodactylProfile? profile = _loadProfile(profileId);
    if (profile == null) {
      throw StateError('Unknown Pterodactyl profile: $profileId');
    }
    return profile;
  }

  PterodactylSmbPanelUsernameLoader _requirePanelUsernameLoader() {
    final PterodactylSmbPanelUsernameLoader? loader = _loadPanelUsername;
    if (loader == null) {
      throw StateError(
        'Automatic Drive account setup needs the Panel account username. '
        'Provide it explicitly or wire the Client API account endpoint.',
      );
    }
    return loader;
  }

  Future<PterodactylSftpKeyPair> _provisionSshKey(
    PterodactylProfile profile,
  ) async {
    final PterodactylSmbSshKeyRegistrar? register = _ensureSshPublicKey;
    if (register == null) {
      throw StateError(
        'Automatic passwordless SFTP setup needs the Client API SSH-key '
        'endpoint.',
      );
    }
    final PterodactylSftpKeyPair pair = await _keyStore.ensure(profile);
    await register(profile.id, name: pair.name, publicKey: pair.publicKey);
    return pair;
  }

  String _defaultKnownHostsFile() {
    return p.join(_metadataDirectoryPath, 'pterodactyl-smb', 'known_hosts');
  }

  String? _driveRootForUpdate(
    PterodactylSmbSettings current,
    String? requested,
  ) {
    if (requested != null) return requested;
    final String legacyRoot = p.join(
      _metadataDirectoryPath,
      'pterodactyl-smb',
      'files',
    );
    return p.equals(current.mountRoot, legacyRoot)
        ? defaultSettings().mountRoot
        : null;
  }

  static bool _validHostKeyType(String value) => const <String>{
    'ssh-ed25519',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'ssh-rsa',
  }.contains(value);

  static bool _validKnownHostsHost(String value, String host, int port) {
    if (port == 22) return value == host || value == '[$host]:22';
    return value == '[$host]:$port';
  }

  static Set<String> _knownHostsTokens(String host, int port) =>
      port == 22 ? <String>{host, '[$host]:22'} : <String>{'[$host]:$port'};

  static String _hostKeyCandidateIdentity(
    PterodactylSshHostKeyCandidate candidate,
  ) =>
      '${candidate.host}\n${candidate.port}\n${candidate.keyType}\n'
      '${candidate.knownHostsLine}\n${candidate.fingerprint}';

  Future<PterodactylSmbCheck> _fuseCheck() async {
    switch (_operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        final bool mountNfsAvailable = await _runner.executableExists(
          '/sbin/mount_nfs',
        );
        final PterodactylSmbCommandResult commands = await _runner.run(
          'rclone',
          const <String>['nfsmount', '--help'],
        );
        final bool nfsmountAvailable = commands.exitCode == 0;
        final bool available = mountNfsAvailable && nfsmountAvailable;
        return PterodactylSmbCheck(
          name: 'nfs-mount',
          level: available
              ? PterodactylSmbCheckLevel.ready
              : PterodactylSmbCheckLevel.error,
          message: available
              ? 'rclone loopback NFS mounting is available.'
              : 'Install current rclone with nfsmount support; macOS '
                    '/sbin/mount_nfs is also required.',
        );
      case PterodactylSmbOperatingSystem.linux:
        final bool helper =
            await _runner.executableExists('fusermount3') ||
            await _runner.executableExists('fusermount');
        final bool available = File('/dev/fuse').existsSync() && helper;
        return PterodactylSmbCheck(
          name: 'fuse',
          level: available
              ? PterodactylSmbCheckLevel.ready
              : PterodactylSmbCheckLevel.error,
          message: available
              ? 'FUSE is available.'
              : 'Install FUSE 3 and grant access to /dev/fuse.',
        );
      case PterodactylSmbOperatingSystem.windows:
        final bool available = await _runner.executableExists('winfsp-x64.dll');
        return PterodactylSmbCheck(
          name: 'fuse',
          level: available
              ? PterodactylSmbCheckLevel.ready
              : PterodactylSmbCheckLevel.error,
          message: available
              ? 'WinFsp is available.'
              : 'Install WinFsp so rclone can mount each SFTP server.',
        );
      case PterodactylSmbOperatingSystem.unsupported:
        return const PterodactylSmbCheck(
          name: 'fuse',
          level: PterodactylSmbCheckLevel.error,
          message: 'FUSE mounting is unsupported on this platform.',
        );
    }
  }

  PterodactylSmbCheck _mountRootCheck(PterodactylSmbSettings configured) {
    final String? pathError = _sharePathError(configured);
    if (pathError != null) {
      return PterodactylSmbCheck(
        name: 'mount-root',
        level: PterodactylSmbCheckLevel.error,
        message: pathError,
      );
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      configured.mountRoot,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      return const PterodactylSmbCheck(
        name: 'mount-root',
        level: PterodactylSmbCheckLevel.error,
        message: 'The Drive root must be a real directory, not a link.',
      );
    }
    return PterodactylSmbCheck(
      name: 'mount-root',
      level: PterodactylSmbCheckLevel.ready,
      message: 'Aggregate files will be mounted at ${configured.mountRoot}.',
    );
  }

  void _validateSharePaths(PterodactylSmbSettings configured) {
    final String? error = _sharePathError(configured);
    if (error != null) throw StateError(error);
  }

  String? _sharePathError(PterodactylSmbSettings configured) {
    final String metadata = p.normalize(_metadataDirectoryPath);
    final String mountRoot = p.normalize(configured.mountRoot);
    final String dedicatedFilesRoot = p.join(
      metadata,
      'pterodactyl-smb',
      'files',
    );
    if (mountRoot == metadata || p.isWithin(mountRoot, metadata)) {
      return 'The Drive root cannot contain Multiplexor metadata.';
    }
    if (p.isWithin(metadata, mountRoot) &&
        mountRoot != dedicatedFilesRoot &&
        !p.isWithin(dedicatedFilesRoot, mountRoot)) {
      return 'Mount roots inside Multiplexor metadata must stay below the '
          'dedicated pterodactyl-smb/files directory.';
    }
    final String knownHosts = p.normalize(configured.knownHostsFile);
    if (knownHosts == mountRoot || p.isWithin(mountRoot, knownHosts)) {
      return 'The SSH known-hosts file cannot be exposed inside the Drive '
          'root.';
    }
    return null;
  }

  Future<List<PterodactylSmbMountTarget>> _loadTargets(
    PterodactylSmbSettings configured,
  ) async {
    final List<PterodactylSmbMountTarget> targets =
        <PterodactylSmbMountTarget>[];
    for (final PterodactylSftpAccount account in configured.enabledAccounts) {
      _requireProfile(account.profileId);
      final List<PterodactylClientServer> servers = await _loadServers(
        account.profileId,
      );
      for (final PterodactylClientServer server in servers) {
        if (server.sftpHost.trim().isEmpty ||
            server.sftpPort < 1 ||
            server.sftpPort > 65535) {
          throw StateError(
            'Server ${server.identifier} has invalid SFTP connection details.',
          );
        }
        targets.add(
          PterodactylSmbMountTarget.fromServer(
            account: account,
            server: server,
          ),
        );
      }
    }
    targets.sort((
      PterodactylSmbMountTarget left,
      PterodactylSmbMountTarget right,
    ) {
      final int profile = left.profileId.compareTo(right.profileId);
      return profile != 0
          ? profile
          : left.relativeDirectory.compareTo(right.relativeDirectory);
    });
    return targets;
  }

  bool _runtimeTargetsMatch(
    PterodactylSmbRuntimeState runtime,
    PterodactylSmbSettings configured,
    List<PterodactylSmbMountTarget> expected,
  ) {
    if (!p.equals(runtime.mountRoot, configured.mountRoot) ||
        runtime.mounts.length != expected.length) {
      return false;
    }
    final Map<String, PterodactylSmbRuntimeMount> actual =
        <String, PterodactylSmbRuntimeMount>{
          for (final PterodactylSmbRuntimeMount mount in runtime.mounts)
            '${mount.profileId}\n${mount.serverIdentifier.toLowerCase()}':
                mount,
        };
    if (actual.length != runtime.mounts.length) return false;
    for (final PterodactylSmbMountTarget target in expected) {
      final PterodactylSmbRuntimeMount? mount =
          actual['${target.profileId}\n${target.serverIdentifier.toLowerCase()}'];
      if (mount == null ||
          mount.serverName != target.serverName ||
          mount.remoteName != target.remoteName ||
          !p.equals(mount.mountPath, target.mountPath(configured)) ||
          mount.connectionSignature != target.connectionSignature) {
        return false;
      }
    }
    return true;
  }

  static bool _runtimeMountIsWithinRoot(
    PterodactylSmbRuntimeMount mount,
    String root,
  ) {
    final String mountPath = p.normalize(mount.mountPath);
    if (!p.isWithin(root, mountPath)) return false;
    final List<String> parts = p.split(p.relative(mountPath, from: root));
    return parts.length == 2 &&
        parts.every(
          (String part) => part.isNotEmpty && part != '.' && part != '..',
        );
  }

  void _prepareOwnedRoot(
    PterodactylSmbSettings configured,
    List<PterodactylSmbMountTarget> targets,
  ) {
    final Directory root = Directory(configured.mountRoot);
    final FileSystemEntityType rootType = FileSystemEntity.typeSync(
      root.path,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.link ||
        (rootType != FileSystemEntityType.notFound &&
            rootType != FileSystemEntityType.directory)) {
      throw StateError('The Drive root must be a real directory.');
    }
    if (!root.existsSync()) root.createSync(recursive: true);
    final File marker = File(p.join(root.path, _rootMarkerName));
    final File legacyMarker = File(p.join(root.path, _legacyRootMarkerName));
    final bool hasCurrentMarker = marker.existsSync();
    final bool hasLegacyMarker = legacyMarker.existsSync();
    final File ownershipMarker = hasCurrentMarker ? marker : legacyMarker;
    final FileSystemEntityType markerType = FileSystemEntity.typeSync(
      ownershipMarker.path,
      followLinks: false,
    );
    if (markerType == FileSystemEntityType.link ||
        (markerType != FileSystemEntityType.notFound &&
            markerType != FileSystemEntityType.file)) {
      throw StateError('The Drive ownership marker is invalid.');
    }
    if (markerType == FileSystemEntityType.notFound) {
      final List<FileSystemEntity> existing = root
          .listSync(followLinks: false)
          .where(
            (FileSystemEntity item) => p.basename(item.path) != '.DS_Store',
          )
          .toList(growable: false);
      if (existing.isNotEmpty) {
        throw StateError(
          'Refusing to mount over a non-empty directory not owned by '
          'Multiplexor: ${root.path}',
        );
      }
      marker.writeAsStringSync(
        '${jsonEncode(<String, Object?>{'schema_version': 1, 'owner': 'multiplexor-pterodactyl-drive'})}\n',
        flush: true,
      );
    } else {
      final Object? decoded;
      try {
        decoded = jsonDecode(ownershipMarker.readAsStringSync());
      } on FormatException {
        throw StateError('The Drive ownership marker is invalid.');
      }
      if (decoded is! Map<String, Object?> ||
          decoded['schema_version'] != 1 ||
          decoded['owner'] != 'multiplexor-pterodactyl-drive' &&
              decoded['owner'] != 'multiplexor-pterodactyl-smb') {
        throw StateError('The Drive ownership marker is invalid.');
      }
      if (!hasCurrentMarker && hasLegacyMarker) {
        legacyMarker.renameSync(marker.path);
        marker.writeAsStringSync(
          '${jsonEncode(<String, Object?>{'schema_version': 1, 'owner': 'multiplexor-pterodactyl-drive'})}\n',
          flush: true,
        );
      }
    }

    final Set<String> currentMountPaths = targets
        .map(
          (PterodactylSmbMountTarget target) =>
              p.normalize(target.mountPath(configured)),
        )
        .toSet();
    _pruneEmptyStaleMountDirectories(root, currentMountPaths);

    for (final PterodactylSmbMountTarget target in targets) {
      final String mountPath = target.mountPath(configured);
      if (!p.isWithin(root.path, mountPath)) {
        throw StateError('A generated SFTP mount escaped the Drive root.');
      }
      final Directory mount = Directory(mountPath);
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        mount.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)) {
        throw StateError('SFTP mount points must be real directories.');
      }
      if (!mount.existsSync() &&
          _operatingSystem == PterodactylSmbOperatingSystem.windows) {
        mount.parent.createSync(recursive: true);
      } else if (!mount.existsSync()) {
        mount.createSync(recursive: true);
      }
      if (!mount.existsSync()) continue;
      if (mount.listSync(followLinks: false).isNotEmpty) {
        throw StateError(
          'Refusing to hide local files under SFTP mount point: $mountPath',
        );
      }
    }
  }

  void _pruneEmptyStaleMountDirectories(
    Directory root,
    Set<String> currentMountPaths,
  ) {
    for (final FileSystemEntity profileEntity in root.listSync(
      followLinks: false,
    )) {
      if (profileEntity is! Directory) continue;
      for (final FileSystemEntity serverEntity in profileEntity.listSync(
        followLinks: false,
      )) {
        if (serverEntity is! Directory) continue;
        final String serverPath = p.normalize(serverEntity.path);
        if (!currentMountPaths.contains(serverPath) &&
            serverEntity.listSync(followLinks: false).isEmpty) {
          serverEntity.deleteSync();
        }
      }
      if (profileEntity.listSync(followLinks: false).isEmpty) {
        profileEntity.deleteSync();
      }
    }
  }

  Future<String> _obscurePassword(PterodactylSftpPassword password) async {
    final PterodactylSmbCommandResult result = await _runner.run(
      'rclone',
      const <String>['obscure', '-'],
      stdinText: password.value,
    );
    final String obscured = result.stdout.trim();
    if (result.exitCode != 0 || obscured.isEmpty) {
      throw StateError('rclone could not prepare the SFTP credential.');
    }
    return obscured;
  }

  Future<_PterodactylSftpMountAuth> _mountAuthentication(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async {
    Object? keyError;
    if (account.useManagedKey) {
      try {
        final PterodactylSftpKeyPair key = await _provisionSshKey(profile);
        return _PterodactylSftpMountAuth(privateKeyPath: key.privateKeyPath);
      } catch (error) {
        keyError = error;
      }
    }
    {
      final PterodactylSftpPassword? password = await _passwordProvider.read(
        profile,
        account,
      );
      if (password != null) {
        return _PterodactylSftpMountAuth(
          obscuredPassword: await _obscurePassword(password),
        );
      }
      if (account.useManagedKey &&
          _ensureSshPublicKey == null &&
          _keyStore.hasPrivateKey(profile)) {
        return _PterodactylSftpMountAuth(
          privateKeyPath: _keyStore.privateKeyPath(profile),
        );
      }
      if ((_environment['SSH_AUTH_SOCK'] ?? '').trim().isNotEmpty) {
        return const _PterodactylSftpMountAuth(useAgent: true);
      }
      throw StateError(
        'Unable to configure SFTP authentication for ${profile.id}'
        '${keyError == null ? '.' : ': $keyError'}',
      );
    }
  }

  Map<String, String> _mountEnvironment(
    PterodactylSmbMountTarget target,
    PterodactylSmbSettings configured,
    _PterodactylSftpMountAuth authentication,
  ) {
    final String prefix = target.environmentPrefix;
    return <String, String>{
      '${prefix}TYPE': 'sftp',
      '${prefix}HOST': target.host,
      '${prefix}PORT': '${target.port}',
      '${prefix}USER': target.sftpUsername,
      '${prefix}KNOWN_HOSTS_FILE': configured.knownHostsFile,
      '${prefix}SHELL_TYPE': 'none',
      '${prefix}DISABLE_HASHCHECK': 'true',
      if (authentication.privateKeyPath != null)
        '${prefix}KEY_FILE': authentication.privateKeyPath!,
      if (authentication.obscuredPassword != null)
        '${prefix}PASS': authentication.obscuredPassword!,
      if (authentication.useAgent) '${prefix}KEY_USE_AGENT': 'true',
    };
  }

  List<String> _mountArguments(
    PterodactylSmbMountTarget target,
    PterodactylSmbSettings configured,
  ) {
    final String stateDirectory = p.join(
      _metadataDirectoryPath,
      'pterodactyl-smb',
      'mounts',
      target.profileId,
      target.serverIdentifier,
    );
    Directory(stateDirectory).createSync(recursive: true);
    final List<String> arguments = <String>[
      _operatingSystem == PterodactylSmbOperatingSystem.macos
          ? 'nfsmount'
          : 'mount',
      '${target.remoteName}:',
      target.mountPath(configured),
      '--config=',
      '--cache-dir',
      p.join(stateDirectory, 'cache'),
      '--vfs-cache-mode',
      'writes',
      '--vfs-cache-max-age',
      '1h',
      '--dir-cache-time',
      '10s',
      '--poll-interval',
      '0',
      '--log-file',
      p.join(stateDirectory, 'rclone.log'),
      '--log-level',
      'INFO',
    ];
    if (_operatingSystem != PterodactylSmbOperatingSystem.windows) {
      arguments.addAll(const <String>['--umask', '077']);
    }
    return arguments;
  }

  Future<bool> _waitForMount(PterodactylSmbRuntimeMount mount) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    do {
      if (await _mountIsVisible(mount.mountPath)) return true;
      final String? description = await _runner.describeProcess(mount.pid);
      if (description == null || !_isOwnedRclone(description, mount)) {
        return false;
      }
      if (mountReadyTimeout == Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (stopwatch.elapsed < mountReadyTimeout);
    return false;
  }

  Future<bool> _mountIsVisible(String mountPath) async {
    switch (_operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        final PterodactylSmbCommandResult result = await _runner.run(
          '/sbin/mount',
          const <String>[],
        );
        return result.exitCode == 0 &&
            result.stdout.contains(' on $mountPath (');
      case PterodactylSmbOperatingSystem.linux:
        final PterodactylSmbCommandResult result = await _runner.run(
          'mountpoint',
          <String>['-q', mountPath],
        );
        return result.exitCode == 0;
      case PterodactylSmbOperatingSystem.windows:
        return Directory(mountPath).existsSync();
      case PterodactylSmbOperatingSystem.unsupported:
        return false;
    }
  }

  Future<void> _rollbackStart(
    PterodactylSmbRuntimeState runtime,
    List<PterodactylSmbProcessHandle> handles,
    String trustedRoot,
  ) async {
    final String normalizedRoot = p.normalize(trustedRoot);
    if (!p.equals(p.normalize(runtime.mountRoot), normalizedRoot)) {
      _runtimeStore.save(runtime);
      return;
    }
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts) {
      if (!_runtimeMountIsWithinRoot(mount, normalizedRoot)) {
        _runtimeStore.save(runtime);
        return;
      }
    }
    bool clean = true;
    bool shareRegistered = runtime.shareRegistered;
    if (runtime.shareRegistered &&
        await _shareManager.exists(runtime.shareName)) {
      try {
        await _shareManager.remove(runtime.shareName);
        shareRegistered = false;
      } catch (_) {
        clean = false;
      }
    } else {
      shareRegistered = false;
    }
    for (int index = handles.length - 1; index >= 0; index--) {
      final PterodactylSmbProcessHandle handle = handles[index];
      handle.kill();
      final int? exitCode = await handle.waitForExit(
        const Duration(seconds: 2),
      );
      if (exitCode == null) {
        handle.kill(ProcessSignal.sigkill);
      }
    }
    for (final PterodactylSmbRuntimeMount mount in runtime.mounts.reversed) {
      try {
        await _unmount(mount);
      } catch (_) {
        clean = false;
      }
    }
    if (clean) {
      _runtimeStore.remove();
    } else {
      _runtimeStore.save(
        PterodactylSmbRuntimeState(
          shareName: runtime.shareName,
          mountRoot: runtime.mountRoot,
          startedAt: runtime.startedAt,
          shareRegistered: shareRegistered,
          mounts: runtime.mounts,
        ),
      );
    }
  }

  Future<void> _waitForProcessExit(PterodactylSmbRuntimeMount mount) async {
    for (int attempt = 0; attempt < 20; attempt++) {
      if (await _runner.describeProcess(mount.pid) == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final String? description = await _runner.describeProcess(mount.pid);
    if (description != null && _isOwnedRclone(description, mount)) {
      if (!_runner.killPid(mount.pid, ProcessSignal.sigkill)) {
        throw StateError(
          'Unable to terminate the Drive mount for ${mount.serverIdentifier}.',
        );
      }
      for (int attempt = 0; attempt < 20; attempt++) {
        if (await _runner.describeProcess(mount.pid) == null) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError(
        'The Drive mount process for ${mount.serverIdentifier} did not exit.',
      );
    }
  }

  Future<void> _unmount(PterodactylSmbRuntimeMount mount) async {
    final String mountPath = mount.mountPath;
    if (!await _mountIsVisible(mountPath)) return;
    PterodactylSmbCommandResult? result;
    switch (_operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        result = await _runner.run('/usr/sbin/diskutil', <String>[
          'unmount',
          mountPath,
        ]);
        if (result.exitCode != 0) {
          result = await _runner.run('/sbin/umount', <String>[mountPath]);
        }
      case PterodactylSmbOperatingSystem.linux:
        if (await _runner.executableExists('fusermount3')) {
          result = await _runner.run('fusermount3', <String>['-u', mountPath]);
        } else if (await _runner.executableExists('fusermount')) {
          result = await _runner.run('fusermount', <String>['-u', mountPath]);
        } else {
          result = await _runner.run('umount', <String>[mountPath]);
        }
      case PterodactylSmbOperatingSystem.windows:
        if (await _runner.describeProcess(mount.pid) != null) {
          throw StateError(
            'The WinFsp mount process is still running for '
            '${mount.serverIdentifier}.',
          );
        }
        // Directory mount points must not exist before rclone starts. WinFsp
        // normally removes the synthetic directory when rclone exits, but an
        // empty placeholder can linger briefly on some installations. Remove
        // only that empty, already-validated mount point; never recurse into it.
        try {
          Directory(mountPath).deleteSync();
        } on FileSystemException {
          // A still-detaching or non-empty mount remains visible below and is
          // reported without deleting any remote content.
        }
      case PterodactylSmbOperatingSystem.unsupported:
        return;
    }
    if (result != null && result.exitCode != 0) {
      throw StateError(
        'The native unmount command failed'
        '${result.diagnostic.isEmpty ? '.' : ': ${result.diagnostic}'}',
      );
    }
    if (!await _waitForUnmount(mountPath)) {
      throw StateError('The mount is still visible after the unmount command.');
    }
  }

  Future<bool> _waitForUnmount(String mountPath) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    do {
      if (!await _mountIsVisible(mountPath)) return true;
      if (unmountReadyTimeout == Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (stopwatch.elapsed < unmountReadyTimeout);
    return false;
  }

  static bool _isOwnedRclone(
    String description,
    PterodactylSmbRuntimeMount mount,
  ) =>
      description.contains('rclone') &&
      (description.contains(' mount ') || description.contains(' nfsmount ')) &&
      description.contains('${mount.remoteName}:') &&
      description.contains(mount.mountPath);
}

final class _PterodactylSftpMountAuth {
  const _PterodactylSftpMountAuth({
    this.privateKeyPath,
    this.obscuredPassword,
    this.useAgent = false,
  }) : assert(
         (privateKeyPath == null ? 0 : 1) +
                 (obscuredPassword == null ? 0 : 1) +
                 (useAgent ? 1 : 0) ==
             1,
       );

  final String? privateKeyPath;
  final String? obscuredPassword;
  final bool useAgent;
}
