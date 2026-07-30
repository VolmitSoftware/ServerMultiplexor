import 'dart:io';

import '../services/app_context.dart';
import 'command_help.dart';
import 'handlers/consumer_handlers.dart';
import 'handlers/monitor_handler.dart';
import 'handlers/passthrough_handlers.dart';
import 'handlers/wizard_handler.dart';

/// Runs one CLI invocation and returns its exit code.
///
/// Every command funnels through here, and so does the one teardown that has
/// to happen on the way back out. `runtime metrics` reads live TPS over a
/// pooled RCON connection that is deliberately held open for reuse, and an
/// open socket keeps the Dart event loop alive long after the command has
/// printed its last line — so a headless `runtime metrics` or
/// `runtime watch --once` never returned while a server was up. Closing the
/// pool here covers every command by construction, which is why it lives at
/// the dispatch boundary rather than in the handlers that happen to reach
/// RCON today.
///
/// Disposing the resource is the fix, not `exit()`: killing the process would
/// hide the next leaked socket instead of closing this one.
Future<int> runCli(List<String> args) async {
  try {
    return await _dispatch(args);
  } finally {
    // Idempotent — the interactive wizard tears the same pool down when it
    // leaves the dashboard, and this runs again on the way out.
    passthroughService.disposeRcon();
  }
}

Future<int> _dispatch(List<String> args) async {
  if (isCliHelpRequest(args)) {
    return printCliHelpForArgs(args);
  }
  if (isCliVersionRequest(args)) {
    printCliVersion();
    return 0;
  }

  if (args.isEmpty) {
    await handleWizard();
    return 0;
  }

  final command = args.first;
  final rest = args.sublist(1);

  try {
    switch (command) {
      case 'wizard':
        await handleWizard();
        return 0;
      case 'doctor':
      case 'backup':
      case 'template':
      case 'content':
        await handleNativePassthrough(<String>[command, ...rest]);
        return 0;
      case 'consumer':
        return _runConsumer(rest);
      case 'repos':
        return _runRepos(rest);
      case 'build':
        return _runBuild(rest);
      case 'server':
        return _runServer(rest);
      case 'instance':
        return _runInstance(rest);
      case 'runtime':
        return _runRuntime(rest);
      case 'plugins':
        return _runPlugins(rest);
      case 'mods':
        return _runMods(rest);
      case 'config':
        return _runConfig(rest);
      case 'help':
        return printCliHelpForArgs(args);
      case 'version':
        printCliVersion();
        return 0;
      default:
        stderr.writeln('[ERROR] Unknown command: $command');
        await handleHelp();
        return 2;
    }
  } on ProcessException catch (e) {
    stderr.writeln('[ERROR] ${e.message}');
    return e.errorCode;
  } catch (e) {
    stderr.writeln('[ERROR] $e');
    return 1;
  }
}

Future<int> _runConsumer(List<String> rest) async {
  final sub = rest.isEmpty ? 'show' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'list':
      await handleConsumerList();
      return 0;
    case 'show':
    case 'current':
      await handleConsumerShow();
      return 0;
    case 'use':
    case 'set':
      await handleConsumerUse(<String, dynamic>{
        'consumer': parsed.option('consumer') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'path':
    case 'root':
      await handleConsumerPath();
      return 0;
    default:
      stderr.writeln('Usage: consumer <list|show|use|path>');
      return 2;
  }
}

Future<int> _runRepos(List<String> rest) async {
  final sub = rest.isEmpty ? 'sync' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'sync':
      await handleReposSync(<String, dynamic>{
        'target':
            parsed.option('target') ?? parsed.positionalOrNull(0) ?? 'all',
      }, const <String, dynamic>{});
      return 0;
    default:
      stderr.writeln('Usage: repos sync [all|paper|purpur|folia|canvas|leaf]');
      return 2;
  }
}

Future<int> _runBuild(List<String> rest) async {
  final sub = rest.isEmpty ? 'list' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'list':
      await handleBuildList();
      return 0;
    case 'list-all':
      await handleBuildListAll(<String, dynamic>{
        'type': parsed.option('type') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'latest':
      await handleBuildLatest(<String, dynamic>{
        'type': parsed.option('type') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'versions':
      await handleBuildVersions(<String, dynamic>{
        'type': parsed.option('type') ?? parsed.positionalOrNull(0) ?? 'all',
      });
      return 0;
    case 'cache-info':
      await handleBuildCacheInfo(<String, dynamic>{
        'type': parsed.option('type') ?? parsed.positionalOrNull(0) ?? 'all',
        'mc': parsed.option('mc'),
      });
      return 0;
    case 'test-latest':
      await handleBuildTestLatest(<String, dynamic>{
        'spigot-mc': parsed.option('spigot-mc') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'prune':
      await handleBuildPrune(<String, dynamic>{
        'type': parsed.option('type') ?? parsed.positionalOrNull(0) ?? 'all',
      });
      return 0;
    case 'paper':
    case 'purpur':
    case 'folia':
    case 'canvas':
    case 'leaf':
    case 'spigot':
    case 'forge':
    case 'fabric':
    case 'neoforge':
      await handleBuildTarget(sub, <String, dynamic>{
        'mc': parsed.option('mc') ?? parsed.positionalOrNull(0),
        'loader': parsed.option('loader'),
        'installer': parsed.option('installer'),
        'force': parsed.flag('force'),
      });
      return 0;
    default:
      stderr.writeln(
        'Usage: build <target|latest|list|list-all|versions|cache-info|test-latest|prune>',
      );
      return 2;
  }
}

Future<int> _runServer(List<String> rest) async {
  final sub = rest.isEmpty ? '' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'create':
      await handleServerCreate(
        <String, dynamic>{
          'name': parsed.option('name') ?? parsed.positionalOrNull(0),
          'type': parsed.option('type'),
          'mc': parsed.option('mc'),
          'loader': parsed.option('loader'),
          'installer': parsed.option('installer'),
          'jar': parsed.option('jar'),
        },
        <String, dynamic>{
          'auto-build': parsed.flag('auto-build'),
          'isolated': parsed.flag('isolated'),
        },
      );
      return 0;
    case 'create-many':
      await handleServerCreateMany(
        <String, dynamic>{
          'types': parsed.option('types') ?? parsed.positionalOrNull(0),
          'prefix': parsed.option('prefix'),
          'mc': parsed.option('mc'),
        },
        <String, dynamic>{
          'auto-build': parsed.flag('auto-build'),
          'isolated': parsed.flag('isolated'),
        },
      );
      return 0;
    default:
      stderr.writeln(
        'Usage: server <create|create-many> ... (create-many: --types paper,purpur,...)',
      );
      return 2;
  }
}

Future<int> _runInstance(List<String> rest) async {
  final sub = rest.isEmpty ? 'list' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'list':
      await handleInstanceList();
      return 0;
    case 'current':
      await handleInstanceCurrent();
      return 0;
    case 'create':
      await handleInstanceCreate(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'clone':
      await handleInstanceClone(<String, dynamic>{
        'source': parsed.option('source') ?? parsed.positionalOrNull(0),
        'target': parsed.option('target') ?? parsed.positionalOrNull(1),
      });
      return 0;
    case 'delete':
      await handleInstanceDelete(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'reset':
      await handleInstanceReset(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'activate':
      await handleInstanceActivate(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'path':
      await handleInstancePath(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'open':
      await handleInstanceOpen(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'safe-update':
      await handleNativePassthrough(<String>['instance', ...rest]);
      return 0;
    case 'update':
      await handleInstanceUpdate(
        <String, dynamic>{
          'name': parsed.option('name') ?? parsed.positionalOrNull(0),
          'type': parsed.option('type'),
          'mc': parsed.option('mc'),
          'jar': parsed.option('jar'),
          'loader': parsed.option('loader'),
        },
        <String, dynamic>{'auto-build': parsed.flag('auto-build')},
      );
      return 0;
    case 'isolated':
      await handleInstanceIsolated(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
        'value': parsed.option('value') ?? parsed.positionalOrNull(1),
      });
      return 0;
    case 'lock':
      await handleInstanceLock(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
        'pin': parsed.option('pin'),
      });
      return 0;
    case 'unlock':
      await handleInstanceUnlock(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
        'pin': parsed.option('pin'),
      });
      return 0;
    case 'locked':
      await handleInstanceLocked(<String, dynamic>{
        'name': parsed.option('name') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'port':
      await handleInstancePort(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
        'port': parsed.option('port') ?? parsed.positionalOrNull(1),
      });
      return 0;
    case 'motd-style':
      await handleInstanceMotdStyle(<String, dynamic>{
        'target': parsed.option('target') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'delete-all':
      await handleInstanceDeleteAll(<String, dynamic>{
        'everywhere': parsed.flag('everywhere'),
        'force': parsed.flag('force'),
      });
      return 0;
    default:
      stderr.writeln(
        'Usage: instance <list|create|clone|delete|reset|activate|path|open|update|safe-update|isolated|lock|unlock|locked|port|motd-style|current|delete-all>',
      );
      return 2;
  }
}

Future<int> _runRuntime(List<String> rest) async {
  final sub = rest.isEmpty ? 'status' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    // Routed here rather than through the native passthrough: the monitor
    // owns the terminal and, interactively, the wizard's own flows.
    case 'watch':
      return handleRuntimeWatch(rest.skip(1).toList(growable: false));
    case 'console':
      await handleRuntimeConsole(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'consoles':
    case 'console-all':
      await handleRuntimeConsoles();
      return 0;
    case 'consoles-lateral':
    case 'console-lateral':
      await handleRuntimeConsolesLateral();
      return 0;
    case 'start':
      await handleRuntimeStart(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
        'no-console': parsed.flag('no-console'),
      });
      return 0;
    case 'stop':
      await handleRuntimeStop(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'restart':
      await handleRuntimeRestart(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
        'no-console': parsed.flag('no-console'),
      });
      return 0;
    case 'status':
      await handleRuntimeStatus(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'stats':
      await handleRuntimeStats(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'list':
      await handleRuntimeList();
      return 0;
    case 'states':
      await handleRuntimeStates();
      return 0;
    case 'metrics':
      await handleRuntimeMetrics();
      return 0;
    case 'settings':
      final action = parsed.positionalOrNull(0) ?? 'show';
      final value = parsed.option('value') ?? parsed.positionalOrNull(1);
      switch (action) {
        case 'show':
        case 'presets':
        case 'reset':
          await handleRuntimeSettings(action);
          return 0;
        case 'set-heap':
        case 'set-preset':
        case 'set-wrap':
        case 'set-log-format':
          if (value == null || value.trim().isEmpty) {
            stderr.writeln('Usage: runtime settings $action <value>');
            return 2;
          }
          await handleRuntimeSettings(action, value: value);
          return 0;
        default:
          stderr.writeln(
            'Usage: runtime settings <show|presets|set-heap|set-preset|set-wrap|set-log-format|reset>',
          );
          return 2;
      }
    default:
      stderr.writeln(
        'Usage: runtime <watch|console|consoles|consoles-lateral|start|stop|restart|status|stats|states|metrics|list|settings> [instance|args] (watch supports --once; start/restart support --instance/--no-console)',
      );
      return 2;
  }
}

Future<int> _runPlugins(List<String> rest) async {
  final sub = rest.isEmpty ? 'show-source' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'show-source':
      await handlePluginsShowSource();
      return 0;
    case 'sync':
      await handlePluginsSync(
        <String, dynamic>{
          'target': parsed.option('target') ?? parsed.positionalOrNull(0),
        },
        <String, dynamic>{
          'all': parsed.flag('all'),
          'clean': parsed.flag('clean'),
        },
      );
      return 0;
    case 'iris-packs-path':
      await handlePluginsIrisPath();
      return 0;
    case 'iris-packs-link':
      await handlePluginsIrisLink(
        <String, dynamic>{
          'target': parsed.option('target') ?? parsed.positionalOrNull(0),
        },
        <String, dynamic>{'all': parsed.flag('all')},
      );
      return 0;
    case 'watch-status':
      await handlePluginsWatchStatus();
      return 0;
    case 'watch-start':
      await handlePluginsWatchStart();
      return 0;
    case 'watch-stop':
      await handlePluginsWatchStop();
      return 0;
    case 'watch-daemon':
      await handlePluginsWatchDaemon();
      return 0;
    default:
      stderr.writeln(
        'Usage: plugins <show-source|sync|iris-packs-path|iris-packs-link|watch-status|watch-start|watch-stop>',
      );
      return 2;
  }
}

Future<int> _runMods(List<String> rest) async {
  final sub = rest.isEmpty ? 'show-source' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'show-source':
      await handlePluginsShowSource(mods: true);
      return 0;
    case 'sync':
      await handlePluginsSync(
        <String, dynamic>{
          'target': parsed.option('target') ?? parsed.positionalOrNull(0),
        },
        <String, dynamic>{
          'all': parsed.flag('all'),
          'clean': parsed.flag('clean'),
        },
        mods: true,
      );
      return 0;
    case 'watch-status':
      await handlePluginsWatchStatus(mods: true);
      return 0;
    case 'watch-start':
      await handlePluginsWatchStart(mods: true);
      return 0;
    case 'watch-stop':
      await handlePluginsWatchStop(mods: true);
      return 0;
    case 'watch-daemon':
      await handlePluginsWatchDaemon(mods: true);
      return 0;
    default:
      stderr.writeln(
        'Usage: mods <show-source|sync|watch-status|watch-start|watch-stop>',
      );
      return 2;
  }
}

Future<int> _runConfig(List<String> rest) async {
  final sub = rest.isEmpty ? 'localize' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
    case 'localize':
      await handleConfigLink(
        <String, dynamic>{
          'target': parsed.option('target') ?? parsed.positionalOrNull(0),
        },
        <String, dynamic>{'all': parsed.flag('all')},
      );
      return 0;
    case 'status':
      await handleConfigStatus(<String, dynamic>{
        'target': parsed.option('target') ?? parsed.positionalOrNull(0),
      });
      return 0;
    default:
      stderr.writeln('Usage: config <localize|status>');
      return 2;
  }
}

_ParsedTokens _parse(List<String> tokens) {
  final options = <String, String>{};
  final flags = <String, bool>{};
  final positional = <String>[];
  const booleanFlags = <String>{
    'all',
    'auto-build',
    'clean',
    'everywhere',
    'force',
    'isolated',
    'no-console',
  };

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (!t.startsWith('--')) {
      positional.add(t);
      continue;
    }

    final withoutPrefix = t.substring(2);
    if (withoutPrefix.contains('=')) {
      final parts = withoutPrefix.split('=');
      final name = parts.first;
      final value = parts.sublist(1).join('=');
      if (booleanFlags.contains(name)) {
        final normalized = value.trim().toLowerCase();
        flags[name] =
            normalized != '0' &&
            normalized != 'false' &&
            normalized != 'no' &&
            normalized != 'off';
      } else {
        options[name] = value;
      }
      continue;
    }

    if (booleanFlags.contains(withoutPrefix)) {
      flags[withoutPrefix] = true;
      continue;
    }

    if (i + 1 < tokens.length && !tokens[i + 1].startsWith('--')) {
      options[withoutPrefix] = tokens[i + 1];
      i++;
      continue;
    }

    flags[withoutPrefix] = true;
  }

  return _ParsedTokens(options: options, flags: flags, positional: positional);
}

class _ParsedTokens {
  _ParsedTokens({
    required this.options,
    required this.flags,
    required this.positional,
  });

  final Map<String, String> options;
  final Map<String, bool> flags;
  final List<String> positional;

  String? option(String name) => options[name];
  bool flag(String name) => flags[name] == true;

  String? positionalOrNull(int index) {
    if (index < 0 || index >= positional.length) {
      return null;
    }
    return positional[index];
  }
}
