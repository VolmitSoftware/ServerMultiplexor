import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const List<int> _jarBytes = <int>[0x50, 0x4b, 3, 4, 10, 20, 30, 40];

void main() {
  group('addons', () {
    late Directory root;
    late ManagerContext context;
    late ConsumerService consumers;
    late NativeCommandService service;

    setUp(() {
      root = Directory.systemTemp.createTempSync('multiplexor-addons-test-');
      context = ManagerContext(rootDir: root.path, verbose: false);
      consumers = ConsumerService(context);
      service = NativeCommandService(
        context: context,
        consumerService: consumers,
      );
    });

    tearDown(() {
      service.disposeRcon();
      root.deleteSync(recursive: true);
    });

    Future<CapturedResult> command(List<String> args) =>
        service.execute(args, stream: false);

    Future<String> createInstance({
      String name = 'demo',
      String type = 'paper',
      String minecraft = '1.21.4',
      ConsumerProfile profile = ConsumerProfile.plugin,
      bool isolated = true,
    }) async {
      service.setConsumerOverride(profile);
      final CapturedResult result = await command(<String>[
        'instance',
        'create',
        name,
        if (isolated) '--isolated',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      final String instance = p.join(
        consumers.rootFor(profile),
        'instances',
        name,
      );
      File(p.join(instance, '.server-source')).writeAsStringSync(
        'type=$type\nmc=$minecraft\nlaunch=jar\nisolated=$isolated\n',
      );
      return instance;
    }

    File jar(String id, {List<int> bytes = _jarBytes}) =>
        File(p.join(root.path, 'fixtures', '$id.jar'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    Map<String, Object?> definition(
      String id, {
      List<String> dependencies = const <String>[],
      String kind = 'plugin',
      List<String> serverTypes = const <String>['paper'],
      Map<String, Object?>? source,
    }) => <String, Object?>{
      'id': id,
      'name': 'Test $id',
      'description': 'Local test addon.',
      'kind': kind,
      'serverTypes': serverTypes,
      'dependencies': dependencies,
      'source':
          source ?? <String, Object?>{'type': 'file', 'path': jar(id).path},
    };

    void registry(List<Map<String, Object?>> definitions) {
      File(p.join(root.path, '.multiplexor', 'addons.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{'addons': definitions}),
        );
    }

    Future<Map<String, Object?>> list() async {
      final CapturedResult result = await command(<String>[
        'addons',
        'list',
        'demo',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      return _object(jsonDecode(result.stdout));
    }

    Future<void> select(String ids) async {
      final CapturedResult result = await command(<String>[
        'addons',
        'set',
        'demo',
        '--select',
        ids,
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
    }

    test('catalog includes all requested built-in addons', () async {
      final CapturedResult result = await command(<String>[
        'addons',
        'catalog',
        '--json',
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      final Map<String, Object?> catalog = _object(jsonDecode(result.stdout));
      expect(
        _entries(catalog).map((Map<String, Object?> entry) => entry['id']),
        containsAll(<String>[
          'essentialsx',
          'fawe',
          'viaversion',
          'viabackwards',
          'protocollib',
        ]),
      );
      final Map<String, Object?> backwards = _entries(catalog).singleWhere(
        (Map<String, Object?> entry) => entry['id'] == 'viabackwards',
      );
      expect(backwards['dependencies'], contains('viaversion'));
    });

    test('installs local addons and persists per-instance selection', () async {
      registry(<Map<String, Object?>>[definition('example')]);
      final String instance = await createInstance();

      await select('example');

      expect(
        File(
          p.join(instance, 'plugins', 'multiplexor-example.jar'),
        ).readAsBytesSync(),
        _jarBytes,
      );
      expect(
        File(p.join(instance, '.multiplexor-addons.json')).existsSync(),
        isTrue,
      );
      service = NativeCommandService(
        context: context,
        consumerService: consumers,
      );
      final Map<String, Object?> status = await list();
      expect(status['instance'], 'demo');
      expect(status['type'], 'paper');
      expect(status['minecraft'], '1.21.4');
      expect(_selectedIds(status), <String>{'example'});
    });

    test('includes dependencies and reuses an unchanged selection', () async {
      registry(<Map<String, Object?>>[
        definition('dependency'),
        definition('dependent', dependencies: <String>['dependency']),
      ]);
      final String instance = await createInstance();
      await select('dependent');
      expect(_selectedIds(await list()), <String>{'dependent', 'dependency'});
      final File dependency = File(
        p.join(instance, 'plugins', 'multiplexor-dependency.jar'),
      );
      final File dependent = File(
        p.join(instance, 'plugins', 'multiplexor-dependent.jar'),
      );
      Directory(p.join(root.path, 'fixtures')).deleteSync(recursive: true);

      await select('dependent');

      expect(dependency.readAsBytesSync(), _jarBytes);
      expect(dependent.readAsBytesSync(), _jarBytes);
      expect(_selectedIds(await list()), <String>{'dependent', 'dependency'});
    });

    test('adding a dependent refreshes its installed dependency', () async {
      registry(<Map<String, Object?>>[
        definition('dependency'),
        definition('dependent', dependencies: <String>['dependency']),
      ]);
      final String instance = await createInstance();
      await select('dependency');
      final File installedDependency = File(
        p.join(instance, 'plugins', 'multiplexor-dependency.jar'),
      );
      expect(installedDependency.readAsBytesSync(), _jarBytes);
      final List<int> newDependencyBytes = <int>[..._jarBytes, 99];
      jar('dependency', bytes: newDependencyBytes);

      await select('dependent');

      expect(installedDependency.readAsBytesSync(), newDependencyBytes);
      expect(
        File(
          p.join(instance, 'plugins', 'multiplexor-dependent.jar'),
        ).readAsBytesSync(),
        _jarBytes,
      );
      expect(_selectedIds(await list()), <String>{'dependent', 'dependency'});
    });

    test(
      'ProtocolLib is unavailable for an unsupported Minecraft version',
      () async {
        await createInstance(minecraft: '99.0');

        final Map<String, Object?> status = await list();

        expect(status['minecraft'], '99.0');
        final Map<String, Object?> protocolLib = _entries(status).singleWhere(
          (Map<String, Object?> entry) => entry['id'] == 'protocollib',
        );
        expect(protocolLib['available'], isFalse);
        expect(protocolLib['reason'], contains('99.0'));
        expect(protocolLib['selected'], isFalse);
      },
    );

    test(
      'puts mod addons in mods and marks plugin addons unavailable',
      () async {
        registry(<Map<String, Object?>>[
          definition(
            'example-mod',
            kind: 'mod',
            serverTypes: <String>['fabric'],
          ),
        ]);
        final String instance = await createInstance(
          type: 'fabric',
          profile: ConsumerProfile.fabric,
        );

        await select('example-mod');

        expect(
          File(
            p.join(instance, 'mods', 'multiplexor-example-mod.jar'),
          ).readAsBytesSync(),
          _jarBytes,
        );
        final Map<String, Object?> status = await list();
        final Map<String, Object?> essentials = _entries(status).singleWhere(
          (Map<String, Object?> entry) => entry['id'] == 'essentialsx',
        );
        expect(essentials['available'], isFalse);
        expect(essentials['reason'], isNotEmpty);
        final CapturedResult refused = await command(<String>[
          'addons',
          'set',
          'demo',
          '--select',
          'essentialsx',
        ]);
        expect(refused.exitCode, isNot(0));
        expect(_selectedIds(await list()), <String>{'example-mod'});
      },
    );

    test(
      'unchecking removes only managed jars and preserves configuration',
      () async {
        registry(<Map<String, Object?>>[definition('example')]);
        final String instance = await createInstance();
        await select('example');
        final File unmanaged = File(p.join(instance, 'plugins', 'manual.jar'))
          ..writeAsBytesSync(_jarBytes);
        final File config =
            File(p.join(instance, 'plugins', 'Example', 'config.yml'))
              ..createSync(recursive: true)
              ..writeAsStringSync('enabled: true\n');

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--none',
        ]);

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          File(
            p.join(instance, 'plugins', 'multiplexor-example.jar'),
          ).existsSync(),
          isFalse,
        );
        expect(unmanaged.readAsBytesSync(), _jarBytes);
        expect(config.readAsStringSync(), 'enabled: true\n');
        expect(_selectedIds(await list()), isEmpty);
      },
    );

    test('refuses to replace an unmanaged target jar', () async {
      registry(<Map<String, Object?>>[definition('example')]);
      final String instance = await createInstance();
      final File target = File(
        p.join(instance, 'plugins', 'multiplexor-example.jar'),
      )..writeAsStringSync('manually supplied jar');

      final CapturedResult result = await command(<String>[
        'addons',
        'set',
        'demo',
        '--select',
        'example',
      ]);

      expect(result.exitCode, isNot(0));
      expect(target.readAsStringSync(), 'manually supplied jar');
      expect(_selectedIds(await list()), isEmpty);
    });

    test(
      'refuses to remove a managed jar modified outside Multiplexor',
      () async {
        registry(<Map<String, Object?>>[definition('example')]);
        final String instance = await createInstance();
        await select('example');
        final File target = File(
          p.join(instance, 'plugins', 'multiplexor-example.jar'),
        )..writeAsStringSync('locally changed jar');
        final String manifest = File(
          p.join(instance, '.multiplexor-addons.json'),
        ).readAsStringSync();

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--none',
        ]);

        expect(result.exitCode, isNot(0));
        expect(target.readAsStringSync(), 'locally changed jar');
        expect(
          File(p.join(instance, '.multiplexor-addons.json')).readAsStringSync(),
          manifest,
        );
      },
    );

    test(
      'failed download leaves installed addons and manifest unchanged',
      () async {
        final HttpServer server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => server.close(force: true));
        int requests = 0;
        server.listen((HttpRequest request) async {
          requests++;
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });
        registry(<Map<String, Object?>>[
          definition('installed'),
          definition('replacement'),
          definition(
            'unavailable',
            source: <String, Object?>{
              'type': 'url',
              'url': 'http://127.0.0.1:${server.port}/missing.jar',
            },
          ),
        ]);
        final String instance = await createInstance();
        await select('installed');
        final File manifest = File(
          p.join(instance, '.multiplexor-addons.json'),
        );
        final String originalManifest = manifest.readAsStringSync();

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--select',
          'replacement,unavailable',
        ]);

        expect(result.exitCode, isNot(0));
        expect(requests, greaterThan(0));
        expect(
          File(
            p.join(instance, 'plugins', 'multiplexor-installed.jar'),
          ).readAsBytesSync(),
          _jarBytes,
        );
        expect(
          File(
            p.join(instance, 'plugins', 'multiplexor-replacement.jar'),
          ).existsSync(),
          isFalse,
        );
        expect(manifest.readAsStringSync(), originalManifest);
        expect(_selectedIds(await list()), <String>{'installed'});
      },
    );

    test(
      'rejects non-jar content before installing any selected addon',
      () async {
        final File invalid = jar(
          'invalid',
          bytes: utf8.encode('<html>Error</html>'),
        );
        registry(<Map<String, Object?>>[
          definition('valid'),
          definition(
            'invalid',
            source: <String, Object?>{'type': 'file', 'path': invalid.path},
          ),
        ]);
        final String instance = await createInstance();

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--select',
          'valid,invalid',
        ]);

        expect(result.exitCode, isNot(0));
        expect(
          File(
            p.join(instance, 'plugins', 'multiplexor-valid.jar'),
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            p.join(instance, 'plugins', 'multiplexor-invalid.jar'),
          ).existsSync(),
          isFalse,
        );
        expect(_selectedIds(await list()), isEmpty);
      },
    );

    test(
      'refuses a symlinked target jar without modifying its destination',
      () async {
        registry(<Map<String, Object?>>[definition('example')]);
        final String instance = await createInstance();
        final File outside = jar('outside');
        final Link target = Link(
          p.join(instance, 'plugins', 'multiplexor-example.jar'),
        )..createSync(outside.path);

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--select',
          'example',
        ]);

        expect(result.exitCode, isNot(0));
        expect(target.targetSync(), outside.path);
        expect(outside.readAsBytesSync(), _jarBytes);
        expect(_selectedIds(await list()), isEmpty);
      },
      skip: Platform.isWindows
          ? 'Requires symlink creation privileges.'
          : false,
    );

    test(
      'refuses a symlinked plugins directory',
      () async {
        registry(<Map<String, Object?>>[definition('example')]);
        final String instance = await createInstance();
        final Directory outside = Directory(p.join(root.path, 'outside'))
          ..createSync();
        Directory(p.join(instance, 'plugins')).deleteSync(recursive: true);
        Link(p.join(instance, 'plugins')).createSync(outside.path);

        final CapturedResult result = await command(<String>[
          'addons',
          'set',
          'demo',
          '--select',
          'example',
        ]);

        expect(result.exitCode, isNot(0));
        expect(outside.listSync(), isEmpty);
      },
      skip: Platform.isWindows
          ? 'Requires symlink creation privileges.'
          : false,
    );

    for (final String invalidCase in <String>[
      'built-in shadow',
      'duplicate id',
      'missing dependency',
      'dependency cycle',
    ]) {
      test('rejects registry $invalidCase', () async {
        final List<Map<String, Object?>> definitions = switch (invalidCase) {
          'built-in shadow' => <Map<String, Object?>>[
            definition('essentialsx'),
          ],
          'duplicate id' => <Map<String, Object?>>[
            definition('duplicate'),
            definition('duplicate'),
          ],
          'missing dependency' => <Map<String, Object?>>[
            definition('orphan', dependencies: <String>['missing']),
          ],
          _ => <Map<String, Object?>>[
            definition('first', dependencies: <String>['second']),
            definition('second', dependencies: <String>['first']),
          ],
        };
        registry(definitions);

        final CapturedResult result = await command(<String>[
          'addons',
          'catalog',
          '--json',
        ]);

        expect(result.exitCode, isNot(0));
        expect(result.stderr, isNotEmpty);
      });
    }

    test('factory reset clears selected addons and their jars', () async {
      registry(<Map<String, Object?>>[definition('example')]);
      final String instance = await createInstance();
      await select('example');

      final CapturedResult result = await command(<String>[
        'instance',
        'reset',
        'demo',
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File(
          p.join(instance, 'plugins', 'multiplexor-example.jar'),
        ).existsSync(),
        isFalse,
      );
      expect(_selectedIds(await list()), isEmpty);
    });

    test('clean drop-in sync preserves managed addon jars', () async {
      registry(<Map<String, Object?>>[definition('example')]);
      final String instance = await createInstance(isolated: false);
      await select('example');
      File(
        p.join(
          consumers.rootFor(ConsumerProfile.plugin),
          'dropins',
          'plugins',
          'shared.jar',
        ),
      ).writeAsBytesSync(_jarBytes);
      File(
        p.join(
          consumers.rootFor(ConsumerProfile.plugin),
          'dropins',
          'plugins',
          'multiplexor-example.jar',
        ),
      ).writeAsBytesSync(<int>[..._jarBytes, 99]);
      final File obsolete = File(p.join(instance, 'plugins', 'obsolete.jar'))
        ..writeAsBytesSync(_jarBytes);

      final CapturedResult result = await command(<String>[
        'plugins',
        'sync',
        'demo',
        '--clean',
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File(
          p.join(instance, 'plugins', 'multiplexor-example.jar'),
        ).readAsBytesSync(),
        _jarBytes,
      );
      expect(
        File(p.join(instance, 'plugins', 'shared.jar')).readAsBytesSync(),
        _jarBytes,
      );
      expect(obsolete.existsSync(), isFalse);
      expect(_selectedIds(await list()), <String>{'example'});
    });
  });
}

Map<String, Object?> _object(Object? value) =>
    Map<String, Object?>.from(value as Map<Object?, Object?>);

List<Map<String, Object?>> _entries(Map<String, Object?> result) =>
    (result['entries'] as List<Object?>).map(_object).toList();

Set<String> _selectedIds(Map<String, Object?> result) => _entries(result)
    .where((Map<String, Object?> entry) => entry['selected'] == true)
    .map((Map<String, Object?> entry) => entry['id'] as String)
    .toSet();
