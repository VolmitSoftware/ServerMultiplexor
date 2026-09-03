import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('NativeCommandService consumer ownership', () {
    late Directory root;
    late NativeCommandService service;
    late ConsumerService consumerService;

    setUp(() {
      root = Directory.systemTemp.createTempSync('multiplexor-test-');
      final context = ManagerContext(rootDir: root.path, verbose: false);
      consumerService = ConsumerService(context);
      service = NativeCommandService(
        context: context,
        consumerService: consumerService,
      );
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    for (final bool force in <bool>[false, true]) {
      test(
        force
            ? 'runtime stop --force immediately kills an unresponsive process'
            : 'runtime stop gives an unresponsive process five seconds',
        () async {
          final File program = File('${root.path}/unresponsive.dart')
            ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';

void main() {
  ProcessSignal.sigterm.watch().listen((ProcessSignal signal) {});
  Timer.periodic(const Duration(seconds: 1), (Timer timer) {});
  stdout.writeln('ready');
}
''');
          final Process runtime = await Process.start(
            Platform.resolvedExecutable,
            <String>[program.path],
          );
          addTearDown(() async {
            runtime.kill(ProcessSignal.sigkill);
            await runtime.exitCode;
          });
          runtime.stderr.drain<void>().ignore();
          expect(
            await runtime.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first,
            'ready',
          );
          final String instance = p.basename(root.path);
          final File pidFile =
              File(
                  '${consumerService.rootFor(ConsumerProfile.plugin)}'
                  '/state/runtime/$instance.server.pid',
                )
                ..createSync(recursive: true)
                ..writeAsStringSync('${runtime.pid}\n');
          final Stopwatch elapsed = Stopwatch()..start();

          final CapturedResult result = await service.execute(<String>[
            'runtime',
            'stop',
            instance,
            if (force) '--force',
          ], stream: false);

          expect(result.exitCode, 0, reason: result.stderr);
          expect(
            await runtime.exitCode.timeout(const Duration(seconds: 2)),
            isNot(0),
          );
          expect(pidFile.existsSync(), isFalse);
          if (force) {
            expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
          } else {
            expect(
              elapsed.elapsed,
              greaterThanOrEqualTo(const Duration(seconds: 5)),
            );
            expect(elapsed.elapsed, lessThan(const Duration(seconds: 8)));
            expect(result.stdout, contains('forcing: $instance'));
          }
        },
        skip: Platform.isWindows,
      );
    }

    test('server create refuses modded types in plugin consumer', () async {
      final result = await service.execute(<String>[
        'server',
        'create',
        'modded',
        '--type',
        'fabric',
        '--jar',
        '/tmp/server.jar',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Server type "fabric" belongs to the fabric consumer'),
      );
      expect(result.stderr, contains('--consumer fabric server create'));
    });

    test('Mohist is owned by the Forge consumer', () async {
      final CapturedResult result = await service.execute(<String>[
        'server',
        'create',
        'hybrid',
        '--type',
        'mohist',
        '--jar',
        '/tmp/server.jar',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Server type "mohist" belongs to the forge consumer'),
      );
      expect(result.stderr, contains('--consumer forge server create'));
    });

    test('Mohist persistently tracks mod and plugin drop-ins', () async {
      service.setConsumerOverride(ConsumerProfile.forge);
      final String forgeRoot = consumerService.rootFor(ConsumerProfile.forge);
      final String pluginRoot = consumerService.rootFor(ConsumerProfile.plugin);
      final Directory modDropins = Directory('$forgeRoot/dropins/mods')
        ..createSync(recursive: true);
      final Directory pluginDropins = Directory('$pluginRoot/dropins/plugins')
        ..createSync(recursive: true);
      final File mod = File('${modDropins.path}/ExampleMod.jar')
        ..writeAsStringSync('mod-v1');
      final File plugin = File('${pluginDropins.path}/ExamplePlugin.jar')
        ..writeAsStringSync('plugin-v1');
      final File serverJar = File('${root.path}/mohist.jar')
        ..writeAsStringSync('mohist server');

      final CapturedResult created = await service.execute(<String>[
        'server',
        'create',
        'hybrid',
        '--type',
        'mohist',
        '--jar',
        serverJar.path,
      ], stream: false);

      expect(created.exitCode, 0, reason: created.stderr);
      final String instance = '$forgeRoot/instances/hybrid';
      expect(
        File('$instance/mods/ExampleMod.jar').readAsStringSync(),
        'mod-v1',
      );
      expect(
        File('$instance/plugins/ExamplePlugin.jar').readAsStringSync(),
        'plugin-v1',
      );
      final String metadata = File(
        '$instance/.server-source',
      ).readAsStringSync();
      expect(metadata, contains('type=mohist'));
      expect(metadata, contains('launch=jar'));
      expect(metadata, contains('dropin_sources=mods,plugins'));

      mod.writeAsStringSync('mod-v2');
      plugin.writeAsStringSync('plugin-v2');
      final CapturedResult synced = await service.execute(<String>[
        'mods',
        'sync',
        'hybrid',
      ], stream: false);

      expect(synced.exitCode, 0, reason: synced.stderr);
      expect(
        File('$instance/mods/ExampleMod.jar').readAsStringSync(),
        'mod-v2',
      );
      expect(
        File('$instance/plugins/ExamplePlugin.jar').readAsStringSync(),
        'plugin-v2',
      );
      final Map<String, dynamic> state =
          jsonDecode(
                File('$instance/.multiplexor-dropins.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> hashes = state['jars'] as Map<String, dynamic>;
      expect(hashes, containsPair('mods/ExampleMod.jar', isA<String>()));
      expect(hashes, containsPair('plugins/ExamplePlugin.jar', isA<String>()));
    });

    test('Mohist can track only plugin drop-ins', () async {
      service.setConsumerOverride(ConsumerProfile.forge);
      final String forgeRoot = consumerService.rootFor(ConsumerProfile.forge);
      final String pluginRoot = consumerService.rootFor(ConsumerProfile.plugin);
      File('$forgeRoot/dropins/mods/SkippedMod.jar')
        ..createSync(recursive: true)
        ..writeAsStringSync('mod');
      File('$pluginRoot/dropins/plugins/TrackedPlugin.jar')
        ..createSync(recursive: true)
        ..writeAsStringSync('plugin');
      final File serverJar = File('${root.path}/mohist.jar')
        ..writeAsStringSync('mohist server');

      final CapturedResult created = await service.execute(<String>[
        'server',
        'create',
        'plugins-only',
        '--type',
        'mohist',
        '--jar',
        serverJar.path,
        '--plugin-dropins',
      ], stream: false);

      expect(created.exitCode, 0, reason: created.stderr);
      final String instance = '$forgeRoot/instances/plugins-only';
      expect(File('$instance/mods/SkippedMod.jar').existsSync(), isFalse);
      expect(File('$instance/plugins/TrackedPlugin.jar').existsSync(), isTrue);
      expect(
        File('$instance/.server-source').readAsStringSync(),
        contains('dropin_sources=plugins'),
      );
    });

    test('Mohist source flags reject incompatible creation modes', () async {
      service.setConsumerOverride(ConsumerProfile.forge);
      final File serverJar = File('${root.path}/server.jar')
        ..writeAsStringSync('server');

      final CapturedResult isolated = await service.execute(<String>[
        'server',
        'create',
        'invalid-isolated',
        '--type',
        'mohist',
        '--jar',
        serverJar.path,
        '--isolated',
        '--plugin-dropins',
      ], stream: false);
      expect(isolated.exitCode, 2);
      expect(isolated.stderr, contains('cannot be combined'));

      final CapturedResult forge = await service.execute(<String>[
        'server',
        'create',
        'invalid-forge',
        '--type',
        'forge',
        '--jar',
        serverJar.path,
        '--plugin-dropins',
      ], stream: false);
      expect(forge.exitCode, 2);
      expect(forge.stderr, contains('only valid for Mohist'));
      final String instances =
          '${consumerService.rootFor(ConsumerProfile.forge)}/instances';
      expect(Directory('$instances/invalid-isolated').existsSync(), isFalse);
      expect(Directory('$instances/invalid-forge').existsSync(), isFalse);
    });

    test(
      'custom jars are imported into content-addressed managed builds',
      () async {
        final File external = File('${root.path}/external/custom.jar');
        external.parent.createSync(recursive: true);
        external.writeAsStringSync('custom jar bytes');
        final String digest = sha256
            .convert(external.readAsBytesSync())
            .toString();

        final CapturedResult result = await service.execute(<String>[
          'server',
          'create',
          'managed-custom',
          '--type',
          'custom',
          '--jar',
          external.path,
          '--isolated',
        ], stream: false);

        expect(result.exitCode, 0, reason: result.stderr);
        final String consumerRoot = consumerService.rootFor(
          ConsumerProfile.plugin,
        );
        final File managed = File('$consumerRoot/builds/custom/$digest.jar');
        final String instance = '$consumerRoot/instances/managed-custom';
        expect(managed.readAsStringSync(), 'custom jar bytes');
        if (!Platform.isWindows) {
          expect(
            File('$instance/server.jar').resolveSymbolicLinksSync(),
            managed.resolveSymbolicLinksSync(),
          );
        }
        expect(
          File('$instance/.server-source').readAsStringSync(),
          contains('jar=${p.normalize(managed.path)}'),
        );
        external.deleteSync();
        expect(
          File('$instance/server.jar').readAsStringSync(),
          'custom jar bytes',
        );
      },
    );

    test(
      'shared server creation writes a host-native restart script and activates',
      () async {
        final File serverJar = File('${root.path}/server.jar')
          ..writeAsStringSync('server');
        final CapturedResult created = await service.execute(<String>[
          'server',
          'create',
          'shared-native',
          '--type',
          'custom',
          '--jar',
          serverJar.path,
        ], stream: false);

        expect(created.exitCode, 0, reason: created.stderr);
        final String consumerRoot = consumerService.rootFor(
          ConsumerProfile.plugin,
        );
        final String instance = '$consumerRoot/instances/shared-native';
        final String scriptName = Platform.isWindows
            ? 'multiplexor-restart.cmd'
            : 'multiplexor-restart.sh';
        expect(File('$instance/$scriptName').existsSync(), isTrue);
        expect(
          File('$instance/spigot.yml').readAsStringSync(),
          contains(
            'restart-script: ${Platform.isWindows ? scriptName : './$scriptName'}',
          ),
        );
        expect(File('$instance/server.jar').readAsStringSync(), 'server');
        expect(File('$instance/ops.json').existsSync(), isTrue);
        expect(Directory('$instance/plugins/iris/packs').existsSync(), isTrue);

        final CapturedResult activated = await service.execute(<String>[
          'instance',
          'activate',
          'shared-native',
        ], stream: false);
        expect(activated.exitCode, 0, reason: activated.stderr);
        expect(
          File('$consumerRoot/state/active-instance.txt').readAsStringSync(),
          'shared-native\n',
        );
      },
    );

    test('isolated server copies only explicitly selected drop-ins', () async {
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.plugin,
      );
      final Directory dropins = Directory('$consumerRoot/dropins/plugins')
        ..createSync(recursive: true);
      File('${dropins.path}/First.jar').writeAsStringSync('first');
      File('${dropins.path}/Second.jar').writeAsStringSync('second');
      final File serverJar = File('${root.path}/server.jar')
        ..writeAsStringSync('server');

      final CapturedResult result = await service.execute(<String>[
        'server',
        'create',
        'picked',
        '--type',
        'custom',
        '--jar',
        serverJar.path,
        '--isolated',
        '--artifact',
        'Second.jar',
      ], stream: false);

      expect(result.exitCode, 0, reason: result.stderr);
      final Directory plugins = Directory(
        '$consumerRoot/instances/picked/plugins',
      );
      expect(File('${plugins.path}/Second.jar').readAsStringSync(), 'second');
      expect(File('${plugins.path}/First.jar').existsSync(), isFalse);
      expect(result.stdout, contains('1 selected drop-in artifact'));
    });

    test('artifact selection requires an isolated server', () async {
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.plugin,
      );
      final Directory dropins = Directory('$consumerRoot/dropins/plugins')
        ..createSync(recursive: true);
      File('${dropins.path}/Example.jar').writeAsStringSync('plugin');

      final CapturedResult result = await service.execute(<String>[
        'server',
        'create',
        'shared',
        '--artifact',
        'Example.jar',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('only valid with --isolated'));
      expect(Directory('$consumerRoot/instances/shared').existsSync(), isFalse);
    });

    test('isolated server can copy selected drop-ins after creation', () async {
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.plugin,
      );
      final Directory dropins = Directory('$consumerRoot/dropins/plugins')
        ..createSync(recursive: true);
      File('${dropins.path}/First.jar').writeAsStringSync('first');
      File('${dropins.path}/Second.jar').writeAsStringSync('second');
      final File serverJar = File('${root.path}/server.jar')
        ..writeAsStringSync('server');

      final CapturedResult created = await service.execute(<String>[
        'server',
        'create',
        'isolated-copy',
        '--type',
        'custom',
        '--jar',
        serverJar.path,
        '--isolated',
      ], stream: false);
      expect(created.exitCode, 0, reason: created.stderr);

      final CapturedResult copied = await service.execute(<String>[
        'plugins',
        'copy',
        'isolated-copy',
        '--artifact',
        'Second.jar',
      ], stream: false);

      expect(copied.exitCode, 0, reason: copied.stderr);
      final Directory plugins = Directory(
        '$consumerRoot/instances/isolated-copy/plugins',
      );
      expect(File('${plugins.path}/Second.jar').readAsStringSync(), 'second');
      expect(File('${plugins.path}/First.jar').existsSync(), isFalse);
      expect(copied.stdout, contains('1 selected drop-in artifact'));
    });

    test('selected drop-in copy refuses subscribed instances', () async {
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.plugin,
      );
      final Directory dropins = Directory('$consumerRoot/dropins/plugins')
        ..createSync(recursive: true);
      File('${dropins.path}/Example.jar').writeAsStringSync('plugin');
      final Directory instance = Directory('$consumerRoot/instances/subscribed')
        ..createSync(recursive: true);

      final CapturedResult copied = await service.execute(<String>[
        'plugins',
        'copy',
        'subscribed',
        '--artifact',
        'Example.jar',
      ], stream: false);

      expect(copied.exitCode, 2);
      expect(copied.stderr, contains('use plugins sync subscribed instead'));
      expect(
        File('${instance.path}/plugins/Example.jar').existsSync(),
        isFalse,
      );
    });

    test('selected mod drop-ins copy into an isolated mod server', () async {
      service.setConsumerOverride(ConsumerProfile.fabric);
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.fabric,
      );
      final Directory dropins = Directory('$consumerRoot/dropins/mods')
        ..createSync(recursive: true);
      File('${dropins.path}/Example.jar').writeAsStringSync('mod');
      final CapturedResult created = await service.execute(<String>[
        'instance',
        'create',
        'fabric-copy',
        '--isolated',
      ], stream: false);
      expect(created.exitCode, 0, reason: created.stderr);

      final CapturedResult copied = await service.execute(<String>[
        'mods',
        'copy',
        'fabric-copy',
        '--artifact',
        'Example.jar',
      ], stream: false);

      expect(copied.exitCode, 0, reason: copied.stderr);
      expect(
        File(
          '$consumerRoot/instances/fabric-copy/mods/Example.jar',
        ).readAsStringSync(),
        'mod',
      );
    });

    test(
      'selected drop-in copy validates every artifact before writing',
      () async {
        final String consumerRoot = consumerService.rootFor(
          ConsumerProfile.plugin,
        );
        final Directory dropins = Directory('$consumerRoot/dropins/plugins')
          ..createSync(recursive: true);
        File('${dropins.path}/Present.jar').writeAsStringSync('present');
        final CapturedResult created = await service.execute(<String>[
          'instance',
          'create',
          'all-or-nothing',
          '--isolated',
        ], stream: false);
        expect(created.exitCode, 0, reason: created.stderr);

        final CapturedResult copied = await service.execute(<String>[
          'plugins',
          'copy',
          'all-or-nothing',
          '--artifact',
          'Present.jar',
          '--artifact',
          'Missing.jar',
        ], stream: false);

        expect(copied.exitCode, 2);
        expect(
          copied.stderr,
          contains('Drop-in artifact not found: Missing.jar'),
        );
        expect(
          File(
            '$consumerRoot/instances/all-or-nothing/plugins/Present.jar',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('instance update imports a replacement custom jar', () async {
      final File first = File('${root.path}/external/first.jar');
      final File second = File('${root.path}/external/second.jar');
      first.parent.createSync(recursive: true);
      first.writeAsStringSync('first jar');
      second.writeAsStringSync('second jar');
      final CapturedResult created = await service.execute(<String>[
        'server',
        'create',
        'managed-update',
        '--type',
        'custom',
        '--jar',
        first.path,
        '--isolated',
      ], stream: false);
      expect(created.exitCode, 0, reason: created.stderr);

      final CapturedResult updated = await service.execute(<String>[
        'instance',
        'update',
        'managed-update',
        '--type',
        'custom',
        '--jar',
        second.path,
      ], stream: false);

      expect(updated.exitCode, 0, reason: updated.stderr);
      final String digest = sha256.convert(second.readAsBytesSync()).toString();
      final String consumerRoot = consumerService.rootFor(
        ConsumerProfile.plugin,
      );
      final File managed = File('$consumerRoot/builds/custom/$digest.jar');
      expect(managed.readAsStringSync(), 'second jar');
      final File instanceJar = File(
        '$consumerRoot/instances/managed-update/server.jar',
      );
      expect(instanceJar.readAsStringSync(), 'second jar');
      if (!Platform.isWindows) {
        expect(
          instanceJar.resolveSymbolicLinksSync(),
          managed.resolveSymbolicLinksSync(),
        );
      }
    });

    test('blank create preserves every pre-existing entity type', () async {
      consumerService.ensureConsumerDirs(ConsumerProfile.plugin);
      final String instances =
          '${consumerService.rootFor(ConsumerProfile.plugin)}/instances';
      final File existingFile = File('$instances/existing-file')
        ..writeAsStringSync('keep file');
      final Directory existingDirectory = Directory(
        '$instances/existing-directory',
      )..createSync();
      final File sentinel = File('${existingDirectory.path}/keep.txt')
        ..writeAsStringSync('keep directory');

      for (final String name in <String>[
        'existing-file',
        'existing-directory',
      ]) {
        final CapturedResult result = await service.execute(<String>[
          'instance',
          'create',
          name,
          '--isolated',
        ], stream: false);
        expect(result.exitCode, 2);
        expect(result.stderr, contains('was not changed'));
      }
      expect(existingFile.readAsStringSync(), 'keep file');
      expect(sentinel.readAsStringSync(), 'keep directory');

      if (!Platform.isWindows) {
        final Directory outside = Directory('${root.path}/outside')
          ..createSync();
        final File outsideSentinel = File('${outside.path}/keep.txt')
          ..writeAsStringSync('keep link target');
        final Link existingLink = Link('$instances/existing-link')
          ..createSync(outside.path);
        final CapturedResult result = await service.execute(<String>[
          'instance',
          'create',
          'existing-link',
          '--isolated',
        ], stream: false);
        expect(result.exitCode, 2);
        expect(
          FileSystemEntity.typeSync(existingLink.path, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(outsideSentinel.readAsStringSync(), 'keep link target');
      }
    });

    test('build refuses modded types in plugin consumer', () async {
      final result = await service.execute(<String>[
        'build',
        'neoforge',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Server type "neoforge" belongs to the neoforge consumer'),
      );
      expect(result.stderr, contains('--consumer neoforge build neoforge'));
    });

    test('build refuses leaf (a plugin type) in a modded consumer', () async {
      service.setConsumerOverride(ConsumerProfile.forge);

      final result = await service.execute(<String>[
        'build',
        'leaf',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Server type "leaf" belongs to the plugin consumer'),
      );
      expect(result.stderr, contains('--consumer plugin build leaf'));
    });

    test('explicit plugin sync replaces a locally modified jar', () async {
      final Directory dropins = Directory(
        '${root.path}/consumers/plugin-consumers/dropins/plugins',
      )..createSync(recursive: true);
      final Directory instance = Directory(
        '${root.path}/consumers/plugin-consumers/instances/test',
      )..createSync(recursive: true);
      final Directory plugins = Directory('${instance.path}/plugins')
        ..createSync(recursive: true);
      final File sourceJar = File('${dropins.path}/Example.jar')
        ..writeAsStringSync('dropin-a');
      final File targetJar = File('${plugins.path}/Example.jar')
        ..writeAsStringSync('local-a');

      final firstResult = await service.execute(<String>[
        'plugins',
        'sync',
        'test',
      ], stream: false);

      expect(firstResult.exitCode, 0);
      expect(targetJar.readAsStringSync(), 'dropin-a');
      targetJar.writeAsStringSync('local-b');
      sourceJar.writeAsStringSync('dropin-b');

      final secondResult = await service.execute(<String>[
        'plugins',
        'sync',
        'test',
      ], stream: false);

      expect(secondResult.exitCode, 0);
      expect(targetJar.readAsStringSync(), 'dropin-b');
      final Map<String, dynamic> state =
          jsonDecode(
                File(
                  '${instance.path}/.multiplexor-dropins.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> jars = state['jars'] as Map<String, dynamic>;
      expect(
        jars['plugins/Example.jar'],
        sha256.convert(utf8.encode('dropin-b')).toString(),
      );
    });

    test('gameplay prepare refuses a shared instance', () async {
      final Directory instance = Directory(
        '${root.path}/consumers/plugin-consumers/instances/shared',
      )..createSync(recursive: true);
      File(
        '${instance.path}/.server-source',
      ).writeAsStringSync('type=paper\nlaunch=jar\n');
      File(
        '${instance.path}/server.properties',
      ).writeAsStringSync('server-port=25565\n');

      final result = await service.execute(<String>[
        'gameplay',
        'prepare',
        'shared',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('restricted to isolated instances'));
    });

    test(
      'gameplay prepare configures offline auth on isolated instance',
      () async {
        final Directory instance = Directory(
          '${root.path}/consumers/plugin-consumers/instances/qa',
        )..createSync(recursive: true);
        File(
          '${instance.path}/.server-source',
        ).writeAsStringSync('type=paper\nlaunch=jar\nisolated=true\n');
        final File properties = File('${instance.path}/server.properties')
          ..writeAsStringSync(
            'server-port=25565\nonline-mode=true\nwhite-list=true\n',
          );

        final result = await service.execute(<String>[
          'gameplay',
          'prepare',
          'qa',
        ], stream: false);

        expect(result.exitCode, 0);
        expect(result.stdout, contains('Gameplay auth prepared: qa'));
        expect(properties.readAsStringSync(), contains('server-ip=127.0.0.1'));
        expect(properties.readAsStringSync(), contains('online-mode=false'));
        expect(properties.readAsStringSync(), contains('white-list=false'));
        expect(properties.readAsStringSync(), contains('spawn-protection=0'));
      },
    );

    test('gameplay run rejects an invalid viewer port', () async {
      final Directory instance = Directory(
        '${root.path}/consumers/plugin-consumers/instances/qa',
      )..createSync(recursive: true);
      File(
        '${instance.path}/.server-source',
      ).writeAsStringSync('type=paper\nlaunch=jar\nisolated=true\n');
      File(
        '${instance.path}/server.properties',
      ).writeAsStringSync('server-port=25565\nonline-mode=false\n');

      final result = await service.execute(<String>[
        'gameplay',
        'run',
        'connect',
        'qa',
        '--viewer-port',
        '70000',
      ], stream: false);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('--viewer-port must be between 1 and 65535'),
      );
    });
  });
}
