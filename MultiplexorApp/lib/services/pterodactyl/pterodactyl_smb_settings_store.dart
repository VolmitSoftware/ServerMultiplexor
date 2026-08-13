import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'pterodactyl_smb_models.dart';

/// Persists only non-secret SMB and SFTP connection metadata.
final class PterodactylSmbSettingsStore {
  PterodactylSmbSettingsStore(String metadataDirectoryPath)
    : file = File(p.join(metadataDirectoryPath, 'pterodactyl-smb.json'));

  PterodactylSmbSettingsStore.atFile(this.file);

  static const int schemaVersion = 1;
  static const Set<String> _rootKeys = <String>{
    'schema_version',
    'share_name',
    'mount_root',
    'known_hosts_file',
    'require_smb_encryption',
    'accounts',
  };
  static const Set<String> _accountKeys = <String>{
    'profile_id',
    'panel_username',
    'enabled',
    'use_managed_key',
  };

  final File file;

  PterodactylSmbSettings? load() {
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw const FormatException('Invalid Pterodactyl SMB settings JSON.');
    }
    final Map<String, Object?> root = _object(decoded, 'settings');
    _checkKeys(root, _rootKeys, 'settings');
    if (root['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported Pterodactyl SMB schema.');
    }
    final Object? rawAccounts = root['accounts'];
    if (rawAccounts is! List<Object?>) {
      throw const FormatException('Pterodactyl SMB accounts must be a list.');
    }
    final List<PterodactylSftpAccount> accounts = <PterodactylSftpAccount>[];
    for (final Object? rawAccount in rawAccounts) {
      final Map<String, Object?> account = _object(rawAccount, 'account');
      _checkKeys(account, _accountKeys, 'account');
      accounts.add(
        PterodactylSftpAccount(
          profileId: _string(account, 'profile_id'),
          panelUsername: _string(account, 'panel_username'),
          enabled: _boolean(account, 'enabled'),
          useManagedKey: account['use_managed_key'] == null
              ? true
              : _boolean(account, 'use_managed_key'),
        ),
      );
    }
    return PterodactylSmbSettings(
      shareName: _string(root, 'share_name'),
      mountRoot: _string(root, 'mount_root'),
      knownHostsFile: _string(root, 'known_hosts_file'),
      requireSmbEncryption: _boolean(root, 'require_smb_encryption'),
      accounts: accounts,
    );
  }

  void save(PterodactylSmbSettings settings) {
    file.parent.createSync(recursive: true);
    final File temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    final List<PterodactylSftpAccount> accounts =
        settings.accounts.values.toList(growable: false)..sort(
          (PterodactylSftpAccount left, PterodactylSftpAccount right) =>
              left.profileId.compareTo(right.profileId),
        );
    final Map<String, Object?> encoded = <String, Object?>{
      'schema_version': schemaVersion,
      'share_name': settings.shareName,
      'mount_root': settings.mountRoot,
      'known_hosts_file': settings.knownHostsFile,
      'require_smb_encryption': settings.requireSmbEncryption,
      'accounts': <Object?>[
        for (final PterodactylSftpAccount account in accounts)
          <String, Object?>{
            'profile_id': account.profileId,
            'panel_username': account.panelUsername,
            'enabled': account.enabled,
            'use_managed_key': account.useManagedKey,
          },
      ],
    };
    try {
      temporary.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(encoded)}\n',
        flush: true,
      );
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  static Map<String, Object?> _object(Object? value, String label) {
    if (value is! Map<String, Object?>) {
      throw FormatException('Pterodactyl SMB $label must be an object.');
    }
    return value;
  }

  static void _checkKeys(
    Map<String, Object?> value,
    Set<String> allowed,
    String label,
  ) {
    for (final String key in value.keys) {
      if (!allowed.contains(key)) {
        throw FormatException(
          'Pterodactyl SMB $label contains an unsupported field.',
        );
      }
    }
  }

  static String _string(Map<String, Object?> value, String key) {
    final Object? field = value[key];
    if (field is! String) {
      throw FormatException('Pterodactyl SMB field $key is invalid.');
    }
    return field;
  }

  static bool _boolean(Map<String, Object?> value, String key) {
    final Object? field = value[key];
    if (field is! bool) {
      throw FormatException('Pterodactyl SMB field $key is invalid.');
    }
    return field;
  }
}
