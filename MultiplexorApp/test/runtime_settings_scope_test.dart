import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late ConsumerService consumers;
  late List<String> inspected;

  Future<CapturedResult> run(List<String> args) =>
      service.execute(args, stream: false);
  Future<String> settings([String? name]) async {
    final CapturedResult result = await run(<String>[
      'runtime',
      'settings',
      'show',
      if (name != null) ...<String>['--instance', name],
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
    return result.stdout;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-runtime-settings-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    consumers = ConsumerService(context);
    inspected = <String>[];
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      javaInspector: (String executable) async {
        inspected.add(executable);
        return executable == 'java25' ? 25 : 17;
      },
    );
    for (final String name in <String>['small', 'large']) {
      final CapturedResult result = await run(<String>[
        'instance',
        'create',
        name,
        '--isolated',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'instance overrides inherit subsequent consumer changes to other fields',
    () async {
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-heap',
          '512M',
          '--instance',
          'small',
        ])).exitCode,
        0,
      );
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-heap',
          '12G',
        ])).exitCode,
        0,
      );
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-preset',
          'vanilla',
        ])).exitCode,
        0,
      );
      expect(await settings('small'), contains('heap size:      512M'));
      expect(await settings('small'), contains('flags profile:  vanilla'));
      expect(await settings('large'), contains('heap size:      12G'));
      expect(await settings(), contains('heap size:      12G'));
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'reset',
          '--instance',
          'small',
        ])).exitCode,
        0,
      );
      expect(await settings('small'), contains('heap size:      12G'));
    },
  );

  test(
    'rejects invalid heap and unknown instance before writing settings',
    () async {
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-heap',
          '0G',
          '--instance',
          'small',
        ])).exitCode,
        2,
      );
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-heap',
          '2G',
          '--instance',
          'missing',
        ])).exitCode,
        2,
      );
      expect(await settings('small'), contains('heap size:      4G'));
    },
  );

  test(
    'Java preflight uses the instance override and blocks before runtime side effects',
    () async {
      final Directory instance = Directory(
        p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', 'small'),
      );
      File(
        p.join(instance.path, '.server-source'),
      ).writeAsStringSync('type=paper\nmc=26.1\nlaunch=jar\n');
      final File restart = File(p.join(instance.path, 'multiplexor-restart.sh'))
        ..writeAsStringSync('unchanged before failed preflight');
      final CapturedResult failed = await run(<String>[
        'runtime',
        'start',
        'small',
        '--no-console',
      ]);
      expect(failed.exitCode, 2);
      expect(failed.stderr, contains('requires Java 25'));
      expect(inspected, <String>['java']);
      expect(restart.readAsStringSync(), 'unchanged before failed preflight');
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-java',
          'java25',
          '--instance',
          'small',
        ])).exitCode,
        0,
      );
      final CapturedResult checked = await run(<String>[
        'runtime',
        'settings',
        'check',
        '--instance',
        'small',
      ]);
      expect(checked.exitCode, 0, reason: checked.stderr);
      expect(inspected.last, 'java25');
      expect(await settings('large'), contains('java executable: java'));
    },
  );

  test(
    'template settings apply only to the new instance and export its values',
    () async {
      final File jar = File(p.join(root.path, 'fixture.jar'))
        ..writeAsBytesSync(<int>[80, 75, 3, 4]);
      final File template = File(
        p.join(root.path, '.multiplexor', 'templates', 'light.yaml'),
      );
      template.parent.createSync(recursive: true);
      template.writeAsStringSync(
        'type: custom\njar: ${jar.path}\nheap: 512M\njvm_preset: vanilla\nisolated: true\n',
      );
      final CapturedResult result = await run(<String>[
        'template',
        'apply',
        'light',
        'new',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(await settings('new'), contains('heap size:      512M'));
      expect(await settings('new'), contains('flags profile:  vanilla'));
      expect(await settings('large'), contains('heap size:      4G'));
      expect(await settings(), contains('flags profile:  aikar'));
      expect(
        (await run(<String>['template', 'export', 'new', 'exported'])).exitCode,
        0,
      );
      expect(
        File(p.join(template.parent.path, 'exported.yaml')).readAsStringSync(),
        contains('heap: 512M'),
      );
    },
  );

  test('invalid template settings fail before creating an instance', () async {
    final File template = File(
      p.join(root.path, '.multiplexor', 'templates', 'bad.yaml'),
    );
    template.parent.createSync(recursive: true);
    template.writeAsStringSync('type: custom\nheap: 0G\n');
    expect(
      (await run(<String>['template', 'apply', 'bad', 'new'])).exitCode,
      2,
    );
    expect(
      Directory(
        p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', 'new'),
      ).existsSync(),
      isFalse,
    );
  });
  test(
    'installer uses configured Java and rejects an old runtime before executing',
    () async {
      final ManagerContext context = ManagerContext(
        rootDir: root.path,
        verbose: false,
      );
      final _InstallerRunner runner = _InstallerRunner();
      service = NativeCommandService(
        context: context,
        consumerService: consumers,
        processRunner: runner,
        javaInspector: (String executable) async =>
            executable == 'java25' ? 25 : 17,
      )..setConsumerOverride(ConsumerProfile.forge);
      final File jar = File(p.join(root.path, 'forge-26.1-installer.jar'))
        ..writeAsBytesSync(<int>[80, 75, 3, 4]);
      final CapturedResult rejected = await run(<String>[
        'server',
        'create',
        'oldjava',
        '--type',
        'forge',
        '--mc',
        '26.1',
        '--jar',
        jar.path,
        '--isolated',
      ]);
      expect(rejected.exitCode, 2, reason: rejected.stderr);
      expect(rejected.stderr, contains('requires Java 25'));
      expect(runner.executables, isEmpty);
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-java',
          'java25',
        ])).exitCode,
        0,
      );
      final CapturedResult created = await run(<String>[
        'server',
        'create',
        'newjava',
        '--type',
        'forge',
        '--mc',
        '26.1',
        '--jar',
        jar.path,
        '--isolated',
      ]);
      expect(created.exitCode, 0, reason: created.stderr);
      expect(runner.executables, <String>['java25']);
    },
  );
}

final class _InstallerRunner extends ProcessRunner {
  final List<String> executables = <String>[];

  @override
  Future<CapturedResult> runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    executables.add(executable);
    expect(arguments, contains('--installServer'));
    File(
        p.join(
          workingDirectory!,
          'libraries',
          Platform.isWindows ? 'win_args.txt' : 'unix_args.txt',
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('fixture args');
    return CapturedResult(exitCode: 0, stdout: '', stderr: '');
  }
}
