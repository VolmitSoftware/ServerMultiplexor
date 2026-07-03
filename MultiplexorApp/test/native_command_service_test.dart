import 'dart:io';

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
  });
}
