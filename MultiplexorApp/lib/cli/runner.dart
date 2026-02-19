import 'dart:io';

import 'handlers/consumer_handlers.dart';
import 'handlers/passthrough_handlers.dart';
import 'handlers/wizard_handler.dart';

Future<int> runCli(List<String> args) async {
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
        await handleHelp();
        return 0;
      case 'version':
        stdout.writeln('Multiplexor CLI v0.2.0');
        stdout.writeln('Minecraft server profile manager');
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
      stderr.writeln('Usage: repos sync [all|paper|purpur|folia|canvas]');
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
    case 'test-latest':
      await handleBuildTestLatest(<String, dynamic>{
        'spigot-mc': parsed.option('spigot-mc') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'paper':
    case 'purpur':
    case 'folia':
    case 'canvas':
    case 'spigot':
    case 'forge':
    case 'fabric':
    case 'neoforge':
      await handleBuildTarget(sub, <String, dynamic>{
        'mc': parsed.option('mc') ?? parsed.positionalOrNull(0),
        'loader': parsed.option('loader'),
        'installer': parsed.option('installer'),
      });
      return 0;
    default:
      stderr.writeln(
        'Usage: build <target|latest|list|list-all|versions|test-latest>',
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
        <String, dynamic>{'auto-build': parsed.flag('auto-build')},
      );
      return 0;
    default:
      stderr.writeln('Usage: server create <name> [--type ...]');
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
      await handleInstanceDeleteAll();
      return 0;
    default:
      stderr.writeln(
        'Usage: instance <list|create|clone|delete|activate|path|port|motd-style|current|delete-all>',
      );
      return 2;
  }
}

Future<int> _runRuntime(List<String> rest) async {
  final sub = rest.isEmpty ? 'status' : rest.first;
  final parsed = _parse(rest.skip(1).toList(growable: false));

  switch (sub) {
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
      });
      return 0;
    case 'stop':
      await handleRuntimeStop(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'status':
      await handleRuntimeStatus(<String, dynamic>{
        'instance': parsed.option('instance') ?? parsed.positionalOrNull(0),
      });
      return 0;
    case 'list':
      await handleRuntimeList();
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
          if (value == null || value.trim().isEmpty) {
            stderr.writeln('Usage: runtime settings $action <value>');
            return 2;
          }
          await handleRuntimeSettings(action, value: value);
          return 0;
        default:
          stderr.writeln(
            'Usage: runtime settings <show|presets|set-heap|set-preset|reset>',
          );
          return 2;
      }
    default:
      stderr.writeln(
        'Usage: runtime <console|consoles|consoles-lateral|start|stop|status|list|settings> [instance|args]',
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
    default:
      stderr.writeln('Usage: mods <show-source|sync>');
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

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (!t.startsWith('--')) {
      positional.add(t);
      continue;
    }

    final withoutPrefix = t.substring(2);
    if (withoutPrefix.contains('=')) {
      final parts = withoutPrefix.split('=');
      options[parts.first] = parts.sublist(1).join('=');
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
