import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory proxy;
  late NativeCommandService service;
  late ConsumerService consumers;
  late int java;
  late List<List<String>> tmuxCalls;

  Future<CapturedResult> run(List<String> args) =>
      service.execute(args, stream: false);
  void metadata([String version = '4.0.0']) {
    File(p.join(proxy.path, '.server-source')).writeAsStringSync(
      'type=velocity\nlaunch=jar\nvelocity_version=$version\n',
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-velocity-runtime-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    consumers = ConsumerService(context);
    java = 25;
    tmuxCalls = <List<String>>[];
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      javaInspector: (String _) async => java,
      processExecutor: (String executable, List<String> args) async {
        if (executable == 'tmux') tmuxCalls.add(args);
        return ProcessResult(
          0,
          executable == 'tmux' &&
                  (args.first == '-V' || args.first == 'new-session')
              ? 0
              : 1,
          '',
          '',
        );
      },
    );
    proxy = Directory(
      p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', 'proxy'),
    )..createSync(recursive: true);
    metadata();
    File(
      p.join(proxy.path, 'velocity.toml'),
    ).writeAsStringSync('bind = "127.0.0.1:28001"\n');
  });
  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  test('proxy port reads and updates TOML without game files', () async {
    expect(
      (await run(<String>['instance', 'port', 'proxy'])).stdout.trim(),
      '28001',
    );
    expect(
      (await run(<String>['instance', 'port', 'proxy', '28002'])).exitCode,
      0,
    );
    expect(
      File(p.join(proxy.path, 'velocity.toml')).readAsStringSync(),
      'bind = "127.0.0.1:28002"\n',
    );
    expect(File(p.join(proxy.path, 'server.properties')).existsSync(), isFalse);
  });

  test('invalid proxy bind never falls back to a Minecraft port', () async {
    File(
      p.join(proxy.path, 'velocity.toml'),
    ).writeAsStringSync('bind = "oops"\n');
    final CapturedResult result = await run(<String>[
      'instance',
      'port',
      'proxy',
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('Velocity bind'));
    expect(File(p.join(proxy.path, 'server.properties')).existsSync(), isFalse);
  });

  test(
    'proxy defaults override game heap and flags while Java inherits',
    () async {
      expect(
        (await run(<String>['runtime', 'settings', 'set-heap', '8G'])).exitCode,
        0,
      );
      final CapturedResult settings = await run(<String>[
        'runtime',
        'settings',
        'show',
        '--instance',
        'proxy',
      ]);
      expect(settings.stdout, contains('heap size:      1G'));
      expect(settings.stdout, contains('flags profile:  vanilla'));
      expect(settings.stdout, contains('console log:    default'));
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'set-heap',
          '512M',
          '--instance',
          'proxy',
        ])).exitCode,
        0,
      );
      expect(
        (await run(<String>[
          'runtime',
          'settings',
          'show',
          '--instance',
          'proxy',
        ])).stdout,
        contains('heap size:      512M'),
      );
    },
  );

  test('Velocity versions enforce their own Java minimum', () async {
    java = 21;
    expect(
      (await run(<String>[
        'runtime',
        'settings',
        'check',
        '--instance',
        'proxy',
      ])).stderr,
      contains('requires Java 25'),
    );
    metadata('3.4.0');
    final CapturedResult checked = await run(<String>[
      'runtime',
      'settings',
      'check',
      '--instance',
      'proxy',
    ]);
    expect(checked.exitCode, 0);
    expect(checked.stdout, isNot(contains('Minecraft version is unknown')));
    metadata('');
    expect(
      (await run(<String>[
        'runtime',
        'settings',
        'check',
        '--instance',
        'proxy',
      ])).exitCode,
      2,
    );
  });

  test(
    'proxy clone reset and gameplay reject without creating game state',
    () async {
      for (final List<String> command in <List<String>>[
        <String>['instance', 'clone', 'proxy', 'copy'],
        <String>['instance', 'reset', 'proxy'],
        <String>['gameplay', 'prepare', 'proxy'],
      ]) {
        final CapturedResult result = await run(command);
        expect(result.exitCode, 2, reason: result.stderr);
        expect(result.stderr, contains('Velocity proxy'));
      }
      expect(
        File(p.join(proxy.path, 'server.properties')).existsSync(),
        isFalse,
      );
      expect(File(p.join(proxy.path, 'eula.txt')).existsSync(), isFalse);
    },
  );

  test('Bukkit synchronization never copies jars to a proxy', () async {
    final Directory source = Directory(
      p.join(consumers.rootFor(ConsumerProfile.plugin), 'dropins', 'plugins'),
    )..createSync(recursive: true);
    File(p.join(source.path, 'bukkit.jar')).writeAsBytesSync(<int>[1, 2, 3]);
    expect((await run(<String>['plugins', 'sync', 'proxy'])).exitCode, 0);
    expect(
      File(p.join(proxy.path, 'plugins', 'bukkit.jar')).existsSync(),
      isFalse,
    );
  });

  test('Velocity ready and graceful shutdown log markers', () {
    expect(
      classifyRuntimeLogTail('[main/INFO]: Done (0.72s)!'),
      RuntimeState.running,
    );
    expect(
      classifyRuntimeLogTail(
        '[main/INFO]: Done (0.72s)!\n[Shutdown/INFO]: Shutting down the proxy...',
      ),
      RuntimeState.stopping,
    );
  });

  Future<int> createNetwork({bool offline = true}) async {
    final File jar = File(p.join(root.path, 'fixture.jar'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final CapturedResult backend = await run(<String>[
      'server',
      'create',
      'backend',
      '--jar',
      jar.path,
      '--type',
      'paper',
      '--mc',
      '1.21.11',
      '--isolated',
    ]);
    expect(backend.exitCode, 0, reason: backend.stderr);
    final ServerSocket reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = reservation.port;
    await reservation.close();
    final CapturedResult created = await run(<String>[
      'network',
      'create',
      'dev',
      '--members',
      'backend',
      '--default',
      'backend',
      '--jar',
      jar.path,
      '--proxy-version',
      '3.4.0',
      if (offline) '--offline',
      '--port',
      '$port',
    ]);
    expect(created.exitCode, 0, reason: created.stderr);
    return port;
  }

  test(
    'network proxy creation has only proxy launch and configuration state',
    () async {
      await createNetwork();
      final Directory created = Directory(
        p.join(proxy.parent.path, 'dev-proxy'),
      );
      expect(File(p.join(created.path, 'velocity.toml')).existsSync(), isTrue);
      expect(
        File(p.join(created.path, 'forwarding.secret')).existsSync(),
        isTrue,
      );
      for (final String name in <String>[
        'server.properties',
        'eula.txt',
        'ops.json',
        'spigot.yml',
        'multiplexor-restart.sh',
        'multiplexor-restart.cmd',
        'plugins/iris',
      ]) {
        expect(
          FileSystemEntity.typeSync(p.join(created.path, name)),
          FileSystemEntityType.notFound,
          reason: name,
        );
      }
    },
  );

  test(
    'linked proxy and backend ports reject mutation and collisions never shift',
    () async {
      final int port = await createNetwork();
      for (final String name in <String>['backend', 'dev-proxy']) {
        final CapturedResult changed = await run(<String>[
          'instance',
          'port',
          name,
          '28003',
        ]);
        expect(changed.exitCode, 2);
        expect(changed.stderr, contains('belongs to network'));
      }
      final ServerSocket occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      addTearDown(occupied.close);
      final CapturedResult started = await run(<String>[
        'runtime',
        'start',
        'dev-proxy',
      ]);
      expect(started.exitCode, 2, reason: started.stderr);
      expect(started.stderr, contains('Network ports are fixed'));
      expect(
        (await run(<String>['instance', 'port', 'dev-proxy'])).stdout.trim(),
        '$port',
      );
    },
  );

  test(
    'tmux proxy launch excludes game flags and setup files',
    () async {
      await createNetwork();
      final CapturedResult started = await run(<String>[
        'runtime',
        'start',
        'dev-proxy',
      ]);
      expect(started.exitCode, 1);
      final List<List<String>> launches = tmuxCalls
          .where((List<String> args) => args.first == 'new-session')
          .toList(growable: false);
      expect(launches, hasLength(1));
      final String command = launches.single.last;
      expect(command, contains('-Xmx1G'));
      expect(command, isNot(contains('--nogui')));
      expect(command, isNot(contains('jdk.incubator.vector')));
      expect(command, isNot(contains('log4j.configurationFile')));
      final Directory created = Directory(
        p.join(proxy.parent.path, 'dev-proxy'),
      );
      expect(
        File(p.join(created.path, 'server.properties')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(created.path, 'multiplexor-restart.sh')).existsSync(),
        isFalse,
      );
    },
    skip: Platform.isWindows ? 'tmux runtime applies to macOS/Linux' : false,
  );

  test(
    'standalone startup preserves stopped network port reservations',
    () async {
      final int port = await createNetwork();
      expect(
        (await run(<String>[
          'instance',
          'create',
          'standalone',
          '--isolated',
        ])).exitCode,
        0,
      );
      expect(
        (await run(<String>[
          'instance',
          'port',
          'standalone',
          '$port',
        ])).exitCode,
        0,
      );
      final CapturedResult started = await run(<String>[
        'runtime',
        'start',
        'standalone',
      ]);
      expect(started.stderr, contains('No launch target found'));
      expect(
        (await run(<String>['instance', 'port', 'standalone'])).stdout.trim(),
        isNot('$port'),
      );
      expect(
        (await run(<String>['instance', 'port', 'dev-proxy'])).stdout.trim(),
        '$port',
      );
    },
  );

  test(
    'tmux proxy stop sends end and waits for the session to exit',
    () async {
      bool running = true;
      final List<String> sent = <String>[];
      final ManagerContext context = ManagerContext(
        rootDir: root.path,
        verbose: false,
      );
      final NativeCommandService stoppingService = NativeCommandService(
        context: context,
        consumerService: consumers,
        processExecutor: (String executable, List<String> args) async {
          if (executable != 'tmux') return ProcessResult(0, 1, '', '');
          if (args.first == 'has-session') {
            return ProcessResult(0, running ? 0 : 1, '', '');
          }
          if (args.first == 'send-keys') {
            if (args.contains('-l')) {
              sent.add(args.last);
              expect(running, isTrue);
            } else {
              expect(args.last, 'Enter');
              expect(sent, <String>['end']);
              running = false;
            }
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', '');
        },
      );
      addTearDown(stoppingService.disposeRcon);
      final CapturedResult stopped = await stoppingService.execute(<String>[
        'runtime',
        'stop',
        'proxy',
      ], stream: false);
      expect(stopped.exitCode, 0, reason: stopped.stderr);
      expect(stopped.stdout, contains('(graceful)'));
      expect(sent, <String>['end']);
    },
    skip: Platform.isWindows ? 'tmux runtime applies to macOS/Linux' : false,
  );

  test(
    'proxy sync uses Velocity source and startup preserves local changes',
    () async {
      await createNetwork(offline: false);
      final Directory source = Directory(
        p.join(
          consumers.rootFor(ConsumerProfile.plugin),
          'dropins',
          'velocity',
        ),
      );
      final File shared = File(p.join(source.path, 'proxy.jar'))
        ..writeAsStringSync('version one');
      expect(
        (await run(<String>['network', 'plugins-sync', 'dev'])).exitCode,
        0,
      );
      final File installed = File(
        p.join(proxy.parent.path, 'dev-proxy', 'plugins', 'proxy.jar'),
      );
      expect(installed.readAsStringSync(), 'version one');
      installed.writeAsStringSync('local edit');
      shared.writeAsStringSync('version two');
      final CapturedResult started = await run(<String>[
        'runtime',
        'start',
        'dev-proxy',
      ]);
      expect(started.exitCode, 1);
      expect(installed.readAsStringSync(), 'local edit');
      expect(started.stderr, contains('preserved locally modified'));
      expect(
        (await run(<String>['network', 'plugins-sync', 'dev'])).exitCode,
        0,
      );
      expect(installed.readAsStringSync(), 'version two');
    },
  );

  test('delete-all removes networks and standalone instances', () async {
    await createNetwork();
    expect(
      (await run(<String>[
        'instance',
        'create',
        'aaa-kept',
        '--isolated',
      ])).exitCode,
      0,
    );
    for (final List<String> command in <List<String>>[
      <String>['instance', 'delete-all', '--force'],
      <String>['instance', 'delete-all', '--everywhere', '--force'],
    ]) {
      final CapturedResult deleted = await run(command);
      expect(deleted.exitCode, 0, reason: deleted.stderr);
      expect((await run(<String>['network', 'list'])).stdout.trim(), '(none)');
      expect(
        Directory(p.join(proxy.parent.path, 'aaa-kept')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(proxy.parent.path, 'backend')).existsSync(),
        isFalse,
      );
    }
  });
}
