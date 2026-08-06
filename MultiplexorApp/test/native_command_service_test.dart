import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:test/test.dart';

void main() {
  group('NativeCommandService consumer ownership', () {
    late Directory root;
    late NativeCommandService service;

    setUp(() {
      root = Directory.systemTemp.createTempSync('multiplexor-test-');
      final context = ManagerContext(rootDir: root.path, verbose: false);
      final consumerService = ConsumerService(context);
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
  });
}
