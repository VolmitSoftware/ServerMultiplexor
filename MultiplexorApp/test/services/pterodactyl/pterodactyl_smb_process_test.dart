import 'dart:io';
import 'dart:isolate';

import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:test/test.dart';

void main() {
  test(
    'command diagnostics remove terminal control sequences and truncate',
    () {
      final PterodactylSmbCommandResult result = PterodactylSmbCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: '\x1b[2Jdanger\x00${'x' * 1200}',
      );

      expect(result.diagnostic, startsWith('danger'));
      expect(result.diagnostic, isNot(contains('\x1b')));
      expect(result.diagnostic, isNot(contains('\x00')));
      expect(result.diagnostic.length, 1003);
    },
  );

  test(
    'detached handles poll process lifetime without reading exitCode',
    () async {
      final DartIoPterodactylSmbProcessRunner runner =
          const DartIoPterodactylSmbProcessRunner();
      final PterodactylSmbProcessHandle handle = await runner.start(
        '/bin/sleep',
        const <String>['0.2'],
        detached: true,
      );

      expect(
        await handle.waitForExit(const Duration(milliseconds: 20)),
        isNull,
      );
      expect(await handle.waitForExit(const Duration(seconds: 2)), 0);
    },
    skip: Platform.isWindows,
  );

  test(
    'detached process survives the short-lived creator process',
    () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-detached-process-',
      );
      addTearDown(() {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
      final Uri? packageConfig = await Isolate.packageConfig;
      expect(packageConfig, isNotNull);
      final File childScript = File('${temporary.path}/spawn.dart')
        ..writeAsStringSync('''
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';

Future<void> main() async {
  final PterodactylSmbProcessHandle handle =
      await const DartIoPterodactylSmbProcessRunner().start(
    '/bin/sleep',
    const <String>['10'],
    detached: true,
  );
  print(handle.pid);
}
''');

      final ProcessResult creator = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          '--packages=${File.fromUri(packageConfig!).path}',
          childScript.path,
        ],
        runInShell: false,
      );
      expect(creator.exitCode, 0, reason: creator.stderr.toString());
      final int childPid = int.parse(creator.stdout.toString().trim());
      addTearDown(() => Process.killPid(childPid, ProcessSignal.sigkill));

      final ProcessResult alive = await Process.run('ps', <String>[
        '-p',
        '$childPid',
        '-o',
        'command=',
      ], runInShell: false);
      expect(alive.exitCode, 0);
      expect(alive.stdout.toString(), contains('/bin/sleep 10'));

      expect(Process.killPid(childPid), isTrue);
    },
    skip: Platform.isWindows,
  );
}
