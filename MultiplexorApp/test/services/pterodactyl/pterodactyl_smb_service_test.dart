import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_sftp_password_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_runtime_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_path_policy.dart';
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
    expect(first.detached, isTrue);
    expect(first.arguments, contains('mx_remote_abc12345:'));
    expect(
      first.arguments,
      containsAllInOrder(<String>[
        '--contimeout',
        '15s',
        '--timeout',
        '2m',
        '--low-level-retries',
        '20',
        '--sftp-idle-timeout',
        '30s',
      ]),
    );
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

  test(
    'concurrent starts share one lifecycle lock and start one target process',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService first = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
      );
      final PterodactylSmbService second = fixture.service();
      first.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await first.configureAccount(profileId: 'remote');
      fixture.runner.startEntered = Completer<void>();
      fixture.runner.releaseStart = Completer<void>();

      final Future<PterodactylSmbStatus> firstStart = first.startDrive();
      await fixture.runner.startEntered!.future;
      final Future<PterodactylSmbStatus> secondStart = second.startDrive();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.runner.started, hasLength(1));
      fixture.runner.releaseStart!.complete();
      final List<PterodactylSmbStatus> results = await Future.wait(
        <Future<PterodactylSmbStatus>>[firstStart, secondStart],
      );

      expect(
        results.every((PterodactylSmbStatus item) => item.running),
        isTrue,
      );
      expect(fixture.runner.started, hasLength(1));
      expect(fixture.runtimeStore.load()!.mounts, hasLength(1));
      await first.stopDrive();
    },
  );

  test(
    'concurrent stop waits for start before changing runtime state',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService first = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
      );
      final PterodactylSmbService second = fixture.service();
      first.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await first.configureAccount(profileId: 'remote');
      fixture.runner.startEntered = Completer<void>();
      fixture.runner.releaseStart = Completer<void>();

      final Future<PterodactylSmbStatus> starting = first.startDrive();
      await fixture.runner.startEntered!.future;
      final Future<PterodactylSmbStatus> stopping = second.stopDrive();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.runner.killedPids, isEmpty);
      expect(fixture.runtimeStore.load(), isNotNull);
      fixture.runner.releaseStart!.complete();
      expect((await starting).running, isTrue);
      expect((await stopping).running, isFalse);
      expect(fixture.runtimeStore.load(), isNull);
      expect(fixture.runner.started.single.alive, isFalse);
    },
  );

  test('lifecycle lock contention is bounded and actionable', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService holder = fixture.service(
      loadPanelUsername: (String profileId) async => 'operator',
      ensureSshPublicKey:
          (
            String profileId, {
            required String name,
            required String publicKey,
          }) async {},
    );
    final PterodactylSmbService contender = fixture.service(
      lifecycleLockTimeout: Duration.zero,
    );
    holder.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await holder.configureAccount(profileId: 'remote');
    fixture.runner.startEntered = Completer<void>();
    fixture.runner.releaseStart = Completer<void>();

    final Future<PterodactylSmbStatus> starting = holder.startDrive();
    await fixture.runner.startEntered!.future;

    await expectLater(
      contender.startDrive(),
      throwsA(
        isA<StateError>()
            .having(
              (StateError error) => error.message,
              'message',
              contains('Another Multiplexor Drive lifecycle operation'),
            )
            .having(
              (StateError error) => error.message,
              'message',
              contains('lifecycle.lock'),
            ),
      ),
    );
    expect(fixture.runner.started, hasLength(1));
    fixture.runner.releaseStart!.complete();
    await starting;
    await holder.stopDrive();
  });

  test('lifecycle lock excludes a separate Multiplexor process', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final Directory lockParent = Directory(
      '${fixture.metadata.path}/pterodactyl-smb',
    )..createSync();
    final File lockFile = File('${lockParent.path}/lifecycle.lock')
      ..createSync();
    final File holderScript = File('${fixture.temporary.path}/hold_lock.dart')
      ..writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final RandomAccessFile handle = File(
    arguments.single,
  ).openSync(mode: FileMode.append);
  handle.lockSync(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.first;
  handle.unlockSync();
  handle.closeSync();
}
''');
    final Process holder = await Process.start(
      Platform.resolvedExecutable,
      <String>[holderScript.path, lockFile.path],
      runInShell: false,
    );
    await utf8.decoder
        .bind(holder.stdout)
        .transform(const LineSplitter())
        .firstWhere((String line) => line == 'locked');
    final PterodactylSmbService service = fixture.service(
      lifecycleLockTimeout: Duration.zero,
    );

    try {
      expect(
        () => service.configureShare(
          mountRoot: fixture.mountRoot.path,
          knownHostsFile: fixture.knownHosts.path,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('Another Multiplexor Drive lifecycle operation'),
          ),
        ),
      );
    } finally {
      holder.stdin.writeln('release');
      await holder.stdin.close();
      expect(await holder.exitCode, 0);
    }
  });

  test(
    'force-detaches a stale macOS NFS mount after normal unmount fails',
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
      fixture.runner.failNormalUnmount = true;
      fixture.runner.forceMountVisible = true;

      final PterodactylSmbStatus stopped = await service.stopDrive();

      expect(stopped.running, isFalse);
      expect(
        fixture.runner.runs.any(
          (_RunCommand command) =>
              command.executable == '/usr/sbin/diskutil' &&
              command.arguments.length >= 2 &&
              command.arguments[0] == 'unmount' &&
              command.arguments[1] == 'force',
        ),
        isTrue,
      );
    },
  );

  test('retains a live mount and cache when graceful stop times out', () async {
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
      processStopTimeout: Duration.zero,
    );
    service.configureShare(
      mountRoot: fixture.mountRoot.path,
      knownHostsFile: fixture.knownHosts.path,
    );
    await service.configureAccount(profileId: 'remote');
    await service.startDrive();
    fixture.runner.ignoreTerminate = true;

    await expectLater(service.stopDrive(), throwsStateError);

    expect(fixture.runner.started.single.alive, isTrue);
    expect(fixture.runtimeStore.file.existsSync(), isTrue);
    expect(fixture.runner.killSignals, isNot(contains(ProcessSignal.sigkill)));
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

  test('repairs one dead target without restarting healthy mounts', () async {
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
    final PterodactylSmbStatus initial = await service.start();
    final _StartedProcess healthy = fixture.runner.started.first;
    final _StartedProcess failed = fixture.runner.started.last;
    failed.alive = false;

    final PterodactylSmbStatus repaired = await service.startDrive();

    expect(initial.mounts, hasLength(2));
    expect(repaired.localDriveRunning, isTrue);
    expect(repaired.shareRegistered, isTrue);
    expect(fixture.runner.shareRegistered, isTrue);
    expect(fixture.runner.started, hasLength(3));
    expect(healthy.alive, isTrue);
    expect(healthy.pid, 100);
    expect(failed.alive, isFalse);
    expect(
      fixture.runner.started.last.arguments,
      contains('mx_remote_def67890:'),
    );
  });

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

  test('direct preflight scans one target without mounting Drive', () async {
    final _Fixture fixture = _Fixture(
      servers: <PterodactylClientServer>[
        _server(identifier: 'abc12345', name: 'Selected'),
        _server(identifier: 'def67890', name: 'Unrelated'),
      ],
    );
    addTearDown(fixture.close);
    fixture.knownHosts.deleteSync();
    final PterodactylSmbService service = fixture.service(
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
    await service.configureAccount(
      profileId: 'remote',
      panelUsername: 'operator',
    );

    expect(
      await service.isServerHostKeyTrusted(
        profileId: 'remote',
        serverIdentifier: 'abc12345',
      ),
      isFalse,
    );
    final List<PterodactylSshHostKeyCandidate> candidates = await service
        .scanServerHostKeys(profileId: 'remote', serverIdentifier: 'abc12345');
    await service.trustHostKeys(candidates);
    await service.verifyDirectServerFilesReady(
      profileId: 'remote',
      serverIdentifier: 'abc12345',
    );

    expect(candidates, hasLength(1));
    expect(
      fixture.runner.runs.where(
        (_RunCommand command) => command.executable == 'ssh-keyscan',
      ),
      hasLength(1),
    );
    expect(fixture.runner.started, isEmpty);
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
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

    await expectLater(
      service.start(),
      throwsA(
        isA<StateError>()
            .having(
              (StateError error) => error.message,
              'message',
              contains('exited before becoming ready'),
            )
            .having(
              (StateError error) => error.message,
              'message',
              contains('rclone.log'),
            )
            .having(
              (StateError error) => error.message,
              'message',
              isNot(contains('code 0')),
            ),
      ),
    );

    expect(fixture.runner.started, hasLength(2));
    expect(
      fixture.runner.started.every((_StartedProcess item) => !item.alive),
      isTrue,
    );
    expect(fixture.runner.shareRegistered, isFalse);
    expect(fixture.runtimeStore.file.existsSync(), isFalse);
    expect(
      service
          .configureShare(
            mountRoot: fixture.mountRoot.path,
            knownHostsFile: fixture.knownHosts.path,
          )
          .mountRoot,
      fixture.mountRoot.path,
    );
  });

  test(
    'failed start retains an unflushed mount without escalating to SIGKILL',
    () async {
      final _Fixture fixture = _Fixture(
        servers: <PterodactylClientServer>[
          _server(identifier: 'abc12345', name: 'Lobby'),
          _server(identifier: 'def67890', name: 'Survival'),
        ],
      );
      addTearDown(fixture.close);
      fixture.runner.failStartNumber = 2;
      fixture.runner.ignoreTerminate = true;
      final PterodactylSmbService service = fixture.service(
        loadPanelUsername: (String profileId) async => 'operator',
        ensureSshPublicKey:
            (
              String profileId, {
              required String name,
              required String publicKey,
            }) async {},
        processStopTimeout: Duration.zero,
      );
      service.configureShare(
        mountRoot: fixture.mountRoot.path,
        knownHostsFile: fixture.knownHosts.path,
      );
      await service.configureAccount(profileId: 'remote');

      await expectLater(service.startDrive(), throwsStateError);

      expect(fixture.runner.started.first.alive, isTrue);
      expect(fixture.runner.killSignals, contains(ProcessSignal.sigterm));
      expect(
        fixture.runner.killSignals,
        isNot(contains(ProcessSignal.sigkill)),
      );
      expect(fixture.runtimeStore.load(), isNotNull);
    },
  );

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
    final Directory finderStale = Directory(
      '${fixture.mountRoot.path}/remote/old-finder--deadcafe',
    )..createSync(recursive: true);
    File('${finderStale.path}/.DS_Store').writeAsStringSync('finder metadata');

    await service.start();

    expect(emptyStale.existsSync(), isFalse);
    expect(finderStale.existsSync(), isFalse);
    expect(nonEmptyStale.existsSync(), isTrue);
    expect(localRecoveryFile.readAsStringSync(), 'keep');
    expect(
      Directory('${fixture.mountRoot.path}/.multiplexor-local-recovery')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((File file) => p.basename(file.path)),
      contains('.DS_Store'),
    );
    await service.stop();
  });

  test(
    'start preserves Finder scaffolding and mounts the recovered folder',
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
      File(
        '${fixture.mountRoot.path}/.multiplexor-drive.json',
      ).writeAsStringSync(
        '{"schema_version":1,"owner":"multiplexor-pterodactyl-drive"}\n',
      );
      final Directory mountPoint = Directory(
        '${fixture.mountRoot.path}/remote/lobby--abc12345',
      )..createSync(recursive: true);
      File('${mountPoint.path}/.DS_Store').writeAsStringSync('finder metadata');

      final PterodactylSmbStatus status = await service.startDrive();

      expect(status.localDriveRunning, isTrue);
      expect(mountPoint.existsSync(), isTrue);
      expect(mountPoint.listSync(followLinks: false), isEmpty);
      final Directory recovery = Directory(
        '${fixture.mountRoot.path}/.multiplexor-local-recovery',
      );
      final List<FileSystemEntity> recovered = recovery.listSync(
        recursive: true,
        followLinks: false,
      );
      expect(
        recovered.whereType<File>().map((File file) => p.basename(file.path)),
        contains('.DS_Store'),
      );
      expect(
        fixture.runner.started.single.arguments,
        containsAll(<String>[
          '--exclude=/.DS_Store',
          '--exclude=/**/.DS_Store',
          '--exclude=/._.DS_Store',
          '--exclude=/**/._.DS_Store',
        ]),
      );
      await service.stopDrive();
      expect(recovery.existsSync(), isTrue);
    },
  );

  test('start quarantines only regular Finder files from VFS cache', () async {
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
    final Directory vfs = Directory(
      '${fixture.metadata.path}/pterodactyl-smb/mounts/remote/abc12345/'
      'cache/vfs/mx_remote_abc12345/cache',
    )..createSync(recursive: true);
    final Directory vfsMeta = Directory(
      '${fixture.metadata.path}/pterodactyl-smb/mounts/remote/abc12345/'
      'cache/vfsMeta/mx_remote_abc12345/cache',
    )..createSync(recursive: true);
    final File queuedFinder = File('${vfs.path}/.DS_Store')
      ..writeAsStringSync('queued Finder write');
    final File queuedFinderMeta = File('${vfsMeta.path}/.DS_Store')
      ..writeAsStringSync('queued Finder metadata');
    final File genuinePending = File('${vfs.path}/server-change.dat')
      ..writeAsStringSync('genuine pending write');

    final PterodactylSmbStatus status = await service.startDrive();

    expect(status.localDriveRunning, isTrue);
    expect(queuedFinder.existsSync(), isFalse);
    expect(queuedFinderMeta.existsSync(), isFalse);
    expect(genuinePending.readAsStringSync(), 'genuine pending write');
    final Directory recovery = Directory(
      '${fixture.metadata.path}/pterodactyl-smb/mounts/remote/abc12345/'
      'finder-metadata-recovery',
    );
    expect(
      recovery
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((File file) => p.basename(file.path) == '.DS_Store'),
      hasLength(2),
    );
    await service.stopDrive();
    expect(genuinePending.readAsStringSync(), 'genuine pending write');
  });

  test('start refuses a Finder-named VFS cache directory', () async {
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
    final Directory finderNamed = Directory(
      '${fixture.metadata.path}/pterodactyl-smb/mounts/remote/abc12345/'
      'cache/vfs/mx_remote_abc12345/.DS_Store',
    )..createSync(recursive: true);
    final File preserved = File('${finderNamed.path}/user-data.txt')
      ..writeAsStringSync('keep');

    await expectLater(
      service.startDrive(),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.toString(),
          'message',
          contains('non-file Finder metadata'),
        ),
      ),
    );

    expect(preserved.readAsStringSync(), 'keep');
    expect(fixture.runner.started, isEmpty);
  });

  test(
    'start refuses a Finder-named VFS cache symlink',
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
      final File external = File('${fixture.temporary.path}/external-data')
        ..writeAsStringSync('keep');
      final Link finderNamed = Link(
        '${fixture.metadata.path}/pterodactyl-smb/mounts/remote/abc12345/'
        'cache/vfs/mx_remote_abc12345/.DS_Store',
      );
      finderNamed.parent.createSync(recursive: true);
      finderNamed.createSync(external.path);

      await expectLater(service.startDrive(), throwsStateError);

      expect(
        FileSystemEntity.typeSync(finderNamed.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(external.readAsStringSync(), 'keep');
      expect(fixture.runner.started, isEmpty);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks may require elevated Windows privileges.'
        : false,
  );

  test('start refuses and preserves meaningful mount-point files', () async {
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
    File('${fixture.mountRoot.path}/.multiplexor-drive.json').writeAsStringSync(
      '{"schema_version":1,"owner":"multiplexor-pterodactyl-drive"}\n',
    );
    final Directory mountPoint = Directory(
      '${fixture.mountRoot.path}/remote/lobby--abc12345',
    )..createSync(recursive: true);
    File(
      '${mountPoint.path}/local-change.txt',
    ).writeAsStringSync('preserve me');

    await expectLater(
      service.startDrive(),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.toString(),
          'message',
          allOf(
            contains('Nothing was deleted or hidden'),
            contains(mountPoint.path),
          ),
        ),
      ),
    );

    expect(fixture.runner.started, isEmpty);
    expect(mountPoint.existsSync(), isTrue);
    expect(
      File('${mountPoint.path}/local-change.txt').readAsStringSync(),
      'preserve me',
    );
    expect(
      Directory(
        '${fixture.mountRoot.path}/.multiplexor-local-recovery',
      ).existsSync(),
      isFalse,
    );
  });

  test('start preserves a Finder-named mount-point directory', () async {
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
    File('${fixture.mountRoot.path}/.multiplexor-drive.json').writeAsStringSync(
      '{"schema_version":1,"owner":"multiplexor-pterodactyl-drive"}\n',
    );
    final Directory finderNamed = Directory(
      '${fixture.mountRoot.path}/remote/lobby--abc12345/.DS_Store',
    )..createSync(recursive: true);
    final File preserved = File('${finderNamed.path}/user-data.txt')
      ..writeAsStringSync('keep');

    await expectLater(service.startDrive(), throwsStateError);

    expect(preserved.readAsStringSync(), 'keep');
    expect(fixture.runner.started, isEmpty);
  });

  test(
    'start preserves a Finder-named mount-point symlink',
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
      File(
        '${fixture.mountRoot.path}/.multiplexor-drive.json',
      ).writeAsStringSync(
        '{"schema_version":1,"owner":"multiplexor-pterodactyl-drive"}\n',
      );
      final File external = File('${fixture.temporary.path}/external-data')
        ..writeAsStringSync('keep');
      final Link finderNamed = Link(
        '${fixture.mountRoot.path}/remote/lobby--abc12345/.DS_Store',
      );
      finderNamed.parent.createSync(recursive: true);
      finderNamed.createSync(external.path);

      await expectLater(service.startDrive(), throwsStateError);

      expect(
        FileSystemEntity.typeSync(finderNamed.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(external.readAsStringSync(), 'keep');
      expect(fixture.runner.started, isEmpty);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks may require elevated Windows privileges.'
        : false,
  );

  test(
    'start reconciles renamed server folders without hiding files',
    () async {
      final _Fixture fixture = _Fixture(
        servers: <PterodactylClientServer>[
          _server(identifier: 'abc12345', name: 'Renamed Lobby'),
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
      fixture.mountRoot.createSync(recursive: true);
      File(
        '${fixture.mountRoot.path}/.multiplexor-drive.json',
      ).writeAsStringSync(
        '{"schema_version":1,"owner":"multiplexor-pterodactyl-drive"}\n',
      );
      final Directory priorFolder = Directory(
        '${fixture.mountRoot.path}/remote/lobby--abc12345',
      )..createSync(recursive: true);
      File('${priorFolder.path}/offline-copy.txt').writeAsStringSync('keep');

      await expectLater(
        service.startDrive(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            'message',
            allOf(
              contains('now maps to'),
              contains('renamed-lobby--abc12345'),
              contains(priorFolder.path),
            ),
          ),
        ),
      );

      expect(priorFolder.existsSync(), isTrue);
      expect(
        File('${priorFolder.path}/offline-copy.txt').readAsStringSync(),
        'keep',
      );
      expect(fixture.runner.started, isEmpty);
    },
  );

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
    'lifecycle lock refuses a symlink without touching its target',
    () {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final File external = File('${fixture.temporary.path}/external-lock')
        ..writeAsStringSync('keep');
      final Directory lockParent = Directory(
        '${fixture.metadata.path}/pterodactyl-smb',
      )..createSync();
      Link('${lockParent.path}/lifecycle.lock').createSync(external.path);
      final PterodactylSmbService service = fixture.service();

      expect(
        () => service.configureShare(
          mountRoot: fixture.mountRoot.path,
          knownHostsFile: fixture.knownHosts.path,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('lifecycle lock must be a real file'),
          ),
        ),
      );
      expect(external.readAsStringSync(), 'keep');
      expect(fixture.settingsStore.file.existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks may require elevated Windows privileges.'
        : false,
  );

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

  test(
    'direct snapshot and mirror await rclone without disrupting Drive',
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
      final _StartedProcess mount = fixture.runner.started.single;
      final String runtimeBefore = fixture.runtimeStore.file.readAsStringSync();
      final int cacheArgument = mount.arguments.indexOf('--cache-dir');
      expect(cacheArgument, greaterThanOrEqualTo(0));
      final File cacheSentinel = File(
        '${mount.arguments[cacheArgument + 1]}/keep-cache.txt',
      )..createSync(recursive: true);
      cacheSentinel.writeAsStringSync('pending browser write');
      final Directory snapshot = Directory(
        '${fixture.temporary.path}/direct-snapshot',
      )..createSync();
      final Directory source = Directory(
        '${fixture.temporary.path}/direct-source',
      )..createSync();
      File('${source.path}/server.properties').writeAsStringSync('motd=test\n');
      final PterodactylSmbDirectSession session = await service
          .openDirectServerFiles(
            profileId: 'remote',
            serverIdentifier: 'ABC12345',
          );

      final Completer<PterodactylSmbCommandResult> snapshotProcess =
          Completer<PterodactylSmbCommandResult>();
      fixture.runner.directRcloneCompletion = snapshotProcess;
      bool snapshotFinished = false;
      final Future<void> snapshotFuture = session
          .snapshotTo(snapshot.path)
          .then((_) => snapshotFinished = true);
      await Future<void>.delayed(Duration.zero);

      expect(snapshotFinished, isFalse);
      expect(fixture.runner.directRuns, hasLength(1));
      snapshotProcess.complete(_success);
      await snapshotFuture;
      expect(snapshotFinished, isTrue);

      final Completer<PterodactylSmbCommandResult> mirrorProcess =
          Completer<PterodactylSmbCommandResult>();
      fixture.runner.directRcloneCompletion = mirrorProcess;
      bool mirrorFinished = false;
      final Future<void> mirrorFuture = session
          .applyFrom(
            sourcePath: source.path,
            mode: PterodactylSmbDirectWriteMode.mirror,
          )
          .then((_) => mirrorFinished = true);
      await Future<void>.delayed(Duration.zero);

      expect(mirrorFinished, isFalse);
      expect(fixture.runner.directRuns, hasLength(2));
      final _RunCommand mirror = fixture.runner.directRuns.last;
      expect(mirror.arguments.first, 'sync');
      expect(mirror.arguments, contains('--create-empty-src-dirs'));
      for (final String exclusion
          in PterodactylTransferPathPolicy.rcloneExclusions) {
        expect(mirror.arguments, contains(exclusion));
      }
      mirrorProcess.complete(_success);
      await mirrorFuture;
      await session.close();

      expect(mirrorFinished, isTrue);
      expect(fixture.runner.started, hasLength(1));
      expect(mount.alive, isTrue);
      expect(fixture.runner.killedPids, isEmpty);
      expect(fixture.runtimeStore.file.readAsStringSync(), runtimeBefore);
      expect(cacheSentinel.readAsStringSync(), 'pending browser write');
      expect(
        fixture.runner.runs.where(
          (_RunCommand command) =>
              command.executable == 'rclone' &&
              command.arguments.firstOrNull == 'rc',
        ),
        isEmpty,
      );
    },
  );

  test('direct transfer failure does not expose password material', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    const String clearPassword = 'clear-panel-secret';
    const String childDiagnostic = 'PRIVATE-CHILD-DIAGNOSTIC';
    final PterodactylSmbService service = fixture.service(
      passwordProvider: _PasswordProvider(clearPassword),
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
    final Directory snapshot = Directory(
      '${fixture.temporary.path}/failed-snapshot',
    )..createSync();
    fixture.runner.directRcloneResult = const PterodactylSmbCommandResult(
      exitCode: 37,
      stdout: clearPassword,
      stderr: '$childDiagnostic obscured-password',
    );
    final PterodactylSmbDirectSession session = await service
        .openDirectServerFiles(
          profileId: 'remote',
          serverIdentifier: 'abc12345',
        );

    Object? failure;
    try {
      await session.snapshotTo(snapshot.path);
    } catch (error) {
      failure = error;
    } finally {
      await session.close();
    }

    expect(failure, isA<StateError>());
    final String message = failure.toString();
    expect(message, contains('exit code 37'));
    expect(message, isNot(contains(clearPassword)));
    expect(message, isNot(contains(childDiagnostic)));
    expect(message, isNot(contains('obscured-password')));
    final _RunCommand direct = fixture.runner.directRuns.single;
    expect(direct.arguments.join(' '), isNot(contains(clearPassword)));
    expect(direct.environment.values, isNot(contains(clearPassword)));
  });

  test('direct snapshot refuses case-colliding Remote paths', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      passwordProvider: _PasswordProvider('panel-secret'),
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
    fixture.runner.directListingJson =
        '[{"Path":"Foo.jar"},{"Path":"foo.jar"}]';
    final Directory snapshot = Directory(
      '${fixture.temporary.path}/colliding-snapshot',
    )..createSync();
    final PterodactylSmbDirectSession session = await service
        .openDirectServerFiles(
          profileId: 'remote',
          serverIdentifier: 'abc12345',
        );
    addTearDown(session.close);

    await expectLater(
      session.snapshotTo(snapshot.path),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('case-colliding'),
        ),
      ),
    );

    expect(fixture.runner.directRuns, isEmpty);
    expect(fixture.runner.started, isEmpty);
  });

  test(
    'direct snapshot refuses NFC and NFD-colliding Remote paths on macOS',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService service = fixture.service(
        passwordProvider: _PasswordProvider('panel-secret'),
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
      fixture.runner.directListingJson = jsonEncode(<Map<String, String>>[
        <String, String>{'Path': 'Caf\u00e9/server.properties'},
        <String, String>{'Path': 'Cafe\u0301/server.properties'},
      ]);
      final Directory snapshot = Directory(
        '${fixture.temporary.path}/normalization-colliding-snapshot',
      )..createSync();
      final PterodactylSmbDirectSession session = await service
          .openDirectServerFiles(
            profileId: 'remote',
            serverIdentifier: 'abc12345',
          );
      addTearDown(session.close);

      await expectLater(
        session.snapshotTo(snapshot.path),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            allOf(
              contains('Unicode-normalization-colliding'),
              contains('macOS'),
            ),
          ),
        ),
      );

      expect(fixture.runner.directRuns, isEmpty);
      expect(fixture.runner.started, isEmpty);
    },
  );

  test(
    'direct snapshot keeps differently normalized names distinct off macOS',
    () async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.close);
      final PterodactylSmbService service = fixture.service(
        passwordProvider: _PasswordProvider('panel-secret'),
        operatingSystem: PterodactylSmbOperatingSystem.linux,
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
      fixture.runner.directListingJson = jsonEncode(<Map<String, String>>[
        <String, String>{'Path': 'Caf\u00e9/server.properties'},
        <String, String>{'Path': 'Cafe\u0301/server.properties'},
      ]);
      final Directory snapshot = Directory(
        '${fixture.temporary.path}/normalization-distinct-snapshot',
      )..createSync();
      final PterodactylSmbDirectSession session = await service
          .openDirectServerFiles(
            profileId: 'remote',
            serverIdentifier: 'abc12345',
          );
      addTearDown(session.close);

      await session.snapshotTo(snapshot.path);

      expect(fixture.runner.directRuns, hasLength(1));
      expect(fixture.runner.started, isEmpty);
    },
  );

  test('direct snapshot refuses Windows-reserved Remote paths', () async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.close);
    final PterodactylSmbService service = fixture.service(
      passwordProvider: _PasswordProvider('panel-secret'),
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
    fixture.runner.directListingJson = '[{"Path":"world/CON.dat"}]';
    final Directory snapshot = Directory(
      '${fixture.temporary.path}/reserved-snapshot',
    )..createSync();
    final PterodactylSmbDirectSession session = await service
        .openDirectServerFiles(
          profileId: 'remote',
          serverIdentifier: 'abc12345',
        );
    addTearDown(session.close);

    await expectLater(
      session.snapshotTo(snapshot.path),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('reserved path'),
        ),
      ),
    );

    expect(fixture.runner.directRuns, isEmpty);
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
    Duration processStopTimeout = const Duration(seconds: 30),
    Duration lifecycleLockTimeout = const Duration(seconds: 30),
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
    processStopTimeout: processStopTimeout,
    lifecycleLockTimeout: lifecycleLockTimeout,
  );

  void close() => temporary.deleteSync(recursive: true);
}

final class _FakeRunner implements PterodactylSmbProcessRunner {
  final List<_StartedProcess> started = <_StartedProcess>[];
  final List<_RunCommand> runs = <_RunCommand>[];
  final Map<int, String> externalDescriptions = <int, String>{};
  final List<int> killedPids = <int>[];
  final List<ProcessSignal> killSignals = <ProcessSignal>[];
  bool shareRegistered = false;
  bool failShareCreate = false;
  bool failUnmount = false;
  bool failNormalUnmount = false;
  bool forceMountVisible = false;
  bool hideMountsOnce = false;
  bool simulateWindowsMounts = false;
  bool ignoreTerminate = false;
  String? openedPath;
  int? failStartNumber;
  String? obscureStdin;
  int keygenRuns = 0;
  Completer<PterodactylSmbCommandResult>? directRcloneCompletion;
  PterodactylSmbCommandResult? directRcloneResult;
  String directListingJson = '[]';
  Completer<void>? startEntered;
  Completer<void>? releaseStart;

  List<_RunCommand> get directRuns => runs
      .where(
        (_RunCommand command) =>
            command.executable == 'rclone' &&
            <String>['copy', 'sync'].contains(command.arguments.firstOrNull) &&
            command.arguments.contains('--config='),
      )
      .toList(growable: false);

  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    final _RunCommand command = _RunCommand(
      executable: executable,
      arguments: List<String>.from(arguments),
      environment: Map<String, String>.from(
        environment ?? const <String, String>{},
      ),
    );
    runs.add(command);
    if (executable == 'rclone' &&
        arguments.firstOrNull == 'lsjson' &&
        arguments.contains('--config=')) {
      return PterodactylSmbCommandResult(
        exitCode: 0,
        stdout: directListingJson,
        stderr: '',
      );
    }
    if (executable == 'rclone' &&
        <String>['copy', 'sync'].contains(arguments.firstOrNull) &&
        arguments.contains('--config=')) {
      final Completer<PterodactylSmbCommandResult>? completion =
          directRcloneCompletion;
      if (completion != null) return completion.future;
      return directRcloneResult ?? _success;
    }
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
      if (failNormalUnmount &&
          executable == '/usr/sbin/diskutil' &&
          arguments.length >= 2 &&
          arguments[0] == 'unmount' &&
          arguments[1] != 'force') {
        return const PterodactylSmbCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'simulated stale NFS mount',
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
    killSignals.add(signal);
    if (ignoreTerminate && signal == ProcessSignal.sigterm) return true;
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
    bool detached = false,
  }) async {
    final _StartedProcess process = _StartedProcess(
      pid: 100 + started.length,
      arguments: List<String>.from(arguments),
      environment: Map<String, String>.from(
        environment ?? const <String, String>{},
      ),
      failImmediately: failStartNumber == started.length + 1,
      detached: detached,
    );
    if (simulateWindowsMounts && arguments.length > 2) {
      Directory(arguments[2]).createSync(recursive: true);
    }
    started.add(process);
    final Completer<void>? entered = startEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await releaseStart?.future;
    return process;
  }
}

final class _RunCommand {
  const _RunCommand({
    required this.executable,
    required this.arguments,
    required this.environment,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
}

final class _StartedProcess implements PterodactylSmbProcessHandle {
  _StartedProcess({
    required this.pid,
    required this.arguments,
    required this.environment,
    required this.failImmediately,
    required this.detached,
  });

  @override
  final int pid;
  final List<String> arguments;
  final Map<String, String> environment;
  final bool failImmediately;
  final bool detached;
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

const PterodactylSmbCommandResult _success = PterodactylSmbCommandResult(
  exitCode: 0,
  stdout: '',
  stderr: '',
);

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
