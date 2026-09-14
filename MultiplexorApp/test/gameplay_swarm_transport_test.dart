import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/gameplay_swarm.dart';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final bool nodeAvailable = _nodeAvailable();
  late Directory root;
  late GameplayTestService service;
  late List<String> output;
  late List<String> errors;

  setUp(() {
    root = Directory.systemTemp.createTempSync(
      'multiplexor swarm [transport] ',
    );
    service = GameplayTestService(
      context: ManagerContext(rootDir: root.path, verbose: false),
    );
    File(p.join(service.harnessDirectory, 'src', 'cli.mjs'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
process.stdout.write(JSON.stringify({argv: process.argv.slice(2), cwd: process.cwd()}) + '\n');
process.stderr.write('fixture stderr\n');
process.exitCode = 7;
''');
    output = <String>[];
    errors = <String>[];
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'swarm passes paths and bounded options intact through a real Node process',
    () async {
      final String plan = p.join(
        root.path,
        r'plan $(echo surprise) [one].json',
      );
      final String artifacts = p.join(root.path, 'report folder');
      final String logPath = p.join(root.path, 'runtime [fixture].log');
      final GameplaySwarmSettings settings = GameplaySwarmSettings.parse(
        profile: plan,
        options: const <String, String>{
          'bots': '256',
          'duration': '604800',
          'seed': '4294967295',
          'join-interval': '100',
          'radius': '64',
          'origin': '-12,80,14',
          'prefix': 'Worker',
          'scatter': '4096',
          'connect-timeout': '12',
          'action-timeout': '13',
        },
        flags: const <String>{'chat'},
        generatedPrefix: 'unused',
      );
      final int exitCode = await service.swarm(
        run: GameplaySwarmRun(
          settings: settings,
          controller: 'Sc1234567890ab',
          host: '::1',
          port: 25565,
          instance: 'fixture',
          artifactsDirectory: artifacts,
          logPath: logPath,
          version: '1.21.11',
          viewerEnabled: true,
          viewerPort: 3001,
          json: true,
        ),
        write: output.add,
        error: errors.add,
      );
      expect(exitCode, 7);
      expect(errors, <String>['fixture stderr']);
      final Map<String, Object?> received =
          (jsonDecode(output.single) as Map<String, Object?>);
      final List<String> arguments = (received['argv']! as List<Object?>)
          .cast<String>();
      expect(arguments.take(2), <String>['swarm', plan]);
      String value(String flag) => arguments[arguments.indexOf(flag) + 1];
      expect(value('--artifacts'), artifacts);
      expect(value('--log-path'), logPath);
      expect(value('--host'), '::1');
      expect(value('--bots'), '256');
      expect(value('--duration'), '604800');
      expect(value('--seed'), '4294967295');
      expect(value('--join-interval'), '100');
      expect(value('--origin'), '-12,80,14');
      expect(value('--scatter'), '4096');
      expect(value('--controller'), 'Sc1234567890ab');
      expect(value('--viewer-port'), '3001');
      expect(arguments, containsAll(<String>['--chat', '--json']));
      expect(arguments, isNot(contains('--build-arena')));
      expect(arguments, isNot(contains('--no-viewer')));
      expect(
        Directory(received['cwd']! as String).resolveSymbolicLinksSync(),
        Directory(service.harnessDirectory).resolveSymbolicLinksSync(),
      );
    },
    skip: nodeAvailable ? false : 'Node is required for the transport fixture',
  );

  test(
    'ordinary swarms omit privileged and viewer arguments',
    () async {
      final int exitCode = await service.swarm(
        run: GameplaySwarmRun(
          settings: GameplaySwarmSettings.parse(
            profile: 'wander',
            options: const <String, String>{},
            flags: const <String>{},
            generatedPrefix: 'Workers',
          ),
          host: '127.0.0.1',
          port: 25565,
          instance: 'fixture',
          artifactsDirectory: root.path,
          logPath: p.join(root.path, 'runtime.log'),
          viewerEnabled: false,
          json: false,
        ),
        write: output.add,
        error: errors.add,
      );
      expect(exitCode, 7);
      final Map<String, Object?> received =
          jsonDecode(output.single) as Map<String, Object?>;
      final List<Object?> arguments = received['argv']! as List<Object?>;
      expect(arguments.take(2), <String>['swarm', 'wander']);
      expect(arguments, contains('--no-viewer'));
      for (final String absent in <String>[
        '--controller',
        '--scatter',
        '--build-arena',
        '--viewer-port',
        '--version',
      ]) {
        expect(arguments, isNot(contains(absent)));
      }
    },
    skip: nodeAvailable ? false : 'Node is required for the transport fixture',
  );

  test(
    'stress preflight and run preserve workload controls',
    () async {
      final String path = p.join(root.path, r'workload $(not-a-command).json');
      final GameplaySwarmSettings settings = GameplaySwarmSettings.parse(
        profile: 'stress',
        options: <String, String>{
          'workload': path,
          'bots': '256',
          'duration': '604800',
          'bounds': '-32,80,-32:32,96,32',
          'goals': 'mine=10000,build=10000',
          'completion': 'goals',
        },
        flags: const <String>{'build-arena'},
        generatedPrefix: 'Worker',
      );
      expect(
        await service.swarmWorkloadValidate(
          settings: settings,
          write: output.add,
          error: errors.add,
        ),
        7,
      );
      final Map<String, Object?> received =
          jsonDecode(output.single) as Map<String, Object?>;
      final List<String> arguments = (received['argv']! as List<Object?>)
          .cast<String>();
      expect(arguments.take(2), <String>['swarm-workload-validate', path]);
      String value(String flag) => arguments[arguments.indexOf(flag) + 1];
      expect(value('--bots'), '256');
      expect(value('--duration'), '604800');
      expect(value('--bounds'), '-32,80,-32:32,96,32');
      expect(value('--goals'), 'mine=10000,build=10000');
      expect(value('--completion'), 'goals');
      expect(arguments, containsAll(<String>['--build-arena', '--json']));
      final GameplaySwarmRun run = GameplaySwarmRun(
        settings: settings,
        host: '127.0.0.1',
        port: 25565,
        instance: 'fixture',
        artifactsDirectory: root.path,
        logPath: p.join(root.path, 'runtime.log'),
        viewerEnabled: false,
        json: true,
        controller: 'Sc1234567890ab',
      );
      for (final String flag in <String>[
        '--bounds',
        '--goals',
        '--completion',
        '--bots',
        '--duration',
      ]) {
        expect(run.arguments[run.arguments.indexOf(flag) + 1], value(flag));
      }
      expect(run.arguments[run.arguments.indexOf('--workload') + 1], path);
    },
    skip: nodeAvailable ? false : 'Node is required for the transport fixture',
  );

  test(
    'custom plan validation preserves its path and child failure',
    () async {
      final String plan = p.join(root.path, 'untrusted plan [2].json');
      final int exitCode = await service.swarmValidate(
        plan,
        bots: 7,
        origin: '3,82,-5',
        write: output.add,
        error: errors.add,
      );
      expect(exitCode, 7);
      final Map<String, Object?> received =
          jsonDecode(output.single) as Map<String, Object?>;
      expect(received['argv'], <String>[
        'swarm-validate',
        plan,
        '--bots',
        '7',
        '--origin',
        '3,82,-5',
        '--json',
      ]);
      expect(errors, <String>['fixture stderr']);
    },
    skip: nodeAvailable ? false : 'Node is required for the transport fixture',
  );

  test(
    'SIGINT reaches the Node child and waits for its cleanup',
    () async {
      File(
        p.join(service.harnessDirectory, 'src', 'cli.mjs'),
      ).writeAsStringSync(r'''
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const hold = setInterval(() => {}, 1000);
process.once('SIGINT', () => {
  process.stdout.write('CHILD_SIGNAL\n');
  setTimeout(() => {
    const artifacts = process.argv[process.argv.indexOf('--artifacts') + 1];
    writeFileSync(join(artifacts, 'child-cleaned.txt'), 'cleaned');
    process.stdout.write('CHILD_CLEANUP\n');
    process.exitCode = 130;
    clearInterval(hold);
  }, 150);
});
process.stdout.write(`CHILD_READY:${process.pid}\n`);
''');
      final File driver = File(p.join(root.path, 'signal_driver.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';
import 'package:multiplexor/models/gameplay_swarm.dart';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
Future<void> main(List<String> arguments) async {
  final String root = arguments.single;
  final GameplayTestService harness = GameplayTestService(
    context: ManagerContext(rootDir: root, verbose: false),
  );
  final int code = await harness.swarm(
    run: GameplaySwarmRun(
      settings: GameplaySwarmSettings.parse(
        profile: 'idle', options: const {}, flags: const {}, generatedPrefix: 'Worker',
      ),
      host: '127.0.0.1', port: 25565, instance: 'fixture',
      artifactsDirectory: root, logPath: '$root/runtime.log',
      viewerEnabled: false, json: false,
    ),
    write: stdout.writeln, error: stderr.writeln,
  );
  stdout.writeln('PARENT_RETURN:$code');
  exitCode = code;
}
''');
      final String packageConfig = p.join(
        Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );
      final Process parent = await Process.start(
        Platform.resolvedExecutable,
        <String>['--packages=$packageConfig', driver.path, root.path],
      );
      final Completer<void> ready = Completer<void>();
      int? childPid;
      bool exited = false;
      bool childOutputClosed = false;
      final Future<int> exit = parent.exitCode.whenComplete(
        () => exited = true,
      );
      final Future<void> stdoutDone = parent.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((String line) {
            output.add(line);
            if (line.startsWith('CHILD_READY:')) {
              childPid = int.parse(line.split(':').last);
              ready.complete();
            }
          })
          .whenComplete(() => childOutputClosed = true);
      final Future<void> stderrDone = parent.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(errors.add);
      try {
        await ready.future.timeout(const Duration(seconds: 10));
        expect(parent.kill(ProcessSignal.sigint), isTrue);
        expect(await exit.timeout(const Duration(seconds: 10)), 130);
        await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
        expect(errors, isEmpty);
        expect(output.skip(1), <String>[
          'CHILD_SIGNAL',
          'CHILD_CLEANUP',
          'PARENT_RETURN:130',
        ]);
        expect(
          File(p.join(root.path, 'child-cleaned.txt')).readAsStringSync(),
          'cleaned',
        );
      } finally {
        if (!exited) parent.kill(ProcessSignal.sigkill);
        if (childPid != null && !childOutputClosed) {
          try {
            Process.killPid(childPid!, ProcessSignal.sigkill);
          } on ProcessException {
            // The child can exit between the stream check and the kill.
          }
        }
        await exit.timeout(const Duration(seconds: 3));
        await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
      }
    },
    skip: Platform.isWindows || !nodeAvailable
        ? 'Requires Node and POSIX process signals'
        : false,
  );
}

bool _nodeAvailable() {
  try {
    return Process.runSync('node', const <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
