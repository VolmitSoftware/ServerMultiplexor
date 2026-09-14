import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  bool nodeAvailable;
  try {
    nodeAvailable =
        Process.runSync('node', <String>['--version']).exitCode == 0;
  } on ProcessException {
    nodeAvailable = false;
  }
  late Directory root;
  late GameplayTestService harness;
  late File cli;

  setUp(() {
    root = Directory.systemTemp.createTempSync(
      'multiplexor sessions [transport] ',
    );
    harness = GameplayTestService(
      context: ManagerContext(rootDir: root.path, verbose: false),
    );
    cli = File(p.join(harness.harnessDirectory, 'src', 'cli.mjs'))
      ..createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'session validation passes paths literally through a Node process',
    () async {
      cli.writeAsStringSync(
        'process.stdout.write(JSON.stringify(process.argv.slice(2)));\n',
      );
      final List<String> output = <String>[];
      final List<String> errors = <String>[];
      final String profile = p.join(
        root.path,
        r'profile $(echo surprise) [one].json',
      );
      final String configuration = p.join(
        root.path,
        'run folder',
        'configuration.json',
      );
      final int result = await harness.sessionsValidate(
        profilePath: profile,
        configurationPath: configuration,
        write: output.add,
        error: errors.add,
      );
      expect(result, 0);
      expect(errors, isEmpty);
      expect(jsonDecode(output.single), <String>[
        'sessions-validate',
        '--profile',
        profile,
        '--configuration',
        configuration,
        '--json',
      ]);
    },
    skip: nodeAvailable ? false : 'Node is required',
  );

  test(
    'supervisor transport waits for worker cleanup after SIGTERM',
    () async {
      cli.writeAsStringSync(r'''
import { writeFileSync } from 'node:fs'
const config = process.argv[process.argv.indexOf('--configuration') + 1]
const timer = setInterval(() => {}, 1000)
process.on('SIGTERM', () => {
  setTimeout(() => {
    writeFileSync(config + '.cleanup', 'worker disconnected')
    clearInterval(timer)
    process.exit(143)
  }, 100)
})
process.stdout.write('worker-ready\n')
''');
      final File script = File(p.join(root.path, 'session-host-fixture.dart'));
      script.writeAsStringSync('''
import 'dart:io';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
Future<void> main(List<String> args) async {
  final GameplayTestService harness = GameplayTestService(context: ManagerContext(rootDir: args[0], verbose: false));
  final int result = await harness.sessionsRun(configurationPath: args[1], write: stdout.writeln, error: stderr.writeln);
  exit(result);
}
''');
      final String configuration = p.join(root.path, 'configuration.json');
      final Process
      child = await Process.start(Platform.resolvedExecutable, <String>[
        '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
        script.path,
        root.path,
        configuration,
      ]);
      final StringBuffer errors = StringBuffer();
      final Future<void> stderrDone = child.stderr
          .transform(utf8.decoder)
          .forEach(errors.write);
      final Completer<void> ready = Completer<void>();
      final Future<void> stdoutDone = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((String line) {
            if (line == 'worker-ready' && !ready.isCompleted) ready.complete();
          });
      try {
        await ready.future.timeout(const Duration(seconds: 20));
        expect(child.kill(ProcessSignal.sigterm), true);
        expect(
          await child.exitCode.timeout(const Duration(seconds: 10)),
          143,
          reason: errors.toString(),
        );
        await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
        expect(
          File('$configuration.cleanup').readAsStringSync(),
          'worker disconnected',
        );
      } finally {
        child.kill(ProcessSignal.sigkill);
      }
    },
    skip: !nodeAvailable || Platform.isWindows
        ? 'Requires Node and POSIX signals'
        : false,
  );
}
