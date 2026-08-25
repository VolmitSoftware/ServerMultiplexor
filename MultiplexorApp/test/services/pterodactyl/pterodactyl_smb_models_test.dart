import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('default Drive root is user-visible on every supported platform', () {
    expect(
      defaultPterodactylDriveRoot(
        operatingSystem: PterodactylSmbOperatingSystem.macos,
        environment: const <String, String>{'HOME': '/Users/brian'},
      ),
      '/Users/brian/Multiplexor Drive',
    );
    expect(
      defaultPterodactylDriveRoot(
        operatingSystem: PterodactylSmbOperatingSystem.linux,
        environment: const <String, String>{'HOME': '/home/brian'},
      ),
      '/home/brian/Multiplexor Drive',
    );
    expect(
      defaultPterodactylDriveRoot(
        operatingSystem: PterodactylSmbOperatingSystem.windows,
        environment: const <String, String>{'USERPROFILE': r'C:\Users\Brian'},
      ),
      r'C:\Users\Brian\Multiplexor Drive',
    );
  });

  test('builds the exact Pterodactyl SFTP username', () {
    final PterodactylSftpAccount account = PterodactylSftpAccount(
      profileId: 'Production',
      panelUsername: 'brian.admin',
    );

    expect(account.profileId, 'production');
    expect(account.usernameFor('Ab12Cd34'), 'brian.admin.Ab12Cd34');
    expect(() => account.usernameFor('../server'), throwsFormatException);
  });

  test('mount target makes untrusted server names safe and collision-free', () {
    final PterodactylSmbMountTarget target =
        PterodactylSmbMountTarget.fromServer(
          account: PterodactylSftpAccount(
            profileId: 'remote',
            panelUsername: 'operator',
          ),
          server: _server(
            identifier: 'abc12345',
            name: '../../My Server\n\u001b[2J',
          ),
        );

    expect(
      target.relativeDirectory,
      p.join('remote', 'my-server-2j--abc12345'),
    );
    expect(target.remoteName, 'mx_remote_abc12345');
    expect(target.sftpUsername, 'operator.abc12345');
  });

  test('settings reject root and symlink-neutral relative paths', () {
    expect(
      () => PterodactylSmbSettings(
        shareName: 'Multiplexor',
        mountRoot: Directory.current.path,
        knownHostsFile: 'relative/known_hosts',
        accounts: const <PterodactylSftpAccount>[],
      ),
      throwsFormatException,
    );
    expect(
      () => PterodactylSmbSettings(
        shareName: '../bad',
        mountRoot: Directory.current.path,
        knownHostsFile: '${Directory.current.path}/known_hosts',
        accounts: const <PterodactylSftpAccount>[],
      ),
      throwsFormatException,
    );
  });
}

PterodactylClientServer _server({
  required String identifier,
  required String name,
}) => PterodactylClientServer(
  identifier: identifier,
  internalId: 1,
  uuid: '00000000-0000-0000-0000-000000000001',
  name: name,
  nodeName: 'node',
  description: '',
  isOwner: true,
  isNodeUnderMaintenance: false,
  status: null,
  sftpHost: 'wings.example.test',
  sftpPort: 2022,
  limits: const PterodactylServerLimits(
    memoryMiB: 1024,
    swapMiB: 0,
    diskMiB: 1024,
    ioWeight: 500,
    cpuPercent: 100,
    threads: null,
    oomDisabled: false,
  ),
  featureLimits: const PterodactylFeatureLimits(
    databases: 0,
    allocations: 0,
    backups: 0,
  ),
  allocations: const <PterodactylAllocation>[],
);
