import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_share.dart';
import 'package:test/test.dart';

void main() {
  test('macOS share is authenticated, writable, and SMB-encrypted', () async {
    final _ShareRunner runner = _ShareRunner();
    final PterodactylSmbShareManager manager = PterodactylSmbShareManager(
      runner: runner,
      operatingSystem: PterodactylSmbOperatingSystem.macos,
    );

    await manager.create(_settings());

    expect(runner.lastExecutable, '/usr/bin/sudo');
    expect(runner.lastArguments, <String>[
      '-n',
      '/usr/sbin/sharing',
      '-a',
      '/tmp/multiplexor-files',
      '-S',
      'Multiplexor',
      '-s',
      '001',
      '-g',
      '000',
      '-R',
      '0',
      '-E',
      '1',
    ]);
  });

  test('Linux usershare disables guest access', () async {
    final _ShareRunner runner = _ShareRunner();
    final PterodactylSmbShareManager manager = PterodactylSmbShareManager(
      runner: runner,
      operatingSystem: PterodactylSmbOperatingSystem.linux,
    );

    await manager.create(_settings());

    expect(runner.lastExecutable, 'net');
    expect(runner.lastArguments, contains('guest_ok=n'));
  });

  test('share command failure is sanitized and surfaced', () async {
    final _ShareRunner runner = _ShareRunner(exitCode: 1, stderr: 'denied');
    final PterodactylSmbShareManager manager = PterodactylSmbShareManager(
      runner: runner,
      operatingSystem: PterodactylSmbOperatingSystem.macos,
    );

    await expectLater(manager.create(_settings()), throwsStateError);
  });
}

PterodactylSmbSettings _settings() => PterodactylSmbSettings(
  shareName: 'Multiplexor',
  mountRoot: '/tmp/multiplexor-files',
  knownHostsFile: '/tmp/multiplexor-known-hosts',
  accounts: const <PterodactylSftpAccount>[],
);

final class _ShareRunner implements PterodactylSmbProcessRunner {
  _ShareRunner({this.exitCode = 0, this.stderr = ''});

  final int exitCode;
  final String stderr;
  String? lastExecutable;
  List<String>? lastArguments;

  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    lastExecutable = executable;
    lastArguments = List<String>.from(arguments);
    return PterodactylSmbCommandResult(
      exitCode: exitCode,
      stdout: '',
      stderr: stderr,
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
  }) => throw UnimplementedError();
}
