import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_runtime_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_settings_store.dart';
import 'package:test/test.dart';

void main() {
  test('settings store round-trips non-secret account metadata', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-smb-settings-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylSmbSettingsStore store = PterodactylSmbSettingsStore(
      temporary.path,
    );
    final PterodactylSmbSettings settings = PterodactylSmbSettings(
      shareName: 'Multiplexor',
      mountRoot: '${temporary.path}/files',
      knownHostsFile: '${temporary.path}/known_hosts',
      requireSmbEncryption: true,
      accounts: <PterodactylSftpAccount>[
        PterodactylSftpAccount(profileId: 'remote', panelUsername: 'operator'),
      ],
    );

    store.save(settings);
    final PterodactylSmbSettings loaded = store.load()!;

    expect(loaded.shareName, settings.shareName);
    expect(loaded.mountRoot, settings.mountRoot);
    expect(loaded.accounts['remote']!.panelUsername, 'operator');
    expect(store.file.readAsStringSync(), isNot(contains('password')));
    expect(store.file.readAsStringSync(), isNot(contains('private_key')));
  });

  test('settings store rejects unknown fields', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-smb-settings-invalid-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylSmbSettingsStore store = PterodactylSmbSettingsStore(
      temporary.path,
    );
    store.file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'share_name': 'Multiplexor',
          'mount_root': '${temporary.path}/files',
          'known_hosts_file': '${temporary.path}/known_hosts',
          'require_smb_encryption': true,
          'accounts': const <Object?>[],
          'api_key': 'must-not-be-accepted',
        }),
      );

    expect(store.load, throwsFormatException);
  });

  test('legacy account settings default to managed SSH keys', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-smb-settings-v1-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylSmbSettingsStore store = PterodactylSmbSettingsStore(
      temporary.path,
    );
    store.file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'share_name': 'Multiplexor',
          'mount_root': '${temporary.path}/files',
          'known_hosts_file': '${temporary.path}/known_hosts',
          'require_smb_encryption': true,
          'accounts': <Object?>[
            <String, Object?>{
              'profile_id': 'remote',
              'panel_username': 'operator',
              'enabled': true,
            },
          ],
        }),
      );

    expect(store.load()!.accounts['remote']!.useManagedKey, isTrue);
  });

  test('runtime state stores only recovery metadata', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-smb-runtime-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylSmbRuntimeStore store = PterodactylSmbRuntimeStore(
      temporary.path,
    );
    final DateTime startedAt = DateTime.utc(2026, 8, 12, 12);
    store.save(
      PterodactylSmbRuntimeState(
        shareName: 'Multiplexor',
        mountRoot: '${temporary.path}/files',
        startedAt: startedAt,
        shareRegistered: true,
        mounts: <PterodactylSmbRuntimeMount>[
          PterodactylSmbRuntimeMount(
            profileId: 'remote',
            serverIdentifier: 'abc12345',
            serverName: 'Server',
            mountPath: '${temporary.path}/files/remote/server--abc12345',
            remoteName: 'mx_remote_abc12345',
            pid: 123,
          ),
        ],
      ),
    );

    final PterodactylSmbRuntimeState loaded = store.load()!;

    expect(loaded.startedAt, startedAt);
    expect(loaded.mounts.single.pid, 123);
    expect(store.file.readAsStringSync(), isNot(contains('password')));
    expect(store.file.readAsStringSync(), isNot(contains('api_key')));
  });
}
