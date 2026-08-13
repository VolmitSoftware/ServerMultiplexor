import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_sftp_password_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_runtime_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_settings_store.dart';
import 'package:test/test.dart';

void main() {
  test('configures passwordless account from Client API callbacks', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    String? registeredName;
    String? registeredKey;
    int ensureCalls = 0;
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {
            ensureCalls++;
            registeredName = name;
            registeredKey = publicKey;
          },
    );

    final PterodactylSmbSettings settings = await service.configureAccount(
      profileId: 'remote',
    );
    await service.configureAccount(profileId: 'remote');

    expect(settings.accounts['remote']!.panelUsername, 'operator');
    expect(registeredName, 'Multiplexor Drive (remote)');
    expect(registeredKey, startsWith('ssh-ed25519 '));
    expect(ensureCalls, 2);
    expect(fixture.runner.keygenRuns, 1);
    expect(
      fixture.settingsStore.file.readAsStringSync(),
      isNot(contains(registeredKey!)),
    );
    expect(
      fixture.settingsStore.file.readAsStringSync(),
      isNot(contains('PRIVATE')),
    );
  });

  test('batch account configuration has one local commit point', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.settingsStore.save(fixture.settings());
    final String settingsBefore = fixture.settingsStore.file.readAsStringSync();
    bool failSecondaryRegistration = true;
    final List<String> registrations = <String>[];
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => '$profileId-user',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {
            registrations.add(profileId);
            if (profileId == 'secondary' && failSecondaryRegistration) {
              throw StateError('simulated registration failure');
            }
          },
    );

    await expectLater(
      service.configureAccounts(
        profileIds: const <String>['remote', 'secondary'],
        shareName: 'Atomic Files',
      ),
      throwsStateError,
    );

    expect(fixture.settingsStore.file.readAsStringSync(), settingsBefore);
    expect(registrations, <String>['remote', 'secondary']);

    failSecondaryRegistration = false;
    final PterodactylSmbSettings configured = await service.configureAccounts(
      profileIds: const <String>['remote', 'secondary'],
      shareName: 'Atomic Files',
    );

    expect(configured.shareName, 'Atomic Files');
    expect(
      configured.accounts.keys,
      containsAll(<String>['remote', 'secondary']),
    );
    expect(configured.accounts['remote']!.panelUsername, 'remote-user');
    expect(configured.accounts['secondary']!.panelUsername, 'secondary-user');
    expect(fixture.runner.keygenRuns, 2);
  });

  test('mounts every server below one authenticated SMB share', () async {
    final _Fixture fixture = _Fixture(
      servers: <PterodactylClientServer>[
        _server(identifier: 'abc12345', name: 'Lobby'),
        _server(identifier: 'def67890', name: 'Survival'),
      ],
    );
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');

    final PterodactylSmbStatus started = await service.start();

    expect(started.running, isTrue);
    expect(started.mounts, hasLength(2));
    expect(fixture.runner.started, hasLength(2));
    final _StartedProcess first = fixture.runner.started.first;
    expect(first.arguments.first, 'nfsmount');
    expect(first.arguments, contains('mx_remote_abc12345:'));
    expect(
      first.environment['RCLONE_CONFIG_MX_REMOTE_ABC12345_USER'],
      'operator.abc12345',
    );
    expect(
      first.environment['RCLONE_CONFIG_MX_REMOTE_ABC12345_KNOWN_HOSTS_FILE'],
      fixture.knownHosts.path,
    );
    expect(
      first.environment['RCLONE_CONFIG_MX_REMOTE_ABC12345_KEY_FILE'],
      endsWith('remote.ed25519'),
    );
    expect(first.environment.keys, isNot(contains(contains('PASS'))));
    expect(first.arguments.join(' '), isNot(contains('PRIVATE')));
    expect(fixture.runner.shareRegistered, isTrue);
    expect(service.connectionUrl(), startsWith('smb://'));

    final PterodactylSmbStatus stopped = await service.stop();

    expect(stopped.running, isFalse);
    expect(fixture.runner.shareRegistered, isFalse);
    expect(
      fixture.runner.started.every((_StartedProcess item) => !item.alive),
      isTrue,
    );
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
  });

  test('starts the local Drive without registering an SMB share', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');

    final PterodactylSmbStatus first = await service.startDrive();
    final PterodactylSmbStatus second = await service.startDrive();

    expect(first.localDriveRunning, isTrue);
    expect(first.shareRegistered, isFalse);
    expect(first.smbShared, isFalse);
    expect(second.running, isTrue);
    expect(fixture.runner.started, hasLength(1));
    expect(fixture.runner.shareRegistered, isFalse);
    await service.stopDrive();
  });

  test('reinstall safely stops a running Drive before refreshing it', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    await service.startDrive();

    await service.installDrive(profileIds: const <String>['remote']);

    expect(fixture.runner.started.single.alive, isFalse);
    expect((await service.status()).running, isFalse);
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
    expect((await service.startDrive()).running, isTrue);
    expect(fixture.runner.started, hasLength(2));
    await service.stopDrive();
  });

  test(
    'opens the exact mounted server folder and repairs a stale mount',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService service = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
      );
      service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await service.configureAccount(profileId: 'remote');
      await service.startDrive();
      fixture.runner.hideMountsOnce = true;

      final String opened = await service.openServerFolder(
        profileId: 'remote',
        serverIdentifier: 'ABC12345',
      );

      expect(opened, '${fixture.mountRoot.path}/remote/lobby--abc12345');
      expect(fixture.runner.openedPath, opened);
      expect(fixture.runner.started, hasLength(2));
      expect(fixture.runner.started.first.alive, isFalse);
      expect(fixture.runner.started.last.alive, isTrue);
      await service.stopDrive();
    },
  );

  test('open reconciles a server rename to its new Drive folder', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    await service.startDrive();
    fixture.servers[0] = _server(name: 'Renamed Lobby');

    final String opened = await service.openServerFolder(
      profileId: 'remote',
      serverIdentifier: 'abc12345',
    );

    expect(opened, '${fixture.mountRoot.path}/remote/renamed-lobby--abc12345');
    expect(fixture.runner.openedPath, opened);
    expect(fixture.runner.started, hasLength(2));
    expect(fixture.runner.started.first.alive, isFalse);
    await service.stopDrive();
  });

  test('Drive install migrates the exact legacy metadata mount root', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final String legacyRoot = '${fixture.metadata.path}/pterodactyl-smb/files';
    fixture.settingsStore.save(
      PterodactylSmbSettings(
        shareName: 'Multiplexor',
        mountRoot: legacyRoot,
        knownHostsFile: fixture.knownHosts.path,
        accounts: const <PterodactylSftpAccount>[],
      ),
    );
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );

    final PterodactylSmbSettings installed = await service.installDrive(
      profileIds: const <String>['remote'],
    );

    expect(installed.mountRoot, '${fixture.temporary.path}/Multiplexor Drive');
  });

  test('host-key scan returns fingerprints without trusting them', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.knownHosts.deleteSync();
    final PterodactylSmbService service = fixture.service();
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(
      profileId: 'remote',
      panelUsername: 'operator',
      provisionSshKey: false,
    );

    final List<PterodactylSshHostKeyCandidate> candidates = await service
        .scanHostKeys();

    expect(candidates, hasLength(1));
    expect(candidates.single.endpoint, '[wings.example.test]:2022');
    expect(candidates.single.fingerprint, 'SHA256:TestFingerprint');
    expect(fixture.knownHosts.existsSync(), isFalse);

    await service.trustHostKeys(candidates);
    final List<PterodactylSshHostKeyCandidate> rescanned = await service
        .scanHostKeys();
    await service.trustHostKeys(rescanned);

    expect(fixture.knownHosts.readAsLinesSync(), <String>[
      '[wings.example.test]:2022 ssh-ed25519 '
          'AAAAC3NzaC1lZDI1NTE5AAAAITestHostKey',
    ]);
  });

  test('host-key persistence refuses an unscanned candidate', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service();
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );

    await expectLater(
      service.trustHostKeys(const <PterodactylSshHostKeyCandidate>[
        PterodactylSshHostKeyCandidate(
          host: 'wings.example.test',
          port: 2022,
          keyType: 'ssh-ed25519',
          knownHostsLine: '[wings.example.test]:2022 ssh-ed25519 AAAATEST',
          fingerprint: 'SHA256:ForgedFingerprint',
        ),
      ]),
      throwsStateError,
    );
  });

  test('password fallback never places plaintext in argv or state', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final _PasswordProvider passwords = _PasswordProvider('clear-panel-secret');
    final PterodactylSmbService service = fixture.service(
      passwordProvider: passwords,
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(
      profileId: 'remote',
      panelUsername: 'operator',
      provisionSshKey: false,
    );

    await service.start();

    final _StartedProcess process = fixture.runner.started.single;
    expect(process.arguments.join(' '), isNot(contains('clear-panel-secret')));
    expect(process.environment.values, isNot(contains('clear-panel-secret')));
    expect(
      process.environment['RCLONE_CONFIG_MX_REMOTE_ABC12345_PASS'],
      'obscured-password',
    );
    expect(fixture.runner.obscureStdin, 'clear-panel-secret');
    expect(
      fixture.settingsStore.file.readAsStringSync(),
      isNot(contains('clear-panel-secret')),
    );
    expect(
      fixture.runtimeStore.file.readAsStringSync(),
      isNot(contains('clear-panel-secret')),
    );
    await service.stop();
  });

  test(
    'no-key account persists and uses password without key provisioning',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      int registrations = 0;
      final PterodactylSmbService service = fixture.service(
        passwordProvider: _PasswordProvider('panel-secret'),
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {
              registrations++;
            },
      );
      service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await service.configureAccount(
        profileId: 'remote',
        panelUsername: 'operator',
        provisionSshKey: false,
      );

      await service.startDrive();

      expect(service.settings!.accounts['remote']!.useManagedKey, isFalse);
      expect(registrations, 0);
      expect(fixture.runner.keygenRuns, 0);
      expect(
        fixture
            .runner
            .started
            .single
            .environment['RCLONE_CONFIG_MX_REMOTE_ABC12345_PASS'],
        'obscured-password',
      );
      await service.stopDrive();
    },
  );

  test('failed mount rolls back prior mounts and runtime state', () async {
    final _Fixture fixture = _Fixture(
      servers: <PterodactylClientServer>[
        _server(identifier: 'abc12345', name: 'Lobby'),
        _server(identifier: 'def67890', name: 'Survival'),
      ],
    );
    addTearDown(fixture.close);
    fixture.runner.failStartNumber = 2;
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');

    await expectLater(service.start(), throwsStateError);

    expect(fixture.runner.started, hasLength(2));
    expect(
      fixture.runner.started.every((_StartedProcess item) => !item.alive),
      isTrue,
    );
    expect(fixture.runner.shareRegistered, isFalse);
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
  });

  test(
    'failed native share creation rolls back every mounted server',
    () async {
      final _Fixture fixture = _Fixture(
        servers: <PterodactylClientServer>[
          _server(identifier: 'abc12345', name: 'Lobby'),
          _server(identifier: 'def67890', name: 'Survival'),
        ],
      );
      addTearDown(fixture.close);
      fixture.runner.failShareCreate = true;
      final PterodactylSmbService service = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
      );
      service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await service.configureAccount(profileId: 'remote');

      await expectLater(service.start(), throwsStateError);

      expect(fixture.runner.started, hasLength(2));
      expect(
        fixture.runner.started.every((_StartedProcess item) => !item.alive),
        isTrue,
      );
      expect(fixture.runner.shareRegistered, isFalse);
      expect(fixture.runtimeStore.file.existsSync(), isFalse);
    },
  );

  test('stop refuses a reused PID and retains recovery state', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.settingsStore.save(fixture.settings());
    final String conflictingMount =
        '${fixture.mountRoot.path}/remote/lobby--abc12345';
    final String ownedMount =
        '${fixture.mountRoot.path}/remote/survival--def67890';
    fixture.runtimeStore.save(
      PterodactylSmbRuntimeState(
        shareName: 'Multiplexor',
        mountRoot: fixture.mountRoot.path,
        startedAt: DateTime.utc(2026, 8, 12),
        shareRegistered: true,
        mounts: <PterodactylSmbRuntimeMount>[
          PterodactylSmbRuntimeMount(
            profileId: 'remote',
            serverIdentifier: 'abc12345',
            serverName: 'Lobby',
            mountPath: conflictingMount,
            remoteName: 'mx_remote_abc12345',
            pid: 99,
          ),
          PterodactylSmbRuntimeMount(
            profileId: 'remote',
            serverIdentifier: 'def67890',
            serverName: 'Survival',
            mountPath: ownedMount,
            remoteName: 'mx_remote_def67890',
            pid: 100,
          ),
        ],
      ),
    );
    fixture.runner.shareRegistered = true;
    fixture.runner.externalDescriptions[99] = 'sleep 999';
    fixture.runner.externalDescriptions[100] =
        'rclone nfsmount mx_remote_def67890: $ownedMount';
    final PterodactylSmbService service = fixture.service();

    await expectLater(service.stop(), throwsStateError);

    expect(fixture.runner.killedPids, isEmpty);
    expect(fixture.runner.shareRegistered, isTrue);
    expect(fixture.runtimeStore.file.existsSync(), isTrue);
  });

  test('stop refuses a runtime mount path outside saved Drive root', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.settingsStore.save(fixture.settings());
    fixture.runtimeStore.save(
      PterodactylSmbRuntimeState(
        shareName: 'Multiplexor Drive',
        mountRoot: fixture.mountRoot.path,
        startedAt: DateTime.utc(2026, 8, 12),
        shareRegistered: false,
        mounts: <PterodactylSmbRuntimeMount>[
          PterodactylSmbRuntimeMount(
            profileId: 'remote',
            serverIdentifier: 'abc12345',
            serverName: 'Lobby',
            mountPath: '${fixture.temporary.path}/outside/lobby',
            remoteName: 'mx_remote_abc12345',
            pid: 99,
          ),
        ],
      ),
    );
    fixture.runner.externalDescriptions[99] =
        'rclone nfsmount mx_remote_abc12345: '
        '${fixture.temporary.path}/outside/lobby';
    final PterodactylSmbService service = fixture.service();

    await expectLater(service.stopDrive(), throwsStateError);

    expect(fixture.runner.killedPids, isEmpty);
    expect(fixture.runtimeStore.file.existsSync(), isTrue);
  });

  test('failed unmount retains recovery state for a safe retry', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    await service.start();
    fixture.runner.forceMountVisible = true;
    fixture.runner.failUnmount = true;

    await expectLater(service.stop(), throwsStateError);

    expect(fixture.runner.shareRegistered, isFalse);
    expect(fixture.runtimeStore.file.existsSync(), isTrue);
    expect(fixture.runtimeStore.load()!.shareRegistered, isFalse);
    expect(fixture.runner.killedPids, contains(100));

    fixture.runner.failUnmount = false;
    fixture.runner.forceMountVisible = false;
    await service.stop();
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
  });

  test('Windows stop removes a detached WinFsp mount placeholder', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.runner.simulateWindowsMounts = true;
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
      operatingSystem: PterodactylSmbOperatingSystem.windows,
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    await service.startDrive();
    final String mountPath = '${fixture.mountRoot.path}/remote/lobby--abc12345';

    expect(Directory(mountPath).existsSync(), isTrue);

    await service.stopDrive();

    expect(Directory(mountPath).existsSync(), isFalse);
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
  });

  test('start prunes only empty stale server mount directories', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    fixture.mountRoot.createSync(recursive: true);
    File(
      '${fixture.mountRoot.path}/.multiplexor-smb-root.json',
    ).writeAsStringSync(
      '{"schema_version":1,"owner":"multiplexor-pterodactyl-smb"}\n',
    );
    final Directory emptyStale = Directory(
      '${fixture.mountRoot.path}/remote/old-name--deadbeef',
    )..createSync(recursive: true);
    final Directory nonEmptyStale = Directory(
      '${fixture.mountRoot.path}/remote/local-recovery--feedface',
    )..createSync(recursive: true);
    final File localRecoveryFile = File('${nonEmptyStale.path}/keep.txt')
      ..writeAsStringSync('keep');

    await service.start();

    expect(emptyStale.existsSync(), isFalse);
    expect(nonEmptyStale.existsSync(), isTrue);
    expect(localRecoveryFile.readAsStringSync(), 'keep');
    await service.stop();
  });

  test('configuration cannot expose Multiplexor metadata or SSH trust', () {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service();

    expect(
      () => service.configureShare(
        mountRoot: fixture.metadata.path,
        knownHostsFile: fixture.knownHosts.path,
      ),
      throwsStateError,
    );
    expect(
      () => service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: '${fixture.mountRoot.path}/known_hosts',
      ),
      throwsStateError,
    );
    expect(fixture.settingsStore.file.existsSync(), isFalse);
  });

  test(
    'start refuses a symlinked mount-root ownership marker',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService service = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
      );
      service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await service.configureAccount(profileId: 'remote');
      fixture.mountRoot.createSync(recursive: true);
      final File externalMarker =
          File('${fixture.temporary.path}/external-marker.json')
            ..writeAsStringSync(
              '{"schema_version":1,"owner":"multiplexor-pterodactyl-smb"}\n',
            );
      Link(
        '${fixture.mountRoot.path}/.multiplexor-smb-root.json',
      ).createSync(externalMarker.path);

      await expectLater(service.start(), throwsStateError);

      expect(fixture.runner.started, isEmpty);
      expect(externalMarker.existsSync(), isTrue);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks may require elevated Windows privileges.'
        : false,
  );

  test('start refuses to cover a non-owned non-empty mount root', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.mountRoot.createSync(recursive: true);
    File('${fixture.mountRoot.path}/user-file.txt').writeAsStringSync('keep');
    final PterodactylSmbService service = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');

    await expectLater(service.start(), throwsStateError);

    expect(
      File('${fixture.mountRoot.path}/user-file.txt').readAsStringSync(),
      'keep',
    );
    expect(fixture.runner.started, isEmpty);
  });
}

final class _Fixture {
  _Fixture({List<PterodactylClientServer>? servers})
    : temporary = Directory.systemTemp.createTempSync(
        'multiplexor-smb-service-',
      ),
      servers = servers ?? <PterodactylClientServer>[_server()] {
    metadata = Directory('${temporary.path}/metadata')..createSync();
    mountRoot = Directory('${temporary.path}/files');
    knownHosts = File('${temporary.path}/known_hosts')
      ..writeAsStringSync('[wings.example.test]:2022 ssh-ed25519 AAAATEST\n');
    settingsStore = PterodactylSmbSettingsStore(metadata.path);
    runtimeStore = PterodactylSmbRuntimeStore(metadata.path);
  }

  final Directory temporary;
  final List<PterodactylClientServer> servers;
  final _FakeRunner runner = _FakeRunner();
  late final Directory metadata;
  late final Directory mountRoot;
  late final File knownHosts;
  late final PterodactylSmbSettingsStore settingsStore;
  late final PterodactylSmbRuntimeStore runtimeStore;

  PterodactylSmbSettings settings() => PterodactylSmbSettings(
    shareName: 'Multiplexor',
    mountRoot: mountRoot.path,
    knownHostsFile: knownHosts.path,
    accounts: <PterodactylSftpAccount>[
      PterodactylSftpAccount(profileId: 'remote', panelUsername: 'operator'),
    ],
  );

  PterodactylSmbService service({
    PterodactylSmbPanelUsernameLoader? loadPanelUsername,
    PterodactylSmbSshKeyRegistrar? ensureSshPublicKey,
    PterodactylSftpPasswordProvider? passwordProvider,
    PterodactylSmbOperatingSystem operatingSystem =
        PterodactylSmbOperatingSystem.macos,
  }) => PterodactylSmbService(
    metadataDirectoryPath: metadata.path,
    loadProfile: (String id) => switch (id) {
      'remote' => _profile(),
      'secondary' => _profile(id: 'secondary'),
      _ => null,
    },
    loadServers: (String id) async => servers,
    loadPanelUsername: loadPanelUsername,
    ensureSshPublicKey: ensureSshPublicKey,
    settingsStore: settingsStore,
    runtimeStore: runtimeStore,
    passwordProvider: passwordProvider ?? _PasswordProvider(null),
    processRunner: runner,
    operatingSystem: operatingSystem,
    environment: const <String, String>{},
    mountReadyTimeout: Duration.zero,
    unmountReadyTimeout: Duration.zero,
  );

  void close() => temporary.deleteSync(recursive: true);
}

final class _FakeRunner implements PterodactylSmbProcessRunner {
  final List<_StartedProcess> started = <_StartedProcess>[];
  final Map<int, String> externalDescriptions = <int, String>{};
  final List<int> killedPids = <int>[];
  bool shareRegistered = false;
  bool failShareCreate = false;
  bool failUnmount = false;
  bool forceMountVisible = false;
  bool hideMountsOnce = false;
  bool simulateWindowsMounts = false;
  String? openedPath;
  int? failStartNumber;
  String? obscureStdin;
  int keygenRuns = 0;

  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    if (executable == 'ssh-keygen' && arguments.firstOrNull == '-lf') {
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: '256 SHA256:TestFingerprint wings.example.test (ED25519)\n',
        stderr: '',
      );
    }
    if (executable == 'ssh-keygen') {
      keygenRuns++;
      final String path = arguments[arguments.indexOf('-f') + 1];
      File(path).writeAsStringSync('PRIVATE\n');
      File('$path.pub').writeAsStringSync(
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusTestKey '
        'multiplexor-smb:remote\n',
      );
    }
    if (executable == 'rclone' && arguments.firstOrNull == 'obscure') {
      obscureStdin = stdinText;
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: 'obscured-password\n',
        stderr: '',
      );
    }
    if (executable == 'rclone' &&
        arguments.firstOrNull == 'nfsmount' &&
        arguments.length > 1 &&
        arguments[1] == '--help') {
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: 'mount\nnfsmount\n',
        stderr: '',
      );
    }
    if (executable == 'ssh-keyscan') {
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout:
            '[wings.example.test]:2022 ssh-ed25519 '
            'AAAAC3NzaC1lZDI1NTE5AAAAITestHostKey\n',
        stderr: '',
      );
    }
    if (executable == '/sbin/mount') {
      if (hideMountsOnce) {
        hideMountsOnce = false;
        return const PterodactylSmbCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        );
      }
      return PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: forceMountVisible && started.isNotEmpty
            ? 'rclone on ${started.first.arguments[2]} (nfs)'
            : started
                  .where((_StartedProcess process) => process.alive)
                  .map(
                    (_StartedProcess process) =>
                        'rclone on ${process.arguments[2]} (nfs)',
                  )
                  .join('\n'),
        stderr: '',
      );
    }
    if (executable == '/usr/bin/open') {
      openedPath = arguments.single;
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }
    if (executable == '/usr/sbin/diskutil' || executable == '/sbin/umount') {
      if (failUnmount) {
        return const PterodactylSmbCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'simulated unmount failure',
        );
      }
      forceMountVisible = false;
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }
    if (executable == '/usr/sbin/sharing') {
      if (arguments.firstOrNull == '-a' && failShareCreate) {
        return const PterodactylSmbCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'simulated share failure',
        );
      }
      if (arguments.firstOrNull == '-a') shareRegistered = true;
      if (arguments.firstOrNull == '-r') shareRegistered = false;
      return PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: arguments.firstOrNull == '-l' && shareRegistered
            ? '{"Multiplexor Drive":{"smb_shared":1}}'
            : '{}',
        stderr: '',
      );
    }
    if (executable == '/usr/bin/sudo' &&
        arguments.length > 2 &&
        arguments[1] == '/usr/sbin/sharing') {
      final String action = arguments[2];
      if (action == '-a' && failShareCreate) {
        return const PterodactylSmbCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'simulated share failure',
        );
      }
      if (action == '-a') shareRegistered = true;
      if (action == '-r') shareRegistered = false;
      return const PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }
    return const PterodactylSmbCommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
    );
  }

  @override
  Future<bool> executableExists(String executable) async => true;

  @override
  Future<String?> describeProcess(int pid) async {
    final String? external = externalDescriptions[pid];
    if (external != null) return external;
    for (final _StartedProcess process in started) {
      if (process.pid == pid && process.alive) {
        return 'rclone ${process.arguments.join(' ')}';
      }
    }
    return null;
  }

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) {
    killedPids.add(pid);
    for (final _StartedProcess process in started) {
      if (process.pid == pid) process.alive = false;
    }
    return true;
  }

  @override
  Future<PterodactylSmbProcessHandle> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final _StartedProcess process = _StartedProcess(
      pid: 100 + started.length,
      arguments: List<String>.from(arguments),
      environment: Map<String, String>.from(
        environment ?? const <String, String>{},
      ),
      failImmediately: failStartNumber == started.length + 1,
    );
    if (simulateWindowsMounts && arguments.length > 2) {
      Directory(arguments[2]).createSync(recursive: true);
    }
    started.add(process);
    return process;
  }
}

final class _StartedProcess implements PterodactylSmbProcessHandle {
  _StartedProcess({
    required this.pid,
    required this.arguments,
    required this.environment,
    required this.failImmediately,
  });

  @override
  final int pid;
  final List<String> arguments;
  final Map<String, String> environment;
  final bool failImmediately;
  bool alive = true;

  @override
  String get diagnostic => failImmediately ? 'simulated mount failure' : '';

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    alive = false;
    return true;
  }

  @override
  Future<int?> waitForExit(Duration timeout) async {
    if (failImmediately) {
      alive = false;
      return 1;
    }
    return alive ? null : 0;
  }
}

final class _PasswordProvider implements PterodactylSftpPasswordProvider {
  _PasswordProvider(this.value);

  final String? value;

  @override
  bool get supportsPersistentEnrollment => false;

  @override
  Future<bool> contains(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async => value != null;

  @override
  Future<void> enroll(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) => throw UnsupportedError('test');

  @override
  Future<PterodactylSftpPassword?> read(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async => value == null ? null : PterodactylSftpPassword(value!);

  @override
  Future<void> remove(
    PterodactylProfile profile,
    PterodactylSftpAccount account,
  ) async {}
}

PterodactylProfile _profile({String id = 'remote'}) => PterodactylProfile(
  id: id,
  name: id == 'remote' ? 'Remote' : 'Secondary',
  panelUri: Uri.parse('https://panel.example.test'),
);

PterodactylClientServer _server({
  String identifier = 'abc12345',
  String name = 'Lobby',
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
