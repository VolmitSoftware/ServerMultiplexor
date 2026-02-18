import 'dart:io';

import 'package:fast_log/fast_log.dart';

import 'package:multiplexor/cli/runner.dart';
import 'package:multiplexor/services/app_context.dart';

Future<void> main(List<String> arguments) async {
  final parsed = _parseGlobalFlags(arguments);
  final normalizedArgs = _normalizePositionalArgs(parsed.args);

  if (parsed.verbose) {
    lDebugMode = true;
    stdout.writeln('[debug] args=${parsed.args.join(' ')}');
    stdout.writeln('[debug] normalized=${normalizedArgs.join(' ')}');
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
      if (i + 1 >= args.length) {
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
      if (i + 1 >= args.length) {
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

List<String> _normalizePositionalArgs(List<String> args) {
  if (args.length < 2) {
    return args;
  }

  List<String> injectSingleValue(String flagName, int index) {
    if (args.length <= index) {
      return args;
    }
    final value = args[index];
    if (value.startsWith('-')) {
      return args;
    }
    return <String>[
      ...args.sublist(0, index),
      '--$flagName',
      value,
      ...args.sublist(index + 1),
    ];
  }

  final top = args[0];
  final sub = args[1];

  switch (top) {
    case 'consumer':
      if (sub == 'use') {
        return injectSingleValue('consumer', 2);
      }
      return args;
    case 'repos':
      if (sub == 'sync') {
        return injectSingleValue('target', 2);
      }
      return args;
    case 'build':
      if (sub == 'latest' || sub == 'versions' || sub == 'list-all') {
        return injectSingleValue('type', 2);
      }
      if (sub == 'test-latest') {
        return injectSingleValue('spigot-mc', 2);
      }
      const targets = <String>{
        'paper',
        'purpur',
        'folia',
        'canvas',
        'spigot',
        'forge',
        'fabric',
        'neoforge',
      };
      if (targets.contains(sub)) {
        return injectSingleValue('mc', 2);
      }
      return args;
    case 'server':
      if (sub == 'create') {
        return injectSingleValue('name', 2);
      }
      return args;
    case 'instance':
      if (sub == 'create' || sub == 'activate' || sub == 'path' || sub == 'delete') {
        return injectSingleValue('name', 2);
      }
      if (sub == 'motd-style') {
        return injectSingleValue('target', 2);
      }
      if (sub == 'clone') {
        var out = injectSingleValue('source', 2);
        if (out != args) {
          out = <String>[
            ...out.sublist(0, 4),
            ...injectSingleValue('target', 4).sublist(4),
          ];
        }
        return out;
      }
      if (sub == 'port') {
        var out = injectSingleValue('instance', 2);
        if (out.length > 4 && !out[4].startsWith('-')) {
          out = <String>[
            ...out.sublist(0, 4),
            '--port',
            out[4],
            ...out.sublist(5),
          ];
        }
        return out;
      }
      return args;
    case 'runtime':
      if (sub == 'console' ||
          sub == 'start' ||
          sub == 'stop' ||
          sub == 'status') {
        return injectSingleValue('instance', 2);
      }
      return args;
    case 'plugins':
    case 'mods':
      if (sub == 'sync') {
        return injectSingleValue('target', 2);
      }
      if (top == 'plugins' && sub == 'iris-packs-link') {
        return injectSingleValue('target', 2);
      }
      return args;
    case 'config':
      if (sub == 'localize' || sub == 'status') {
        return injectSingleValue('target', 2);
      }
      return args;
    default:
      return args;
  }
}
