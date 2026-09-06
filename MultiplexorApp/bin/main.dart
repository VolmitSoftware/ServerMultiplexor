import 'dart:io';

import 'package:fast_log/fast_log.dart';

import 'package:multiplexor/cli/command_help.dart';
import 'package:multiplexor/cli/runner.dart';
import 'package:multiplexor/services/app_context.dart';

Future<void> main(List<String> arguments) async {
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
