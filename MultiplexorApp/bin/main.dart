import 'dart:io';

import 'package:fast_log/fast_log.dart';

import 'package:multiplexor/cli/command_help.dart';
import 'package:multiplexor/cli/runner.dart';
import 'package:multiplexor/services/app_context.dart';
import 'package:multiplexor/services/self_update_installer.dart';
import 'package:multiplexor/services/self_update_release.dart';
import 'package:multiplexor/services/self_update_service.dart';
import 'package:multiplexor/services/self_update_settings.dart';

Future<void> main(List<String> arguments) async {
  final int? helperCode = await runSelfUpdateHelper(arguments);
  if (helperCode != null) {
    exit(helperCode);
  }
  final parsed = _parseGlobalFlags(arguments);
  final normalizedArgs = parsed.args;

  if (parsed.verbose) {
    lDebugMode = true;
    stdout.writeln('[debug] args=${parsed.args.join(' ')}');
    stdout.writeln('[debug] normalized=${normalizedArgs.join(' ')}');
  }

  if (isCliHelpRequest(normalizedArgs)) {
    final code = printCliHelpForArgs(normalizedArgs);
    if (code != 0) {
      exit(code);
    }
    return;
  }

  if (isCliVersionRequest(normalizedArgs)) {
    printCliVersion();
    return;
  }

  final bool updateCommand =
      normalizedArgs.isNotEmpty && normalizedArgs.first == 'update';
  final bool releaseBuild =
      multiplexorReleaseBuild && isRunningCompiledExecutable();
  final bool automaticUpdate =
      releaseBuild &&
      opensUpdateDashboard(normalizedArgs) &&
      stdin.hasTerminal &&
      stdout.hasTerminal &&
      Platform.environment['MULTIPLEXOR_NO_UPDATE'] != '1';
  if (updateCommand || automaticUpdate) {
    GithubUpdateClient? client;
    try {
      client = GithubUpdateClient();
      final String executable = File(
        Platform.resolvedExecutable,
      ).resolveSymbolicLinksSync();
      final SelfUpdateService updater = SelfUpdateService(
        currentVersion: UpdateVersion.parse(multiplexorVersion),
        executablePath: executable,
        releaseBuild: releaseBuild,
        platform: UpdatePlatform.current(),
        store: SelfUpdateStore(SelfUpdateStore.defaultDirectory(), executable),
        client: client,
      );
      if (updateCommand) {
        exitCode = await updater.command(normalizedArgs.sublist(1));
        if (updater.exitRequired) exit(exitCode);
        return;
      }
      final int? restartCode = await updater.automatic(arguments);
      if (restartCode != null) {
        exit(restartCode);
      }
    } catch (error) {
      stderr.writeln('[update] $error');
      if (updateCommand) {
        exitCode = error is FormatException ? 2 : 1;
        return;
      }
    } finally {
      client?.close();
    }
  }

  try {
    initializeAppContext(
      requestedConsumer: parsed.consumer,
      verbose: parsed.verbose,
      rootOverride: parsed.root,
    );
  } on Exception catch (e) {
    stderr.writeln('[ERROR] $e');
    exit(2);
  }

  final code = await runCli(normalizedArgs);
  if (code != 0) {
    exit(code);
  }
}

_GlobalParseResult _parseGlobalFlags(List<String> args) {
  final out = <String>[];
  String? consumer;
  String? root;
  var verbose = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--verbose' || arg == '-v') {
      verbose = true;
      continue;
    }

    if (arg == '--consumer') {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        stderr.writeln('[ERROR] Missing value for --consumer');
        exit(2);
      }
      consumer = args[i + 1];
      i++;
      continue;
    }

    if (arg.startsWith('--consumer=')) {
      consumer = arg.substring('--consumer='.length);
      continue;
    }

    if (arg == '--root') {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        stderr.writeln('[ERROR] Missing value for --root');
        exit(2);
      }
      root = args[i + 1];
      i++;
      continue;
    }

    if (arg.startsWith('--root=')) {
      root = arg.substring('--root='.length);
      continue;
    }

    out.add(arg);
  }

  return _GlobalParseResult(
    args: out,
    consumer: consumer,
    root: root,
    verbose: verbose,
  );
}

class _GlobalParseResult {
  _GlobalParseResult({
    required this.args,
    required this.consumer,
    required this.root,
    required this.verbose,
  });

  final List<String> args;
  final String? consumer;
  final String? root;
  final bool verbose;
}
