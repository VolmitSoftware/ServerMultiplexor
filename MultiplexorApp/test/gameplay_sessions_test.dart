import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/cli/local_command.dart';
import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/models/gameplay_sessions.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/networks/network_definition.dart';
import 'package:multiplexor/services/networks/network_store.dart';
import 'package:multiplexor/services/recovery_runtime.dart';
import 'package:multiplexor/services/server_ping.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory instance;
  late File profile;
  late NativeCommandService service;
  late _SessionHarness harness;
  late _SessionRuntime runtime;
  late List<Future<CapturedResult>> hosts;
  late List<String> console;

  void createNetwork({bool online = false}) {
    final Directory proxy = Directory(p.join(instance.parent.path, 'proxy'))
      ..createSync();
    File(
      p.join(proxy.path, '.server-source'),
    ).writeAsStringSync('type=velocity\nisolated=true\n');
    final NetworkStore store = NetworkStore(
      stateDirectory: Directory(
        p.join(instance.parent.parent.path, 'state', 'networks'),
      ),
      instancePath: (ConsumerProfile _, String name) =>
          p.join(instance.parent.path, name),
    );
    store.create(
      NetworkDefinition(
        name: 'lab',
        proxy: 'proxy',
        port: 28565,
        onlineMode: online,
        defaultServer: 'survival',
        members: <NetworkMember>[
          const NetworkMember(
            consumer: ConsumerProfile.plugin,
            instance: 'fixture',
            alias: 'survival',
            port: 25565,
          ),
        ],
      ),
    );
  }

  Future<CapturedResult> command(List<String> args) =>
      service.execute(<String>['gameplay', 'sessions', ...args], stream: false);

  Future<String> start({List<String> flags = const <String>[]}) async {
    final CapturedResult result = await command(<String>[
      'start',
      profile.path,
      '--instance',
      'fixture',
      '--json',
      ...flags,
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
    return readMap(result.stdout)['runId']! as String;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor sessions [test] ');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: true,
    );
    final ConsumerService consumers = ConsumerService(context)
      ..ensureConsumerDirs(ConsumerProfile.plugin);
    instance = Directory(
      p.join(consumers.rootFor(ConsumerProfile.plugin), 'instances', 'fixture'),
    )..createSync(recursive: true);
    File(
      p.join(instance.path, '.server-source'),
    ).writeAsStringSync('type=paper\nmc=1.21.11\nisolated=true\n');
    File(p.join(instance.path, 'server.properties')).writeAsStringSync(
      'server-port=25565\nserver-ip=127.0.0.1\nonline-mode=false\n',
    );
    File(p.join(instance.path, 'ops.json')).writeAsStringSync('[]');
    profile = File(p.join(root.path, 'profile [one].json'))
      ..writeAsStringSync('{"schemaVersion":1}');
    runtime = _SessionRuntime();
    harness = _SessionHarness(context: context);
    hosts = <Future<CapturedResult>>[];
    console = <String>[];
    String? pendingConsole;
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      recoveryRuntime: runtime,
      gameplayHarnessFactory: (ManagerContext _) => harness,
      sessionHostLauncher: (List<String> args) async {
        hosts.add(service.execute(args, stream: false));
        return pid;
      },
      processExecutor: (String executable, List<String> args) async {
        if (executable == 'tmux' && args.first == 'send-keys') {
          for (final String value in args) {
            if (value.startsWith('op ') || value.startsWith('deop ')) {
              pendingConsole = value;
            }
          }
          if (args.contains('Enter') && pendingConsole != null) {
            final String value = pendingConsole!;
            console.add(value);
            final String username = value.split(' ').last;
            final File ops = File(p.join(instance.path, 'ops.json'));
            final List<Object?> entries =
                jsonDecode(ops.readAsStringSync()) as List<Object?>;
            entries.removeWhere(
              (Object? entry) =>
                  entry is Map<String, Object?> && entry['name'] == username,
            );
            if (value.startsWith('op ')) {
              entries.add(<String, Object?>{'name': username, 'level': 4});
            }
            ops.writeAsStringSync(jsonEncode(entries));
            pendingConsole = null;
          }
        }
        return ProcessResult(0, 0, '', '');
      },
    );
  });

  tearDown(() async {
    for (final String path in harness.configurations) {
      File(
        p.join(p.dirname(path), 'stop.request'),
      ).writeAsStringSync('test cleanup');
    }
    await Future.wait(hosts).timeout(const Duration(seconds: 5));
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  test('session command parser selects action-specific flags and arity', () {
    expect(
      LocalCommand.parse(<String>['gameplay', 'sessions']).arguments,
      <String>['gameplay', 'sessions', 'list'],
    );
    for (final List<String> invalid in <List<String>>[
      <String>['start'],
      <String>['status'],
      <String>['list', 'extra'],
      <String>['stop', 'session-a', '--prepare'],
      <String>['resume', 'session-a', '--instance', 'fixture'],
      <String>['unknown'],
    ]) {
      expect(
        () => LocalCommand.parse(<String>['gameplay', 'sessions', ...invalid]),
        throwsFormatException,
      );
    }
    expect(
      LocalCommand.parse(<String>[
        'gameplay',
        'sessions',
        'start',
        'profile.json',
        '--network',
        'lab',
        '--start',
      ]).arguments.last,
      '--start',
    );
  });

  test(
    'invalid profile fails before target preparation or process launch',
    () async {
      harness.validationExit = 2;
      final CapturedResult result = await command(<String>[
        'start',
        profile.path,
        '--instance',
        'fixture',
        '--prepare',
        '--start',
      ]);
      expect(result.exitCode, 2);
      expect(runtime.events, isEmpty);
      expect(hosts, isEmpty);
    },
  );

  test('validation reports a structured stdout error without stderr', () async {
    harness.validationExit = 2;
    harness.validationStderr = null;
    harness.validationStdout = jsonEncode(<String, Object?>{
      'status': 'failed',
      'error': 'population.groupSize must be between 1 and 1',
    });
    final CapturedResult result = await command(<String>[
      'validate',
      profile.path,
      '--instance',
      'fixture',
    ]);
    expect(result.exitCode, 2);
    expect(
      result.stderr,
      contains(
        'Session profile validation failed: population.groupSize must be between 1 and 1',
      ),
    );
    expect(hosts, isEmpty);
  });

  test('validation retains stderr alongside the structured error', () async {
    harness.validationExit = 2;
    harness.validationStdout = '{"status":"failed","error":"Invalid bounds"}';
    harness.validationStderr = 'Profile could not be loaded';
    final CapturedResult result = await command(<String>[
      'validate',
      profile.path,
      '--instance',
      'fixture',
    ]);
    expect(result.stderr, contains('Invalid bounds'));
    expect(result.stderr, contains('Profile could not be loaded'));
  });

  test(
    'validation falls back to exit code when diagnostics are unavailable',
    () async {
      harness.validationExit = 7;
      harness.validationStdout = 'incomplete JSON';
      harness.validationStderr = null;
      final CapturedResult result = await command(<String>[
        'validate',
        profile.path,
        '--instance',
        'fixture',
      ]);
      expect(result.exitCode, 7);
      expect(result.stderr, contains('worker exited with code 7'));
    },
  );

  test(
    'validation checks isolated target and mutually exclusive selectors',
    () async {
      for (final List<String> flags in <List<String>>[
        <String>[],
        <String>['--instance', 'fixture', '--network', 'lab'],
      ]) {
        expect(
          (await command(<String>[
            'validate',
            profile.path,
            ...flags,
          ])).exitCode,
          2,
        );
      }
      File(
        p.join(instance.path, '.server-source'),
      ).writeAsStringSync('type=paper\n');
      final CapturedResult shared = await command(<String>[
        'validate',
        profile.path,
        '--instance',
        'fixture',
      ]);
      expect(shared.exitCode, 2);
      expect(shared.stderr, contains('isolated'));
      expect(runtime.events, isEmpty);
    },
  );

  test(
    'network preparation is rejected before changing backend configuration',
    () async {
      final CapturedResult result = await command(<String>[
        'start',
        profile.path,
        '--network',
        'lab',
        '--prepare',
        '--start',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('--prepare is only'));
      expect(hosts, isEmpty);
    },
  );

  test('network members cannot be targeted as standalone sessions', () async {
    File(
      p.join(instance.path, '.server-source'),
    ).writeAsStringSync('type=paper\nisolated=true\nnetwork=lab\n');
    final CapturedResult result = await command(<String>[
      'validate',
      profile.path,
      '--instance',
      'fixture',
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('belongs to network'));
  });

  test(
    'worker operator identity collision is rejected before launch',
    () async {
      File(
        p.join(instance.path, 'ops.json'),
      ).writeAsStringSync('[{"name":"Sess001","level":4}]');
      final CapturedResult result = await command(<String>[
        'start',
        profile.path,
        '--instance',
        'fixture',
        '--start',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('already an operator'));
      expect(hosts, isEmpty);
    },
  );

  test(
    'background run returns while workers remain connected and stops cleanly',
    () async {
      final String run = await start(
        flags: <String>['--start', '--stop-after'],
      );
      expect(
        readMap(
          (await command(<String>['status', run, '--json'])).stdout,
        )['active'],
        true,
      );
      expect(runtime.running, isTrue);
      expect((await command(<String>['list', '--json'])).stdout, contains(run));
      final CapturedResult stopped = await command(<String>[
        'stop',
        run,
        '--json',
      ]);
      expect(stopped.exitCode, 0, reason: stopped.stderr);
      final Map<String, Object?> summary = readMap(stopped.stdout);
      expect(summary['active'], false);
      expect(sessionObject(summary['host'])['cleanupComplete'], true);
      expect(runtime.running, false);
      expect(runtime.events, <String>['start', 'ready', 'stop']);
    },
  );

  test('second session cannot acquire a running target', () async {
    await start(flags: <String>['--start']);
    final CapturedResult second = await command(<String>[
      'start',
      profile.path,
      '--instance',
      'fixture',
      '--start',
    ]);
    expect(second.exitCode, 2);
    expect(second.stderr, contains('already owns'));
    expect(hosts, hasLength(1));
  });

  test(
    'running sessions release the fleet configuration lock after startup',
    () async {
      final String run = await start(
        flags: <String>['--start', '--stop-after'],
      );
      final File probe = File(p.join(root.path, 'exclusive-lock-probe.dart'));
      probe.writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final RandomAccessFile lock = File(args.single).openSync(mode: FileMode.append);
  try { lock.lockSync(FileLock.exclusive); }
  finally { lock.closeSync(); }
}
''');
      final ProcessResult result =
          await Process.run(Platform.resolvedExecutable, <String>[
            probe.path,
            p.join(
              instance.parent.parent.path,
              'state',
              'network-operation.lock',
            ),
          ]).timeout(const Duration(seconds: 10));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final CapturedResult status = await command(<String>[
        'status',
        run,
        '--json',
      ]);
      expect(readMap(status.stdout)['active'], true);
    },
  );

  test('stop-after preserves an instance that was already running', () async {
    runtime.running = true;
    final String run = await start(flags: <String>['--stop-after']);
    final CapturedResult stop = await command(<String>['stop', run]);
    expect(stop.exitCode, 0, reason: stop.stderr);
    expect(runtime.running, true);
    expect(runtime.events, <String>['ready']);
  });

  test(
    'controller is revoked after workers stop and regular users stay non-op',
    () async {
      harness.requiresController = true;
      final String run = await start(
        flags: <String>['--start', '--stop-after'],
      );
      expect(console, hasLength(1));
      expect(console.single, startsWith('op Pc'));
      expect(console.single, isNot(contains('Sess')));
      final CapturedResult stop = await command(<String>['stop', run]);
      expect(stop.exitCode, 0, reason: stop.stderr);
      expect(console.last, 'deop ${console.first.substring(3)}');
      expect(File(p.join(instance.path, 'ops.json')).readAsStringSync(), '[]');
    },
    skip: Platform.isWindows ? 'Uses tmux console transport' : false,
  );

  test(
    'failed readiness rolls back only the runtime this run started',
    () async {
      runtime.ready = false;
      final CapturedResult result = await command(<String>[
        'start',
        profile.path,
        '--instance',
        'fixture',
        '--start',
        '--json',
      ]);
      expect(result.exitCode, 1);
      expect(runtime.running, false);
      expect(runtime.events, <String>['start', 'ready', 'stop']);
      expect(harness.configurations, isEmpty);
    },
  );

  test(
    'resume preserves run identity and skips fixture controller setup',
    () async {
      harness.requiresController = true;
      final String run = await start(
        flags: <String>['--start', '--stop-after'],
      );
      await command(<String>['stop', run]);
      final int initialCommands = console.length;
      final CapturedResult resume = await command(<String>[
        'resume',
        run,
        '--json',
      ]);
      expect(resume.exitCode, 0, reason: resume.stderr);
      expect(readMap(resume.stdout)['runId'], run);
      final Map<String, Object?> configuration = readSessionObject(
        File(harness.configurations.last),
      );
      expect(configuration['resume'], true);
      expect(console, hasLength(initialCommands));
      await command(<String>['stop', run]);
      expect(
        runtime.events.where((String value) => value == 'start'),
        hasLength(2),
      );
    },
    skip: Platform.isWindows ? 'Uses tmux console transport' : false,
  );

  test('resume rejects profile changes and reset world identities', () async {
    final String run = await start(flags: <String>['--start', '--stop-after']);
    await command(<String>['stop', run]);
    final File savedProfile = File(
      p.join(p.dirname(harness.configurations.single), 'profile.json'),
    );
    final String original = savedProfile.readAsStringSync();
    savedProfile.writeAsStringSync('{}');
    final CapturedResult changed = await command(<String>['resume', run]);
    expect(changed.exitCode, 2);
    expect(changed.stderr, contains('profile changed'));
    savedProfile.writeAsStringSync(original);
    File(p.join(instance.path, 'world', '.multiplexor-world-id')).deleteSync();
    final CapturedResult reset = await command(<String>['resume', run]);
    expect(reset.exitCode, 2);
    expect(reset.stderr, contains('World identity changed'));
    expect(runtime.running, false);
    expect(harness.configurations, hasLength(1));
  });

  test(
    'offline network uses proxy endpoint and preserves preexisting backend runtime',
    () async {
      createNetwork();
      runtime.running = true;
      final String before = File(
        p.join(instance.path, 'config', 'paper-global.yml'),
      ).readAsStringSync();
      final CapturedResult started = await command(<String>[
        'start',
        profile.path,
        '--network',
        'lab',
        '--start',
        '--stop-after',
        '--json',
      ]);
      expect(started.exitCode, 0, reason: started.stderr);
      final Map<String, Object?> summary = readMap(started.stdout);
      final Map<String, Object?> target = sessionObject(summary['target']);
      expect(target['port'], 28565);
      expect(target['defaultBackend'], 'survival');
      expect(target['proxy'], 'proxy');
      expect(
        target['observerPath'],
        endsWith('plugins/MultiplexorObserver/metrics.json'),
      );
      expect(
        runtime.runningInstances,
        containsAll(<String>['fixture', 'proxy']),
      );
      final CapturedResult stopped = await command(<String>[
        'stop',
        summary['runId']! as String,
      ]);
      expect(stopped.exitCode, 0, reason: stopped.stderr);
      expect(runtime.runningInstances, <String>{'fixture'});
      expect(
        File(
          p.join(instance.path, 'config', 'paper-global.yml'),
        ).readAsStringSync(),
        before,
      );
    },
  );

  test(
    'online networks and drifted forwarding fail session preflight',
    () async {
      createNetwork(online: true);
      final CapturedResult online = await command(<String>[
        'validate',
        profile.path,
        '--network',
        'lab',
      ]);
      expect(online.exitCode, 2);
      expect(online.stderr, contains('offline loopback'));
      expect(hosts, isEmpty);
    },
  );

  test(
    'forwarding drift is not silently repaired during session validation',
    () async {
      createNetwork();
      final File properties = File(p.join(instance.path, 'server.properties'));
      properties.writeAsStringSync(
        '${properties.readAsStringSync()}\nonline-mode=true\n',
      );
      final CapturedResult result = await command(<String>[
        'validate',
        profile.path,
        '--network',
        'lab',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('configuration is invalid'));
      expect(properties.readAsStringSync(), endsWith('online-mode=true\n'));
      expect(hosts, isEmpty);
    },
  );

  test('run IDs cannot escape the state directory', () async {
    final CapturedResult result = await command(<String>[
      'stop',
      '../../fixture',
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('Invalid session run ID'));
  });
}

Map<String, Object?> readMap(String source) =>
    sessionObject(jsonDecode(source));

final class _SessionHarness extends GameplayTestService {
  _SessionHarness({required super.context});
  int validationExit = 0;
  String? validationStdout;
  String? validationStderr = 'invalid fixture profile';
  bool requiresController = false;
  final List<String> configurations = <String>[];

  @override
  bool get installed => true;

  @override
  Future<int> sessionsValidate({
    required String profilePath,
    String? configurationPath,
    required void Function(String) write,
    required void Function(String) error,
  }) async {
    if (validationExit != 0) {
      if (validationStdout != null) write(validationStdout!);
      if (validationStderr != null) error(validationStderr!);
      return validationExit;
    }
    write(
      jsonEncode(<String, Object?>{
        'status': 'passed',
        'profile': <String, Object?>{'schemaVersion': 1},
        'playerNames': <String>['Sess001', 'Sess002'],
        'maximumPopulation': 2,
        'requiresController': requiresController,
      }),
    );
    return 0;
  }

  @override
  Future<int> sessionsRun({
    required String configurationPath,
    required void Function(String) write,
    required void Function(String) error,
  }) async {
    configurations.add(configurationPath);
    final Directory directory = File(configurationPath).parent;
    writeSessionObject(
      File(p.join(directory.path, 'status.json')),
      <String, Object?>{
        'state': 'running',
        'connectedPopulation': 2,
        'desiredPopulation': 2,
      },
    );
    writeSessionObject(
      File(p.join(directory.path, 'checkpoint.json')),
      <String, Object?>{'schemaVersion': 1},
    );
    final File stop = File(p.join(directory.path, 'stop.request'));
    while (!stop.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    writeSessionObject(
      File(p.join(directory.path, 'report.json')),
      <String, Object?>{'status': 'stopped'},
    );
    return 0;
  }
}

final class _SessionRuntime implements RecoveryRuntime {
  final Set<String> runningInstances = <String>{};
  bool get running => runningInstances.contains('fixture');
  set running(bool value) {
    if (value) {
      runningInstances.add('fixture');
    } else {
      runningInstances.remove('fixture');
    }
  }

  bool ready = true;
  final List<String> events = <String>[];
  @override
  Future<bool> isRunning(ConsumerProfile profile, String instance) async =>
      runningInstances.contains(instance);
  @override
  Future<void> start(ConsumerProfile profile, String instance) async {
    runningInstances.add(instance);
    events.add('start');
  }

  @override
  Future<void> stopGracefully(ConsumerProfile profile, String instance) async {
    runningInstances.remove(instance);
    events.add('stop');
  }

  @override
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async {
    events.add('ready');
    return ready
        ? const MinecraftPingResult(
            online: 0,
            max: 20,
            versionName: 'fixture',
            motd: '',
            sample: <String>[],
            latency: Duration.zero,
          )
        : null;
  }
}
