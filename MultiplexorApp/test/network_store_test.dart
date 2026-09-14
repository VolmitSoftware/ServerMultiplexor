import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/networks/network_configuration.dart';
import 'package:multiplexor/services/networks/network_definition.dart';
import 'package:multiplexor/services/networks/network_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory root;
  late Directory state;
  late NetworkStore store;

  String instancePath(ConsumerProfile consumer, String name) =>
      p.join(root.path, consumer.shortName, name);

  File file(String instance, String relative) =>
      File(p.join(instancePath(ConsumerProfile.plugin, instance), relative));

  void write(String instance, String relative, String text) {
    final File target = file(instance, relative);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(text);
  }

  void backend(
    String name, {
    String type = 'paper',
    String mc = '1.21.11',
    bool isolated = true,
  }) {
    write(
      name,
      '.server-source',
      'type=$type\nmc=$mc\n${isolated ? 'isolated=true\n' : ''}jar=/cache/$type.jar\n',
    );
    write(
      name,
      'server.properties',
      '# existing\nonline-mode=true\nserver-port=25565\nmotd=Original world\n',
    );
    write(
      name,
      'spigot.yml',
      'settings:\n  bungeecord: true\n  debug: false\n',
    );
    write(
      name,
      'config/paper-global.yml',
      'proxies:\n  velocity:\n    enabled: false\n    secret: prior-secret\nmisc:\n  region-file-cache-size: 512\n',
    );
  }

  NetworkDefinition definition({
    String name = 'dev',
    String proxy = 'gateway',
    bool online = true,
    String bind = '127.0.0.1',
    int port = 25565,
    List<NetworkMember>? members,
    String defaultServer = 'lobby',
    List<String> fallbacks = const <String>[],
  }) => NetworkDefinition(
    name: name,
    proxy: proxy,
    onlineMode: online,
    bind: bind,
    port: port,
    defaultServer: defaultServer,
    fallbackServers: fallbacks,
    members:
        members ??
        <NetworkMember>[
          const NetworkMember(
            consumer: ConsumerProfile.plugin,
            instance: 'lobby',
            alias: 'lobby',
            port: 25566,
          ),
          const NetworkMember(
            consumer: ConsumerProfile.plugin,
            instance: 'survival',
            alias: 'survival',
            port: 25567,
          ),
        ],
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-network-');
    state = Directory(p.join(root.path, 'state', 'networks'));
    store = NetworkStore(stateDirectory: state, instancePath: instancePath);
    write(
      'gateway',
      '.server-source',
      'type=velocity\nlaunch=jar\nisolated=true\n',
    );
    backend('lobby');
    backend('survival');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'network model rejects invalid routes, aliases, consumers and ports',
    () {
      expect(
        definition(defaultServer: 'missing').validate(),
        contains('Unknown route: missing.'),
      );
      expect(
        definition(fallbacks: <String>['lobby']).validate(),
        contains('Duplicate route: lobby.'),
      );
      expect(definition(online: false, bind: '0.0.0.0').validate(), isNotEmpty);
      expect(definition(name: '../escape').validate(), isNotEmpty);
      expect(
        definition(
          members: const <NetworkMember>[
            NetworkMember(
              consumer: ConsumerProfile.forge,
              instance: 'lobby',
              alias: 'try',
              port: 25565,
            ),
          ],
        ).validate(),
        hasLength(greaterThan(2)),
      );
      expect(
        definition(
          members: const <NetworkMember>[
            NetworkMember(
              consumer: ConsumerProfile.plugin,
              instance: 'lobby',
              alias: 'lobby',
              port: 25566,
            ),
            NetworkMember(
              consumer: ConsumerProfile.plugin,
              instance: 'LOBBY',
              alias: 'LOBBY',
              port: 25567,
            ),
          ],
        ).validate(),
        contains('Duplicate backend alias: LOBBY.'),
      );
      expect(
        NetworkDefinition.fromJson(definition().toJson()).toJson(),
        definition().toJson(),
      );
    },
  );

  test('create configures modern forwarding and redacts public model', () {
    final NetworkDefinition network = definition(
      fallbacks: <String>['survival'],
    );
    store.create(network);
    expect(store.validateConfiguration(network), isEmpty);
    expect(store.list().single.name, 'dev');
    expect(store.load('dev').toJson(), network.toJson());
    final String secret = file(
      'gateway',
      'forwarding.secret',
    ).readAsStringSync().trim();
    expect(secret, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(jsonEncode(store.load('dev').toJson()), isNot(contains(secret)));
    final Map<String, Object?> proxy = TomlDocument.parse(
      file('gateway', 'velocity.toml').readAsStringSync(),
    ).toMap();
    expect(proxy['servers'], <String, Object?>{
      'lobby': '127.0.0.1:25566',
      'survival': '127.0.0.1:25567',
      'try': <String>['lobby', 'survival'],
    });
    final YamlMap paper =
        loadYaml(file('lobby', 'config/paper-global.yml').readAsStringSync())
            as YamlMap;
    expect(paper['proxies']['velocity']['secret'], secret);
    expect(paper['proxies']['velocity']['online-mode'], isTrue);
    expect(paper['misc']['region-file-cache-size'], 512);
    expect(
      file('lobby', '.server-source').readAsStringSync(),
      contains('network=dev'),
    );
    if (!Platform.isWindows) {
      expect(
        file('gateway', 'forwarding.secret').statSync().mode & 0x1ff,
        0x180,
      );
    }
  });

  test(
    'detach restores original managed keys and preserves later unrelated changes',
    () {
      store.create(definition());
      file('lobby', 'server.properties').writeAsStringSync(
        'motd=Edited while attached\n',
        mode: FileMode.append,
      );
      file(
        'lobby',
        'config/paper-global.yml',
      ).writeAsStringSync('feature: retained\n', mode: FileMode.append);
      store.delete('dev');
      final NetworkConfigDocument properties = NetworkConfigDocument(
        NetworkConfigFormat.properties,
        file('lobby', 'server.properties').readAsStringSync(),
      );
      expect(properties.value('online-mode'), 'true');
      expect(properties.value('server-port'), '25565');
      expect(properties.contains('server-ip'), isFalse);
      expect(properties.value('motd'), 'Edited while attached');
      final YamlMap paper =
          loadYaml(file('lobby', 'config/paper-global.yml').readAsStringSync())
              as YamlMap;
      expect(paper['proxies']['velocity']['enabled'], isFalse);
      expect(paper['proxies']['velocity']['secret'], 'prior-secret');
      expect(
        (paper['proxies']['velocity'] as YamlMap).containsKey('online-mode'),
        isFalse,
      );
      expect(paper['feature'], 'retained');
      expect(
        file('lobby', '.server-source').readAsStringSync(),
        isNot(contains('network=')),
      );
      expect(
        file('gateway', '.server-source').readAsStringSync(),
        isNot(contains('network=')),
      );
      expect(file('gateway', 'velocity.toml').existsSync(), isTrue);
      expect(store.list(), isEmpty);
    },
  );

  test('update adds and removes members while preserving TOML tuning', () {
    store.create(definition());
    final File proxy = file('gateway', 'velocity.toml');
    proxy.writeAsStringSync(
      '\n[advanced]\ncompression-threshold = 128\n',
      mode: FileMode.append,
    );
    backend('creative');
    final NetworkDefinition updated = definition(
      members: const <NetworkMember>[
        NetworkMember(
          consumer: ConsumerProfile.plugin,
          instance: 'lobby',
          alias: 'lobby',
          port: 25566,
        ),
        NetworkMember(
          consumer: ConsumerProfile.plugin,
          instance: 'creative',
          alias: 'creative',
          port: 25568,
        ),
      ],
      fallbacks: <String>['creative'],
    );
    store.update(updated);
    expect(store.validateConfiguration(updated), isEmpty);
    expect(
      TomlDocument.parse(proxy.readAsStringSync()).toMap()['advanced'],
      <String, Object?>{'compression-threshold': 128},
    );
    expect(
      file('survival', 'server.properties').readAsStringSync(),
      contains('online-mode=true'),
    );
    expect(
      file('survival', '.server-source').readAsStringSync(),
      isNot(contains('network=')),
    );
    store.delete('dev');
    expect(
      file('creative', 'server.properties').readAsStringSync(),
      contains('online-mode=true'),
    );
  });

  for (final String routes in <String>['[]', '["missing"]', '"missing"']) {
    test(
      'create rejects forced-host routes $routes before changing backends',
      () {
        write(
          'gateway',
          'velocity.toml',
          '[forced-hosts]\n"join.example" = $routes\n',
        );
        final String before = file(
          'lobby',
          'server.properties',
        ).readAsStringSync();
        expect(
          () => store.create(definition()),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('forced-hosts'),
            ),
          ),
        );
        expect(file('lobby', 'server.properties').readAsStringSync(), before);
        expect(store.list(), isEmpty);
      },
    );
  }

  test(
    'configuration checks and updates reject invalid forced-host routes',
    () {
      store.create(definition());
      final File proxy = file('gateway', 'velocity.toml');
      final Map<String, Object?> config = TomlDocument.parse(
        proxy.readAsStringSync(),
      ).toMap();
      final String before = file(
        'lobby',
        'server.properties',
      ).readAsStringSync();
      for (final Object routes in <Object>[
        <String>[],
        <String>['missing'],
        'missing',
      ]) {
        config['forced-hosts'] = <String, Object?>{'join.example': routes};
        proxy.writeAsStringSync(TomlDocument.fromMap(config).toString());
        expect(
          store.validateConfiguration(definition()).join(),
          contains('forced-hosts'),
        );
        expect(() => store.update(definition()), throwsStateError);
        expect(file('lobby', 'server.properties').readAsStringSync(), before);
      }
    },
  );

  test('valid scalar forced-host routes survive create and update unchanged', () {
    write(
      'gateway',
      'velocity.toml',
      '[forced-hosts]\n"join.example" = "lobby"\n"survival.example" = ["survival", "lobby"]\n',
    );
    store.create(definition());
    expect(store.validateConfiguration(definition()), isEmpty);
    final NetworkDefinition updated = definition(
      fallbacks: <String>['survival'],
    );
    store.update(updated);
    expect(store.validateConfiguration(updated), isEmpty);
    final Map<String, Object?> proxy = TomlDocument.parse(
      file('gateway', 'velocity.toml').readAsStringSync(),
    ).toMap();
    expect(proxy['forced-hosts'], <String, Object?>{
      'join.example': 'lobby',
      'survival.example': <String>['survival', 'lobby'],
    });
  });

  test(
    'removing a backend referenced by forced-hosts leaves membership intact',
    () {
      write(
        'gateway',
        'velocity.toml',
        '[forced-hosts]\n"join.example" = "survival"\n',
      );
      store.create(definition());
      final NetworkDefinition updated = definition(
        members: const <NetworkMember>[
          NetworkMember(
            consumer: ConsumerProfile.plugin,
            instance: 'lobby',
            alias: 'lobby',
            port: 25566,
          ),
        ],
      );
      expect(() => store.update(updated), throwsStateError);
      expect(store.load('dev').members, hasLength(2));
      expect(
        file('survival', '.server-source').readAsStringSync(),
        contains('network=dev'),
      );
      expect(
        file('survival', 'server.properties').readAsStringSync(),
        contains('online-mode=false'),
      );
    },
  );

  test(
    'membership cannot be duplicated even when backend marker was removed',
    () {
      store.create(definition());
      write('gateway2', '.server-source', 'type=velocity\nisolated=true\n');
      write(
        'lobby',
        '.server-source',
        'type=paper\nmc=1.21.11\nisolated=true\n',
      );
      expect(
        () => store.create(
          definition(
            name: 'other',
            proxy: 'gateway2',
            port: 25580,
            members: const <NetworkMember>[
              NetworkMember(
                consumer: ConsumerProfile.plugin,
                instance: 'lobby',
                alias: 'lobby',
                port: 25581,
              ),
            ],
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('already belongs'),
          ),
        ),
      );
    },
  );

  test(
    'managed drift blocks changes and diagnostics omit forwarding secret',
    () {
      store.create(definition());
      final String before = file(
        'lobby',
        'server.properties',
      ).readAsStringSync();
      file('lobby', 'server.properties').writeAsStringSync(
        before.replaceAll('server-port=25566', 'server-port=25599'),
      );
      final List<String> errors = store.validateConfiguration(definition());
      expect(errors.join(), contains('server-port'));
      expect(() => store.delete('dev'), throwsStateError);
      expect(
        file('lobby', 'server.properties').readAsStringSync(),
        contains('25599'),
      );
      write('lobby', 'server.properties', before);
      write(
        'lobby',
        'config/paper-global.yml',
        'proxies: [\n SECRET-THAT-MUST-NOT-LEAK',
      );
      expect(
        store.validateConfiguration(definition()).join(),
        isNot(contains('SECRET-THAT-MUST-NOT-LEAK')),
      );
    },
  );

  test(
    'symlink configuration is rejected before any instance is changed',
    () {
      final File target = File(p.join(root.path, 'shared.yml'))
        ..writeAsStringSync('settings:\n  bungeecord: true\n');
      file('survival', 'spigot.yml').deleteSync();
      Link(file('survival', 'spigot.yml').path).createSync(target.path);
      expect(() => store.create(definition()), throwsStateError);
      expect(
        file('lobby', 'server.properties').readAsStringSync(),
        contains('online-mode=true'),
      );
      expect(target.readAsStringSync(), 'settings:\n  bungeecord: true\n');
      expect(store.list(), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('offline mode requires isolated members and modern Paper versions', () {
    backend('lobby', isolated: false);
    expect(() => store.create(definition(online: false)), throwsStateError);
    backend('lobby', mc: '1.18.2');
    expect(() => store.create(definition()), throwsStateError);
    backend('lobby', type: 'spigot');
    expect(() => store.create(definition()), throwsStateError);
    backend('lobby', mc: '26.1');
    store.create(definition(online: false));
    expect(store.validateConfiguration(definition(online: false)), isEmpty);
  });

  for (final String operation in <String>[
    'create',
    'update',
    'delete',
    'repair',
  ]) {
    test('$operation failure rolls every file back', () {
      if (operation != 'create') store.create(definition());
      if (operation == 'repair') {
        final File properties = file('lobby', 'server.properties');
        properties.writeAsStringSync(
          properties.readAsStringSync().replaceAll(
            'server-port=25566',
            'server-port=25599',
          ),
        );
      }
      final Map<String, String> before = <String, String>{
        for (final File entry
            in root.listSync(recursive: true).whereType<File>())
          entry.path: entry.readAsStringSync(),
      };
      int writes = 0;
      final NetworkStore failing = NetworkStore(
        stateDirectory: state,
        instancePath: instancePath,
        beforeWrite: (String path) {
          if (++writes == 5) throw StateError('Injected failure');
        },
      );
      expect(
        () {
          switch (operation) {
            case 'create':
              failing.create(definition());
            case 'update':
              failing.update(definition(fallbacks: <String>['survival']));
            case 'delete':
              failing.delete('dev');
            case 'repair':
              failing.repair('dev');
          }
        },
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('original configuration was restored'),
          ),
        ),
      );
      final Map<String, String> after = <String, String>{
        for (final File entry
            in root.listSync(recursive: true).whereType<File>())
          if (p.basename(entry.path) != '.lock' ||
              before.containsKey(entry.path))
            entry.path: entry.readAsStringSync(),
      };
      expect(after, before);
      expect(
        File(p.join(state.path, '.transaction.json')).existsSync(),
        isFalse,
      );
    });
  }

  test(
    'configuration editor preserves nested keys and restores absent parents',
    () {
      final NetworkConfigDocument yaml = NetworkConfigDocument(
        NetworkConfigFormat.yaml,
        'unrelated: 1\n',
      );
      final Map<String, Object?> before = yaml.snapshot(
        'proxies.velocity.enabled',
      );
      yaml.set('proxies.velocity.enabled', true);
      yaml.restore('proxies.velocity.enabled', before);
      expect(loadYaml(yaml.render()), <String, Object?>{'unrelated': 1});
    },
  );

  test('recognized cached jar names supply missing Minecraft metadata', () {
    write(
      'lobby',
      '.server-source',
      'type=paper\njar=/cache/paper-1.21.11-42.jar\nisolated=true\n',
    );
    store.create(definition());
    expect(store.validateConfiguration(definition()), isEmpty);
    expect(
      file('lobby', '.server-source').readAsStringSync(),
      isNot(contains('mc=')),
    );
  });

  test('dotted instance and network names roundtrip through TOML routes', () {
    backend('lobby.dev');
    final NetworkDefinition network = definition(
      name: 'dev.local',
      defaultServer: 'lobby.dev',
      members: const <NetworkMember>[
        NetworkMember(
          consumer: ConsumerProfile.plugin,
          instance: 'lobby.dev',
          alias: 'lobby.dev',
          port: 25566,
        ),
      ],
    );
    store.create(network);
    expect(store.load('dev.local').toJson(), network.toJson());
    expect(store.validateConfiguration(network), isEmpty);
    final Map<String, Object?> proxy = TomlDocument.parse(
      file('gateway', 'velocity.toml').readAsStringSync(),
    ).toMap();
    expect((proxy['servers'] as Map)['lobby.dev'], '127.0.0.1:25566');
    store.delete('dev.local');
    expect(
      file('lobby.dev', 'server.properties').readAsStringSync(),
      contains('online-mode=true'),
    );
  });

  test('explicit repair reapplies managed keys and retains original settings', () {
    store.create(definition());
    final File properties = file('lobby', 'server.properties');
    properties.writeAsStringSync(
      '${properties.readAsStringSync().replaceAll('server-port=25566', 'server-port=25599')}view-distance=7\n',
    );
    final File proxy = file('gateway', 'velocity.toml');
    proxy.writeAsStringSync(
      '${proxy.readAsStringSync().replaceAll('MODERN', 'NONE')}\n[advanced]\ncompression-threshold = 128\n',
    );
    final String secret = file(
      'gateway',
      'forwarding.secret',
    ).readAsStringSync();
    expect(store.validateConfiguration(definition()), isNotEmpty);
    expect(() => store.update(definition()), throwsStateError);
    store.repair('dev');
    expect(store.validateConfiguration(definition()), isEmpty);
    expect(properties.readAsStringSync(), contains('view-distance=7'));
    expect(file('gateway', 'forwarding.secret').readAsStringSync(), secret);
    expect(
      TomlDocument.parse(proxy.readAsStringSync()).toMap()['advanced'],
      <String, Object?>{'compression-threshold': 128},
    );
    store.delete('dev');
    expect(properties.readAsStringSync(), contains('server-port=25565'));
    expect(properties.readAsStringSync(), contains('online-mode=true'));
  });

  test('repair refuses a missing secret and preserves pending edits', () {
    store.create(definition());
    file('gateway', 'forwarding.secret').deleteSync();
    final File properties = file('lobby', 'server.properties');
    final String changed = properties.readAsStringSync().replaceAll(
      'server-port=25566',
      'server-port=25599',
    );
    properties.writeAsStringSync(changed);
    expect(
      () => store.repair('dev'),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('forwarding secret is missing'),
        ),
      ),
    );
    expect(properties.readAsStringSync(), changed);
  });

  test('YAML alias editing errors never expose existing secrets', () {
    write(
      'lobby',
      'config/paper-global.yml',
      'saved: &forwarding\n  enabled: false\n  secret: NEVER-EXPOSE-THIS-SECRET\nproxies:\n  velocity: *forwarding\n',
    );
    try {
      store.create(definition());
      fail('Aliases must be rejected');
    } catch (error) {
      expect(error.toString(), isNot(contains('NEVER-EXPOSE-THIS-SECRET')));
      expect(error.toString(), contains('explicit mappings'));
    }
    expect(
      file('lobby', 'server.properties').readAsStringSync(),
      contains('online-mode=true'),
    );
  });

  test('incomplete original snapshots prevent detach', () {
    store.create(definition());
    final File record = File(p.join(state.path, 'dev.json'));
    final Map<String, Object?> data = Map<String, Object?>.from(
      jsonDecode(record.readAsStringSync()) as Map,
    );
    data['originals'] = <String, Object?>{
      'plugin/lobby': <String, Object?>{},
      'plugin/survival': <String, Object?>{},
    };
    record.writeAsStringSync(jsonEncode(data));
    expect(() => store.delete('dev'), throwsStateError);
    expect(
      file('lobby', '.server-source').readAsStringSync(),
      contains('network=dev'),
    );
  });

  test(
    'read commands leave pending transaction files untouched until explicit recovery',
    () {
      store.create(definition());
      final File properties = file('lobby', 'server.properties');
      final String before = properties.readAsStringSync();
      final String after = before.replaceAll(
        'server-port=25566',
        'server-port=25590',
      );
      final File journal = File(p.join(state.path, '.transaction.json'));
      journal.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'committed': false,
          'definitions': <Object?>[definition().toJson()],
          'files': <String, Object?>{
            properties.path: <String, Object?>{
              'before': before,
              'after': after,
            },
          },
        }),
      );
      properties.writeAsStringSync(after);
      expect(store.pendingRecoveryDefinitions().single.name, 'dev');
      expect(() => store.load('dev'), throwsStateError);
      expect(() => store.list(), throwsStateError);
      expect(() => store.validateConfiguration(definition()), throwsStateError);
      expect(properties.readAsStringSync(), after);
      final NetworkStore recovery = NetworkStore(
        stateDirectory: state,
        instancePath: instancePath,
        beforeWrite: (_) =>
            throw StateError('This hook must not run during recovery'),
      );
      recovery.recover();
      expect(properties.readAsStringSync(), before);
      expect(store.pendingRecoveryDefinitions(), isEmpty);
      expect(store.validateConfiguration(definition()), isEmpty);
    },
  );

  test(
    'recovery refuses config changes made after an interrupted transaction',
    () {
      store.create(definition());
      final File properties = file('lobby', 'server.properties');
      final String before = properties.readAsStringSync();
      final File journal = File(p.join(state.path, '.transaction.json'));
      journal.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'committed': false,
          'definitions': <Object?>[definition().toJson()],
          'files': <String, Object?>{
            properties.path: <String, Object?>{
              'before': before,
              'after': '$before# planned\n',
            },
          },
        }),
      );
      properties.writeAsStringSync('$before# subsequent operator change\n');
      expect(() => store.recover(), throwsStateError);
      expect(journal.existsSync(), isTrue);
      expect(
        properties.readAsStringSync(),
        contains('subsequent operator change'),
      );
    },
  );

  test('committed journals are never rolled back', () {
    store.create(definition());
    final File properties = file('lobby', 'server.properties');
    final String current = properties.readAsStringSync();
    File(p.join(state.path, '.transaction.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': 1,
        'committed': true,
        'definitions': <Object?>[definition().toJson()],
        'files': <String, Object?>{
          properties.path: <String, Object?>{
            'before': 'old settings',
            'after': current,
          },
        },
      }),
    );
    expect(store.pendingRecoveryDefinitions(), isEmpty);
    expect(store.load('dev').name, 'dev');
    store.recover();
    expect(properties.readAsStringSync(), current);
  });

  test('network store rejects an overlapping command in this process', () {
    final NetworkStore nested = NetworkStore(
      stateDirectory: state,
      instancePath: instancePath,
      beforeWrite: (_) {
        expect(() => store.list(), throwsStateError);
      },
    );
    nested.create(definition());
    expect(store.load('dev').name, 'dev');
  });

  test('network store uses a cross-process exclusive file lock', () async {
    store.list();
    final File script = File(p.join(root.path, 'hold-lock.dart'));
    script.writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final RandomAccessFile file = File(args.single).openSync(mode: FileMode.append);
  file.lockSync(FileLock.exclusive);
  stdout.writeln('ready');
  await stdin.first;
  file.closeSync();
}
''');
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>[script.path, p.join(state.path, '.lock')],
    );
    try {
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10)),
        'ready',
      );
      expect(() => store.list(), throwsStateError);
      process.stdin.add(<int>[10]);
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    } finally {
      process.kill();
    }
    expect(store.list(), isEmpty);
  });
}
