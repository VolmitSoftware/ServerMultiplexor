import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
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
        expect(
          File('$instance/server.jar').resolveSymbolicLinksSync(),
          managed.resolveSymbolicLinksSync(),
        );
        expect(
          File('$instance/.server-source').readAsStringSync(),
          contains('jar=${managed.path}'),
        );
        external.deleteSync();
        expect(
          File('$instance/server.jar').readAsStringSync(),
          'custom jar bytes',
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
      expect(
        File(
          '$consumerRoot/instances/managed-update/server.jar',
        ).resolveSymbolicLinksSync(),
        managed.resolveSymbolicLinksSync(),
      );
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
