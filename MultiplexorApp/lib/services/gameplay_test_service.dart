import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/gameplay_swarm.dart';
import 'manager_context.dart';

class GameplayTestService {
  GameplayTestService({required this.context});

  final ManagerContext context;

  String get harnessDirectory =>
      p.join(context.rootDir, 'MultiplexorApp', 'tool', 'mineflayer');

  bool get installed =>
      <String>[
        'mineflayer',
        'mineflayer-pathfinder',
        'prismarine-viewer',
      ].every(
        (String package) => File(
          p.join(harnessDirectory, 'node_modules', package, 'package.json'),
        ).existsSync(),
      );

  Future<int> setup({
    required void Function(String line) write,
    required void Function(String line) error,
  }) {
    if (!File(p.join(harnessDirectory, 'package.json')).existsSync()) {
      error('[ERROR] Mineflayer harness is missing: $harnessDirectory');
      return Future<int>.value(2);
    }
    if (!File(p.join(harnessDirectory, 'package-lock.json')).existsSync()) {
      error('[ERROR] Mineflayer package lock is missing: $harnessDirectory');
      return Future<int>.value(2);
    }
    return _run(
      'npm',
      const <String>['ci', '--no-audit', '--no-fund'],
      // npm on Windows is npm.cmd, a batch shim CreateProcess refuses to
      // launch; only the shell can start it. The harness runs (`node
      // src/cli.mjs`) go to a real executable and stay off the shell, where
      // scenario arguments cannot be re-parsed on the way through.
      shell: Platform.isWindows,
      write: write,
      error: error,
    );
  }

  Future<int> doctor({
    required bool json,
    required void Function(String line) write,
    required void Function(String line) error,
  }) {
    return _runHarness(
      <String>['doctor', if (json) '--json'],
      write: write,
      error: error,
    );
  }

  Future<int> list({
    required bool json,
    required void Function(String line) write,
    required void Function(String line) error,
  }) {
    return _runHarness(
      <String>['list', if (json) '--json'],
      write: write,
      error: error,
    );
  }

  Future<int> run({
    required GameplayTestRun run,
    required void Function(String line) write,
    required void Function(String line) error,
  }) {
    final arguments = <String>[
      'run',
      '--scenario',
      run.scenario,
      '--host',
      run.host,
      '--port',
      '${run.port}',
      '--instance',
      run.instance,
      '--username',
      run.username,
      '--auth',
      run.auth,
      '--timeout',
      '${run.timeoutSeconds}',
      '--connect-timeout',
      '${run.connectTimeoutSeconds}',
      '--assertion-timeout',
      '${run.assertionTimeoutSeconds}',
      '--artifacts',
      run.artifactsDirectory,
      '--log-path',
      run.logPath,
      if (run.version != null) ...<String>['--version', run.version!],
      if (run.profilesFolder != null) ...<String>[
        '--profiles-folder',
        run.profilesFolder!,
      ],
      if (run.command != null) ...<String>['--command', run.command!],
      if (run.expected != null) ...<String>['--expect', run.expected!],
      if (run.effect != null) ...<String>['--effect', run.effect!],
      if (!run.viewerEnabled) '--no-viewer',
      if (run.viewerPort != null) ...<String>[
        '--viewer-port',
        '${run.viewerPort}',
      ],
      if (run.json) '--json',
    ];
    return _runHarness(arguments, write: write, error: error);
  }

  Future<int> swarmProfiles({
    required bool json,
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    <String>['swarm-profiles', if (json) '--json'],
    write: write,
    error: error,
  );

  Future<int> sessionsValidate({
    required String profilePath,
    String? configurationPath,
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    <String>[
      'sessions-validate',
      '--profile',
      profilePath,
      if (configurationPath != null) ...<String>[
        '--configuration',
        configurationPath,
      ],
      '--json',
    ],
    write: write,
    error: error,
  );

  Future<int> sessionsRun({
    required String configurationPath,
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    <String>['sessions-run', '--configuration', configurationPath, '--json'],
    write: write,
    error: error,
    forwardSignals: true,
  );

  Future<int> swarmValidate(
    String path, {
    required int bots,
    String origin = '0,80,0',
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    <String>[
      'swarm-validate',
      path,
      '--bots',
      '$bots',
      '--origin',
      origin,
      '--json',
    ],
    write: write,
    error: error,
  );

  Future<int> swarm({
    required GameplaySwarmRun run,
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    run.arguments,
    write: write,
    error: error,
    forwardSignals: true,
  );

  Future<int> swarmWorkloadValidate({
    required GameplaySwarmSettings settings,
    required void Function(String line) write,
    required void Function(String line) error,
  }) => _runHarness(
    <String>[
      'swarm-workload-validate',
      if (settings.workload != null) settings.workload!,
      '--bots',
      '${settings.bots}',
      '--duration',
      '${settings.durationSeconds}',
      '--origin',
      settings.origin,
      '--radius',
      '${settings.radius}',
      if (settings.buildArena) '--build-arena',
      if (settings.bounds != null) ...<String>[
        '--bounds',
        settings.bounds!.argument,
      ],
      if (settings.goalsArgument != null) ...<String>[
        '--goals',
        settings.goalsArgument!,
      ],
      if (settings.completion != null) ...<String>[
        '--completion',
        settings.completion!,
      ],
      '--json',
    ],
    write: write,
    error: error,
  );

  Future<int> _runHarness(
    List<String> arguments, {
    required void Function(String line) write,
    required void Function(String line) error,
    bool forwardSignals = false,
  }) {
    final cli = p.join(harnessDirectory, 'src', 'cli.mjs');
    if (!File(cli).existsSync()) {
      error('[ERROR] Mineflayer harness is missing: $cli');
      return Future<int>.value(2);
    }
    return _run(
      'node',
      <String>[cli, ...arguments],
      write: write,
      error: error,
      forwardSignals: forwardSignals,
    );
  }

  Future<int> _run(
    String executable,
    List<String> arguments, {
    required void Function(String line) write,
    required void Function(String line) error,
    bool shell = false,
    bool forwardSignals = false,
  }) async {
    Process? child;
    ProcessSignal? pendingSignal;
    final List<StreamSubscription<ProcessSignal>> signals =
        <StreamSubscription<ProcessSignal>>[];
    if (forwardSignals) {
      for (final ProcessSignal signal in <ProcessSignal>[
        ProcessSignal.sigint,
        if (!Platform.isWindows) ProcessSignal.sigterm,
      ]) {
        signals.add(
          signal.watch().listen((ProcessSignal signal) {
            pendingSignal = signal;
            child?.kill(signal);
          }),
        );
      }
    }
    try {
      final Process process;
      try {
        process = await Process.start(
          executable,
          arguments,
          workingDirectory: harnessDirectory,
          runInShell: shell,
        );
      } on ProcessException catch (exception) {
        error('[ERROR] ${exception.message}');
        return exception.errorCode;
      }
      child = process;
      if (pendingSignal != null) process.kill(pendingSignal!);
      final Future<void> stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(write);
      final Future<void> stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(error);
      final int exitCode = await process.exitCode;
      await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
      return exitCode;
    } finally {
      for (final StreamSubscription<ProcessSignal> subscription in signals) {
        await subscription.cancel();
      }
    }
  }
}

class GameplaySwarmRun {
  const GameplaySwarmRun({
    required this.settings,
    required this.host,
    required this.port,
    required this.instance,
    required this.artifactsDirectory,
    required this.logPath,
    required this.viewerEnabled,
    required this.json,
    this.controller,
    this.version,
    this.viewerPort,
  });

  final GameplaySwarmSettings settings;
  final String host;
  final int port;
  final String instance;
  final String artifactsDirectory;
  final String logPath;
  final bool viewerEnabled;
  final bool json;
  final String? controller;
  final String? version;
  final int? viewerPort;

  List<String> get arguments => <String>[
    'swarm',
    settings.profile,
    '--host',
    host,
    '--port',
    '$port',
    '--instance',
    instance,
    '--bots',
    '${settings.bots}',
    '--duration',
    '${settings.durationSeconds}',
    '--seed',
    '${settings.seed}',
    '--join-interval',
    '${settings.joinIntervalMilliseconds}',
    '--radius',
    '${settings.radius}',
    '--prefix',
    settings.prefix,
    '--origin',
    settings.origin,
    '--connect-timeout',
    '${settings.connectTimeoutSeconds}',
    '--action-timeout',
    '${settings.actionTimeoutSeconds}',
    '--artifacts',
    artifactsDirectory,
    '--log-path',
    logPath,
    if (settings.buildArena) '--build-arena',
    if (settings.scatter != null) ...<String>[
      '--scatter',
      '${settings.scatter}',
    ],
    if (settings.chat) '--chat',
    if (settings.workload != null) ...<String>[
      '--workload',
      settings.workload!,
    ],
    if (settings.bounds != null) ...<String>[
      '--bounds',
      settings.bounds!.argument,
    ],
    if (settings.goalsArgument != null) ...<String>[
      '--goals',
      settings.goalsArgument!,
    ],
    if (settings.completion != null) ...<String>[
      '--completion',
      settings.completion!,
    ],
    if (controller != null) ...<String>['--controller', controller!],
    if (version != null) ...<String>['--version', version!],
    if (!viewerEnabled) '--no-viewer',
    if (viewerPort != null) ...<String>['--viewer-port', '$viewerPort'],
    if (json) '--json',
  ];
}

class GameplayTestRun {
  const GameplayTestRun({
    required this.artifactsDirectory,
    required this.assertionTimeoutSeconds,
    required this.auth,
    required this.connectTimeoutSeconds,
    required this.host,
    required this.instance,
    required this.json,
    required this.logPath,
    required this.port,
    required this.scenario,
    required this.timeoutSeconds,
    required this.username,
    required this.viewerEnabled,
    this.command,
    this.effect,
    this.expected,
    this.profilesFolder,
    this.version,
    this.viewerPort,
  });

  final String artifactsDirectory;
  final int assertionTimeoutSeconds;
  final String auth;
  final String? command;
  final int connectTimeoutSeconds;
  final String? effect;
  final String? expected;
  final String host;
  final String instance;
  final bool json;
  final String logPath;
  final int port;
  final String? profilesFolder;
  final String scenario;
  final int timeoutSeconds;
  final String username;
  final String? version;
  final bool viewerEnabled;
  final int? viewerPort;
}
