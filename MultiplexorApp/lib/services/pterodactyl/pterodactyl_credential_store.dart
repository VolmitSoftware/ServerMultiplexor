import 'dart:io';

import 'pterodactyl_credential.dart';
import 'pterodactyl_profile.dart';

/// Resolves credentials from session memory, environment, then macOS Keychain.
///
/// Persistent enrollment delegates the secret prompt directly to
/// `/usr/bin/security`; the secret is never placed in argv, configuration, or
/// Multiplexor output.
final class PterodactylCredentialStore {
  PterodactylCredentialStore(
    this.metadataDirectoryPath, {
    Map<String, String>? environment,
    this.securityExecutable = '/usr/bin/security',
  }) : _environment = environment ?? Platform.environment;

  static const String keychainService = 'com.volmit.multiplexor.pterodactyl';

  final String metadataDirectoryPath;
  final String securityExecutable;
  final Map<String, String> _environment;
  final Map<String, PterodactylCredential> _session =
      <String, PterodactylCredential>{};

  static String keychainAccountFor(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) => 'v1:${profile.id}:${role.key}:${profile.origin}';

  static String environmentVariableFor(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) {
    final String id = _environmentId(profile.id);
    final String suffix = switch (role) {
      PterodactylCredentialRole.client => 'CLIENT_API_KEY',
      PterodactylCredentialRole.application => 'APPLICATION_API_KEY',
    };
    return 'MULTIPLEXOR_PTERODACTYL_${id}_$suffix';
  }

  static String environmentOriginVariableFor(PterodactylProfile profile) =>
      'MULTIPLEXOR_PTERODACTYL_${_environmentId(profile.id)}_ORIGIN';

  void putForSession(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
    PterodactylCredential credential,
  ) {
    _session[keychainAccountFor(profile, role)] = credential;
  }

  Future<PterodactylCredential?> read(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    final String account = keychainAccountFor(profile, role);
    final PterodactylCredential? session = _session[account];
    if (session != null) return session;

    final String? environmentValue =
        _environment[environmentVariableFor(profile, role)];
    if (environmentValue != null) {
      final String originVariable = environmentOriginVariableFor(profile);
      if (_environment[originVariable] != profile.origin) {
        throw StateError(
          '$originVariable must exactly match the configured panel origin.',
        );
      }
      final PterodactylCredential credential = PterodactylCredential(
        environmentValue,
      );
      _session[account] = credential;
      return credential;
    }
    if (!Platform.isMacOS) return null;

    final ProcessResult result = await Process.run(securityExecutable, <String>[
      'find-generic-password',
      '-a',
      account,
      '-s',
      keychainService,
      '-w',
    ], runInShell: false);
    if (result.exitCode == 44) return null;
    if (result.exitCode != 0) {
      throw StateError(
        'Unable to read the Pterodactyl credential from Keychain.',
      );
    }
    String value = result.stdout.toString();
    if (value.endsWith('\n')) value = value.substring(0, value.length - 1);
    if (value.endsWith('\r')) value = value.substring(0, value.length - 1);
    final PterodactylCredential credential = PterodactylCredential(value);
    _session[account] = credential;
    return credential;
  }

  Future<bool> contains(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async => await read(profile, role) != null;

  Future<void> enroll(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'Persistent credential enrollment requires macOS.',
      );
    }
    final String account = keychainAccountFor(profile, role);
    final Process process = await Process.start(
      securityExecutable,
      <String>[
        'add-generic-password',
        '-a',
        account,
        '-s',
        keychainService,
        '-D',
        'Multiplexor Pterodactyl API key',
        '-j',
        'Multiplexor ${profile.id} ${role.key} ${profile.origin}',
        '-U',
        '-T',
        '',
        '-w',
      ],
      mode: ProcessStartMode.inheritStdio,
      runInShell: false,
    );
    if (await process.exitCode != 0) {
      throw StateError(
        'Unable to enroll the Pterodactyl credential in Keychain.',
      );
    }
    _session.remove(account);
  }

  /// Persists a validated credential supplied through masked input.
  ///
  /// The value is passed to `/usr/bin/security` on stdin so it never appears
  /// in argv, configuration, shell history, or Multiplexor output. Platforms
  /// without Keychain retain it for this process only; environment-backed
  /// credentials remain the supported non-macOS persistence mechanism.
  Future<void> save(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
    PterodactylCredential credential,
  ) async {
    if (!Platform.isMacOS) {
      putForSession(profile, role, credential);
      return;
    }
    final String account = keychainAccountFor(profile, role);
    final Process process = await Process.start(
      securityExecutable,
      <String>[
        'add-generic-password',
        '-a',
        account,
        '-s',
        keychainService,
        '-D',
        'Multiplexor Pterodactyl API key',
        '-j',
        'Multiplexor ${profile.id} ${role.key} ${profile.origin}',
        '-U',
        '-T',
        '',
        '-w',
      ],
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    final Future<void> stdoutDrained = process.stdout.drain<void>();
    final Future<void> stderrDrained = process.stderr.drain<void>();
    process.stdin.writeln(credential.value);
    await process.stdin.close();
    final int exitCode = await process.exitCode;
    await Future.wait<void>(<Future<void>>[stdoutDrained, stderrDrained]);
    if (exitCode != 0) {
      throw StateError(
        'Unable to save the Pterodactyl credential in Keychain.',
      );
    }
    _session[account] = credential;
  }

  /// Restores a previously read credential after a failed replacement.
  Future<void> restore(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
    PterodactylCredential credential,
  ) => save(profile, role, credential);

  Future<void> remove(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    final String account = keychainAccountFor(profile, role);
    _session.remove(account);
    if (!Platform.isMacOS) return;
    final ProcessResult result = await Process.run(securityExecutable, <String>[
      'delete-generic-password',
      '-a',
      account,
      '-s',
      keychainService,
    ], runInShell: false);
    if (result.exitCode != 0 && result.exitCode != 44) {
      throw StateError(
        'Unable to remove the Pterodactyl credential from Keychain.',
      );
    }
  }

  static String _environmentId(String profileId) {
    final StringBuffer encoded = StringBuffer();
    for (final int codeUnit in profileId.codeUnits) {
      if ((codeUnit >= 0x30 && codeUnit <= 0x39) ||
          (codeUnit >= 0x61 && codeUnit <= 0x7a)) {
        encoded.writeCharCode(codeUnit >= 0x61 ? codeUnit - 0x20 : codeUnit);
      } else {
        encoded.write('_${codeUnit.toRadixString(16).toUpperCase()}');
      }
    }
    return encoded.toString();
  }
}
