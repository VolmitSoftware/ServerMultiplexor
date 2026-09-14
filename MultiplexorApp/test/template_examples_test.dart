import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/models/template_summary.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/recovery_runtime.dart';
import 'package:multiplexor/services/server_ping.dart';
import 'package:multiplexor/services/template_catalog.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory root;
  late ConsumerService consumers;
  late NativeCommandService service;
  late _TemplateRuntime runtime;

  String instancePath(String name) =>
      p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', name);
  String contents(String instance, String filename) =>
      File(p.join(instancePath(instance), filename)).readAsStringSync();
  Future<CapturedResult> command(List<String> args) =>
      service.execute(args, stream: false);
  Future<CapturedResult> apply(
    String template,
    String name, [
    List<String> flags = const <String>[],
  ]) => command(<String>['template', 'apply', template, name, ...flags]);
  File cache(String type) {
    final File jar = File(
      p.join(
        consumers.rootFor(ConsumerProfile.plugin),
        'builds',
        type,
        '$type-${type == 'velocity' ? '4.1.1' : '1.21.11'}-fixture.jar',
      ),
    );
    jar.parent.createSync(recursive: true);
    jar.writeAsBytesSync(<int>[80, 75, 3, 4]);
    return jar;
  }

  Future<File> copyExample(String example, String custom) async {
    final CapturedResult shown = await command(<String>[
      'template',
      'show',
      example,
    ]);
    expect(shown.exitCode, 0, reason: shown.stderr);
    final File file = File(
      p.join(root.path, '.multiplexor', 'templates', '$custom.yaml'),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(shown.stdout);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync(
      'multiplexor-template-examples-',
    );
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: true,
    );
    consumers = ConsumerService(context)
      ..ensureConsumerDirs(ConsumerProfile.plugin);
    runtime = _TemplateRuntime();
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      recoveryRuntime: runtime,
      processExecutor: (String _, List<String> _) async =>
          ProcessResult(0, 1, '', ''),
    );
  });
  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  test(
    'fresh workspace includes five examples without source or YAML installation',
    () async {
      final List<TemplateSummary> summaries = service.listTemplates();
      expect(
        summaries.map((TemplateSummary item) => item.name),
        unorderedEquals(<String>[
          'paper-dev',
          'purpur-survival',
          'bot-settlement',
          'velocity-lobby-survival',
          'velocity-bot-lab',
        ]),
      );
      expect(
        summaries.every(
          (TemplateSummary item) =>
              item.bundled &&
              item.description.isNotEmpty &&
              item.minecraft == '1.21.11',
        ),
        isTrue,
      );
      final TemplateSummary network = summaries.firstWhere(
        (TemplateSummary item) => item.name == 'velocity-bot-lab',
      );
      expect(network.kind, 'network');
      expect(network.backendCount, 2);
      expect(network.buildTypes, <String>['purpur']);
      expect(
        Directory(p.join(root.path, '.multiplexor', 'templates')).existsSync(),
        isFalse,
      );
      final CapturedResult listed = await command(<String>['template', 'list']);
      expect(listed.stdout, contains('velocity-bot-lab'));
    },
  );

  test('bundled names cannot be initialized overwritten or deleted', () async {
    for (final List<String> args in <List<String>>[
      <String>['init', 'paper-dev'],
      <String>['delete', 'paper-dev'],
      <String>['export', 'missing', 'paper-dev'],
    ]) {
      final CapturedResult result = await command(<String>[
        'template',
        ...args,
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('read-only'));
    }
  });

  test(
    'examples are consumer gated while custom mod templates remain available',
    () async {
      consumers.writeActive(ConsumerProfile.fabric);
      expect(service.listTemplates(), isEmpty);
      final CapturedResult result = await apply('velocity-bot-lab', 'lab');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('require --consumer plugin'));
      expect(
        (await command(<String>[
          'template',
          'init',
          'fabric-local',
          '--type',
          'fabric',
          '--mc',
          '1.21.11',
        ])).exitCode,
        0,
      );
      expect(service.listTemplates().single.name, 'fabric-local');
    },
  );

  test(
    'all single server examples create stopped instances with separate free ports',
    () async {
      cache('paper');
      cache('purpur');
      final Set<String> ports = <String>{};
      for (final String name in <String>[
        'paper-dev',
        'purpur-survival',
        'bot-settlement',
      ]) {
        final CapturedResult result = await apply(name, name);
        expect(result.exitCode, 0, reason: result.stderr);
        expect(contents(name, '.server-source'), contains('mc=1.21.11'));
        expect(
          contents(name, '.multiplexor-runtime.env'),
          contains('HEAP_SIZE=2G'),
        );
        final String properties = contents(name, 'server.properties');
        ports.add(
          RegExp(
            r'^server-port=(\d+)$',
            multiLine: true,
          ).firstMatch(properties)![1]!,
        );
        expect(
          File(
            p.join(instancePath(name), '.multiplexor-create-owner'),
          ).existsSync(),
          isFalse,
        );
      }
      expect(ports, hasLength(3));
      expect(runtime.starts, isEmpty);
      expect(
        contents('bot-settlement', '.server-source'),
        contains('isolated=true'),
      );
      expect(
        contents('bot-settlement', 'server.properties'),
        contains('online-mode=false'),
      );
      expect(
        contents('bot-settlement', 'server.properties'),
        contains('server-ip=127.0.0.1'),
      );
      expect(
        contents('bot-settlement', 'server.properties'),
        contains('level-type=minecraft:flat'),
      );
      expect(
        FileSystemEntity.isLinkSync(
          p.join(instancePath('bot-settlement'), 'ops.json'),
        ),
        isFalse,
      );
      expect(
        Directory(p.join(instancePath('bot-settlement'), 'world')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'network show is complete reusable YAML with stable lobby and survival aliases',
    () async {
      cache('purpur');
      cache('velocity');
      final File copied = await copyExample('velocity-bot-lab', 'copied-lab');
      final YamlMap yaml = loadYaml(copied.readAsStringSync()) as YamlMap;
      expect(yaml['kind'], 'network');
      expect(
        (yaml['backends'] as YamlMap).keys,
        unorderedEquals(<String>['lobby', 'survival']),
      );
      final CapturedResult result = await apply('copied-lab', 'lab');
      expect(result.exitCode, 0, reason: result.stderr);
      final CapturedResult checked = await command(<String>[
        'network',
        'check',
        'lab',
        '--json',
      ]);
      expect(checked.exitCode, 0, reason: checked.stderr);
      final Map<String, dynamic> status =
          jsonDecode(checked.stdout) as Map<String, dynamic>;
      expect(status['issues'], isEmpty);
      final CapturedResult listed = await command(<String>[
        'network',
        'list',
        '--json',
      ]);
      final Map<String, dynamic> network =
          (jsonDecode(listed.stdout) as List).single as Map<String, dynamic>;
      expect(network['defaultServer'], 'lobby');
      expect(network['onlineMode'], false);
      final List<dynamic> members = network['members'] as List<dynamic>;
      expect(
        members.map((dynamic item) => item['alias']),
        unorderedEquals(<String>['lobby', 'survival']),
      );
      expect(
        members.map((dynamic item) => item['instance']),
        unorderedEquals(<String>['lab-lobby', 'lab-survival']),
      );
      expect(
        contents('lab-proxy', '.multiplexor-runtime.env'),
        contains('HEAP_SIZE=1G'),
      );
      expect(
        contents('lab-proxy', 'velocity.toml'),
        contains("player-info-forwarding-mode = 'MODERN'"),
      );
      expect(
        contents('lab-survival', 'config/paper-global.yml'),
        contains('velocity:'),
      );
      expect(
        contents('lab-survival', 'server.properties'),
        contains('online-mode=false'),
      );
      for (final String name in <String>[
        'lab-lobby',
        'lab-survival',
        'lab-proxy',
      ]) {
        expect(
          File(
            p.join(instancePath(name), '.multiplexor-create-owner'),
          ).existsSync(),
          isFalse,
        );
      }
      expect(runtime.starts, isEmpty);
    },
  );

  test(
    'network backend ports avoid existing stopped standalone servers',
    () async {
      cache('purpur');
      cache('velocity');
      expect((await apply('bot-settlement', 'settlement')).exitCode, 0);
      final CapturedResult result = await apply('velocity-bot-lab', 'lab');
      expect(result.exitCode, 0, reason: result.stderr);
      final Map<int, List<String>> ports = service.configuredInstancePorts();
      expect(ports, hasLength(4));
      expect(
        ports.values.every((List<String> owners) => owners.length == 1),
        isTrue,
        reason: '$ports',
      );
    },
  );

  test(
    'normal network keeps online authentication and normal survival terrain',
    () async {
      cache('purpur');
      cache('velocity');
      final CapturedResult result = await apply(
        'velocity-lobby-survival',
        'friends',
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        contents('friends-proxy', 'velocity.toml'),
        contains('online-mode = true'),
      );
      expect(
        contents('friends-survival', 'server.properties'),
        contains('difficulty=normal'),
      );
      expect(
        contents('friends-survival', 'server.properties'),
        isNot(contains('level-type=minecraft:flat')),
      );
    },
  );

  test(
    'invalid final backend settings fail before allocating the first backend',
    () async {
      cache('purpur');
      cache('velocity');
      final File copied = await copyExample('velocity-bot-lab', 'invalid-lab');
      copied.writeAsStringSync(
        copied.readAsStringSync().replaceFirst(
          '    heap: 2G',
          '    heap: 0G',
          copied.readAsStringSync().indexOf('  survival:'),
        ),
      );
      final CapturedResult result = await apply('invalid-lab', 'lab');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('Invalid template heap'));
      expect(Directory(instancePath('lab-lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('lab-proxy')).existsSync(), isFalse);
    },
  );

  test('case duplicate aliases fail before changing the workspace', () async {
    cache('purpur');
    final File copied = await copyExample('velocity-bot-lab', 'duplicate-lab');
    copied.writeAsStringSync(
      copied.readAsStringSync().replaceFirst('  survival:', '  LOBBY:'),
    );
    final CapturedResult result = await apply('duplicate-lab', 'lab');
    expect(result.exitCode, 2);
    expect(result.stderr, contains('Invalid backend alias'));
    expect(Directory(instancePath('lab-lobby')).existsSync(), isFalse);
  });

  test(
    'entry repeated in fallback fails before creating any backend',
    () async {
      cache('purpur');
      final File copied = await copyExample('velocity-bot-lab', 'bad-routes');
      copied.writeAsStringSync(
        copied.readAsStringSync().replaceFirst('    - survival', '    - lobby'),
      );
      final CapturedResult result = await apply('bad-routes', 'lab');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('Entry and fallback routes'));
      expect(Directory(instancePath('lab-lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('lab-survival')).existsSync(), isFalse);
    },
  );

  test(
    'target collisions preserve existing paths before any creation',
    () async {
      cache('purpur');
      final Directory existing = Directory(instancePath('lab-survival'))
        ..createSync();
      final File marker = File(p.join(existing.path, 'keep.txt'))
        ..writeAsStringSync('existing world');
      final CapturedResult result = await apply('velocity-bot-lab', 'lab');
      expect(result.exitCode, 2);
      expect(marker.readAsStringSync(), 'existing world');
      expect(Directory(instancePath('lab-lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('lab-proxy')).existsSync(), isFalse);
    },
  );

  test(
    'late runtime inspection failure rolls back only owned instances and keeps caches',
    () async {
      final File purpur = cache('purpur');
      final File velocity = cache('velocity');
      final Directory unrelated = Directory(instancePath('keep'))..createSync();
      final File world = File(p.join(unrelated.path, 'world.dat'))
        ..writeAsStringSync('keep');
      runtime.failOnceOn = 'lab-survival';
      final CapturedResult result = await apply('velocity-bot-lab', 'lab');
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('injected inspection failure'));
      for (final String name in <String>[
        'lab-lobby',
        'lab-survival',
        'lab-proxy',
      ]) {
        expect(Directory(instancePath(name)).existsSync(), isFalse);
      }
      expect(purpur.existsSync(), isTrue);
      expect(velocity.existsSync(), isTrue);
      expect(world.readAsStringSync(), 'keep');
      expect(
        (jsonDecode(
              (await command(<String>['network', 'list', '--json'])).stdout,
            )
            as List),
        isEmpty,
      );
    },
  );

  test(
    'a resource which starts externally is retained with exact recovery guidance',
    () async {
      cache('purpur');
      cache('velocity');
      runtime.running.add('lab-survival');
      final CapturedResult result = await apply('velocity-bot-lab', 'lab');
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('[RECOVERY] Retained template resources: lab-survival'),
      );
      expect(Directory(instancePath('lab-survival')).existsSync(), isTrue);
      expect(Directory(instancePath('lab-lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('lab-proxy')).existsSync(), isFalse);
    },
  );

  test(
    'isolated sync stays isolated and reports the skipped subscription',
    () async {
      cache('purpur');
      final File dropin = File(
        p.join(
          consumers.rootFor(ConsumerProfile.plugin),
          'dropins',
          'plugins',
          'example.jar',
        ),
      )..writeAsStringSync('fixture');
      final CapturedResult result = await apply(
        'bot-settlement',
        'lab',
        <String>['--sync'],
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('shared drop-in sync was skipped'));
      expect(
        File(
          p.join(instancePath('lab'), 'plugins', p.basename(dropin.path)),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('all bundled definitions round-trip through YAML show', () async {
    for (final BundledTemplate bundled in bundledTemplates) {
      final CapturedResult shown = await command(<String>[
        'template',
        'show',
        bundled.name,
      ]);
      final YamlMap parsed = loadYaml(shown.stdout) as YamlMap;
      expect(parsed['name'], bundled.name);
      expect(parsed['kind'], bundled.summary.kind);
      expect(parsed['description'], bundled.description);
    }
  });
}

class _TemplateRuntime implements RecoveryRuntime {
  final List<String> starts = <String>[];
  final Set<String> running = <String>{};
  String? failOnceOn;

  @override
  Future<bool> isRunning(ConsumerProfile profile, String instance) async {
    if (failOnceOn == instance) {
      failOnceOn = null;
      throw StateError('injected inspection failure');
    }
    return running.contains(instance);
  }

  @override
  Future<void> start(ConsumerProfile profile, String instance) async =>
      starts.add(instance);

  @override
  Future<void> stopGracefully(ConsumerProfile profile, String instance) async =>
      running.remove(instance);

  @override
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async => null;
}
