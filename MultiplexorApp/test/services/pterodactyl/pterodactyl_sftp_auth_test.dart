import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_sftp_key_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_sftp_password_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:test/test.dart';

void main() {
  test(
    'environment password is bound to profile origin and username',
    () async {
      final PterodactylProfile profile = _profile();
      final PterodactylSftpAccount account = _account();
      final String passwordVariable =
          PterodactylSftpPasswordStore.environmentVariableFor(account);
      final String originVariable =
          PterodactylSftpPasswordStore.environmentOriginVariableFor(account);
      final String usernameVariable =
          PterodactylSftpPasswordStore.environmentUsernameVariableFor(account);
      final PterodactylSftpPasswordStore valid = PterodactylSftpPasswordStore(
        environment: <String, String>{
          passwordVariable: 'panel-password',
          originVariable: profile.origin,
          usernameVariable: account.panelUsername,
        },
      );

      expect((await valid.read(profile, account))!.value, 'panel-password');
      expect(
        (await valid.read(profile, account)).toString(),
        contains('REDACTED'),
      );

      final PterodactylSftpPasswordStore wrongOrigin =
          PterodactylSftpPasswordStore(
            environment: <String, String>{
              passwordVariable: 'panel-password',
              originVariable: 'https://evil.example.test',
              usernameVariable: account.panelUsername,
            },
          );
      await expectLater(wrongOrigin.read(profile, account), throwsStateError);
    },
  );

  test('key store creates a private key without exposing it as text', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-sftp-key-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final _KeygenRunner runner = _KeygenRunner();
    final PterodactylSftpKeyStore store = PterodactylSftpKeyStore(
      metadataDirectoryPath: temporary.path,
      runner: runner,
    );

    final PterodactylSftpKeyPair pair = await store.ensure(_profile());

    expect(File(pair.privateKeyPath).readAsStringSync(), 'PRIVATE\n');
    expect(pair.publicKey, startsWith('ssh-ed25519 '));
    expect(pair.toString(), isNot(contains('PRIVATE')));
    expect(
      runner.commands.singleWhere(
        (String value) => value.contains('ssh-keygen'),
      ),
      isNot(contains('PRIVATE')),
    );
    expect(store.hasPrivateKey(_profile()), isTrue);
  });
}

PterodactylProfile _profile() => PterodactylProfile(
  id: 'remote',
  name: 'Remote',
  panelUri: Uri.parse('https://panel.example.test'),
);

PterodactylSftpAccount _account() =>
    PterodactylSftpAccount(profileId: 'remote', panelUsername: 'operator');

final class _KeygenRunner implements PterodactylSmbProcessRunner {
  final List<String> commands = <String>[];

  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    commands.add('$executable ${arguments.join(' ')}');
    if (executable == 'ssh-keygen') {
      final String path = arguments[arguments.indexOf('-f') + 1];
      File(path).writeAsStringSync('PRIVATE\n');
      File('$path.pub').writeAsStringSync(
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusTestKey '
        'multiplexor-smb:remote\n',
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
  Future<String?> describeProcess(int pid) async => null;

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  Future<PterodactylSmbProcessHandle> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool detached = false,
  }) => throw UnimplementedError();
}
