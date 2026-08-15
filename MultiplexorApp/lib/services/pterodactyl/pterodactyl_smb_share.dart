import 'dart:io';

import 'pterodactyl_smb_models.dart';
import 'pterodactyl_smb_process.dart';

typedef PterodactylSmbPrivilegeAuthorizer = Future<int> Function();

PterodactylSmbOperatingSystem detectPterodactylSmbOperatingSystem() {
  if (Platform.isMacOS) return PterodactylSmbOperatingSystem.macos;
  if (Platform.isLinux) return PterodactylSmbOperatingSystem.linux;
  if (Platform.isWindows) return PterodactylSmbOperatingSystem.windows;
  return PterodactylSmbOperatingSystem.unsupported;
}

/// Registers the already-mounted aggregate root with the host SMB service.
///
/// This intentionally uses native authenticated shares. It never creates a
/// guest share or writes an SMB password into Multiplexor state.
final class PterodactylSmbShareManager {
  PterodactylSmbShareManager({
    required this.runner,
    required this.operatingSystem,
    Map<String, String>? environment,
    PterodactylSmbPrivilegeAuthorizer? privilegeAuthorizer,
  }) : _environment = environment ?? Platform.environment,
       _privilegeAuthorizer = privilegeAuthorizer ?? _authorizeMacosSudo;

  final PterodactylSmbProcessRunner runner;
  final PterodactylSmbOperatingSystem operatingSystem;
  final Map<String, String> _environment;
  final PterodactylSmbPrivilegeAuthorizer _privilegeAuthorizer;

  /// The SMB client and server are on the same machine.
  ///
  /// Using the advertised hostname routes this local Drive through mDNS and
  /// the active Wi-Fi/Ethernet interface. Finder then loses the mounted share
  /// when that interface sleeps or changes networks even though the local SMB
  /// server is still available. Loopback keeps the session independent of
  /// external network state.
  String get connectionHost => 'localhost';

  String connectionUrl(String shareName) =>
      'smb://$connectionHost/${Uri.encodeComponent(shareName)}';

  /// Explicitly opens the platform authorization prompt. Normal start/stop
  /// operations always use non-interactive `sudo -n` and therefore never hang.
  Future<void> authorize() async {
    if (operatingSystem != PterodactylSmbOperatingSystem.macos) return;
    if (await _privilegeAuthorizer() != 0) {
      throw StateError('macOS SMB share authorization was not granted.');
    }
  }

  Future<List<PterodactylSmbCheck>> doctor() async {
    switch (operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        final bool available = await runner.executableExists(
          '/usr/sbin/sharing',
        );
        final bool sudoAvailable = await runner.executableExists(
          '/usr/bin/sudo',
        );
        final bool authorized =
            sudoAvailable &&
            (await runner.run('/usr/bin/sudo', const <String>[
                  '-n',
                  '-v',
                ])).exitCode ==
                0;
        return <PterodactylSmbCheck>[
          PterodactylSmbCheck(
            name: 'smb-share-tool',
            level: available && sudoAvailable
                ? PterodactylSmbCheckLevel.ready
                : PterodactylSmbCheckLevel.error,
            message: available && sudoAvailable
                ? 'macOS SMB share management is available.'
                : 'The macOS sharing and sudo utilities are required.',
          ),
          PterodactylSmbCheck(
            name: 'smb-share-authorization',
            level: authorized
                ? PterodactylSmbCheckLevel.ready
                : PterodactylSmbCheckLevel.error,
            message: authorized
                ? 'macOS SMB share authorization is active.'
                : 'Authorize SMB sharing first with sudo -v; Multiplexor '
                      'uses sudo -n and will never block for a password.',
          ),
        ];
      case PterodactylSmbOperatingSystem.linux:
        final bool netAvailable = await runner.executableExists('net');
        final bool smbdAvailable = await runner.executableExists('smbd');
        return <PterodactylSmbCheck>[
          PterodactylSmbCheck(
            name: 'samba-usershare',
            level: netAvailable && smbdAvailable
                ? PterodactylSmbCheckLevel.ready
                : PterodactylSmbCheckLevel.error,
            message: netAvailable && smbdAvailable
                ? 'Samba usershare management is available.'
                : 'Install Samba and enable usershares for the current user.',
          ),
          const PterodactylSmbCheck(
            name: 'samba-account',
            level: PterodactylSmbCheckLevel.warning,
            message: 'The current OS user must also have a Samba password.',
          ),
        ];
      case PterodactylSmbOperatingSystem.windows:
        final bool available = await runner.executableExists('net.exe');
        final bool hasUsername = (_environment['USERNAME'] ?? '').isNotEmpty;
        return <PterodactylSmbCheck>[
          PterodactylSmbCheck(
            name: 'windows-share-tool',
            level: available && hasUsername
                ? PterodactylSmbCheckLevel.ready
                : PterodactylSmbCheckLevel.error,
            message: available && hasUsername
                ? 'Windows SMB share management is available.'
                : 'Windows net.exe and the current username are required.',
          ),
        ];
      case PterodactylSmbOperatingSystem.unsupported:
        return const <PterodactylSmbCheck>[
          PterodactylSmbCheck(
            name: 'smb-share-tool',
            level: PterodactylSmbCheckLevel.error,
            message: 'This operating system has no Multiplexor SMB adapter.',
          ),
        ];
    }
  }

  Future<bool> exists(String shareName) async {
    switch (operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        final PterodactylSmbCommandResult result = await runner.run(
          '/usr/sbin/sharing',
          <String>['-l', '-f', 'json'],
        );
        if (result.exitCode != 0) return false;
        final String quotedName = '"$shareName"';
        return result.stdout.contains(quotedName) ||
            result.stdout
                .split('\n')
                .any((String line) => line.trim() == shareName);
      case PterodactylSmbOperatingSystem.linux:
        return (await runner.run('net', <String>[
              'usershare',
              'info',
              shareName,
            ])).exitCode ==
            0;
      case PterodactylSmbOperatingSystem.windows:
        return (await runner.run('net.exe', <String>[
              'share',
              shareName,
            ])).exitCode ==
            0;
      case PterodactylSmbOperatingSystem.unsupported:
        return false;
    }
  }

  Future<void> create(PterodactylSmbSettings settings) async {
    final PterodactylSmbCommandResult result;
    switch (operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        result = await runner.run('/usr/bin/sudo', <String>[
          '-n',
          '/usr/sbin/sharing',
          '-a',
          settings.mountRoot,
          '-S',
          settings.shareName,
          '-s',
          '001',
          '-g',
          '000',
          '-R',
          '0',
          '-E',
          settings.requireSmbEncryption ? '1' : '0',
        ]);
        break;
      case PterodactylSmbOperatingSystem.linux:
        result = await runner.run('net', <String>[
          'usershare',
          'add',
          settings.shareName,
          settings.mountRoot,
          'Multiplexor Pterodactyl servers',
          'Everyone:F',
          'guest_ok=n',
        ]);
        break;
      case PterodactylSmbOperatingSystem.windows:
        final String? username = _environment['USERNAME'];
        if (username == null || username.isEmpty) {
          throw StateError('The current Windows username is unavailable.');
        }
        result = await runner.run('net.exe', <String>[
          'share',
          '${settings.shareName}=${settings.mountRoot}',
          '/GRANT:$username,FULL',
        ]);
        break;
      case PterodactylSmbOperatingSystem.unsupported:
        throw UnsupportedError('SMB sharing is unsupported on this platform.');
    }
    if (result.exitCode != 0) {
      final String detail = result.diagnostic;
      throw StateError(
        'Unable to register the SMB share${detail.isEmpty ? '.' : ': $detail'}',
      );
    }
  }

  Future<void> remove(String shareName) async {
    final PterodactylSmbCommandResult result;
    switch (operatingSystem) {
      case PterodactylSmbOperatingSystem.macos:
        result = await runner.run('/usr/bin/sudo', <String>[
          '-n',
          '/usr/sbin/sharing',
          '-r',
          shareName,
        ]);
        break;
      case PterodactylSmbOperatingSystem.linux:
        result = await runner.run('net', <String>[
          'usershare',
          'delete',
          shareName,
        ]);
        break;
      case PterodactylSmbOperatingSystem.windows:
        result = await runner.run('net.exe', <String>[
          'share',
          shareName,
          '/delete',
          '/y',
        ]);
        break;
      case PterodactylSmbOperatingSystem.unsupported:
        return;
    }
    if (result.exitCode != 0 && await exists(shareName)) {
      final String detail = result.diagnostic;
      throw StateError(
        'Unable to remove the SMB share${detail.isEmpty ? '.' : ': $detail'}',
      );
    }
  }
}

Future<int> _authorizeMacosSudo() async {
  final Process process = await Process.start(
    '/usr/bin/sudo',
    const <String>['-v'],
    mode: ProcessStartMode.inheritStdio,
    runInShell: false,
  );
  return process.exitCode;
}
