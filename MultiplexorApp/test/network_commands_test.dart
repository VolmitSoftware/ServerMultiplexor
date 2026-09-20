import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/recovery_runtime.dart';
import 'package:multiplexor/services/server_ping.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late ConsumerService consumers;
  late _NetworkRuntime runtime;
  late File jar;
  late int port;

  String instancePath(String name) =>
      p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', name);
  Future<CapturedResult> command(List<String> args) =>
      service.execute(args, stream: false);
  Future<void> create({bool offline = true}) async {
    final CapturedResult result = await command(<String>[
      'network',
      'create',
      'test',
      '--members',
      'lobby,survival',
      '--default',
      'lobby',
      '--jar',
      jar.path,
      '--port',
      '$port',
      if (offline) '--offline',
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-network-command-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: true,
    );
    consumers = ConsumerService(context)
      ..ensureConsumerDirs(ConsumerProfile.plugin);
    runtime = _NetworkRuntime();
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      recoveryRuntime: runtime,
      javaInspector: (String _) async => 25,
      processExecutor: (String _, List<String> _) async =>
          ProcessResult(0, 1, '', ''),
    );
    jar = File(p.join(root.path, 'velocity.jar'))
      ..writeAsStringSync('fixture jar');
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    port = socket.port;
    await socket.close();
    for (final String name in <String>['lobby', 'survival', 'extra']) {
      final Directory directory = Directory(instancePath(name))
        ..createSync(recursive: true);
      File(p.join(directory.path, '.server-source')).writeAsStringSync(
        'type=paper\nmc=1.21.11\nlaunch=jar\njar=${jar.path}\nisolated=true\n',
      );
      File(p.join(directory.path, 'server.properties')).writeAsStringSync(
        'server-port=25565\nonline-mode=true\nserver-ip=\nmotd=$name\n',
      );
    }
  });
  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  test(
    'creates proxy without game files and returns a secret-free status',
    () async {
      await create();
      final CapturedResult status = await command(<String>[
        'network',
        'status',
        'test',
        '--json',
      ]);
      expect(status.exitCode, 0, reason: status.stderr);
      final Map<String, dynamic> decoded =
          jsonDecode(status.stdout) as Map<String, dynamic>;
      expect(decoded['state'], 'stopped');
      expect(decoded['issues'], isEmpty);
      expect(decoded['instances'], hasLength(3));
      final String secret = File(
        p.join(instancePath('test-proxy'), 'forwarding.secret'),
      ).readAsStringSync().trim();
      expect(status.stdout, isNot(contains(secret)));
      for (final String filename in <String>[
        'server.properties',
        'eula.txt',
        'ops.json',
        '.multiplexor-create-owner',
      ]) {
        expect(
          File(p.join(instancePath('test-proxy'), filename)).existsSync(),
          isFalse,
        );
      }
      final CapturedResult candidates = await command(<String>[
        'network',
        'candidates',
        '--json',
      ]);
      expect(
        (jsonDecode(candidates.stdout) as List).single['instance'],
        'extra',
      );
    },
  );

  test(
    'start waits for backends before proxy and stop reverses order',
    () async {
      await create();
      expect((await command(<String>['network', 'start', 'test'])).exitCode, 0);
      expect(runtime.events, <String>[
        'start:lobby',
        'ready:lobby',
        'start:survival',
        'ready:survival',
        'start:test-proxy',
        'ready:test-proxy',
      ]);
      runtime.events.clear();
      expect((await command(<String>['network', 'stop', 'test'])).exitCode, 0);
      expect(runtime.events, <String>[
        'stop:test-proxy',
        'stop:survival',
        'stop:lobby',
      ]);
    },
  );

  for (final int players in <int>[0, 7]) {
    test('status reports $players players from the proxy', () async {
      await create(offline: false);
      expect(
        (await command(<String>[
          'network',
          'configure',
          'test',
          '--bind',
          '0.0.0.0',
        ])).exitCode,
        0,
      );
      runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      addTearDown(server.close);
      final List<Socket> clients = <Socket>[];
      addTearDown(() {
        for (final Socket client in clients) {
          client.destroy();
        }
      });
      server.listen((Socket client) {
        clients.add(client);
        bool replied = false;
        client.listen((List<int> _) {
          if (replied) return;
          replied = true;
          final List<int> payload = utf8.encode(
            jsonEncode(<String, Object?>{
              'players': <String, int>{'online': players, 'max': 100},
            }),
          );
          final List<int> packet = <int>[
            0,
            ...encodeVarInt(payload.length),
            ...payload,
          ];
          client.add(<int>[...encodeVarInt(packet.length), ...packet]);
        });
      });
      final CapturedResult status = await command(<String>[
        'network',
        'status',
        'test',
        '--json',
      ]);
      expect(status.exitCode, 0, reason: status.stderr);
      final Map<String, Object?> decoded =
          jsonDecode(status.stdout) as Map<String, Object?>;
      expect(decoded['playersOnline'], players);
      expect(decoded['state'], 'running');
      expect(clients, hasLength(1));
    });
  }

  test(
    'unreachable proxy reports unavailable players instead of zero',
    () async {
      await create();
      runtime.running.add('test-proxy');
      final CapturedResult status = await command(<String>[
        'network',
        'status',
        'test',
        '--json',
      ]);
      final Map<String, Object?> decoded =
          jsonDecode(status.stdout) as Map<String, Object?>;
      expect(decoded, containsPair('playersOnline', null));
      expect(decoded['state'], 'degraded');
      expect(
        (await command(<String>['network', 'status', 'test'])).stdout,
        contains('players unavailable'),
      );
    },
  );

  test('stopped status and configuration checks do not ping players', () async {
    await create();
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    addTearDown(server.close);
    int connections = 0;
    server.listen((Socket client) {
      connections++;
      client.destroy();
    });
    final CapturedResult stopped = await command(<String>[
      'network',
      'status',
      'test',
      '--json',
    ]);
    expect(
      jsonDecode(stopped.stdout) as Map<String, Object?>,
      containsPair('playersOnline', null),
    );
    runtime.running.add('test-proxy');
    final CapturedResult checked = await command(<String>[
      'network',
      'check',
      'test',
      '--json',
    ]);
    expect(
      jsonDecode(checked.stdout) as Map<String, Object?>,
      containsPair('playersOnline', null),
    );
    expect(connections, 0);
  });

  test('failed network start stops only processes it started', () async {
    await create();
    runtime.running.add('lobby');
    runtime.failReadiness = 'survival';
    final CapturedResult result = await command(<String>[
      'network',
      'start',
      'test',
    ]);
    expect(result.exitCode, isNot(0));
    expect(runtime.running, <String>{'lobby'});
    expect(runtime.events, <String>[
      'ready:lobby',
      'start:survival',
      'ready:survival',
      'stop:survival',
    ]);
  });

  test(
    'removing a backend stops the network and preserves backend data',
    () async {
      await create();
      runtime.running.add('lobby');
      final File properties = File(
        p.join(instancePath('survival'), 'server.properties'),
      );
      properties.writeAsStringSync(
        '${properties.readAsStringSync()}view-distance=7\n',
      );
      final CapturedResult removed = await command(<String>[
        'network',
        'remove',
        'test',
        'survival',
      ]);
      expect(removed.exitCode, 0, reason: removed.stderr);
      expect(runtime.events, <String>['stop:lobby']);
      expect(runtime.running, isEmpty);
      expect(properties.readAsStringSync(), contains('online-mode=true'));
      expect(properties.readAsStringSync(), contains('view-distance=7'));
      expect(properties.readAsStringSync(), contains('motd=survival'));
      expect(
        (await command(<String>[
          'network',
          'add',
          'test',
          'extra',
          '--alias',
          'creative',
        ])).exitCode,
        0,
      );
    },
  );

  test(
    'linked instance reset and configuration operations are refused',
    () async {
      await create();
      for (final List<String> args in <List<String>>[
        <String>['instance', 'reset', 'lobby'],
        <String>['instance', 'clone', 'lobby', 'copy'],
        <String>['instance', 'port', 'lobby', '25590'],
        <String>['instance', 'isolated', 'lobby', 'false'],
        <String>['instance', 'update', 'lobby', '--jar', jar.path],
        <String>['instance', 'safe-update', 'lobby', '--jar', jar.path],
      ]) {
        final CapturedResult result = await command(args);
        expect(
          result.exitCode,
          2,
          reason: '${args.join(' ')}: ${result.stderr}',
        );
        expect(result.stderr, contains('network'));
      }
    },
  );

  test(
    'drift is reported and refuses startup before any process starts',
    () async {
      await create();
      final File properties = File(
        p.join(instancePath('lobby'), 'server.properties'),
      );
      properties.writeAsStringSync(
        properties.readAsStringSync().replaceAll(
          'server-ip=127.0.0.1',
          'server-ip=0.0.0.0',
        ),
      );
      expect(
        (await command(<String>[
          'network',
          'check',
          'test',
          '--json',
        ])).exitCode,
        1,
      );
      expect((await command(<String>['network', 'start', 'test'])).exitCode, 2);
      expect(runtime.events, isEmpty);
    },
  );

  test(
    'deleting the entry backend promotes its fallback and stops the network',
    () async {
      await create();
      expect(
        (await command(<String>[
          'network',
          'configure',
          'test',
          '--fallback',
          'survival',
        ])).exitCode,
        0,
      );
      runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
      final CapturedResult deleted = await command(<String>[
        'instance',
        'delete',
        'lobby',
      ]);
      expect(deleted.exitCode, 0, reason: deleted.stderr);
      expect(Directory(instancePath('lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('survival')).existsSync(), isTrue);
      expect(runtime.events, <String>[
        'stop:test-proxy',
        'stop:survival',
        'stop:lobby',
      ]);
      expect(runtime.running, isEmpty);
      final CapturedResult status = await command(<String>[
        'network',
        'status',
        'test',
        '--json',
      ]);
      expect(status.exitCode, 0, reason: status.stderr);
      final Map<String, Object?> decoded =
          jsonDecode(status.stdout) as Map<String, Object?>;
      final Map<String, Object?> network =
          decoded['network'] as Map<String, Object?>;
      expect(network['defaultServer'], 'survival');
      expect(network['fallbackServers'], isEmpty);
      expect(network['members'], hasLength(1));
      expect(decoded['issues'], isEmpty);
    },
  );

  test('deleting a fallback backend leaves a valid entry route', () async {
    await create();
    expect(
      (await command(<String>[
        'network',
        'configure',
        'test',
        '--fallback',
        'survival',
      ])).exitCode,
      0,
    );
    final CapturedResult deleted = await command(<String>[
      'instance',
      'delete',
      'survival',
    ]);
    expect(deleted.exitCode, 0, reason: deleted.stderr);
    final CapturedResult status = await command(<String>[
      'network',
      'status',
      'test',
      '--json',
    ]);
    final Map<String, Object?> decoded =
        jsonDecode(status.stdout) as Map<String, Object?>;
    final Map<String, Object?> network =
        decoded['network'] as Map<String, Object?>;
    expect(network['defaultServer'], 'lobby');
    expect(network['fallbackServers'], isEmpty);
    expect(decoded['issues'], isEmpty);
  });

  test(
    'deleting the final backend dissolves its network and keeps the proxy',
    () async {
      await create();
      for (final String name in <String>['survival', 'lobby']) {
        final CapturedResult deleted = await command(<String>[
          'instance',
          'delete',
          name,
        ]);
        expect(deleted.exitCode, 0, reason: deleted.stderr);
        expect(Directory(instancePath(name)).existsSync(), isFalse);
      }
      expect(
        jsonDecode(
          (await command(<String>['network', 'list', '--json'])).stdout,
        ),
        isEmpty,
      );
      expect(Directory(instancePath('test-proxy')).existsSync(), isTrue);
      expect(
        File(
          p.join(instancePath('test-proxy'), '.server-source'),
        ).readAsStringSync(),
        isNot(contains('network=')),
      );
    },
  );

  test(
    'deleting the proxy dissolves its network and restores surviving backends',
    () async {
      await create();
      final CapturedResult deleted = await command(<String>[
        'instance',
        'delete',
        'test-proxy',
      ]);
      expect(deleted.exitCode, 0, reason: deleted.stderr);
      expect(Directory(instancePath('test-proxy')).existsSync(), isFalse);
      expect(
        jsonDecode(
          (await command(<String>['network', 'list', '--json'])).stdout,
        ),
        isEmpty,
      );
      for (final String name in <String>['lobby', 'survival']) {
        expect(
          File(
            p.join(instancePath(name), 'server.properties'),
          ).readAsStringSync(),
          contains('online-mode=true'),
        );
        expect(
          File(p.join(instancePath(name), '.server-source')).readAsStringSync(),
          isNot(contains('network=')),
        );
      }
    },
  );

  for (final bool everywhere in <bool>[false, true]) {
    test(
      'delete-all removes network instances${everywhere ? ' across consumers' : ''}',
      () async {
        await create();
        runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
        final CapturedResult deleted = await command(<String>[
          'instance',
          'delete-all',
          if (everywhere) '--everywhere',
          '--force',
        ]);
        expect(deleted.exitCode, 0, reason: deleted.stderr);
        for (final String name in <String>[
          'lobby',
          'survival',
          'test-proxy',
          'extra',
        ]) {
          expect(Directory(instancePath(name)).existsSync(), isFalse);
        }
        expect(runtime.running, isEmpty);
        expect(
          jsonDecode(
            (await command(<String>['network', 'list', '--json'])).stdout,
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'selected bulk deletion removes both network backends without races',
    () async {
      await create();
      final CapturedResult deleted = await command(<String>[
        'instance',
        'bulk',
        'delete',
        'lobby',
        'survival',
        '--confirm',
        'DELETE lobby,survival',
        '--concurrency',
        '8',
      ]);
      expect(deleted.exitCode, 0, reason: deleted.stderr);
      expect(deleted.stdout, contains('2 succeeded, 0 skipped, 0 failed'));
      expect(Directory(instancePath('lobby')).existsSync(), isFalse);
      expect(Directory(instancePath('survival')).existsSync(), isFalse);
      expect(Directory(instancePath('test-proxy')).existsSync(), isTrue);
      expect(
        jsonDecode(
          (await command(<String>['network', 'list', '--json'])).stdout,
        ),
        isEmpty,
      );
    },
  );

  test(
    'locked deletion leaves the network and running processes untouched',
    () async {
      await create();
      File(
        p.join(instancePath('lobby'), '.server-source'),
      ).writeAsStringSync('locked=true\n', mode: FileMode.append);
      runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
      final CapturedResult deleted = await command(<String>[
        'instance',
        'delete',
        'lobby',
      ]);
      expect(deleted.exitCode, isNot(0));
      expect(deleted.stderr, contains('locked'));
      expect(runtime.events, isEmpty);
      expect(Directory(instancePath('lobby')).existsSync(), isTrue);
      expect((await command(<String>['network', 'check', 'test'])).exitCode, 0);
    },
  );

  test(
    'failed network stop leaves deletion target and topology intact',
    () async {
      await create();
      runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
      runtime.failStop = 'test-proxy';
      final CapturedResult deleted = await command(<String>[
        'instance',
        'delete',
        'lobby',
      ]);
      expect(deleted.exitCode, isNot(0));
      expect(Directory(instancePath('lobby')).existsSync(), isTrue);
      expect(runtime.running, <String>{'lobby', 'survival', 'test-proxy'});
      expect((await command(<String>['network', 'check', 'test'])).exitCode, 0);
    },
  );

  test('wipe preserves locked backends while removing the network', () async {
    await create();
    File(
      p.join(instancePath('lobby'), '.server-source'),
    ).writeAsStringSync('locked=true\n', mode: FileMode.append);
    expect(
      (await command(<String>['instance', 'activate', 'lobby'])).exitCode,
      0,
    );
    final CapturedResult deleted = await command(<String>[
      'instance',
      'delete-all',
      '--force',
    ]);
    expect(deleted.exitCode, 0, reason: deleted.stderr);
    expect(Directory(instancePath('lobby')).existsSync(), isTrue);
    for (final String name in <String>['survival', 'test-proxy', 'extra']) {
      expect(Directory(instancePath(name)).existsSync(), isFalse);
    }
    expect(
      File(
        p.join(instancePath('lobby'), 'server.properties'),
      ).readAsStringSync(),
      contains('online-mode=true'),
    );
    expect(
      (await command(<String>['instance', 'current'])).stdout.trim(),
      'lobby',
    );
    expect(
      jsonDecode((await command(<String>['network', 'list', '--json'])).stdout),
      isEmpty,
    );
  });

  test('failed cross-consumer wipe reports failure', () async {
    await create();
    runtime.running.add('test-proxy');
    runtime.failStop = 'test-proxy';
    final CapturedResult deleted = await command(<String>[
      'instance',
      'delete-all',
      '--everywhere',
      '--force',
    ]);
    expect(deleted.exitCode, isNot(0));
    expect(deleted.stdout, isNot(contains('[OK] Wipe complete')));
    expect(Directory(instancePath('lobby')).existsSync(), isTrue);
    expect((await command(<String>['network', 'check', 'test'])).exitCode, 0);
  });

  for (final List<String> missing in <List<String>>[
    <String>['lobby'],
    <String>['test-proxy'],
    <String>['lobby', 'survival', 'test-proxy', 'extra'],
  ]) {
    test(
      'wipe removes stale network records with missing ${missing.join(', ')}',
      () async {
        await create();
        for (final String name in missing) {
          Directory(instancePath(name)).deleteSync(recursive: true);
        }
        final CapturedResult deleted = await command(<String>[
          'instance',
          'delete-all',
          '--force',
        ]);
        expect(deleted.exitCode, 0, reason: deleted.stderr);
        expect(Directory(instancePath('extra')).parent.listSync(), isEmpty);
        expect(
          jsonDecode(
            (await command(<String>['network', 'list', '--json'])).stdout,
          ),
          isEmpty,
        );
      },
    );
  }

  test('occupied network port fails without reassignment', () async {
    await create();
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    try {
      final CapturedResult result = await command(<String>[
        'network',
        'start',
        'test',
      ]);
      expect(result.exitCode, 2, reason: result.stderr);
      expect(result.stderr, contains('Port $port'));
      expect(runtime.events, isEmpty);
    } finally {
      await socket.close();
    }
  });

  test(
    'explicit repair reapplies managed keys while preserving other settings',
    () async {
      await create();
      final File properties = File(
        p.join(instancePath('lobby'), 'server.properties'),
      );
      properties.writeAsStringSync(
        '${properties.readAsStringSync().replaceAll('online-mode=false', 'online-mode=true')}view-distance=6\n',
      );
      final CapturedResult repaired = await command(<String>[
        'network',
        'repair',
        'test',
      ]);
      expect(repaired.exitCode, 0, reason: repaired.stderr);
      expect(properties.readAsStringSync(), contains('online-mode=false'));
      expect(properties.readAsStringSync(), contains('view-distance=6'));
      expect((await command(<String>['network', 'check', 'test'])).exitCode, 0);
    },
  );

  test('instance named none is accepted as a network member', () async {
    Directory(instancePath('extra')).renameSync(instancePath('none'));
    final CapturedResult result = await command(<String>[
      'network',
      'create',
      'named-none',
      '--members',
      'none',
      '--default',
      'none',
      '--jar',
      jar.path,
      '--port',
      '$port',
      '--offline',
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
  });

  test(
    'offline mode rejects shared backends and LAN binding without artifacts',
    () async {
      final File source = File(p.join(instancePath('lobby'), '.server-source'));
      source.writeAsStringSync(
        source.readAsStringSync().replaceAll('isolated=true', 'isolated=false'),
      );
      final List<String> args = <String>[
        'network',
        'create',
        'unsafe',
        '--members',
        'lobby',
        '--default',
        'lobby',
        '--jar',
        jar.path,
        '--offline',
      ];
      final CapturedResult shared = await command(args);
      expect(shared.exitCode, 2);
      expect(shared.stderr, contains('isolated'));
      final CapturedResult lan = await command(<String>[
        ...args,
        '--bind',
        '0.0.0.0',
      ]);
      expect(lan.exitCode, 2);
      expect(Directory(instancePath('unsafe-proxy')).existsSync(), isFalse);
    },
  );

  test(
    'delete needs exact name confirmation and keeps all instances',
    () async {
      await create();
      expect(
        (await command(<String>[
          'network',
          'delete',
          'test',
          '--confirm',
          'wrong',
        ])).exitCode,
        2,
      );
      runtime.running.addAll(<String>['lobby', 'survival', 'test-proxy']);
      final CapturedResult deleted = await command(<String>[
        'network',
        'delete',
        'test',
        '--confirm',
        'test',
      ]);
      expect(deleted.exitCode, 0, reason: deleted.stderr);
      expect(runtime.running, isEmpty);
      expect(
        jsonDecode(
          (await command(<String>['network', 'list', '--json'])).stdout,
        ),
        isEmpty,
      );
      for (final String instance in <String>[
        'lobby',
        'survival',
        'test-proxy',
      ]) {
        expect(Directory(instancePath(instance)).existsSync(), isTrue);
      }
      expect(
        File(
          p.join(instancePath('lobby'), 'server.properties'),
        ).readAsStringSync(),
        contains('online-mode=true'),
      );
    },
  );
}

class _NetworkRuntime implements RecoveryRuntime {
  final Set<String> running = <String>{};
  final List<String> events = <String>[];
  String? failReadiness;
  String? failStop;

  @override
  Future<bool> isRunning(ConsumerProfile profile, String instance) async =>
      running.contains(instance);

  @override
  Future<void> start(ConsumerProfile profile, String instance) async {
    events.add('start:$instance');
    running.add(instance);
  }

  @override
  Future<void> stopGracefully(ConsumerProfile profile, String instance) async {
    events.add('stop:$instance');
    if (instance == failStop) throw StateError('Stop failed: $instance');
    running.remove(instance);
  }

  @override
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async {
    events.add('ready:$instance');
    if (instance == failReadiness) return null;
    return MinecraftPingResult(
      online: 0,
      max: 20,
      versionName: 'fixture',
      motd: '',
      sample: <String>[],
      latency: Duration.zero,
    );
  }
}
