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
  late ConsumerService consumers;
  late NativeCommandService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-create-version-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    consumers = ConsumerService(context);
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      processRunner: const _InstallerRunner(),
    );
  });

  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  File jar(String relative) => File(p.join(root.path, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync('test server bytes');

  Map<String, String> metadata(
    String name, {
    ConsumerProfile profile = ConsumerProfile.plugin,
  }) => <String, String>{
    for (final String line in File(
      p.join(consumers.rootFor(profile), 'instances', name, '.server-source'),
    ).readAsLinesSync())
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };

  Future<void> create(List<String> args) async {
    final CapturedResult result = await service.execute(<String>[
      'server',
      ...args,
    ], stream: false);
    expect(result.exitCode, 0, reason: result.stderr);
  }

  test(
    'explicit Leaf import retains inferred MC before content hashing',
    () async {
      final File source = jar('external/leaf-26.2-96.jar');
      await create(<String>[
        'create',
        'leaf-import',
        '--type',
        'leaf',
        '--jar',
        source.path,
        '--isolated',
      ]);

      final Map<String, String> state = metadata('leaf-import');
      expect(state['mc'], '26.2');
      expect(p.basename(state['jar']!), matches(r'^[a-f0-9]{64}\.jar$'));
    },
  );

  test('explicit mc survives import of an unversioned custom jar', () async {
    final File source = jar('external/server.jar');
    await create(<String>[
      'create',
      'custom-version',
      '--type',
      'custom',
      '--jar',
      source.path,
      '--mc',
      '1.21.11',
      '--isolated',
    ]);

    expect(metadata('custom-version')['mc'], '1.21.11');
  });

  test('unknown custom imports do not invent a Minecraft version', () async {
    final File source = jar('external/custom-26.2.jar');
    await create(<String>[
      'create',
      'unknown',
      '--type',
      'custom',
      '--jar',
      source.path,
      '--isolated',
    ]);

    expect(metadata('unknown'), isNot(contains('mc')));
  });

  test('cached creation persists the requested Minecraft version', () async {
    jar('consumers/plugin-consumers/builds/leaf/leaf-26.1.2-73.jar');
    await create(<String>[
      'create',
      'cached',
      '--type',
      'leaf',
      '--mc',
      '26.1.2',
      '--isolated',
    ]);

    expect(metadata('cached')['mc'], '26.1.2');
  });

  test(
    'batch creation persists Minecraft version on every selected type',
    () async {
      jar('consumers/plugin-consumers/builds/leaf/leaf-26.2-96.jar');
      jar('consumers/plugin-consumers/builds/paper/paper-26.2-123.jar');
      await create(<String>[
        'create-many',
        '--types',
        'leaf,paper',
        '--prefix',
        'versions',
        '--mc',
        '26.2',
        '--isolated',
      ]);

      expect(metadata('versions-leaf')['mc'], '26.2');
      expect(metadata('versions-paper')['mc'], '26.2');
    },
  );

  test('Forge installer imports preserve inferred MC before hashing', () async {
    service.setConsumerOverride(ConsumerProfile.forge);
    final File source = jar('external/forge-1.21.4-54.1.0-installer.jar');
    await create(<String>[
      'create',
      'forge-version',
      '--type',
      'forge',
      '--jar',
      source.path,
      '--isolated',
    ]);

    final Map<String, String> state = metadata(
      'forge-version',
      profile: ConsumerProfile.forge,
    );
    expect(state['launch'], 'argsfile');
    expect(state['mc'], '1.21.4');
    expect(p.basename(state['installer']!), matches(r'^[a-f0-9]{64}\.jar$'));
  });

  test(
    'NeoForge installer creation persists explicit MC independently of loader',
    () async {
      service.setConsumerOverride(ConsumerProfile.neoforge);
      final File source = jar('external/neoforge-21.11.35-installer.jar');
      await create(<String>[
        'create',
        'neoforge-version',
        '--type',
        'neoforge',
        '--jar',
        source.path,
        '--mc',
        '1.21.11',
        '--isolated',
      ]);

      expect(
        metadata('neoforge-version', profile: ConsumerProfile.neoforge)['mc'],
        '1.21.11',
      );
    },
  );
}

final class _InstallerRunner extends ProcessRunner {
  const _InstallerRunner();

  @override
  Future<CapturedResult> runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    expect(executable, 'java');
    expect(arguments, contains('--installServer'));
    File(
        p.join(
          workingDirectory!,
          'libraries',
          Platform.isWindows ? 'win_args.txt' : 'unix_args.txt',
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('test launch arguments');
    return CapturedResult(exitCode: 0, stdout: '', stderr: '');
  }
}
