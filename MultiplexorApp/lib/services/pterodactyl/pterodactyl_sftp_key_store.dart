import 'dart:io';

import 'package:path/path.dart' as p;

import 'pterodactyl_profile.dart';
import 'pterodactyl_smb_process.dart';

final class PterodactylSftpKeyPair {
  const PterodactylSftpKeyPair({
    required this.privateKeyPath,
    required this.publicKey,
    required this.name,
  });

  final String privateKeyPath;
  final String publicKey;
  final String name;
}

/// Owns one non-interactive ed25519 SFTP identity per Panel profile.
///
/// The private key is never returned as text, passed in argv, or copied into
/// configuration. `ssh-keygen` writes it directly into a mode-0700 directory;
/// the resulting file is forced to mode 0600 before it can be used.
final class PterodactylSftpKeyStore {
  PterodactylSftpKeyStore({
    required String metadataDirectoryPath,
    required PterodactylSmbProcessRunner runner,
  }) : _keysDirectory = Directory(
         p.join(metadataDirectoryPath, 'pterodactyl-smb', 'keys'),
       ),
       _runner = runner;

  final Directory _keysDirectory;
  final PterodactylSmbProcessRunner _runner;

  String privateKeyPath(PterodactylProfile profile) =>
      p.join(_keysDirectory.path, '${profile.id}.ed25519');

  String publicKeyPath(PterodactylProfile profile) =>
      '${privateKeyPath(profile)}.pub';

  String keyName(PterodactylProfile profile) =>
      'Multiplexor Drive (${profile.id})';

  bool hasPrivateKey(PterodactylProfile profile) {
    final File key = File(privateKeyPath(profile));
    final File publicKey = File(publicKeyPath(profile));
    return FileSystemEntity.typeSync(key.path, followLinks: false) ==
            FileSystemEntityType.file &&
        key.lengthSync() > 0 &&
        FileSystemEntity.typeSync(publicKey.path, followLinks: false) ==
            FileSystemEntityType.file &&
        publicKey.lengthSync() > 0;
  }

  Future<PterodactylSftpKeyPair> ensure(PterodactylProfile profile) async {
    _prepareDirectory();
    final String privatePath = privateKeyPath(profile);
    final String publicPath = publicKeyPath(profile);
    final File privateKey = File(privatePath);
    final File publicKey = File(publicPath);

    final FileSystemEntityType privateType = FileSystemEntity.typeSync(
      privatePath,
      followLinks: false,
    );
    final FileSystemEntityType publicType = FileSystemEntity.typeSync(
      publicPath,
      followLinks: false,
    );
    if ((privateType != FileSystemEntityType.notFound &&
            privateType != FileSystemEntityType.file) ||
        (publicType != FileSystemEntityType.notFound &&
            publicType != FileSystemEntityType.file)) {
      throw StateError('Multiplexor SFTP keys must be real files, not links.');
    }

    if ((privateType == FileSystemEntityType.file) !=
        (publicType == FileSystemEntityType.file)) {
      throw StateError(
        'Incomplete Multiplexor SFTP key pair for ${profile.id}; restore or '
        'remove both files before retrying.',
      );
    }
    if (!privateKey.existsSync()) {
      final PterodactylSmbCommandResult generated = await _runner
          .run('ssh-keygen', <String>[
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-C',
            'multiplexor-smb:${profile.id}',
            '-f',
            privatePath,
          ]);
      if (generated.exitCode != 0) {
        throw StateError(
          'Unable to generate an ed25519 SFTP key for ${profile.id}.',
        );
      }
    }
    await _enforcePermissions(privatePath, publicPath);
    if (privateKey.lengthSync() == 0 || publicKey.lengthSync() == 0) {
      throw StateError('The generated SFTP key pair is empty.');
    }
    final String publicKeyText = publicKey.readAsStringSync().trim();
    if (!RegExp(
      r'^ssh-ed25519 [A-Za-z0-9+/]+=*(?: .*)?$',
    ).hasMatch(publicKeyText)) {
      throw StateError('The generated SFTP public key is invalid.');
    }
    return PterodactylSftpKeyPair(
      privateKeyPath: privatePath,
      publicKey: publicKeyText,
      name: keyName(profile),
    );
  }

  void _prepareDirectory() {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      _keysDirectory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw StateError(
        'The Multiplexor SFTP key path must be a real directory.',
      );
    }
    if (!_keysDirectory.existsSync()) {
      _keysDirectory.createSync(recursive: true);
    }
  }

  Future<void> _enforcePermissions(
    String privatePath,
    String publicPath,
  ) async {
    if (Platform.isWindows) return;
    final PterodactylSmbCommandResult directoryMode = await _runner.run(
      'chmod',
      <String>['700', _keysDirectory.path],
    );
    final PterodactylSmbCommandResult privateMode = await _runner.run(
      'chmod',
      <String>['600', privatePath],
    );
    final PterodactylSmbCommandResult publicMode = await _runner.run(
      'chmod',
      <String>['644', publicPath],
    );
    if (directoryMode.exitCode != 0 ||
        privateMode.exitCode != 0 ||
        publicMode.exitCode != 0) {
      throw StateError('Unable to secure the Multiplexor SFTP key files.');
    }
  }
}
