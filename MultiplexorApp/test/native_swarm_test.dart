import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/models/gameplay_swarm.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/rcon_client.dart';
import 'package:multiplexor/services/recovery_runtime.dart';
import 'package:multiplexor/services/server_ping.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_rcon.dart';

void main() {
  late Directory root;
  late String instancePath;
  late NativeCommandService service;
  late _SwarmRuntime runtime;
  late _SwarmHarness harness;
  late File properties;
  late File source;
  late List<String> consoleCommands;
  late List<Future<void>> pendingOperatorWrites;
  late FakeRcon console;
  late RconConnectionPool tmuxConsole;
  String? failedConsolePrefix;
  String? pendingConsoleCommand;
  Completer<void>? grantGate;
  Completer<void>? revokeGate;
  Completer<void>? grantSent;
  Completer<void>? revokeSent;

  void applyOperatorCommand(String command) {
    final File ops = File(p.join(instancePath, 'ops.json'));
    final List<Object?> entries =
        jsonDecode(ops.readAsStringSync()) as List<Object?>;
    final String name = command.split(' ').last;
    entries.removeWhere(
      (Object? entry) => entry is Map && entry['name'] == name,
    );
    if (command.startsWith('op ')) {
      entries.add(<String, Object>{'name': name, 'level': 4});
    }
    ops.writeAsStringSync(jsonEncode(entries));
  }

  String? handleConsoleCommand(String command) {
    consoleCommands.add(command);
    if (failedConsolePrefix != null &&
        command.startsWith(failedConsolePrefix!)) {
      return null;
    }
    final bool grant = command.startsWith('op ');
    final Completer<void>? sent = grant ? grantSent : revokeSent;
    if (sent != null && !sent.isCompleted) sent.complete();
    final Completer<void>? gate = grant ? grantGate : revokeGate;
    if (gate == null) {
      applyOperatorCommand(command);
    } else {
      pendingOperatorWrites.add(
        gate.future.then((_) => applyOperatorCommand(command)),
      );
    }
    return '';
  }

  Future<CapturedResult> command(
    List<String> options, {
    String mode = 'idle',
  }) => service.execute(<String>[
    'gameplay',
    'swarm',
    mode,
    'fixture',
    ...options,
  ], stream: false);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-swarm-test-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    final ConsumerService consumers = ConsumerService(context)
      ..ensureConsumerDirs(ConsumerProfile.plugin);
    instancePath = p.join(
      consumers.rootFor(ConsumerProfile.plugin),
      'instances',
      'fixture',
    );
    Directory(instancePath).createSync(recursive: true);
    source = File(p.join(instancePath, '.server-source'))
      ..writeAsStringSync('type=paper\nmc=1.21.11\nisolated=true\n');
    properties = File(p.join(instancePath, 'server.properties'))
      ..writeAsStringSync(
        'server-port=25565\nserver-ip=127.0.0.1\nonline-mode=false\n',
      );
    File(p.join(instancePath, 'ops.json')).writeAsStringSync('[]');
    runtime = _SwarmRuntime();
    harness = _SwarmHarness(context: context);
    consoleCommands = <String>[];
    pendingOperatorWrites = <Future<void>>[];
    failedConsolePrefix = null;
    pendingConsoleCommand = null;
    grantGate = null;
    revokeGate = null;
    grantSent = null;
    revokeSent = null;
    console = await FakeRcon.start(
      password: 'swarm-test',
      onCommand: handleConsoleCommand,
    );
    tmuxConsole = RconConnectionPool();
    properties.writeAsStringSync(
      'enable-rcon=true\nrcon.port=${console.port}\nrcon.password=swarm-test\n',
      mode: FileMode.append,
    );
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      recoveryRuntime: runtime,
      gameplayHarnessFactory: (ManagerContext _) => harness,
      processExecutor: (String executable, List<String> arguments) async {
        if (executable == 'tmux' && arguments.first == 'send-keys') {
          for (final String argument in arguments) {
            if (argument.startsWith('op ') || argument.startsWith('deop ')) {
              pendingConsoleCommand = argument;
            }
          }
          if (arguments.contains('Enter') && pendingConsoleCommand != null) {
            final String command = pendingConsoleCommand!;
            pendingConsoleCommand = null;
            // Exercise the RCON fixture on Unix as well as Windows.
            final String? response = await tmuxConsole.command(
              '127.0.0.1',
              console.port,
              'swarm-test',
              command,
            );
            if (response == null) {
              return ProcessResult(0, 1, '', 'injected console failure');
            }
          }
        }
        return ProcessResult(0, 0, '', '');
      },
    );
  });

  tearDown(() async {
    for (final Completer<void>? gate in <Completer<void>?>[
      grantGate,
      revokeGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await Future.wait(pendingOperatorWrites);
    service.disposeRcon();
    tmuxConsole.disposeAll();
    await console.close();
    root.deleteSync(recursive: true);
  });

  for (final List<String> invalid in <List<String>>[
    <String>['--bots', '0'],
    <String>['--bots', '257'],
    <String>['--bots', '4bots'],
    <String>['--duration', '0'],
    <String>['--connect-timeout', 'no'],
    <String>['--action-timeout', '0'],
    <String>['--seed', 'NaN'],
    <String>['--origin', '0,80'],
    <String>['--prefix', 'worker\nop intruder'],
    <String>['--viewer-port', '0'],
    <String>['--scatter', '7'],
    <String>['--scatter', '32', '--build-arena'],
  ]) {
    test(
      'rejects ${invalid.first} ${jsonEncode(invalid.last)} before preparation',
      () async {
        properties.writeAsStringSync(
          'server-port=25565\nserver-ip=0.0.0.0\nonline-mode=true\n',
        );
        final String before = properties.readAsStringSync();
        final CapturedResult result = await command(<String>[
          ...invalid,
          '--prepare',
          '--start',
          '--stop-after',
        ]);
        expect(result.exitCode, 2, reason: result.stderr);
        expect(properties.readAsStringSync(), before);
        expect(runtime.events, isEmpty);
        expect(harness.runs, isEmpty);
        expect(consoleCommands, isEmpty);
      },
    );
  }

  test(
    'rejects unsafe targets before starting or invoking the harness',
    () async {
      for (final (String, String) metadata in <(String, String)>[
        ('type=paper\nisolated=false\n', 'isolated'),
        ('type=velocity\nisolated=true\n', 'Velocity'),
        ('type=paper\nisolated=true\nnetwork=attached\n', 'network'),
      ]) {
        source.writeAsStringSync(metadata.$1);
        final CapturedResult result = await command(<String>['--start']);
        expect(result.exitCode, 2, reason: '${metadata.$2}: ${result.stderr}');
        expect(runtime.events, isEmpty);
        expect(harness.runs, isEmpty);
      }
    },
  );

  test('requires offline loopback binding before starting', () async {
    for (final String unsafe in <String>[
      'server-ip=127.0.0.1\nonline-mode=true\n',
      'server-ip=0.0.0.0\nonline-mode=false\n',
      'server-ip=192.0.2.1\nonline-mode=false\n',
    ]) {
      properties.writeAsStringSync('server-port=25565\n$unsafe');
      final CapturedResult result = await command(<String>['--start']);
      expect(result.exitCode, 2, reason: result.stderr);
      expect(runtime.events, isEmpty);
      expect(harness.runs, isEmpty);
    }
  });

  test('requires start permission for a stopped instance', () async {
    final CapturedResult result = await command(<String>[]);
    expect(result.exitCode, 2);
    expect(runtime.events, isEmpty);
    expect(harness.runs, isEmpty);
  });

  test(
    'invalid custom plans fail before preparation or runtime changes',
    () async {
      final File plan = File(p.join(root.path, 'invalid plan.json'))
        ..writeAsStringSync('{}');
      harness.validationExitCode = 2;
      properties.writeAsStringSync(
        'server-port=25565\nserver-ip=0.0.0.0\nonline-mode=true\n',
      );
      final String before = properties.readAsStringSync();
      final CapturedResult result = await command(<String>[
        '--prepare',
        '--start',
        '--stop-after',
        '--bots',
        '7',
        '--origin',
        '3,82,-5',
      ], mode: plan.path);
      expect(result.exitCode, 2);
      expect(harness.validatedPlans, <String>[plan.path]);
      expect(harness.validationSettings, <(int, String)>[(7, '3,82,-5')]);
      expect(properties.readAsStringSync(), before);
      expect(runtime.events, isEmpty);
      expect(harness.runs, isEmpty);
      expect(consoleCommands, isEmpty);
    },
  );

  test('ordinary workers do not receive operator commands', () async {
    runtime.running = true;
    final CapturedResult result = await command(<String>[
      '--bots',
      '2',
      '--duration',
      '1',
      '--no-viewer',
      '--stop-after',
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(harness.runs, hasLength(1));
    expect(harness.runs.single.instance, 'fixture');
    expect(harness.runs.single.host, '127.0.0.1');
    expect(harness.runs.single.controller, isNull);
    expect(consoleCommands, isEmpty);
    expect(runtime.running, isTrue);
    expect(runtime.events, <String>['ready']);
  });

  test('invalid stress workloads fail before server preparation', () async {
    final File workload = File(p.join(root.path, 'invalid workload.json'))
      ..writeAsStringSync('{}');
    harness.validationExitCode = 2;
    properties.writeAsStringSync(
      'server-port=25565\nserver-ip=0.0.0.0\nonline-mode=true\n',
    );
    final String before = properties.readAsStringSync();
    final CapturedResult result = await command(<String>[
      '--workload',
      workload.path,
      '--bots',
      '256',
      '--duration',
      '604800',
      '--bounds',
      '-32,80,-32:32,96,32',
      '--goals',
      'mine=1000',
      '--completion',
      'goals',
      '--prepare',
      '--start',
      '--stop-after',
    ], mode: 'stress');
    expect(result.exitCode, 2);
    expect(harness.validatedWorkloads, hasLength(1));
    expect(harness.validatedWorkloads.single.workload, workload.absolute.path);
    expect(harness.validatedWorkloads.single.bots, 256);
    expect(harness.validatedWorkloads.single.durationSeconds, 604800);
    expect(properties.readAsStringSync(), before);
    expect(runtime.events, isEmpty);
    expect(harness.runs, isEmpty);
    expect(consoleCommands, isEmpty);
  });

  test('default stress preflight reserves and revokes a controller', () async {
    runtime.running = true;
    final CapturedResult result = await command(<String>[
      '--duration',
      '7200',
      '--no-viewer',
    ], mode: 'stress');
    expect(result.exitCode, 0, reason: result.stderr);
    expect(harness.validatedWorkloads.single.workload, isNull);
    expect(harness.runs.single.controller, isNotNull);
    final String controller = harness.runs.single.controller!;
    expect(consoleCommands, <String>['op $controller', 'deop $controller']);
    expect(
      jsonDecode(File(p.join(instancePath, 'ops.json')).readAsStringSync()),
      isEmpty,
    );
    expect(runtime.running, isTrue);
  });

  test(
    'capacity includes the controller before granting operator status',
    () async {
      runtime.maximumPlayers = 5;
      runtime.onlinePlayers = 1;
      final CapturedResult result = await command(<String>[
        '--bots',
        '4',
        '--build-arena',
        '--start',
        '--stop-after',
        '--no-viewer',
      ], mode: 'redstone');
      expect(result.exitCode, 2, reason: result.stderr);
      expect(result.stderr, contains('5 free player slots'));
      expect(harness.runs, isEmpty);
      expect(consoleCommands, isEmpty);
      expect(runtime.events, <String>['start', 'ready', 'stop']);
      expect(runtime.running, isFalse);
    },
  );

  test(
    'ordinary workers can use the exact remaining player capacity',
    () async {
      runtime.running = true;
      runtime.maximumPlayers = 5;
      runtime.onlinePlayers = 1;
      final CapturedResult result = await command(<String>[
        '--bots',
        '4',
        '--no-viewer',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(harness.runs, hasLength(1));
      expect(consoleCommands, isEmpty);
    },
  );

  test(
    'waits for operator changes before bots start or ownership is released',
    () async {
      runtime.running = true;
      grantGate = Completer<void>();
      revokeGate = Completer<void>();
      grantSent = Completer<void>();
      revokeSent = Completer<void>();
      bool completed = false;
      final Future<CapturedResult> running = command(<String>[
        '--build-arena',
        '--no-viewer',
      ], mode: 'redstone').whenComplete(() => completed = true);
      try {
        await grantSent!.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(harness.runs, isEmpty);
        expect(completed, isFalse);
        grantGate!.complete();
        await revokeSent!.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(harness.runs, hasLength(1));
        expect(completed, isFalse);
        final CapturedResult conflict = await command(<String>['--no-viewer']);
        expect(conflict.exitCode, 2);
        expect(conflict.stderr, contains('already running'));
        revokeGate!.complete();
        expect((await running).exitCode, 0);
        expect(
          jsonDecode(File(p.join(instancePath, 'ops.json')).readAsStringSync()),
          isEmpty,
        );
        final CapturedResult retry = await command(<String>['--no-viewer']);
        expect(retry.exitCode, 0, reason: retry.stderr);
      } finally {
        if (!grantGate!.isCompleted) grantGate!.complete();
        if (!revokeGate!.isCompleted) revokeGate!.complete();
        await running.timeout(const Duration(seconds: 3));
      }
    },
  );

  test('prepares then starts and stops only the runtime it owns', () async {
    properties.writeAsStringSync(
      'server-port=25565\nserver-ip=0.0.0.0\nonline-mode=true\n',
    );
    runtime.onStart = () {
      expect(properties.readAsStringSync(), contains('online-mode=false'));
      expect(properties.readAsStringSync(), contains('server-ip=127.0.0.1'));
    };
    final CapturedResult result = await command(<String>[
      '--prepare',
      '--start',
      '--stop-after',
      '--no-viewer',
    ]);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(runtime.events, <String>['start', 'ready', 'stop']);
    expect(runtime.running, isFalse);
    expect(harness.runs, hasLength(1));
  });

  test(
    'failed readiness stops an owned runtime without spawning bots',
    () async {
      runtime.ready = false;
      final CapturedResult result = await command(<String>[
        '--start',
        '--stop-after',
        '--no-viewer',
      ]);
      expect(result.exitCode, isNot(0));
      expect(runtime.events, <String>['start', 'ready', 'stop']);
      expect(runtime.running, isFalse);
      expect(harness.runs, isEmpty);
      expect(consoleCommands, isEmpty);
    },
  );

  test(
    'harness failure preserves its exit status and stops owned runtime',
    () async {
      harness.exitCode = 7;
      final CapturedResult result = await command(<String>[
        '--start',
        '--stop-after',
        '--no-viewer',
      ]);
      expect(result.exitCode, 7, reason: result.stderr);
      expect(runtime.events, <String>['start', 'ready', 'stop']);
      expect(runtime.running, isFalse);
    },
  );

  test('controller is revoked after a throwing arena run', () async {
    harness.onRun = (GameplaySwarmRun _) async {
      throw StateError('injected swarm failure');
    };
    final CapturedResult result = await command(<String>[
      '--build-arena',
      '--start',
      '--stop-after',
      '--no-viewer',
    ], mode: 'redstone');
    expect(result.exitCode, isNot(0));
    final String controller = harness.runs.single.controller!;
    expect(controller, matches(RegExp(r'^Sc[0-9a-f]{12}$')));
    expect(consoleCommands, <String>['op $controller', 'deop $controller']);
    expect(runtime.events, <String>['start', 'ready', 'stop']);
    expect(runtime.running, isFalse);
  });

  test('rejects worker names that already have operator privileges', () async {
    File(p.join(instancePath, 'ops.json')).writeAsStringSync(
      jsonEncode(<Object>[
        <String, Object>{'name': 'Probe01', 'level': 4},
      ]),
    );
    final CapturedResult result = await command(<String>[
      '--prefix',
      'Probe',
      '--bots',
      '2',
      '--start',
      '--no-viewer',
    ]);
    expect(result.exitCode, 2, reason: result.stderr);
    expect(runtime.events, isEmpty);
    expect(harness.runs, isEmpty);
    expect(consoleCommands, isEmpty);
  });

  test('deop failure is reported and still stops the owned runtime', () async {
    failedConsolePrefix = 'deop ';
    final CapturedResult result = await command(<String>[
      '--build-arena',
      '--start',
      '--stop-after',
      '--no-viewer',
    ], mode: 'redstone');
    expect(result.exitCode, isNot(0));
    expect(result.stderr.toLowerCase(), contains('revoke'));
    expect(
      consoleCommands.where((String value) => value.startsWith('deop ')),
      hasLength(1),
    );
    expect(runtime.running, isFalse);
    expect(runtime.events.last, 'stop');
  });

  test(
    'failed operator grant still attempts revocation exactly once',
    () async {
      failedConsolePrefix = 'op ';
      final CapturedResult result = await command(<String>[
        '--build-arena',
        '--start',
        '--stop-after',
        '--no-viewer',
      ], mode: 'redstone');
      expect(result.exitCode, isNot(0));
      expect(harness.runs, isEmpty);
      expect(consoleCommands, hasLength(2));
      expect(consoleCommands.first, startsWith('op Sc'));
      expect(consoleCommands.last, 'de${consoleCommands.first}');
      expect(runtime.running, isFalse);
      expect(runtime.events.last, 'stop');
    },
  );

  test(
    'server exit removes only this controller from the local ops file',
    () async {
      runtime.running = true;
      final Map<String, Object> existing = <String, Object>{
        'name': 'Owner',
        'uuid': 'preserved',
        'level': 4,
      };
      harness.onRun = (GameplaySwarmRun run) async {
        File(p.join(instancePath, 'ops.json')).writeAsStringSync(
          jsonEncode(<Object>[
            existing,
            <String, Object>{'name': run.controller!, 'level': 4},
          ]),
        );
        runtime.running = false;
        return 1;
      };
      final CapturedResult result = await command(<String>[
        '--build-arena',
        '--no-viewer',
      ], mode: 'redstone');
      expect(result.exitCode, 1);
      expect(
        jsonDecode(File(p.join(instancePath, 'ops.json')).readAsStringSync()),
        <Object>[existing],
      );
      expect(consoleCommands, <String>['op ${harness.runs.single.controller}']);
      expect(runtime.events, <String>['ready']);
    },
  );

  test(
    'rejects simultaneous ownership and releases it after a failed run',
    () async {
      runtime.running = true;
      final Completer<void> entered = Completer<void>();
      final Completer<int> finish = Completer<int>();
      harness.onRun = (GameplaySwarmRun _) {
        entered.complete();
        return finish.future;
      };
      final Future<CapturedResult> first = command(<String>['--no-viewer']);
      await entered.future.timeout(const Duration(seconds: 3));
      try {
        final CapturedResult second = await command(<String>[
          '--no-viewer',
        ]).timeout(const Duration(seconds: 3));
        expect(second.exitCode, isNot(0));
        expect(harness.runs, hasLength(1));
      } finally {
        finish.complete(5);
      }
      expect((await first).exitCode, 5);
      harness.onRun = null;
      final CapturedResult retry = await command(<String>['--no-viewer']);
      expect(retry.exitCode, 0, reason: retry.stderr);
      expect(harness.runs, hasLength(2));
      expect(runtime.running, isTrue);
    },
  );
}

class _SwarmHarness extends GameplayTestService {
  _SwarmHarness({required super.context});

  final List<GameplaySwarmRun> runs = <GameplaySwarmRun>[];
  final List<String> validatedPlans = <String>[];
  final List<GameplaySwarmSettings> validatedWorkloads =
      <GameplaySwarmSettings>[];
  final List<(int, String)> validationSettings = <(int, String)>[];
  Future<int> Function(GameplaySwarmRun)? onRun;
  int exitCode = 0;
  int validationExitCode = 0;

  @override
  bool get installed => true;

  @override
  Future<int> swarmValidate(
    String path, {
    required int bots,
    String origin = '0,80,0',
    required void Function(String line) write,
    required void Function(String line) error,
  }) async {
    validatedPlans.add(path);
    validationSettings.add((bots, origin));
    return validationExitCode;
  }

  @override
  Future<int> swarmWorkloadValidate({
    required GameplaySwarmSettings settings,
    required void Function(String line) write,
    required void Function(String line) error,
  }) async {
    validatedWorkloads.add(settings);
    return validationExitCode;
  }

  @override
  Future<int> swarm({
    required GameplaySwarmRun run,
    required void Function(String line) write,
    required void Function(String line) error,
  }) async {
    runs.add(run);
    return onRun == null ? exitCode : await onRun!(run);
  }
}

class _SwarmRuntime implements RecoveryRuntime {
  bool running = false;
  bool ready = true;
  int maximumPlayers = 20;
  int onlinePlayers = 0;
  void Function()? onStart;
  final List<String> events = <String>[];

  @override
  Future<bool> isRunning(ConsumerProfile profile, String instance) async =>
      running;

  @override
  Future<void> start(ConsumerProfile profile, String instance) async {
    onStart?.call();
    events.add('start');
    running = true;
  }

  @override
  Future<void> stopGracefully(ConsumerProfile profile, String instance) async {
    events.add('stop');
    running = false;
  }

  @override
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async {
    events.add('ready');
    return ready
        ? MinecraftPingResult(
            online: onlinePlayers,
            max: maximumPlayers,
            versionName: 'fixture',
            motd: '',
            sample: <String>[],
            latency: Duration.zero,
          )
        : null;
  }
}
