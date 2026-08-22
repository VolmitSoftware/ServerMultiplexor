import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
    // `npm ci` is the reproducible install and the one to prefer, but it
    // requires a lockfile, and the lockfile is not in the repo — so on a
    // fresh checkout demanding one meant setup could never run at all. The
    // plain install writes the lock that every install after it uses.
    final bool locked = File(
      p.join(harnessDirectory, 'package-lock.json'),
    ).existsSync();
    if (!locked) {
      write('[INFO] No package lock yet; resolving dependencies once.');
    }
    return _run(
      'npm',
      locked
          ? const <String>['ci', '--no-audit', '--no-fund']
          : const <String>['install', '--no-audit', '--no-fund'],
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

  Future<int> _runHarness(
    List<String> arguments, {
    required void Function(String line) write,
    required void Function(String line) error,
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
    );
  }

  Future<int> _run(
    String executable,
    List<String> arguments, {
    required void Function(String line) write,
    required void Function(String line) error,
    bool shell = false,
  }) async {
    Process process;
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
  }
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
