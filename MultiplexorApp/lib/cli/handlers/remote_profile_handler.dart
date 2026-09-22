import 'dart:async';
import 'dart:io';

import '../../services/app_context.dart';
import '../../services/profiling/remote_profiler_agent_cache.dart';
import '../../services/profiling/remote_profiler_models.dart';
import '../../services/profiling/remote_profiler_service.dart';
import '../../services/pterodactyl/pterodactyl_console_protocol.dart';
import '../remote_profile_command.dart';

Future<int> handleRemoteProfile(
  List<String> args, {
  Future<void> Function(RemoteProfilerTunnel)? waitForTunnel,
}) async {
  try {
    final RemoteProfileCommand command = RemoteProfileCommand.parse(args);
    final String? profileId =
        command.option('profile') ?? pterodactylService.activeProfile()?.id;
    if (profileId == null) {
      throw StateError(
        'Select a Pterodactyl account with remote account use <id>.',
      );
    }
    final RemoteProfilerService service = remoteProfilerService(profileId);
    switch (command.action) {
      case RemoteProfileAction.hostSet:
        await remoteProfilerGateway(profileId).configureHost(
          command.server,
          command.option('ssh-target')!,
          sshPort: int.parse(command.option('ssh-port') ?? '22'),
          identityFile: command.option('identity-file'),
          knownHostsFile: command.option('known-hosts-file'),
          sudoDocker: command.flag('sudo-docker'),
        );
        stdout.writeln('[OK] Saved SSH host for this account and node.');
      case RemoteProfileAction.check:
        final RemoteProfilerCheck check = await service.check(command.server);
        for (final String line in remoteProfilerCheckLines(check)) {
          stdout.writeln(line);
        }
        return check.ready ? 0 : 1;
      case RemoteProfileAction.start:
        final RemoteProfilerCheck check = await service.check(command.server);
        if (!check.ready) {
          throw StateError(check.issues.join('; '));
        }
        if (check.isRunning &&
            !command.flag('attach') &&
            !command.flag('restart')) {
          throw StateError(
            'The server is running. Add --restart to authorize its graceful restart.',
          );
        }
        if (!check.isRunning && command.flag('attach')) {
          throw StateError('Attach requires an already-running JVM.');
        }
        final String agentDirectory =
            command.option('agent-dir') ??
            await RemoteProfilerAgentCache(appContext.metadataDir).resolve(
              architecture: check.architecture,
              version: command.option('agent-version') ?? '16.2',
            );
        final RemoteProfilerCapture capture = await service.start(
          command.server,
          RemoteProfilerOptions(
            agentDirectory: agentDirectory,
            configPath: command.option('config'),
            duration: command.duration,
            live: command.flag('live'),
            sessionId: int.parse(command.option('session-id') ?? '1'),
            port: int.parse(command.option('port') ?? '8849'),
            restart: command.flag('restart'),
            attach: command.flag('attach'),
          ),
        );
        _printCapture(capture);
        stdout.writeln(
          capture.live
              ? 'Open remote profile live for this server to connect JProfiler.'
              : 'Use remote profile status and fetch for this server after recording.',
        );
        if (!capture.startupRestored) return 1;
      case RemoteProfileAction.status:
        _printCapture(await service.status(command.server));
      case RemoteProfileAction.fetch:
        final RemoteProfilerFetch result = await service.fetch(
          command.server,
          destinationDirectory: command.option('output'),
        );
        _printCapture(result.capture);
        for (final String file in result.files) {
          stdout.writeln('snapshot: ${_safe(file)}');
        }
        stdout.writeln('logs: ${_safe(result.logsPath)}');
        if (command.flag('open')) {
          if (result.files.isEmpty) {
            throw StateError('No snapshot is available to open.');
          }
          await _openSnapshot(result.files.last);
        }
      case RemoteProfileAction.recover:
        final RemoteProfilerCapture capture = await service.recover(
          command.server,
        );
        _printCapture(capture);
        if (!capture.startupRestored) return 1;
      case RemoteProfileAction.live:
        final RemoteProfilerTunnel tunnel = await service.openTunnel(
          command.server,
          localPort: int.parse(command.option('local-port') ?? '8849'),
        );
        try {
          stdout.writeln('JProfiler connection: 127.0.0.1:${tunnel.localPort}');
          stdout.writeln(
            'Keep this command open while connected. Closing the tunnel leaves the server running.',
          );
          await (waitForTunnel ?? _waitForInterrupt)(tunnel);
        } finally {
          await tunnel.close();
          stdout.writeln('Profiling tunnel closed.');
        }
    }
    return 0;
  } on ArgumentError catch (error) {
    stderr.writeln('[ERROR] ${_safe(error.message.toString())}');
    stderr.writeln('Run ./start.sh help remote for profiling command forms.');
    return 2;
  } on Object catch (error) {
    stderr.writeln('[ERROR] ${_safe(error.toString())}');
    return 1;
  }
}

List<String> remoteProfilerCheckLines(RemoteProfilerCheck check) => <String>[
  'server: ${_safe(check.target.name)} (${_safe(check.target.id)})',
  'node: ${check.target.nodeId}',
  'platform: ${_safe(check.os)} / ${_safe(check.architecture)}',
  'java: ${_safe(check.javaVersion)}',
  'running: ${check.isRunning}',
  'ready: ${check.ready}',
  for (final String issue in check.issues) 'issue: ${_safe(issue)}',
];

List<String> remoteProfilerCaptureLines(RemoteProfilerCapture capture) =>
    <String>[
      'capture: ${_safe(capture.id)}',
      'server: ${_safe(capture.target.name)} (${_safe(capture.target.id)})',
      'phase: ${capture.phase.name}',
      'mode: ${capture.live ? 'live' : 'offline'}',
      'target: ${capture.attached ? 'running JVM attachment' : 'JVM startup'}',
      if (!capture.live) 'duration: ${capture.durationSeconds}s',
      'startup restored: ${capture.startupRestored}',
      if (capture.stage != null)
        'remote snapshots: ${_safe(capture.stage!.remoteDirectory)}',
      if (capture.error != null) 'error: ${_safe(capture.error!)}',
      'A loaded profiling agent remains in that JVM until a normal restart.',
    ];

void _printCapture(RemoteProfilerCapture capture) {
  for (final String line in remoteProfilerCaptureLines(capture)) {
    stdout.writeln(line);
  }
}

String _safe(String value) => PterodactylConsoleSanitizer.text(
  value,
).replaceAll(RegExp(r'[\r\n\t]'), ' ');

Future<void> _waitForInterrupt(RemoteProfilerTunnel tunnel) async {
  final Completer<void> stopped = Completer<void>();
  final StreamSubscription<ProcessSignal> interrupt = ProcessSignal.sigint
      .watch()
      .listen((ProcessSignal _) {
        if (!stopped.isCompleted) stopped.complete();
      });
  StreamSubscription<ProcessSignal>? terminate;
  try {
    if (!Platform.isWindows) {
      terminate = ProcessSignal.sigterm.watch().listen((ProcessSignal _) {
        if (!stopped.isCompleted) stopped.complete();
      });
    }
    stdout.writeln('Press Ctrl-C to close the tunnel.');
    final int? exited = await Future.any<int?>(<Future<int?>>[
      stopped.future.then<int?>((_) => null),
      tunnel.exitCode.then<int?>((int code) => code),
    ]);
    if (exited != null) {
      throw StateError('Profiling SSH tunnel disconnected (exit $exited).');
    }
  } finally {
    await interrupt.cancel();
    await terminate?.cancel();
  }
}

Future<void> _openSnapshot(String path) async {
  final String executable = Platform.isMacOS
      ? 'open'
      : Platform.isWindows
      ? 'rundll32'
      : 'xdg-open';
  final List<String> arguments = Platform.isWindows
      ? <String>['url.dll,FileProtocolHandler', path]
      : <String>[path];
  final ProcessResult result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not open the snapshot. Open ${_safe(path)} in JProfiler.',
    );
  }
}
