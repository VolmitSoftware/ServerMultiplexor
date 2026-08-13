import 'dart:io';

import 'pterodactyl_profile.dart';
import 'pterodactyl_smb_models.dart';

/// A Panel account password whose diagnostics are always redacted.
final class PterodactylSftpPassword {
  PterodactylSftpPassword(String value) : value = _validate(value);

  static final RegExp _unsafe = RegExp(r'[\x00\r\n]');

  final String value;

  static String _validate(String value) {
    if (value.isEmpty || value.length > 8192 || _unsafe.hasMatch(value)) {
      throw const FormatException('Invalid Pterodactyl SFTP password.');
    }
    return value;
  }

  @override
  String toString() => 'PterodactylSftpPassword([REDACTED])';
}

/// Resolves an optional SFTP password from memory, environment, then Keychain.
///
/// SSH-agent authentication needs no password and is preferred on every OS.
/// Persistent password enrollment is limited to macOS because its `security`
/// helper can collect a value without placing it in argv, app config, or logs.
abstract interface class PterodactylSftpPasswordProvider {
  bool get supportsPersistentEnrollment;

  Future<PterodactylSftpPassword?> read(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  );

  Future<bool> contains(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  );

  Future<void> enroll(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  );

  Future<void> remove(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  );
}

final class PterodactylSftpPasswordStore
    implements PterodactylSftpPasswordProvider {
  PterodactylSftpPasswordStore({
    Map<String, String>? environment,
    this.securityExecutable = '/usr/bin/security',
  }) : _environment = environment ?? Platform.environment;

  static const String keychainService =
      'com.volmit.multiplexor.pterodactyl-sftp';

  final String securityExecutable;
  final Map<String, String> _environment;
  final Map<String, PterodactylSftpPassword> _session =
      <String, PterodactylSftpPassword>{};

  @override
  bool get supportsPersistentEnrollment => Platform.isMacOS;

  static String keychainAccountFor(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) => 'v1:${profile.id}:${account.panelUsername}:${profile.origin}';

  static String environmentVariableFor(PterodactylSftpAccount account) =>
      'MULTIPLEXOR_PTERODACTYL_${_environmentId(account.profileId)}_'
      'SFTP_PASSWORD';

  static String environmentOriginVariableFor(PterodactylSftpAccount account) =>
      'MULTIPLEXOR_PTERODACTYL_${_environmentId(account.profileId)}_ORIGIN';

  static String environmentUsernameVariableFor(
    PterodactylSftpAccount account,
  ) =>
      'MULTIPLEXOR_PTERODACTYL_${_environmentId(account.profileId)}_'
      'SFTP_USERNAME';

  void putForSession(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
    PterodactylSftpPassword password,
  ) {
    _session[keychainAccountFor(profile, account)] = password;
  }

  @override
  Future<PterodactylSftpPassword?> read(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async {
    final String key = keychainAccountFor(profile, account);
    final PterodactylSftpPassword? session = _session[key];
    if (session != null) return session;

    final String? environmentValue =
        _environment[environmentVariableFor(account)];
    if (environmentValue != null) {
      final String originVariable = environmentOriginVariableFor(account);
      final String usernameVariable = environmentUsernameVariableFor(account);
      if (_environment[originVariable] != profile.origin ||
          _environment[usernameVariable] != account.panelUsername) {
        throw StateError(
          '$originVariable and $usernameVariable must exactly match the '
          'configured SFTP account.',
        );
      }
      final PterodactylSftpPassword password = PterodactylSftpPassword(
        environmentValue,
      );
      _session[key] = password;
      return password;
    }
    if (!Platform.isMacOS) return null;

    final ProcessResult result = await Process.run(securityExecutable, <String>[
      'find-generic-password',
      '-a',
      key,
      '-s',
      keychainService,
      '-w',
    ], runInShell: false);
    if (result.exitCode == 44) return null;
    if (result.exitCode != 0) {
      throw StateError(
        'Unable to read the Pterodactyl SFTP password from Keychain.',
      );
    }
    String value = result.stdout.toString();
    if (value.endsWith('\n')) value = value.substring(0, value.length - 1);
    if (value.endsWith('\r')) value = value.substring(0, value.length - 1);
    final PterodactylSftpPassword password = PterodactylSftpPassword(value);
    _session[key] = password;
    return password;
  }

  @override
  Future<bool> contains(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async => await read(profile, account) != null;

  @override
  Future<void> enroll(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'Persistent SFTP password enrollment requires macOS. Use an SSH '
        'agent, a session password, or the guarded environment variables.',
      );
    }
    final String key = keychainAccountFor(profile, account);
    final Process process = await Process.start(
      securityExecutable,
      <String>[
        'add-generic-password',
        '-a',
        key,
        '-s',
        keychainService,
        '-D',
        'Multiplexor Pterodactyl SFTP password',
        '-j',
        'Multiplexor ${profile.id} SFTP ${profile.origin}',
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
        'Unable to enroll the Pterodactyl SFTP password in Keychain.',
      );
    }
    _session.remove(key);
  }

  @override
  Future<void> remove(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async {
    final String key = keychainAccountFor(profile, account);
    _session.remove(key);
    if (!Platform.isMacOS) return;
    final ProcessResult result = await Process.run(securityExecutable, <String>[
      'delete-generic-password',
      '-a',
      key,
      '-s',
      keychainService,
    ], runInShell: false);
    if (result.exitCode != 0 && result.exitCode != 44) {
      throw StateError(
        'Unable to remove the Pterodactyl SFTP password from Keychain.',
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
