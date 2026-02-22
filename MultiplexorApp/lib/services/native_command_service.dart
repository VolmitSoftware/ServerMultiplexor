import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/consumer_profile.dart';
import '../utils/process_runner.dart';
import 'consumer_service.dart';
import 'manager_context.dart';

class NativeCommandService {
  NativeCommandService({required this.context, required this.consumerService});

  final ManagerContext context;
  final ConsumerService consumerService;

  Future<CapturedResult> execute(
    List<String> args, {
    required bool stream,
  }) async {
    final io = _NativeIoBuffer(stream: stream);

    try {
      if (args.isEmpty) {
        _printHelp(io);
        return io.result(0);
      }

      final exitCode = await _dispatch(args, io);
      return io.result(exitCode);
    } on _NativeCommandException catch (e) {
      io.error('[ERROR] ${e.message}');
      return io.result(e.exitCode);
    } catch (e, st) {
      io.error('[ERROR] $e');
      if (context.verbose) {
        io.error('$st');
      }
      return io.result(1);
    }
  }

  Future<int> _dispatch(List<String> args, _NativeIoBuffer io) async {
    final command = args.first;
    final rest = args.sublist(1);

    switch (command) {
      case 'help':
      case '-h':
      case '--help':
        _printHelp(io);
        return 0;
      case 'version':
        io.write('Multiplexor CLI v0.2.0');
        io.write('Minecraft server profile manager (native mode)');
        return 0;
      case 'consumer':
        return _dispatchConsumer(rest, io);
      case 'instance':
        return _dispatchInstance(rest, io);
      case 'server':
        return _dispatchServer(rest, io);
      case 'runtime':
        return _dispatchRuntime(rest, io);
      case 'plugins':
        return _dispatchPlugins(rest, io, mods: false);
      case 'mods':
        return _dispatchPlugins(rest, io, mods: true);
      case 'config':
        return _dispatchConfig(rest, io);
      case 'build':
        return _dispatchBuild(rest, io);
      case 'repos':
        return _dispatchRepos(rest, io);
      default:
        throw _NativeCommandException('Unknown command: $command', 2);
    }
  }

  Future<int> _dispatchConsumer(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'show' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);

    switch (sub) {
      case 'list':
        final active = _activeConsumer;
        for (final profile in ConsumerProfile.values) {
          final mark = profile == active ? ' (active)' : '';
          io.write('${profile.shortName}$mark');
        }
        return 0;
      case 'show':
      case 'current':
        io.write(_activeConsumer.shortName);
        return 0;
      case 'use':
      case 'set':
        final raw = rest.isNotEmpty ? rest.first : '';
        final profile = ConsumerProfile.parse(raw);
        if (profile == null) {
          throw _NativeCommandException(
            'Usage: consumer use <plugin|forge|fabric|neoforge>',
            2,
          );
        }
        consumerService.ensureConsumerDirs(profile);
        consumerService.writeActive(profile);
        io.write('[OK] Active consumer: ${profile.shortName}');
        io.write('[INFO] Consumer root: ${_consumerRoot(profile)}');
        return 0;
      case 'path':
      case 'root':
        io.write(_consumerRoot(_activeConsumer));
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: consumer <list|show|use|path>',
          2,
        );
    }
  }

  Future<int> _dispatchInstance(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'list':
        final active = _currentInstance(profile);
        for (final name in _instanceNames(profile)) {
          io.write(name == active ? '$name (active)' : name);
        }
        return 0;
      case 'current':
        final current = _currentInstance(profile);
        if (current == null || current.isEmpty) {
          return 1;
        }
        io.write(current);
        return 0;
      case 'create':
        final name = _requireValue(rest, 'Usage: instance create <name>');
        _instanceCreateBlank(profile, name, io: io);
        io.write(
          '[OK] Instance created: $name (port ${_instanceGetServerPort(profile, name)})',
        );
        return 0;
      case 'clone':
        if (rest.length < 2) {
          throw _NativeCommandException(
            'Usage: instance clone <source> <new>',
            2,
          );
        }
        _instanceClone(profile, rest[0], rest[1], io: io);
        io.write(
          '[OK] Cloned instance: ${rest[0]} -> ${rest[1]} (port ${_instanceGetServerPort(profile, rest[1])})',
        );
        return 0;
      case 'delete':
        final name = _requireValue(rest, 'Usage: instance delete <name>');
        _instanceDelete(profile, name);
        io.write('[OK] Deleted instance: $name');
        return 0;
      case 'reset':
        final name = _requireValue(rest, 'Usage: instance reset <name>');
        await _instanceReset(profile, name, io);
        io.write('[OK] Reset instance: $name');
        return 0;
      case 'activate':
        final name = _requireValue(rest, 'Usage: instance activate <name>');
        _instanceActivate(profile, name);
        io.write('[OK] Active instance: $name');
        return 0;
      case 'path':
        final name = rest.isNotEmpty ? rest.first : _currentInstance(profile);
        if (name == null || name.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        if (!_instanceExists(profile, name)) {
          throw _NativeCommandException('Instance not found: $name', 2);
        }
        io.write(_instanceDir(profile, name));
        return 0;
      case 'port':
        return _dispatchInstancePort(profile, rest, io);
      case 'motd-style':
        _instanceStyleMotd(profile, rest.isEmpty ? null : rest.first);
        io.write('[OK] Styled MOTD updated');
        return 0;
      case 'delete-all':
        _instanceDeleteAll(profile, interactive: io.stream);
        io.write('[OK] Deleted all instances');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: instance <list|create|clone|delete|reset|activate|path|port|motd-style|current|delete-all>',
          2,
        );
    }
  }

  Future<int> _dispatchInstancePort(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    if (args.isEmpty) {
      final active = _currentInstance(profile);
      if (active == null) {
        throw _NativeCommandException('No active instance set', 2);
      }
      io.write('${_instanceGetServerPort(profile, active)}');
      return 0;
    }

    if (args.length == 1) {
      final one = args[0];
      if (_instanceExists(profile, one)) {
        io.write('${_instanceGetServerPort(profile, one)}');
        return 0;
      }

      if (_looksNumeric(one)) {
        final active = _currentInstance(profile);
        if (active == null) {
          throw _NativeCommandException('No active instance set', 2);
        }
        _instanceSetServerPort(profile, active, int.parse(one));
        io.write('[OK] Server port for $active set to $one');
        return 0;
      }

      throw _NativeCommandException('Instance not found: $one', 2);
    }

    if (args.length == 2) {
      final instance = args[0];
      final portText = args[1];
      if (!_instanceExists(profile, instance)) {
        throw _NativeCommandException('Instance not found: $instance', 2);
      }
      if (!_looksNumeric(portText)) {
        throw _NativeCommandException('Port must be numeric', 2);
      }
      _instanceSetServerPort(profile, instance, int.parse(portText));
      io.write('[OK] Server port for $instance set to $portText');
      return 0;
    }

    throw _NativeCommandException('Usage: instance port [instance] [port]', 2);
  }

  Future<int> _dispatchServer(List<String> args, _NativeIoBuffer io) async {
    if (args.isEmpty || args.first != 'create') {
      throw _NativeCommandException(
        'Usage: server create <name> [--type ...] [--jar ...] [--auto-build]',
        2,
      );
    }

    final rest = args.sublist(1);
    if (rest.isEmpty) {
      throw _NativeCommandException(
        'Usage: server create <name> [--type ...]',
        2,
      );
    }

    final name = rest.first;
    final options = _parseOptions(rest.sublist(1));

    final type = (options['type'] ?? 'purpur').toLowerCase();
    final jar = options['jar'];
    final profile = _activeConsumer;

    if (jar != null && jar.isNotEmpty) {
      _serverCreateFromJar(profile, name, type: type, jarPath: jar, io: io);
      io.write(
        '[OK] Server instance created: $name ($type, port ${_instanceGetServerPort(profile, name)})',
      );
      return 0;
    }

    final requestedMc = options['mc'];
    final mc = requestedMc?.trim().isNotEmpty == true
        ? requestedMc!
        : await _resolveLatestMcVersion(type);

    final jarPath = _findCachedJar(profile, type: type, mc: mc);
    if (jarPath == null) {
      throw _NativeCommandException(
        'No cached jar for $type mc=$mc in ${_buildDir(profile, type)}. Build/download a jar or use --jar <path>.',
        2,
      );
    }

    _serverCreateFromJar(profile, name, type: type, jarPath: jarPath, io: io);
    io.write(
      '[OK] Server instance created: $name ($type mc=$mc, port ${_instanceGetServerPort(profile, name)})',
    );
    return 0;
  }

  Future<int> _dispatchRuntime(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'status' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'start':
        final parsed = _parseRuntimeTargetArgs(rest, allowNoConsole: true);
        await _runtimeStart(profile, parsed.instance, io);
        if (!parsed.noConsole) {
          await _runtimeConsole(profile, parsed.instance, io);
        }
        return 0;
      case 'console':
        final parsed = _parseRuntimeTargetArgs(rest, allowNoConsole: false);
        await _runtimeConsole(profile, parsed.instance, io);
        return 0;
      case 'consoles':
      case 'console-all':
        await _runtimeConsoles(profile, io, layout: 'grid');
        return 0;
      case 'consoles-lateral':
      case 'console-lateral':
        await _runtimeConsoles(profile, io, layout: 'lateral');
        return 0;
      case 'stop':
        await _runtimeStop(profile, rest.isNotEmpty ? rest.first : null, io);
        return 0;
      case 'status':
        await _runtimeStatus(profile, rest.isNotEmpty ? rest.first : null, io);
        return 0;
      case 'list':
        for (final name in await _runtimeListRunning(profile)) {
          io.write(name);
        }
        return 0;
      case 'settings':
        return _dispatchRuntimeSettings(profile, rest, io);
      default:
        throw _NativeCommandException(
          'Usage: runtime <console|consoles|consoles-lateral|start|stop|status|list|settings> [instance|args] (start supports --instance/--no-console)',
          2,
        );
    }
  }

  Future<int> _dispatchRuntimeSettings(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final action = args.isEmpty ? 'show' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    var settings = _runtimeSettingsLoad(profile);

    switch (action) {
      case 'show':
        io.write('heap size:      ${settings.heap}');
        io.write('flags profile:  ${settings.profile}');
        io.write('jvm args:       ${settings.jvmArgs}');
        io.write('settings file:  ${_runtimeSettingsFile(profile)}');
        return 0;
      case 'presets':
        for (final preset in _runtimeSettingsPresets.keys) {
          io.write(preset);
        }
        return 0;
      case 'set-heap':
        if (rest.isEmpty || !_runtimeHeapLooksValid(rest.first)) {
          throw _NativeCommandException(
            'Heap must look like 2G, 4G, 8G, 12G...',
            2,
          );
        }
        settings = settings.copyWith(heap: rest.first.toUpperCase());
        _runtimeSettingsSave(profile, settings);
        io.write('[OK] Heap size set to: ${settings.heap}');
        return 0;
      case 'set-preset':
        if (rest.isEmpty) {
          throw _NativeCommandException(
            'Usage: runtime settings set-preset <aikar|vanilla|conservative>',
            2,
          );
        }
        final preset = rest.first.toLowerCase();
        final argsValue = _runtimeSettingsPresets[preset];
        if (argsValue == null) {
          throw _NativeCommandException(
            'Unknown JVM preset: $preset (expected: aikar|vanilla|conservative)',
            2,
          );
        }
        settings = settings.copyWith(profile: preset, jvmArgs: argsValue);
        _runtimeSettingsSave(profile, settings);
        io.write('[OK] JVM flag preset set to: ${settings.profile}');
        return 0;
      case 'reset':
        settings = const _RuntimeSettingsData();
        _runtimeSettingsSave(profile, settings);
        io.write('[OK] Runtime settings reset to defaults');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: runtime settings <show|presets|set-heap|set-preset|reset>',
          2,
        );
    }
  }

  Future<int> _dispatchPlugins(
    List<String> args,
    _NativeIoBuffer io, {
    required bool mods,
  }) async {
    final sub = args.isEmpty ? 'show-source' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'show-source':
        io.write(_dropinsSource(profile, mods: mods));
        return 0;
      case 'sync':
        var clean = false;
        var all = false;
        String? target;

        for (final arg in rest) {
          if (arg == '--clean') {
            clean = true;
            continue;
          }
          if (arg == '--all') {
            all = true;
            continue;
          }
          if (target == null) {
            target = arg;
            continue;
          }
          throw _NativeCommandException('Unknown plugins sync arg: $arg', 2);
        }

        if (all) {
          for (final instance in _instanceNames(profile)) {
            final report = _pluginsSyncInstance(
              profile,
              instance,
              clean: clean,
              sourceModsOverride: mods,
              strict: true,
            );
            io.write(
              '[OK] Copied ${report.copiedJars.length} jar(s) -> $instance',
            );
            if (report.copiedJars.isNotEmpty) {
              io.write('[INFO] Copied jars: ${report.copiedJars.join(', ')}');
            }
          }
          return 0;
        }

        target ??= _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        final report = _pluginsSyncInstance(
          profile,
          target,
          clean: clean,
          sourceModsOverride: mods,
          strict: true,
        );
        io.write('[OK] Copied ${report.copiedJars.length} jar(s) -> $target');
        if (report.copiedJars.isNotEmpty) {
          io.write('[INFO] Copied jars: ${report.copiedJars.join(', ')}');
        }
        return 0;
      case 'iris-packs-path':
        if (!_isPluginConsumer(profile)) {
          throw _NativeCommandException(
            'Iris packs are only used for plugin consumers',
            2,
          );
        }
        io.write(_irisSharedPacksDir(profile));
        return 0;
      case 'iris-packs-link':
        if (!_isPluginConsumer(profile)) {
          throw _NativeCommandException(
            'Iris packs are only used for plugin consumers',
            2,
          );
        }
        if (rest.isNotEmpty && rest.first == '--all') {
          for (final instance in _instanceNames(profile)) {
            _irisPacksLinkInstance(profile, instance);
            io.write('[OK] Iris packs linked: $instance');
          }
          return 0;
        }
        final target = rest.isNotEmpty ? rest.first : _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        _irisPacksLinkInstance(profile, target);
        io.write('[OK] Iris packs linked: $target');
        return 0;
      case 'watch-start':
        if (mods) {
          throw _NativeCommandException(
            'watch-start is only available for plugins',
            2,
          );
        }
        return _pluginsWatchStart(profile, io, mods: mods);
      case 'watch-stop':
        if (mods) {
          throw _NativeCommandException(
            'watch-stop is only available for plugins',
            2,
          );
        }
        return _pluginsWatchStop(profile, io, mods: mods);
      case 'watch-status':
        if (mods) {
          throw _NativeCommandException(
            'watch-status is only available for plugins',
            2,
          );
        }
        return _pluginsWatchStatus(profile, io, mods: mods);
      case 'watch-daemon':
        if (mods) {
          throw _NativeCommandException(
            'watch-daemon is only available for plugins',
            2,
          );
        }
        return _pluginsWatchDaemon(profile, io, mods: mods);
      default:
        throw _NativeCommandException(
          'Usage: plugins <show-source|sync|iris-packs-path|iris-packs-link|watch-start|watch-stop|watch-status>',
          2,
        );
    }
  }

  Future<int> _dispatchConfig(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'localize' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'localize':
        if (rest.isNotEmpty && rest.first == '--all') {
          for (final instance in _instanceNames(profile)) {
            _configLinkInstance(profile, instance);
            io.write('[OK] Config localized: $instance');
          }
          return 0;
        }

        final target = rest.isNotEmpty ? rest.first : _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        _configLinkInstance(profile, target);
        io.write('[OK] Config localized: $target');
        return 0;
      case 'status':
        final target = rest.isNotEmpty ? rest.first : _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        _configStatus(profile, target, io);
        return 0;
      default:
        throw _NativeCommandException('Usage: config <localize|status>', 2);
    }
  }

  Future<int> _dispatchBuild(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'list':
        for (final type in _allBuildTypes) {
          final latest = _buildLatestJarPath(profile, type);
          if (latest == null) {
            io.write('$type: (not built)');
          } else {
            io.write('$type: $latest');
          }
        }
        return 0;
      case 'list-all':
        final target = rest.isEmpty ? 'all' : rest.first;
        await _buildListAll(profile, target, io);
        return 0;
      case 'latest':
        if (rest.isEmpty) {
          throw _NativeCommandException(
            'Usage: build latest <paper|purpur|folia|canvas|forge|fabric|neoforge|spigot>',
            2,
          );
        }
        final version = await _resolveLatestMcVersion(rest.first);
        io.write(version);
        return 0;
      case 'versions':
        final target = rest.isEmpty ? 'all' : rest.first;
        await _buildVersions(profile, target, io);
        return 0;
      case 'test-latest':
        final testOptions = _parseOptions(rest);
        await _buildTestLatest(profile, testOptions, io);
        return 0;
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'spigot':
      case 'forge':
      case 'fabric':
      case 'neoforge':
        final buildOptions = _parseOptions(rest);
        await _buildTarget(profile, sub, buildOptions, io);
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: build <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge|latest|list|list-all|versions|test-latest>',
          2,
        );
    }
  }

  Future<int> _dispatchRepos(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'sync' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'sync':
        final target = rest.isEmpty ? 'all' : rest.first;
        await _reposSync(profile, target, io);
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: repos sync [all|paper|purpur|folia|canvas]',
          2,
        );
    }
  }

  Future<void> _reposSync(
    ConsumerProfile profile,
    String target,
    _NativeIoBuffer io,
  ) async {
    final types = switch (target) {
      'all' => const <String>['paper', 'purpur', 'folia', 'canvas'],
      'paper' || 'purpur' || 'folia' || 'canvas' => <String>[target],
      _ => throw _NativeCommandException(
        'Usage: repos sync [all|paper|purpur|folia|canvas]',
        2,
      ),
    };

    for (final type in types) {
      final url = _repoUrl(type);
      final dir = _repoDir(profile, type);
      final gitDir = Directory(p.join(dir, '.git'));

      if (gitDir.existsSync()) {
        io.write('[INFO] Updating repo: $type');
        await _runAndRequireSuccess(
          'git',
          <String>['-C', dir, 'fetch', '--all', '--prune'],
          'Repo fetch failed: $type',
          io,
        );
        final pullResult = await _runProcess('git', <String>[
          '-C',
          dir,
          'pull',
          '--ff-only',
        ]);
        if (pullResult.exitCode != 0) {
          io.write(
            '[WARN] git pull was not ff-only for $type. Keeping local state.',
          );
        }
      } else {
        io.write('[INFO] Cloning repo: $type');
        await _runAndRequireSuccess(
          'git',
          <String>['clone', url, dir],
          'Repo clone failed: $type',
          io,
        );
      }

      io.write('[OK] Repo ready: $type -> $dir');
    }
  }

  Future<int> _pluginsWatchStart(
    ConsumerProfile profile,
    _NativeIoBuffer io, {
    required bool mods,
  }) async {
    final logFilePath = _pluginsWatchLogFile(profile, mods: mods);
    final commandName = mods ? 'mods' : 'plugins';
    final session = _pluginsWatchSessionName(profile, mods: mods);

    if (!await _tmuxInstalled()) {
      throw _NativeCommandException(
        'tmux is required for watcher start/stop/status. Install tmux and retry.',
        2,
      );
    }

    if (await _tmuxSessionExists(session)) {
      io.write(
        '[WARN] ${mods ? 'Mods' : 'Plugins'} watcher already running (session $session)',
      );
      io.write('[INFO] Log: $logFilePath');
      return 0;
    }

    File(logFilePath).createSync(recursive: true);
    final daemonCommand = _selfInvocationCommand(
      profile: profile,
      args: <String>[commandName, 'watch-daemon'],
    );

    final result = await _runProcess('tmux', <String>[
      'new-session',
      '-d',
      '-s',
      session,
      'sh -lc ${_shellQuote('cd ${_shellQuote(context.rootDir)} && $daemonCommand')}',
    ]);
    if (result.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to start ${mods ? 'mods' : 'plugins'} watcher: ${result.stderr}',
        1,
      );
    }

    var alive = false;
    for (var i = 0; i < 20; i++) {
      if (await _tmuxSessionExists(session)) {
        alive = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!alive) {
      throw _NativeCommandException(
        'Watcher failed to stay running (session did not persist)',
        1,
      );
    }

    io.write('[OK] ${mods ? 'Mods' : 'Plugins'} watcher started');
    io.write('[INFO] tmux session: $session');
    io.write('[INFO] Log: $logFilePath');
    return 0;
  }

  Future<int> _pluginsWatchStop(
    ConsumerProfile profile,
    _NativeIoBuffer io, {
    required bool mods,
  }) async {
    final session = _pluginsWatchSessionName(profile, mods: mods);
    if (!await _tmuxSessionExists(session)) {
      io.write('[WARN] ${mods ? 'Mods' : 'Plugins'} watcher is not running');
      return 0;
    }

    final result = await _runProcess('tmux', <String>[
      'kill-session',
      '-t',
      session,
    ]);
    if (result.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to stop watcher session $session: ${result.stderr}',
        1,
      );
    }

    io.write('[OK] ${mods ? 'Mods' : 'Plugins'} watcher stopped');
    return 0;
  }

  Future<int> _pluginsWatchStatus(
    ConsumerProfile profile,
    _NativeIoBuffer io, {
    required bool mods,
  }) async {
    final logFilePath = _pluginsWatchLogFile(profile, mods: mods);
    final source = _dropinsSource(profile, mods: mods);
    final session = _pluginsWatchSessionName(profile, mods: mods);
    final running = await _tmuxSessionExists(session);

    io.write('watch:   ${running ? 'running' : 'stopped'}');
    io.write('session: ${running ? session : 'none'}');
    io.write('source:  $source');
    io.write('log:     $logFilePath');
    return 0;
  }

  Future<int> _pluginsWatchDaemon(
    ConsumerProfile profile,
    _NativeIoBuffer io, {
    required bool mods,
  }) async {
    final pidFilePath = _pluginsWatchPidFile(profile, mods: mods);
    File(pidFilePath)
      ..createSync(recursive: true)
      ..writeAsStringSync('$pid\n');

    final source = _dropinsSource(profile, mods: mods);
    final sourceDir = Directory(source)..createSync(recursive: true);
    io.write(
      '[INFO] ${mods ? 'Mods' : 'Plugins'} watcher daemon started (pid $pid)',
    );
    io.write('[INFO] Watching: $source');

    Future<void> syncAll() async {
      final instances = _instanceNames(profile);
      if (instances.isEmpty) {
        io.write('[INFO] No instances available for watcher sync');
        return;
      }

      for (final instance in instances) {
        try {
          final report = _pluginsSyncInstance(
            profile,
            instance,
            clean: false,
            sourceModsOverride: mods,
            strict: false,
          );
          if (report.copiedJars.isNotEmpty) {
            io.write(
              '[SYNC] $instance copied ${report.copiedJars.length} jar(s): ${report.copiedJars.join(', ')}',
            );
            await _announceDropinSync(
              profile,
              instance,
              report.copiedJars.length,
            );
          }
          if (report.failedJars.isNotEmpty) {
            for (final failed in report.failedJars) {
              io.error('[WARN] Watch sync failed for $instance: $failed');
            }
          }
        } catch (e, st) {
          io.error('[WARN] Watch sync failed for $instance: $e');
          if (context.verbose) {
            io.error('$st');
          }
        }
      }
    }

    Future<void> syncChangedJar(String sourceJarPath) async {
      final instances = _instanceNames(profile);
      if (instances.isEmpty) {
        return;
      }

      for (final instance in instances) {
        try {
          final report = _pluginsSyncOneJarToInstance(
            profile,
            instance,
            sourceJarPath,
            strict: false,
          );
          if (report.copiedJars.isNotEmpty) {
            io.write('[SYNC] $instance copied ${report.copiedJars.join(', ')}');
            await _announceDropinSync(
              profile,
              instance,
              report.copiedJars.length,
            );
          }
          if (report.failedJars.isNotEmpty) {
            for (final failed in report.failedJars) {
              io.error('[WARN] Watch sync failed for $instance: $failed');
            }
          }
        } catch (e, st) {
          io.error('[WARN] Watch sync failed for $instance: $e');
          if (context.verbose) {
            io.error('$st');
          }
        }
      }
    }

    await syncAll();

    final lastSyncedFingerprintByPath = <String, String>{};
    for (final entity in sourceDir.listSync(recursive: false)) {
      if (entity is! File) {
        continue;
      }
      final path = p.normalize(entity.path);
      if (!path.toLowerCase().endsWith('.jar')) {
        continue;
      }
      final stat = entity.statSync();
      lastSyncedFingerprintByPath[path] =
          '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }

    var syncing = false;
    final pendingJarPaths = <String>{};
    final changedJarPaths = <String>{};
    Timer? debounce;
    String? jarFingerprint(String path) {
      final file = File(path);
      if (!file.existsSync()) {
        return null;
      }
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }
      return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }

    Future<void> requestSync({Iterable<String>? jarPaths}) async {
      if (jarPaths != null) {
        for (final path in jarPaths) {
          final normalized = p.normalize(path.trim());
          if (normalized.isEmpty) {
            continue;
          }
          pendingJarPaths.add(normalized);
        }
      }
      if (syncing) {
        return;
      }

      syncing = true;
      try {
        while (pendingJarPaths.isNotEmpty) {
          final jarBatch = pendingJarPaths.toList(growable: false);
          pendingJarPaths.clear();

          for (final path in jarBatch) {
            final currentFingerprint = jarFingerprint(path);
            if (currentFingerprint == null) {
              continue;
            }
            final previousFingerprint = lastSyncedFingerprintByPath[path];
            if (previousFingerprint == currentFingerprint) {
              continue;
            }
            await syncChangedJar(path);
            final afterFingerprint = jarFingerprint(path);
            if (afterFingerprint != null) {
              lastSyncedFingerprintByPath[path] = afterFingerprint;
            }
          }
        }
      } finally {
        syncing = false;
      }
    }

    final stop = Completer<void>();
    void requestStop() {
      if (!stop.isCompleted) {
        stop.complete();
      }
    }

    final watchSub = sourceDir.watch(recursive: false).listen((event) {
      if (event.isDirectory) {
        return;
      }
      final path = p.normalize(event.path);
      if (!path.toLowerCase().endsWith('.jar')) {
        return;
      }
      if (event.type == FileSystemEvent.delete) {
        return;
      }
      changedJarPaths.add(path);
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 350), () {
        final batch = changedJarPaths.toList(growable: false);
        changedJarPaths.clear();
        unawaited(requestSync(jarPaths: batch));
      });
    });

    StreamSubscription<ProcessSignal>? sigintSub;
    StreamSubscription<ProcessSignal>? sigtermSub;
    StreamSubscription<ProcessSignal>? sighupSub;
    if (!Platform.isWindows) {
      sigintSub = ProcessSignal.sigint.watch().listen((_) => requestStop());
      sigtermSub = ProcessSignal.sigterm.watch().listen((_) => requestStop());
      sighupSub = ProcessSignal.sighup.watch().listen((_) => requestStop());
    }

    await stop.future;

    debounce?.cancel();
    await watchSub.cancel();
    await sigintSub?.cancel();
    await sigtermSub?.cancel();
    await sighupSub?.cancel();
    File(pidFilePath).deleteSyncSafe();
    io.write('[INFO] ${mods ? 'Mods' : 'Plugins'} watcher daemon stopped');
    return 0;
  }

  Future<void> _buildTestLatest(
    ConsumerProfile profile,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    final targets = <String>['paper', 'purpur', 'folia', 'canvas'];
    final failures = <String>[];

    for (final type in targets) {
      try {
        await _buildTarget(profile, type, const <String, String>{}, io);
      } catch (e) {
        failures.add('$type: $e');
      }
    }

    final spigotMc = options['spigot-mc']?.trim();
    if (spigotMc != null && spigotMc.isNotEmpty) {
      try {
        await _buildTarget(profile, 'spigot', <String, String>{
          'mc': spigotMc,
        }, io);
      } catch (e) {
        failures.add('spigot: $e');
      }
    }

    if (failures.isNotEmpty) {
      throw _NativeCommandException(
        'test-latest completed with failures:\n${failures.join('\n')}',
        1,
      );
    }
  }

  Future<void> _buildTarget(
    ConsumerProfile profile,
    String type,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    final normalized = type.toLowerCase();
    final requestedMc = options['mc']?.trim();
    final mc = requestedMc != null && requestedMc.isNotEmpty
        ? requestedMc
        : await _resolveLatestMcVersion(normalized);

    switch (normalized) {
      case 'paper':
      case 'folia':
        await _buildDownloadPaperLike(profile, normalized, mc, io);
        return;
      case 'purpur':
        await _buildDownloadPurpur(profile, mc, io);
        return;
      case 'canvas':
        await _buildDownloadCanvas(profile, mc, io);
        return;
      case 'fabric':
        await _buildDownloadFabric(
          profile,
          mc,
          options['loader']?.trim(),
          options['installer']?.trim(),
          io,
        );
        return;
      case 'forge':
        await _buildDownloadForge(profile, mc, options['loader']?.trim(), io);
        return;
      case 'neoforge':
        await _buildDownloadNeoForge(
          profile,
          mc,
          options['loader']?.trim(),
          io,
        );
        return;
      case 'spigot':
        await _buildWithBuildTools(profile, mc, io);
        return;
      default:
        throw _NativeCommandException('Unknown build target: $type', 2);
    }
  }

  Future<void> _buildDownloadPaperLike(
    ConsumerProfile profile,
    String type,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final buildsUrl =
        'https://api.papermc.io/v2/projects/$type/versions/$mc/builds';
    final json = await _httpGetJsonObject(buildsUrl);
    final buildsRaw = json['builds'];
    if (buildsRaw is! List) {
      throw _NativeCommandException(
        'Unexpected $type builds payload for $mc',
        1,
      );
    }

    var bestBuild = -1;
    String? artifactName;
    for (final raw in buildsRaw) {
      if (raw is! Map) {
        continue;
      }
      final build = raw['build'];
      final downloads = raw['downloads'];
      if (build is! num || downloads is! Map) {
        continue;
      }
      final app = downloads['application'];
      if (app is! Map) {
        continue;
      }
      final name = app['name'];
      if (name is! String || name.trim().isEmpty) {
        continue;
      }
      if (build.toInt() > bestBuild) {
        bestBuild = build.toInt();
        artifactName = name.trim();
      }
    }

    if (bestBuild <= 0 || artifactName == null) {
      throw _NativeCommandException(
        'No downloadable $type build found for mc=$mc',
        1,
      );
    }

    final downloadUrl =
        'https://api.papermc.io/v2/projects/$type/versions/$mc/builds/$bestBuild/downloads/$artifactName';
    final output = p.join(_buildDir(profile, type), '$type-$mc-$bestBuild.jar');
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, type, output);
    io.write('[OK] Cached $type build $bestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildDownloadPurpur(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final meta = await _httpGetJsonObject(
      'https://api.purpurmc.org/v2/purpur/$mc',
    );
    final builds = meta['builds'];
    int? latestBuild;
    if (builds is Map && builds['latest'] != null) {
      latestBuild = int.tryParse(builds['latest'].toString());
    }
    if (latestBuild == null || latestBuild <= 0) {
      throw _NativeCommandException(
        'Could not resolve latest Purpur build for mc=$mc',
        1,
      );
    }

    final downloadUrl =
        'https://api.purpurmc.org/v2/purpur/$mc/$latestBuild/download';
    final output = p.join(
      _buildDir(profile, 'purpur'),
      'purpur-$mc-$latestBuild.jar',
    );
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, 'purpur', output);
    io.write('[OK] Cached purpur build $latestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildDownloadCanvas(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final payload = await _httpGetJsonObject(
      'https://canvasmc.io/api/v2/builds/all?minecraft_version=$mc',
    );
    final builds = payload['builds'];
    if (builds is! List || builds.isEmpty) {
      throw _NativeCommandException('No Canvas builds available for mc=$mc', 1);
    }

    Map<String, dynamic>? selected;
    for (final raw in builds) {
      if (raw is! Map) {
        continue;
      }
      final candidate = Map<String, dynamic>.from(raw);
      final experimental = candidate['isExperimental'] == true;
      if (!experimental) {
        selected = candidate;
        break;
      }
      selected ??= candidate;
    }
    if (selected == null) {
      throw _NativeCommandException(
        'No downloadable Canvas build found for mc=$mc',
        1,
      );
    }

    final downloadUrl = selected['downloadUrl']?.toString().trim();
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw _NativeCommandException(
        'Canvas API returned empty download URL',
        1,
      );
    }
    final buildNumber = selected['buildNumber']?.toString().trim() ?? 'unknown';
    final channel =
        selected['channelVersion']?.toString().trim().isNotEmpty == true
        ? selected['channelVersion'].toString().trim()
        : mc;
    final output = p.join(
      _buildDir(profile, 'canvas'),
      'canvas-$channel-$buildNumber.jar',
    );
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, 'canvas', output);
    io.write('[OK] Cached canvas build $buildNumber for mc=$channel');
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildDownloadFabric(
    ConsumerProfile profile,
    String mc,
    String? loaderInput,
    String? installerInput,
    _NativeIoBuffer io,
  ) async {
    final loader = loaderInput != null && loaderInput.isNotEmpty
        ? loaderInput
        : await _resolveLatestFabricLoader(mc);
    final installer = installerInput != null && installerInput.isNotEmpty
        ? installerInput
        : await _resolveLatestFabricInstaller();

    final downloadUrl =
        'https://meta.fabricmc.net/v2/versions/loader/$mc/$loader/$installer/server/jar';
    final output = p.join(
      _buildDir(profile, 'fabric'),
      'fabric-$mc-loader.$loader-installer.$installer.jar',
    );
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, 'fabric', output);
    io.write(
      '[OK] Cached fabric server launcher for mc=$mc loader=$loader installer=$installer',
    );
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildDownloadForge(
    ConsumerProfile profile,
    String mc,
    String? loaderInput,
    _NativeIoBuffer io,
  ) async {
    final loader = loaderInput != null && loaderInput.isNotEmpty
        ? loaderInput
        : await _resolveLatestForgeLoader(mc);
    final full = '$mc-$loader';
    final downloadUrl =
        'https://maven.minecraftforge.net/net/minecraftforge/forge/$full/forge-$full-installer.jar';
    final output = p.join(
      _buildDir(profile, 'forge'),
      'forge-$full-installer.jar',
    );
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, 'forge', output);
    io.write('[OK] Cached forge installer for mc=$mc loader=$loader');
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildDownloadNeoForge(
    ConsumerProfile profile,
    String mc,
    String? loaderInput,
    _NativeIoBuffer io,
  ) async {
    final loader = loaderInput != null && loaderInput.isNotEmpty
        ? loaderInput
        : await _resolveLatestNeoForgeLoader(mc);
    final downloadUrl =
        'https://maven.neoforged.net/releases/net/neoforged/neoforge/$loader/neoforge-$loader-installer.jar';
    final output = p.join(
      _buildDir(profile, 'neoforge'),
      'neoforge-$loader-installer.jar',
    );
    await _downloadToFile(downloadUrl, output);
    _registerBuiltJar(profile, 'neoforge', output);
    io.write('[OK] Cached neoforge installer for loader=$loader');
    io.write('[INFO] Jar: $output');
  }

  Future<void> _buildWithBuildTools(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final buildDir = _buildDir(profile, 'spigot');
    final toolsDir = p.join(buildDir, 'tools');
    Directory(buildDir).createSync(recursive: true);
    Directory(toolsDir).createSync(recursive: true);

    final buildToolsUrl =
        Platform.environment['SPIGOT_BUILDTOOLS_URL']?.trim().isNotEmpty == true
        ? Platform.environment['SPIGOT_BUILDTOOLS_URL']!.trim()
        : 'https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar';
    final buildToolsJar = p.join(toolsDir, 'BuildTools.jar');
    if (!File(buildToolsJar).existsSync()) {
      io.write('[INFO] Downloading BuildTools.jar');
      await _downloadToFile(buildToolsUrl, buildToolsJar);
    }

    final workDir = p.join(
      buildDir,
      'work-$mc-${DateTime.now().millisecondsSinceEpoch}',
    );
    Directory(workDir).createSync(recursive: true);

    io.write(
      '[INFO] Running BuildTools for Spigot mc=$mc (this can take a while)',
    );
    final result = await Process.run(
      'java',
      <String>['-jar', buildToolsJar, '--rev', mc, '--compile', 'SPIGOT'],
      workingDirectory: workDir,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw _NativeCommandException(
        'BuildTools failed for mc=$mc: ${result.stderr}',
        1,
      );
    }

    final builtJars =
        Directory(workDir)
            .listSync(recursive: false, followLinks: false)
            .whereType<File>()
            .where(
              (f) => RegExp(r'^spigot-.*\.jar$').hasMatch(p.basename(f.path)),
            )
            .toList(growable: false)
          ..sort(
            (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
          );
    if (builtJars.isEmpty) {
      throw _NativeCommandException(
        'BuildTools completed but no spigot-*.jar was produced',
        1,
      );
    }

    final newest = builtJars.last;
    final output = p.join(buildDir, 'spigot-$mc.jar');
    newest.copySync(output);
    _registerBuiltJar(profile, 'spigot', output);
    io.write('[OK] Cached spigot server jar for mc=$mc');
    io.write('[INFO] Jar: $output');
  }

  Future<String> _resolveLatestFabricLoader(String mc) async {
    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/loader/$mc',
    );
    if (payload.isEmpty || payload.first is! Map) {
      throw _NativeCommandException(
        'Could not resolve Fabric loader for mc=$mc',
        1,
      );
    }
    final first = Map<String, dynamic>.from(payload.first as Map);
    final loader = first['loader'];
    if (loader is! Map || loader['version'] == null) {
      throw _NativeCommandException(
        'Fabric loader payload missing version for mc=$mc',
        1,
      );
    }
    return loader['version'].toString().trim();
  }

  Future<String> _resolveLatestFabricInstaller() async {
    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/installer',
    );
    if (payload.isEmpty || payload.first is! Map) {
      throw _NativeCommandException('Could not resolve Fabric installer', 1);
    }
    final first = Map<String, dynamic>.from(payload.first as Map);
    final version = first['version']?.toString().trim() ?? '';
    if (version.isEmpty) {
      throw _NativeCommandException(
        'Fabric installer payload missing version',
        1,
      );
    }
    return version;
  }

  Future<String> _resolveLatestForgeLoader(String mc) async {
    try {
      final promotions = await _httpGetJsonObject(
        'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json',
      );
      final promosRaw = promotions['promos'];
      if (promosRaw is Map) {
        final promos = Map<String, dynamic>.from(promosRaw);
        for (final key in <String>['$mc-recommended', '$mc-latest']) {
          final value = promos[key]?.toString().trim() ?? '';
          if (value.isNotEmpty) {
            return value;
          }
        }
      }
    } catch (_) {}

    final metadata = await _httpGetText(
      'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml',
    );
    final versions = RegExp(r'<version>([^<]+)</version>')
        .allMatches(metadata)
        .map((m) => m.group(1)!.trim())
        .toList(growable: false);
    final matches = versions
        .where((v) => v.startsWith('$mc-'))
        .toList(growable: false);
    if (matches.isEmpty) {
      throw _NativeCommandException(
        'Could not resolve Forge loader for mc=$mc',
        1,
      );
    }
    final full = matches.last;
    return full.substring('$mc-'.length);
  }

  Future<String> _resolveLatestNeoForgeLoader(String mc) async {
    final key = mc.startsWith('1.') ? mc.substring(2) : mc;
    final metadata = await _httpGetText(
      'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml',
    );
    final versions = RegExp(r'<version>([^<]+)</version>')
        .allMatches(metadata)
        .map((m) => m.group(1)!.trim())
        .toList(growable: false);
    final matches = versions
        .where((v) => v.startsWith('$key.') || v.startsWith('$key-'))
        .toList(growable: false);
    if (matches.isEmpty) {
      throw _NativeCommandException(
        'Could not resolve NeoForge loader for mc=$mc',
        1,
      );
    }
    return matches.last;
  }

  Future<Map<String, dynamic>> _httpGetJsonObject(String url) async {
    final text = await _httpGetText(url);
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw _NativeCommandException('Expected JSON object from $url', 1);
  }

  Future<List<dynamic>> _httpGetJsonList(String url) async {
    final text = await _httpGetText(url);
    final decoded = jsonDecode(text);
    if (decoded is List<dynamic>) {
      return decoded;
    }
    if (decoded is List) {
      return List<dynamic>.from(decoded);
    }
    throw _NativeCommandException('Expected JSON list from $url', 1);
  }

  Future<String> _httpGetText(String url) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, 'multiplexor/0.2.0');
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          throw _NativeCommandException(
            'HTTP ${response.statusCode} from $url${body.trim().isEmpty ? '' : ': ${body.trim()}'}',
            1,
          );
        }
        return await response.transform(utf8.decoder).join();
      } on _NativeCommandException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
          continue;
        }
      } finally {
        client.close(force: true);
      }
    }
    throw _NativeCommandException('Request failed for $url: $lastError', 1);
  }

  Future<void> _downloadToFile(String url, String outputPath) async {
    final out = File(outputPath);
    out.parent.createSync(recursive: true);
    Object? lastError;

    for (var attempt = 1; attempt <= 3; attempt++) {
      final tmp = File('$outputPath.part');
      tmp.deleteSyncSafe();
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, 'multiplexor/0.2.0');
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.transform(utf8.decoder).join();
          throw _NativeCommandException(
            'Failed download from $url (HTTP ${response.statusCode})${body.trim().isEmpty ? '' : ': ${body.trim()}'}',
            1,
          );
        }

        final sink = tmp.openWrite(mode: FileMode.writeOnly);
        await response.listen((chunk) => sink.add(chunk)).asFuture<void>();
        await sink.flush();
        await sink.close();
        if (out.existsSync()) {
          out.deleteSync();
        }
        tmp.renameSync(out.path);
        return;
      } on _NativeCommandException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
          continue;
        }
      } finally {
        client.close(force: true);
        tmp.deleteSyncSafe();
      }
    }
    throw _NativeCommandException('Download failed for $url: $lastError', 1);
  }

  void _registerBuiltJar(ConsumerProfile profile, String type, String jarPath) {
    final absolute = File(jarPath).absolute.path;
    final latest = p.join(_buildDir(profile, type), 'latest.jar');
    try {
      _replaceWithSymlink(latest, absolute);
    } catch (_) {
      File(latest).deleteSyncSafe();
      File(absolute).copySync(latest);
    }
  }

  Future<void> _buildListAll(
    ConsumerProfile profile,
    String target,
    _NativeIoBuffer io,
  ) async {
    if (target == 'all') {
      for (var i = 0; i < _allBuildTypes.length; i++) {
        await _buildListAll(profile, _allBuildTypes[i], io);
        if (i != _allBuildTypes.length - 1) {
          io.write('');
        }
      }
      return;
    }

    if (!_allBuildTypes.contains(target)) {
      throw _NativeCommandException(
        'Usage: build list-all [paper|purpur|spigot|folia|canvas|forge|fabric|neoforge]',
        2,
      );
    }

    io.write('$target builds:');
    final dir = Directory(_buildDir(profile, target));
    if (!dir.existsSync()) {
      io.write('  (none)');
      return;
    }

    final jars =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jar'))
            .map((f) => f.path)
            .toList(growable: false)
          ..sort();

    if (jars.isEmpty) {
      io.write('  (none)');
      return;
    }

    for (final jar in jars.reversed) {
      io.write('  $jar');
    }
  }

  Future<void> _buildVersions(
    ConsumerProfile profile,
    String target,
    _NativeIoBuffer io,
  ) async {
    if (target == 'all') {
      for (final type in const <String>['paper', 'purpur', 'folia', 'canvas']) {
        await _buildVersions(profile, type, io);
        io.write('');
      }
      io.write(
        'forge/fabric/neoforge/spigot versions are resolved dynamically at runtime.',
      );
      return;
    }

    if (<String>{'paper', 'purpur', 'folia', 'canvas'}.contains(target)) {
      io.write('$target stable versions (origin/ver/*):');
      final versions = await _repoStableVersions(profile, target);
      if (versions.isEmpty) {
        io.write('  (none: run repos sync $target)');
      } else {
        for (final version in versions) {
          io.write('  - $version');
        }
      }
      return;
    }

    io.write('$target versions are resolved dynamically.');
  }

  Future<String> _resolveLatestMcVersion(String type) async {
    final normalized = type.toLowerCase();
    final profile = _activeConsumer;

    if (<String>{'paper', 'purpur', 'folia', 'canvas'}.contains(normalized)) {
      final stable = await _repoLatestStableVersion(profile, normalized);
      if (stable != null && stable.isNotEmpty) {
        return stable;
      }
    }

    final latestRelease = await _latestMinecraftRelease();
    if (latestRelease.isNotEmpty) {
      return latestRelease;
    }

    throw _NativeCommandException(
      'Could not resolve latest Minecraft version for $type',
      2,
    );
  }

  Future<String> _latestMinecraftRelease() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json',
        ),
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      final payload = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return '';
      }
      final latest = decoded['latest'];
      if (latest is! Map<String, dynamic>) {
        return '';
      }
      final release = latest['release'];
      if (release is String && release.trim().isNotEmpty) {
        return release.trim();
      }
      return '';
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> _repoStableVersions(
    ConsumerProfile profile,
    String type,
  ) async {
    final repoDir = _repoDir(profile, type);
    final gitDir = Directory(p.join(repoDir, '.git'));
    if (!gitDir.existsSync()) {
      return const <String>[];
    }

    final result = await _runProcess('git', <String>[
      '-C',
      repoDir,
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/remotes/origin/ver',
    ]);

    if (result.exitCode != 0) {
      return const <String>[];
    }

    final stdoutText = result.stdout.toString();
    final versions =
        stdoutText
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.startsWith('origin/ver/'))
            .map((line) => line.substring('origin/ver/'.length))
            .where((line) => RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(line))
            .toSet()
            .toList(growable: false)
          ..sort(_compareVersions);

    return versions;
  }

  Future<String?> _repoLatestStableVersion(
    ConsumerProfile profile,
    String type,
  ) async {
    final versions = await _repoStableVersions(profile, type);
    if (versions.isEmpty) {
      return null;
    }
    return versions.last;
  }

  int _compareVersions(String a, String b) {
    final av = _Version.parse(a);
    final bv = _Version.parse(b);
    return av.compareTo(bv);
  }

  Map<String, String> _parseOptions(List<String> args) {
    final options = <String, String>{};

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];

      if (!arg.startsWith('--')) {
        throw _NativeCommandException('Unknown argument: $arg', 2);
      }

      final key = arg.substring(2);
      if (key == 'auto-build') {
        options['auto-build'] = 'true';
        continue;
      }

      if (i + 1 >= args.length) {
        throw _NativeCommandException('Missing value for --$key', 2);
      }

      final value = args[i + 1].trim();
      options[key] = value;
      i++;
    }

    return options;
  }

  _RuntimeTargetArgs _parseRuntimeTargetArgs(
    List<String> args, {
    required bool allowNoConsole,
  }) {
    String? instance;
    var noConsole = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i].trim();
      if (arg.isEmpty) {
        continue;
      }

      if (arg == '--no-console') {
        if (!allowNoConsole) {
          throw _NativeCommandException('Unknown runtime arg: $arg', 2);
        }
        noConsole = true;
        continue;
      }

      if (arg == '--instance') {
        if (i + 1 >= args.length) {
          throw _NativeCommandException('Missing value for --instance', 2);
        }
        final value = args[i + 1].trim();
        if (value.isEmpty) {
          throw _NativeCommandException('Missing value for --instance', 2);
        }
        instance = value;
        i++;
        continue;
      }

      if (arg.startsWith('--instance=')) {
        final value = arg.substring('--instance='.length).trim();
        if (value.isEmpty) {
          throw _NativeCommandException('Missing value for --instance', 2);
        }
        instance = value;
        continue;
      }

      if (arg.startsWith('--')) {
        throw _NativeCommandException('Unknown runtime arg: $arg', 2);
      }

      if (instance != null) {
        throw _NativeCommandException('Unknown runtime arg: $arg', 2);
      }
      instance = arg;
    }

    return _RuntimeTargetArgs(instance: instance, noConsole: noConsole);
  }

  void _serverCreateFromJar(
    ConsumerProfile profile,
    String name, {
    required String type,
    required String jarPath,
    _NativeIoBuffer? io,
  }) {
    if (name.trim().isEmpty) {
      throw _NativeCommandException('Server name required', 2);
    }

    final jarFile = File(jarPath);
    if (!jarFile.existsSync()) {
      throw _NativeCommandException('Jar not found: $jarPath', 2);
    }
    var resolvedJarPath = jarFile.absolute.path;
    try {
      resolvedJarPath = jarFile.resolveSymbolicLinksSync();
    } catch (_) {}

    _instanceCreateBlank(profile, name, io: io);

    final normalizedType = type.toLowerCase().trim();
    final installerBased =
        (normalizedType == 'forge' || normalizedType == 'neoforge') &&
        _looksLikeInstallerJar(resolvedJarPath);
    if (installerBased) {
      _serverCreateFromInstaller(
        profile,
        name,
        normalizedType,
        resolvedJarPath,
      );
      _instanceApplyStyledMotd(profile, name, force: true);
      return;
    }

    final instanceDir = _instanceDir(profile, name);
    final serverJar = p.join(instanceDir, 'server.jar');
    _replaceWithSymlink(serverJar, resolvedJarPath);

    File(p.join(instanceDir, '.server-source')).writeAsStringSync(
      ['type=$normalizedType', 'launch=jar', 'jar=$resolvedJarPath'].join('\n'),
    );
    _instanceApplyStyledMotd(profile, name, force: true);
  }

  bool _looksLikeInstallerJar(String path) {
    final paths = <String>{path};
    try {
      paths.add(File(path).resolveSymbolicLinksSync());
    } catch (_) {}

    for (final candidate in paths) {
      final lower = p.basename(candidate).toLowerCase();
      if (lower.contains('installer') && lower.endsWith('.jar')) {
        return true;
      }
    }
    return false;
  }

  void _serverCreateFromInstaller(
    ConsumerProfile profile,
    String instance,
    String type,
    String installerJarPath,
  ) {
    final instanceDir = _instanceDir(profile, instance);
    final localInstaller = p.join(instanceDir, 'installer.jar');
    _replaceWithSymlink(localInstaller, File(installerJarPath).absolute.path);

    final result = Process.runSync(
      'java',
      <String>['-jar', localInstaller, '--installServer', '.'],
      workingDirectory: instanceDir,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to install $type server in $instance: ${result.stderr}',
        1,
      );
    }

    final argsRel = _findInstalledServerArgsFile(instanceDir);
    if (argsRel == null) {
      throw _NativeCommandException(
        'Installer completed but no unix_args.txt was found for $instance',
        1,
      );
    }

    File(p.join(instanceDir, '.server-source')).writeAsStringSync(
      [
        'type=$type',
        'launch=argsfile',
        'args_file_rel=$argsRel',
        'installer=${File(installerJarPath).absolute.path}',
      ].join('\n'),
    );
  }

  String? _findInstalledServerArgsFile(String instanceDir) {
    final runSh = File(p.join(instanceDir, 'run.sh'));
    if (runSh.existsSync()) {
      final text = runSh.readAsStringSync();
      final match = RegExp(r"""@([^\s"'`]*unix_args\.txt)""").firstMatch(text);
      if (match != null) {
        final candidate = match.group(1);
        if (candidate != null && candidate.trim().isNotEmpty) {
          final normalized = candidate.trim();
          final candidatePath = p.join(instanceDir, normalized);
          if (File(candidatePath).existsSync()) {
            return normalized;
          }
        }
      }
    }

    final candidates = <String>[];
    for (final entity in Directory(
      instanceDir,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (p.basename(entity.path) == 'unix_args.txt') {
        candidates.add(p.relative(entity.path, from: instanceDir));
      }
    }
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => a.length.compareTo(b.length));
    return candidates.first;
  }

  Future<void> _runtimeStart(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    final instance = inputInstance?.trim().isNotEmpty == true
        ? inputInstance!.trim()
        : _currentInstance(profile);

    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }

    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    _instanceEnsureSharedPluginOps(profile, instance, io: io);

    if (!await _tmuxInstalled()) {
      throw _NativeCommandException(
        'tmux is required for runtime start/console. Install tmux and retry.',
        2,
      );
    }

    await _runtimeEnsureDropinsWatcher(profile, io);

    if (await _runtimeRunning(profile, instance)) {
      io.write('[WARN] Already running: $instance');
      return;
    }

    final startupSync = _pluginsSyncInstance(
      profile,
      instance,
      clean: false,
      sourceModsOverride: false,
      strict: false,
    );
    if (startupSync.copiedJars.isNotEmpty) {
      io.write(
        '[SYNC] Startup copied ${startupSync.copiedJars.length} jar(s) -> $instance',
      );
      io.write('[SYNC] ${startupSync.copiedJars.join(', ')}');
    }
    if (startupSync.failedJars.isNotEmpty) {
      for (final failed in startupSync.failedJars) {
        io.error('[WARN] Startup sync failed for $instance: $failed');
      }
    }

    await _runtimePrepareInstancePort(profile, instance, io);

    final launch = _runtimeLaunchTarget(profile, instance);
    if (!File(launch.path).existsSync()) {
      throw _NativeCommandException(
        'No launch target found for instance: $instance (${launch.path})',
        2,
      );
    }

    final runtimeDir = _runtimeDir(profile);
    Directory(runtimeDir).createSync(recursive: true);

    final logFile = File(_runtimeLogFile(profile, instance));
    logFile
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    final settings = _runtimeSettingsLoad(profile);
    final launchWorkingDir = _runtimeLaunchWorkingDir(profile, instance);
    final javaCommandParts = <String>[
      'java',
      ..._javaArgsForLaunch(
        launch,
        settings,
        workingDirectory: launchWorkingDir,
      ),
    ];
    final javaCommand = javaCommandParts.map(_shellQuote).join(' ');

    final runScript =
        'cd ${_shellQuote(launchWorkingDir)} && exec $javaCommand';
    final tmuxSession = _tmuxSessionName(profile, instance);

    // Clear stale runtime markers when switching to tmux-backed runtime.
    File(_runtimeServerPidFile(profile, instance)).deleteSyncSafe();
    File(_runtimeConsolePidFile(profile, instance)).deleteSyncSafe();

    if (await _tmuxSessionExists(tmuxSession)) {
      await _runProcess('tmux', <String>['kill-session', '-t', tmuxSession]);
    }

    final startResult = await _runProcess('tmux', <String>[
      'new-session',
      '-d',
      '-s',
      tmuxSession,
      ..._tmuxDetachedSizeArgs(),
      'sh -lc ${_shellQuote(runScript)}',
    ]);
    if (startResult.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to start runtime for $instance: ${startResult.stderr}',
        1,
      );
    }
    await _tmuxEnablePaneLogging(tmuxSession, logFile.path);

    await Future<void>.delayed(const Duration(milliseconds: 350));
    final running = await _tmuxSessionExists(tmuxSession);
    if (!running) {
      throw _NativeCommandException(
        'Failed to start runtime for $instance. Check log: ${logFile.path}',
        1,
      );
    }

    await _tmuxConfigureConsoleSession(tmuxSession);

    io.write('[OK] Runtime started: $instance');
    io.write('[INFO] tmux session: $tmuxSession');
    io.write('[INFO] Log: ${logFile.path}');
  }

  Future<void> _tmuxEnablePaneLogging(
    String tmuxSession,
    String logFilePath,
  ) async {
    final command = 'cat >> ${_shellQuote(logFilePath)}';
    final targets = <String>['$tmuxSession:0.0', '$tmuxSession:0'];
    for (final target in targets) {
      final result = await _runProcess('tmux', <String>[
        'pipe-pane',
        '-o',
        '-t',
        target,
        command,
      ]);
      if (result.exitCode == 0) {
        return;
      }
    }
  }

  Future<void> _runtimeEnsureDropinsWatcher(
    ConsumerProfile profile,
    _NativeIoBuffer io,
  ) async {
    if (!_isPluginConsumer(profile)) {
      return;
    }

    final session = _pluginsWatchSessionName(profile, mods: false);
    if (await _tmuxSessionExists(session)) {
      return;
    }

    try {
      await _pluginsWatchStart(profile, io, mods: false);
    } catch (e) {
      io.error('[WARN] Could not auto-start plugins watcher: $e');
    }
  }

  Future<void> _announceDropinSync(
    ConsumerProfile profile,
    String instance,
    int updatedCount,
  ) async {
    if (updatedCount <= 0) {
      return;
    }
    final session = _tmuxSessionName(profile, instance);
    if (!await _tmuxSessionExists(session)) {
      return;
    }
    await _runProcess('tmux', <String>[
      'display-message',
      '-t',
      session,
      'Dropins synced: $updatedCount jar update(s)',
    ]);
  }

  Future<void> _runtimeConsole(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    String? instance = inputInstance?.trim().isNotEmpty == true
        ? inputInstance!.trim()
        : null;

    if (instance == null) {
      final running = await _runtimeListRunning(profile);
      if (running.length == 1) {
        instance = running.first;
        io.write('[INFO] One running server detected: $instance');
      }
    }

    instance ??= _currentInstance(profile);

    if (instance == null || instance.isEmpty) {
      final running = await _runtimeListRunning(profile);
      if (running.length > 1) {
        throw _NativeCommandException(
          'Multiple servers are running. Use: runtime console <instance>',
          2,
        );
      }
      throw _NativeCommandException('No active instance set', 2);
    }

    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    if (!await _tmuxInstalled()) {
      throw _NativeCommandException(
        'tmux is required for runtime start/console. Install tmux and retry.',
        2,
      );
    }

    final tmuxSession = _tmuxSessionName(profile, instance);
    if (await _tmuxSessionExists(tmuxSession) &&
        !await _tmuxSessionHasLivePane(tmuxSession)) {
      await _runProcess('tmux', <String>['kill-session', '-t', tmuxSession]);
    }
    if (!await _tmuxSessionExists(tmuxSession)) {
      io.write('[INFO] Runtime is not running. Starting $instance...');
      await _runtimeStart(profile, instance, io);
      if (!await _tmuxSessionExists(tmuxSession)) {
        throw _NativeCommandException(
          'Failed to start tmux session for $instance',
          1,
        );
      }
    }

    await _runtimeAttachTmux(profile, instance, io);
  }

  Future<void> _runtimeConsoles(
    ConsumerProfile profile,
    _NativeIoBuffer io, {
    required String layout,
  }) async {
    if (!await _tmuxInstalled()) {
      throw _NativeCommandException(
        'tmux is required for runtime consoles. Install tmux and retry.',
        2,
      );
    }

    final running = await _runtimeListRunning(profile);
    if (running.isEmpty) {
      io.write('[WARN] No running servers.');
      return;
    }
    running.sort();

    final layoutName = switch (layout) {
      'lateral' => 'even-horizontal',
      _ => 'tiled',
    };

    final session = _allConsolesSessionName(profile);
    if (await _tmuxSessionExists(session)) {
      await _runProcess('tmux', <String>['kill-session', '-t', session]);
    }

    String paneCommandFor(String instance) {
      final port = _instanceGetServerPort(profile, instance);
      final targetSession = _tmuxSessionName(profile, instance);
      final heading = '=== $instance (port $port) ===';
      final missingMessage = 'Session not available: $instance';
      return 'printf %s\\n ${_shellQuote(heading)}; '
          'if tmux has-session -t ${_shellQuote(targetSession)} 2>/dev/null; then '
          'exec env -u TMUX tmux attach-session -t ${_shellQuote(targetSession)}; '
          'else '
          'echo ${_shellQuote(missingMessage)}; '
          'exec sh; '
          'fi';
    }

    final first = running.first;
    final create = await _runProcess('tmux', <String>[
      'new-session',
      '-d',
      '-s',
      session,
      ..._tmuxDetachedSizeArgs(),
      'sh -lc ${_shellQuote(paneCommandFor(first))}',
    ]);
    if (create.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to open all consoles view: ${create.stderr}',
        1,
      );
    }

    for (var i = 1; i < running.length; i++) {
      final instance = running[i];
      final split = await _runProcess('tmux', <String>[
        'split-window',
        '-t',
        '$session:0',
        'sh -lc ${_shellQuote(paneCommandFor(instance))}',
      ]);
      if (split.exitCode != 0) {
        throw _NativeCommandException(
          'Failed to add pane for $instance: ${split.stderr}',
          1,
        );
      }
      await _runProcess('tmux', <String>[
        'select-layout',
        '-t',
        '$session:0',
        layoutName,
      ]);
    }
    await _runProcess('tmux', <String>[
      'select-layout',
      '-t',
      '$session:0',
      layoutName,
    ]);

    await _tmuxConfigureConsoleSession(session);
    await _runProcess('tmux', <String>[
      'set-window-option',
      '-t',
      '$session:0',
      'pane-border-status',
      'top',
    ]);
    await _runProcess('tmux', <String>[
      'set-window-option',
      '-t',
      '$session:0',
      'pane-border-format',
      '#{pane_title}',
    ]);
    for (var i = 0; i < running.length; i++) {
      final instance = running[i];
      final title = '$instance : ${_instanceGetServerPort(profile, instance)}';
      await _runProcess('tmux', <String>[
        'select-pane',
        '-t',
        '$session:0.$i',
        '-T',
        title,
      ]);
    }

    Future<bool> bindRootIfMissing(String key, List<String> action) async {
      final listKeys = await _runProcess('tmux', <String>[
        'list-keys',
        '-T',
        'root',
      ]);
      var hasBinding = false;
      if (listKeys.exitCode == 0) {
        final lines = (listKeys.stdout ?? '')
            .toString()
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        final pattern = RegExp('^bind-key(?:\\s+-T\\s+root)?\\s+$key\\b');
        hasBinding = lines.any((line) => pattern.hasMatch(line));
      }
      if (hasBinding) {
        return false;
      }
      final bind = await _runProcess('tmux', <String>[
        'bind-key',
        '-T',
        'root',
        key,
        ...action,
      ]);
      return bind.exitCode == 0;
    }

    final boundEsc = await bindRootIfMissing('Escape', <String>[
      'detach-client',
    ]);
    final boundLeft = await bindRootIfMissing('Left', <String>[
      'select-pane',
      '-L',
    ]);
    final boundRight = await bindRootIfMissing('Right', <String>[
      'select-pane',
      '-R',
    ]);

    final layoutLabel = layout == 'lateral' ? 'lateral' : 'grid';
    io.write(
      'All Consoles ($layoutLabel): ${running.length} running server(s)',
    );
    io.write('Navigate panes: Left/Right arrows');
    io.write('Type directly in focused pane (interactive).');
    io.write('Scroll: mouse wheel (or Ctrl+B then [ for copy mode)');
    io.write('Detach: Esc (or Ctrl+B then D)');

    final attach = await Process.start(
      'tmux',
      <String>['attach-session', '-t', session],
      environment: _terminalAttachEnv(),
      mode: ProcessStartMode.inheritStdio,
    );
    final exit = await attach.exitCode;

    if (boundEsc) {
      await _runProcess('tmux', <String>['unbind-key', '-T', 'root', 'Escape']);
    }
    if (boundLeft) {
      await _runProcess('tmux', <String>['unbind-key', '-T', 'root', 'Left']);
    }
    if (boundRight) {
      await _runProcess('tmux', <String>['unbind-key', '-T', 'root', 'Right']);
    }

    if (exit != 0) {
      io.error('[ERROR] Failed to attach all consoles view (tmux exit=$exit).');
    }
  }

  Future<void> _runtimeAttachTmux(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) async {
    final tmuxSession = _tmuxSessionName(profile, instance);
    if (!await _tmuxSessionExists(tmuxSession)) {
      throw _NativeCommandException('No running tmux session for $instance', 2);
    }

    await _tmuxConfigureConsoleSession(tmuxSession);

    io.write('Server Console: $instance');
    io.write('Press Esc to detach and return (or Ctrl+B then D).');
    io.write('Scroll: mouse wheel (or Ctrl+B then [ for copy mode).');

    var temporaryEscBinding = false;
    final listKeys = await _runProcess('tmux', <String>[
      'list-keys',
      '-T',
      'root',
    ]);
    var hasEscapeBinding = false;
    if (listKeys.exitCode == 0) {
      final lines = (listKeys.stdout ?? '')
          .toString()
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      hasEscapeBinding = lines.any(
        (line) =>
            RegExp(r'^bind-key(?:\s+-T\s+root)?\s+Escape\b').hasMatch(line),
      );
    }

    if (!hasEscapeBinding) {
      final bind = await _runProcess('tmux', <String>[
        'bind-key',
        '-T',
        'root',
        'Escape',
        'detach-client',
      ]);
      if (bind.exitCode == 0) {
        temporaryEscBinding = true;
      } else {
        io.error(
          '[WARN] Could not enable Esc detach binding; use Ctrl+B then D.',
        );
      }
    }

    final attach = await Process.start(
      'tmux',
      <String>['attach-session', '-t', tmuxSession],
      environment: _terminalAttachEnv(),
      mode: ProcessStartMode.inheritStdio,
    );
    final exit = await attach.exitCode;

    if (temporaryEscBinding) {
      await _runProcess('tmux', <String>['unbind-key', '-T', 'root', 'Escape']);
    }

    if (exit != 0) {
      io.error(
        '[ERROR] Failed to attach console for $instance (tmux exit=$exit).',
      );
    }
    io.write('Server console exited with code $exit');
  }

  Future<void> _tmuxConfigureConsoleSession(String tmuxSession) async {
    final commands = <List<String>>[
      <String>['set-option', '-t', tmuxSession, 'mouse', 'on'],
      <String>['set-option', '-t', tmuxSession, 'history-limit', '200000'],
      <String>['set-window-option', '-t', '$tmuxSession:0', 'mode-keys', 'vi'],
      <String>[
        'set-window-option',
        '-t',
        '$tmuxSession:0',
        'window-size',
        'latest',
      ],
      <String>[
        'set-window-option',
        '-t',
        '$tmuxSession:0',
        'aggressive-resize',
        'on',
      ],
    ];
    for (final args in commands) {
      var ok = false;
      for (var attempt = 0; attempt < 5; attempt++) {
        final result = await _runProcess('tmux', args);
        if (result.exitCode == 0) {
          ok = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!ok) {
        return;
      }
    }
  }

  List<String> _tmuxDetachedSizeArgs() {
    var cols = 220;
    var rows = 60;

    final envCols = int.tryParse(
      (Platform.environment['COLUMNS'] ?? '').trim(),
    );
    final envRows = int.tryParse((Platform.environment['LINES'] ?? '').trim());
    if (envCols != null && envCols > 0) {
      cols = envCols;
    }
    if (envRows != null && envRows > 0) {
      rows = envRows;
    }

    if (stdout.hasTerminal) {
      final terminalCols = stdout.terminalColumns;
      final terminalRows = stdout.terminalLines;
      if (terminalCols > 0) {
        cols = terminalCols;
      }
      if (terminalRows > 0) {
        rows = terminalRows;
      }
    }

    if (cols < 160) {
      cols = 160;
    }
    if (cols > 500) {
      cols = 500;
    }
    if (rows < 40) {
      rows = 40;
    }
    if (rows > 200) {
      rows = 200;
    }

    return <String>['-x', '$cols', '-y', '$rows'];
  }

  Map<String, String> _terminalAttachEnv() {
    final env = Map<String, String>.from(Platform.environment);
    final term = (env['TERM'] ?? '').trim().toLowerCase();
    if (term.isEmpty || term == 'dumb') {
      env['TERM'] = 'xterm-256color';
    }
    return env;
  }

  Future<void> _runtimeStop(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    final instance = inputInstance?.trim().isNotEmpty == true
        ? inputInstance!.trim()
        : _currentInstance(profile);

    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }

    final tmuxSession = _tmuxSessionName(profile, instance);
    var stopped = false;
    if (await _tmuxSessionExists(tmuxSession)) {
      final killResult = await _runProcess('tmux', <String>[
        'kill-session',
        '-t',
        tmuxSession,
      ]);
      if (killResult.exitCode == 0) {
        stopped = true;
      }
    }

    final pids = <int>{};
    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    final consolePid = _readPid(_runtimeConsolePidFile(profile, instance));
    if (serverPid != null) {
      pids.add(serverPid);
    }
    if (consolePid != null) {
      pids.add(consolePid);
    }

    if (pids.isNotEmpty) {
      for (final pid in pids) {
        Process.killPid(pid, ProcessSignal.sigterm);
      }

      for (var i = 0; i < 20; i++) {
        var allStopped = true;
        for (final pid in pids) {
          if (await _pidRunning(pid)) {
            allStopped = false;
            break;
          }
        }
        if (allStopped) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      for (final pid in pids) {
        if (await _pidRunning(pid)) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      }
      stopped = true;
    }

    File(_runtimeServerPidFile(profile, instance)).deleteSyncSafe();
    File(_runtimeConsolePidFile(profile, instance)).deleteSyncSafe();

    if (stopped) {
      io.write('[OK] Runtime stopped: $instance');
    } else {
      io.write('[WARN] Runtime stopped: $instance');
    }
  }

  Future<void> _runtimeStatus(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    final instance = inputInstance?.trim().isNotEmpty == true
        ? inputInstance!.trim()
        : _currentInstance(profile);

    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }

    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final tmuxSession = _tmuxSessionName(profile, instance);
    var tmuxRunning = await _tmuxSessionExists(tmuxSession);
    if (tmuxRunning && !await _tmuxSessionHasLivePane(tmuxSession)) {
      await _runProcess('tmux', <String>['kill-session', '-t', tmuxSession]);
      tmuxRunning = false;
    }
    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    final consolePid = _readPid(_runtimeConsolePidFile(profile, instance));
    final serverRunning =
        serverPid != null && await _pidRunning(serverPid) && !tmuxRunning;
    final consoleRunning =
        consolePid != null && await _pidRunning(consolePid) && !tmuxRunning;

    final running = tmuxRunning || serverRunning || consoleRunning;
    if (running) {
      io.write('[OK] Runtime running: $instance');
    } else {
      io.write('[WARN] Runtime stopped: $instance');
    }

    final mode = tmuxRunning
        ? 'tmux'
        : consoleRunning
        ? 'console'
        : serverRunning
        ? 'background'
        : 'stopped';

    io.write('mode:         $mode');
    io.write('tmux session: ${tmuxRunning ? tmuxSession : 'none'}');
    io.write('server port:  ${_instanceGetServerPort(profile, instance)}');
    io.write('console pid:  ${consolePid ?? 'none'}');
    io.write('server pid:   ${serverPid ?? 'none'}');
    io.write('log:          ${_runtimeLogFile(profile, instance)}');
  }

  Future<List<String>> _runtimeListRunning(ConsumerProfile profile) async {
    final running = <String>[];
    for (final name in _instanceNames(profile)) {
      if (await _runtimeRunning(profile, name)) {
        running.add(name);
      }
    }
    return running;
  }

  Future<bool> _runtimeRunning(ConsumerProfile profile, String instance) async {
    final session = _tmuxSessionName(profile, instance);
    if (await _tmuxSessionExists(session)) {
      if (await _tmuxSessionHasLivePane(session)) {
        return true;
      }
      await _runProcess('tmux', <String>['kill-session', '-t', session]);
    }

    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    if (serverPid != null && await _pidRunning(serverPid)) {
      return true;
    }

    final consolePid = _readPid(_runtimeConsolePidFile(profile, instance));
    if (consolePid != null && await _pidRunning(consolePid)) {
      return true;
    }

    return false;
  }

  Future<bool> _tmuxInstalled() async {
    final result = await _runProcess('tmux', <String>['-V']);
    return result.exitCode == 0;
  }

  String _tmuxSessionName(ConsumerProfile profile, String instance) {
    final safeProfile = profile.shortName.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '-',
    );
    final safeInstance = instance.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return 'mc-$safeProfile-$safeInstance';
  }

  String _allConsolesSessionName(ConsumerProfile profile) {
    final safeProfile = profile.shortName.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '-',
    );
    return 'mc-$safeProfile-all-consoles';
  }

  String _pluginsWatchSessionName(
    ConsumerProfile profile, {
    required bool mods,
  }) {
    final safeProfile = profile.shortName.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '-',
    );
    return 'watch-$safeProfile-${mods ? 'mods' : 'plugins'}';
  }

  Future<bool> _tmuxSessionExists(String name) async {
    final result = await _runProcess('tmux', <String>[
      'has-session',
      '-t',
      name,
    ]);
    return result.exitCode == 0;
  }

  Future<bool> _tmuxSessionHasLivePane(String session) async {
    final result = await _runProcess('tmux', <String>[
      'list-panes',
      '-t',
      session,
      '-F',
      '#{pane_dead}',
    ]);
    if (result.exitCode != 0) {
      return false;
    }
    final lines = (result.stdout ?? '')
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    return lines.any((line) => line == '0');
  }

  Future<bool> _pidRunning(int pid) async {
    try {
      final result = await Process.run('kill', <String>['-0', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String _runtimeSettingsFile(ConsumerProfile profile) {
    return p.join(_stateDir(profile), 'runtime-settings.env');
  }

  _RuntimeSettingsData _runtimeSettingsLoad(ConsumerProfile profile) {
    var heap = _RuntimeSettingsData.defaults.heap;
    var jvmArgs = _RuntimeSettingsData.defaults.jvmArgs;
    var runtimeProfile = _RuntimeSettingsData.defaults.profile;
    final file = File(_runtimeSettingsFile(profile));

    if (file.existsSync()) {
      for (final raw in file.readAsLinesSync()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#') || !line.contains('=')) {
          continue;
        }
        final idx = line.indexOf('=');
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        switch (key) {
          case 'HEAP_SIZE':
            if (_runtimeHeapLooksValid(value)) {
              heap = value.toUpperCase();
            }
            break;
          case 'JVM_ARGS':
            if (value.isNotEmpty) {
              jvmArgs = value;
            }
            break;
          case 'JVM_PROFILE':
            if (value.isNotEmpty) {
              runtimeProfile = value.toLowerCase();
            }
            break;
          default:
            break;
        }
      }
    }

    final envHeap = Platform.environment['HEAP_SIZE'];
    if (envHeap != null && envHeap.trim().isNotEmpty) {
      final normalizedHeap = envHeap.trim().toUpperCase();
      if (_runtimeHeapLooksValid(normalizedHeap)) {
        heap = normalizedHeap;
      }
    }
    final envJvmArgs = Platform.environment['JVM_ARGS'];
    if (envJvmArgs != null && envJvmArgs.trim().isNotEmpty) {
      jvmArgs = envJvmArgs.trim();
    }
    final envProfile = Platform.environment['JVM_PROFILE'];
    if (envProfile != null && envProfile.trim().isNotEmpty) {
      runtimeProfile = envProfile.trim().toLowerCase();
    }

    if (!_runtimeSettingsPresets.containsKey(runtimeProfile)) {
      runtimeProfile = _runtimeSettingsGuessProfileForArgs(jvmArgs);
    }

    return _RuntimeSettingsData(
      heap: heap,
      jvmArgs: jvmArgs,
      profile: runtimeProfile,
    );
  }

  void _runtimeSettingsSave(
    ConsumerProfile profile,
    _RuntimeSettingsData settings,
  ) {
    final file = File(_runtimeSettingsFile(profile));
    file.createSync(recursive: true);
    file.writeAsStringSync(
      '${['# Multiplexor runtime settings (${profile.shortName})', 'HEAP_SIZE=${settings.heap}', 'JVM_PROFILE=${settings.profile}', 'JVM_ARGS=${settings.jvmArgs}'].join('\n')}\n',
    );
  }

  bool _runtimeHeapLooksValid(String heap) {
    return RegExp(r'^[0-9]{1,2}[GgMm]$').hasMatch(heap.trim());
  }

  String _runtimeSettingsGuessProfileForArgs(String args) {
    final normalized = args.trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final entry in _runtimeSettingsPresets.entries) {
      final candidate = entry.value.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (candidate == normalized) {
        return entry.key;
      }
    }
    return 'custom';
  }

  List<String> _javaArgsForLaunch(
    _LaunchTarget launch,
    _RuntimeSettingsData settings, {
    String? workingDirectory,
  }) {
    final heap = settings.heap;
    final jvmArgsRaw = settings.jvmArgs;

    final flags = jvmArgsRaw
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    if (launch.kind == _LaunchKind.argsFile) {
      var argsFile = launch.path;
      if (workingDirectory != null && workingDirectory.isNotEmpty) {
        if (p.isAbsolute(argsFile)) {
          // Prefer real-path comparison so symlink working dirs can use
          // relative @args paths (important for bracketed workspace paths).
          final realWorkingDirectory = _tryResolveRealPath(workingDirectory);
          final realArgsFile = _tryResolveRealPath(argsFile);
          if (realWorkingDirectory != null && realArgsFile != null) {
            try {
              final relative = p.relative(
                realArgsFile,
                from: realWorkingDirectory,
              );
              if (!relative.startsWith('..')) {
                argsFile = relative;
              }
            } catch (_) {}
          }
        }

        if (p.isAbsolute(argsFile)) {
          try {
            final relative = p.relative(argsFile, from: workingDirectory);
            if (!relative.startsWith('..')) {
              argsFile = relative;
            }
          } catch (_) {}
        }
      }

      return <String>[
        '-Xms$heap',
        '-Xmx$heap',
        ...flags,
        '@$argsFile',
        'nogui',
      ];
    }

    return <String>[
      '-Xms$heap',
      '-Xmx$heap',
      ...flags,
      '-jar',
      launch.path,
      '--nogui',
    ];
  }

  String _runtimeLaunchWorkingDir(ConsumerProfile profile, String instance) {
    final instanceDir = _instanceDir(profile, instance);
    if (!instanceDir.contains('[') && !instanceDir.contains(']')) {
      return instanceDir;
    }

    final linksRoot = p.join(
      Directory.systemTemp.path,
      'multiplexor-path-links',
      '${profile.shortName}-${_stablePathHash(context.rootDir)}',
    );
    Directory(linksRoot).createSync(recursive: true);
    final linkPath = p.join(linksRoot, instance);
    _replaceWithSymlink(linkPath, instanceDir);
    return linkPath;
  }

  String? _tryResolveRealPath(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {}

    try {
      return File(path).resolveSymbolicLinksSync();
    } catch (_) {}

    return null;
  }

  String _stablePathHash(String input) {
    const int offset = 0x811C9DC5;
    const int prime = 0x01000193;
    var hash = offset;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * prime) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  bool _shouldUseExternalInstanceStore(ConsumerProfile profile) {
    if (_isPluginConsumer(profile)) {
      return false;
    }
    return context.rootDir.contains('[') || context.rootDir.contains(']');
  }

  String _externalInstanceStoreRoot() {
    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return p.join(home, '.multiplexor');
    }
    return p.join(Directory.systemTemp.path, 'multiplexor');
  }

  void _migrateLegacyInstancesDirectory(String legacyDir, String externalDir) {
    final legacyType = FileSystemEntity.typeSync(legacyDir, followLinks: false);
    if (legacyType != FileSystemEntityType.directory) {
      return;
    }

    final legacyEntries = Directory(
      legacyDir,
    ).listSync(recursive: false, followLinks: false);
    for (final entry in legacyEntries) {
      final base = p.basename(entry.path);
      final destination = p.join(externalDir, base);
      final destinationType = FileSystemEntity.typeSync(
        destination,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound) {
        continue;
      }

      try {
        entry.renameSync(destination);
        continue;
      } catch (_) {}

      if (entry is Directory) {
        _copyDirectory(entry, Directory(destination));
        Directory(entry.path).deleteSync(recursive: true);
      } else if (entry is File) {
        File(destination).createSync(recursive: true);
        entry.copySync(destination);
        entry.deleteSync();
      } else if (entry is Link) {
        _replaceWithSymlink(destination, entry.targetSync());
        entry.deleteSync();
      }
    }
  }

  _LaunchTarget _runtimeLaunchTarget(ConsumerProfile profile, String instance) {
    final source = _serverSource(profile, instance);
    final launch = source['launch'] ?? '';

    if (launch == 'argsfile') {
      final rel = source['args_file_rel'] ?? '';
      if (rel.isEmpty) {
        return _LaunchTarget(kind: _LaunchKind.argsFile, path: '');
      }
      return _LaunchTarget(
        kind: _LaunchKind.argsFile,
        path: p.join(_instanceDir(profile, instance), rel),
      );
    }

    if (launch == 'jar') {
      final rel = source['jar_rel'] ?? '';
      if (rel.isNotEmpty) {
        return _LaunchTarget(
          kind: _LaunchKind.jar,
          path: p.join(_instanceDir(profile, instance), rel),
        );
      }

      final abs = source['jar'] ?? '';
      if (abs.isNotEmpty) {
        return _LaunchTarget(kind: _LaunchKind.jar, path: abs);
      }
    }

    return _LaunchTarget(
      kind: _LaunchKind.jar,
      path: p.join(_instanceDir(profile, instance), 'server.jar'),
    );
  }

  Future<void> _runtimePrepareInstancePort(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) async {
    var port = 25565;
    while (port <= 65535) {
      if (!await _runtimePortInUse(profile, instance, port)) {
        final current = _instanceGetServerPort(profile, instance);
        if (current != port) {
          _instanceSetServerPort(profile, instance, port);
          io.write('[INFO] Auto-assigned port for $instance: $port');
        }
        return;
      }
      port++;
    }

    throw _NativeCommandException('No available port found in 25565-65535', 2);
  }

  Future<bool> _runtimePortInUse(
    ConsumerProfile profile,
    String instance,
    int port,
  ) async {
    for (final candidateProfile in ConsumerProfile.values) {
      for (final other in _instanceNames(candidateProfile)) {
        if (candidateProfile == profile && other == instance) {
          continue;
        }
        if (await _runtimeRunning(candidateProfile, other) &&
            _instanceGetServerPort(candidateProfile, other) == port) {
          return true;
        }
      }
    }

    if (await _runtimeSocketPortInUse(port)) {
      return true;
    }

    return false;
  }

  Future<bool> _runtimeSocketPortInUse(int port) async {
    if (!await _runtimeCanBind(InternetAddress.anyIPv4, port)) {
      return true;
    }
    if (!await _runtimeCanBind(InternetAddress.loopbackIPv4, port)) {
      return true;
    }
    if (!await _runtimeCanBind(InternetAddress.anyIPv6, port, v6Only: true)) {
      return true;
    }
    if (!await _runtimeCanBind(
      InternetAddress.loopbackIPv6,
      port,
      v6Only: true,
    )) {
      return true;
    }
    return false;
  }

  Future<bool> _runtimeCanBind(
    InternetAddress address,
    int port, {
    bool v6Only = false,
  }) async {
    try {
      final socket = await ServerSocket.bind(address, port, v6Only: v6Only);
      await socket.close();
      return true;
    } on SocketException catch (e) {
      final message = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      if (message.contains('address already in use') ||
          message.contains('address in use')) {
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  void _configStatus(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    for (final rel in _sharedConfigFilesForInstance(profile, instance)) {
      final src = p.join(_instanceDir(profile, instance), rel);
      if (_isLink(src)) {
        io.write('FILE $rel -> symlink (${Link(src).targetSync()})');
      } else {
        io.write('FILE $rel -> local');
      }
    }

    for (final rel in _sharedConfigDirsBase) {
      final src = p.join(_instanceDir(profile, instance), rel);
      if (_isLink(src)) {
        io.write('DIR  $rel -> symlink (${Link(src).targetSync()})');
      } else {
        io.write('DIR  $rel -> local');
      }
    }
  }

  void _configLinkInstance(ConsumerProfile profile, String instance) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final instanceDir = _instanceDir(profile, instance);

    for (final rel in _sharedConfigFilesForInstance(profile, instance)) {
      final src = p.join(instanceDir, rel);
      if (!_isLink(src)) {
        continue;
      }
      final target = _resolveLinkTargetAbsolute(src);
      Link(src).deleteSync();
      Directory(p.dirname(src)).createSync(recursive: true);
      if (target != null && File(target).existsSync()) {
        File(target).copySync(src);
      } else {
        File(src).createSync(recursive: true);
      }
    }

    for (final rel in _sharedConfigDirsBase) {
      final src = p.join(instanceDir, rel);
      if (!_isLink(src)) {
        continue;
      }
      final target = _resolveLinkTargetAbsolute(src);
      Link(src).deleteSync();
      if (target != null && Directory(target).existsSync()) {
        _copyDirectory(Directory(target), Directory(src));
      } else {
        Directory(src).createSync(recursive: true);
      }
    }
  }

  void _irisPacksLinkInstance(ConsumerProfile profile, String instance) {
    if (!_isPluginConsumer(profile)) {
      return;
    }
    if (!_instanceExists(profile, instance)) {
      return;
    }

    final shared = _irisSharedPacksDir(profile);
    final src = p.join(
      _instanceDir(profile, instance),
      'plugins',
      'iris',
      'packs',
    );
    Directory(shared).createSync(recursive: true);
    Directory(p.dirname(src)).createSync(recursive: true);

    if (_isLink(src)) {
      final current = Link(src).targetSync();
      final absolute = p.isAbsolute(current)
          ? current
          : p.normalize(p.join(p.dirname(src), current));
      if (absolute == shared) {
        return;
      }
      Link(src).deleteSync();
    }

    if (Directory(src).existsSync()) {
      _copyDirectory(Directory(src), Directory(shared));
      Directory(src).deleteSync(recursive: true);
    } else if (File(src).existsSync()) {
      File(src).deleteSync();
    }

    _replaceWithSymlink(src, shared);
  }

  _DropinSyncReport _pluginsSyncInstance(
    ConsumerProfile profile,
    String instance, {
    required bool clean,
    required bool sourceModsOverride,
    required bool strict,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final source = _dropinsSource(profile, mods: sourceModsOverride);
    final sourceDir = Directory(source);
    sourceDir.createSync(recursive: true);

    final targetSubdir = _instanceDropinTargetSubdir(profile, instance);
    final targetDir = Directory(
      p.join(_instanceDir(profile, instance), targetSubdir),
    );
    targetDir.createSync(recursive: true);

    if (clean) {
      for (final entity in targetDir.listSync()) {
        if (entity is File && entity.path.endsWith('.jar')) {
          entity.deleteSync();
        }
      }
    }

    final copied = <String>[];
    final failed = <String>[];
    final jars =
        sourceDir
            .listSync()
            .whereType<File>()
            .where((entity) => entity.path.toLowerCase().endsWith('.jar'))
            .toList(growable: false)
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    for (final entity in jars) {
      try {
        final targetPath = p.join(targetDir.path, p.basename(entity.path));
        final sourceStat = entity.statSync();
        _deletePathEntity(targetPath, recursive: true);
        entity.copySync(targetPath);
        File(targetPath).setLastModifiedSync(sourceStat.modified);
        copied.add(p.basename(entity.path));
      } catch (e) {
        failed.add('${p.basename(entity.path)}: $e');
      }
    }

    if (strict && failed.isNotEmpty) {
      throw _NativeCommandException(
        'Failed to sync ${failed.length} jar(s): ${failed.join('; ')}',
        1,
      );
    }

    return _DropinSyncReport(copiedJars: copied, failedJars: failed);
  }

  _DropinSyncReport _pluginsSyncOneJarToInstance(
    ConsumerProfile profile,
    String instance,
    String sourceJarPath, {
    required bool strict,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final sourceFile = File(sourceJarPath);
    if (!sourceFile.existsSync()) {
      return const _DropinSyncReport(
        copiedJars: <String>[],
        failedJars: <String>[],
      );
    }

    final targetSubdir = _instanceDropinTargetSubdir(profile, instance);
    final targetDir = Directory(
      p.join(_instanceDir(profile, instance), targetSubdir),
    );
    targetDir.createSync(recursive: true);

    final copied = <String>[];
    final failed = <String>[];
    final jarName = p.basename(sourceFile.path);
    try {
      final targetPath = p.join(targetDir.path, jarName);
      final sourceStat = sourceFile.statSync();
      _deletePathEntity(targetPath, recursive: true);
      sourceFile.copySync(targetPath);
      File(targetPath).setLastModifiedSync(sourceStat.modified);
      copied.add(jarName);
    } catch (e) {
      failed.add('$jarName: $e');
    }

    if (strict && failed.isNotEmpty) {
      throw _NativeCommandException(
        'Failed to sync ${failed.length} jar(s): ${failed.join('; ')}',
        1,
      );
    }

    return _DropinSyncReport(copiedJars: copied, failedJars: failed);
  }

  String _instanceDropinTargetSubdir(ConsumerProfile profile, String instance) {
    final sourceType = _instanceSourceType(profile, instance);
    if (_isModdedType(sourceType)) {
      return 'mods';
    }
    return _isPluginConsumer(profile) ? 'plugins' : 'mods';
  }

  String _instanceSourceType(ConsumerProfile profile, String instance) {
    final source = _serverSource(profile, instance);
    return source['type']?.trim().toLowerCase() ?? 'custom';
  }

  String _instancePlatformLabel(String type) {
    return switch (type) {
      'purpur' => 'Purpur',
      'paper' => 'Paper',
      'folia' => 'Folia',
      'canvas' => 'Canvas',
      'spigot' => 'Spigot',
      'forge' => 'Forge',
      'fabric' => 'Fabric',
      'neoforge' => 'NeoForge',
      _ => 'Custom',
    };
  }

  String _instancePlatformPrimaryColor(String type) {
    return switch (type) {
      'purpur' => 'd',
      'paper' => 'b',
      'folia' => 'a',
      'canvas' => 'e',
      'spigot' => '6',
      'forge' => 'c',
      'fabric' => '9',
      'neoforge' => '6',
      _ => '7',
    };
  }

  String _instanceStyledMotd(
    ConsumerProfile profile,
    String instance,
    String type,
  ) {
    final platform = _instancePlatformLabel(type);
    final color = _instancePlatformPrimaryColor(type);
    final consumer = profile.shortName;
    final consumerLabel =
        '${consumer[0].toUpperCase()}${consumer.substring(1).toLowerCase()}';
    return '§$color§l$platform§8 » §f$instance§8 §o($consumerLabel)§r';
  }

  void _instanceSetMotd(ConsumerProfile profile, String instance, String motd) {
    final path = _instanceServerProperties(profile, instance);
    final file = File(path);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
      file.writeAsStringSync('server-port=25565\n');
    }

    final lines = file.readAsLinesSync();
    var replaced = false;
    final next = <String>[];
    for (final raw in lines) {
      if (raw.trim().startsWith('motd=')) {
        next.add('motd=$motd');
        replaced = true;
      } else {
        next.add(raw);
      }
    }
    if (!replaced) {
      next.add('motd=$motd');
    }
    file.writeAsStringSync('${next.join('\n')}\n');
  }

  String? _instanceGetMotdRaw(ConsumerProfile profile, String instance) {
    final file = File(_instanceServerProperties(profile, instance));
    if (!file.existsSync()) {
      return null;
    }
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.startsWith('motd=')) {
        return line.substring('motd='.length).trim();
      }
    }
    return null;
  }

  void _instanceApplyStyledMotd(
    ConsumerProfile profile,
    String instance, {
    required bool force,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    _ensureLocalServerProperties(profile, instance);
    final current = _instanceGetMotdRaw(profile, instance);
    if (!force &&
        current != null &&
        current.isNotEmpty &&
        current != instance) {
      return;
    }

    final type = _instanceSourceType(profile, instance);
    final motd = _instanceStyledMotd(profile, instance, type);
    _instanceSetMotd(profile, instance, motd);
  }

  void _instanceStyleMotd(ConsumerProfile profile, String? target) {
    final normalized = target?.trim() ?? '';
    if (normalized == '--all') {
      for (final instance in _instanceNames(profile)) {
        _instanceApplyStyledMotd(profile, instance, force: true);
      }
      return;
    }

    final instance = normalized.isEmpty
        ? _currentInstance(profile)
        : normalized;
    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }
    _instanceApplyStyledMotd(profile, instance, force: true);
  }

  Map<String, String> _serverSource(ConsumerProfile profile, String instance) {
    final file = File(
      p.join(_instanceDir(profile, instance), '.server-source'),
    );
    if (!file.existsSync()) {
      return const <String, String>{};
    }

    final out = <String, String>{};
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || !line.contains('=')) {
        continue;
      }
      final idx = line.indexOf('=');
      out[line.substring(0, idx)] = line.substring(idx + 1);
    }
    return out;
  }

  String _pluginSharedOpsFile(ConsumerProfile profile) {
    return p.join(
      _consumerRoot(profile),
      'shared-plugin-data',
      'ops',
      'ops.json',
    );
  }

  void _opsWarn(_NativeIoBuffer? io, String message) {
    final line = '[WARN] $message';
    if (io != null) {
      io.error(line);
      return;
    }
    stderr.writeln(line);
  }

  List<Map<String, dynamic>> _readOpsEntries(
    String filePath, {
    _NativeIoBuffer? io,
    String? contextLabel,
  }) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _opsWarn(
          io,
          'Invalid ops format in ${contextLabel ?? filePath}; expected JSON array. Treating as empty.',
        );
        return const <Map<String, dynamic>>[];
      }

      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) {
          out.add(Map<String, dynamic>.from(item));
        }
      }
      return out;
    } catch (e) {
      _opsWarn(
        io,
        'Could not parse ops file ${contextLabel ?? filePath}: $e. Treating as empty.',
      );
      return const <Map<String, dynamic>>[];
    }
  }

  String? _opsMergeKey(Map<String, dynamic> entry) {
    final uuid = entry['uuid']?.toString().trim();
    if (uuid != null && uuid.isNotEmpty) {
      return 'uuid:${uuid.toLowerCase()}';
    }
    final name = entry['name']?.toString().trim();
    if (name != null && name.isNotEmpty) {
      return 'name:${name.toLowerCase()}';
    }
    return null;
  }

  void _instanceEnsureSharedPluginOps(
    ConsumerProfile profile,
    String instance, {
    _NativeIoBuffer? io,
  }) {
    if (!_isPluginConsumer(profile) || !_instanceExists(profile, instance)) {
      return;
    }

    final sharedOpsPath = _pluginSharedOpsFile(profile);
    final sharedOpsFile = File(sharedOpsPath);
    sharedOpsFile.createSync(recursive: true);
    if (sharedOpsFile.readAsStringSync().trim().isEmpty) {
      sharedOpsFile.writeAsStringSync('[]\n');
    }

    final instanceOpsPath = p.join(_instanceDir(profile, instance), 'ops.json');
    final instanceOpsLinkedToShared =
        _isLink(instanceOpsPath) &&
        _resolveLinkTargetAbsolute(instanceOpsPath) == sharedOpsPath;

    final sharedEntries = _readOpsEntries(
      sharedOpsPath,
      io: io,
      contextLabel: 'shared ops',
    );
    final instanceEntries = instanceOpsLinkedToShared
        ? const <Map<String, dynamic>>[]
        : _readOpsEntries(
            instanceOpsPath,
            io: io,
            contextLabel: 'instance $instance ops',
          );

    final byKey = <String, Map<String, dynamic>>{};
    var unnamedCounter = 0;
    for (final source in <List<Map<String, dynamic>>>[
      sharedEntries,
      instanceEntries,
    ]) {
      for (final entry in source) {
        final key = _opsMergeKey(entry) ?? 'unnamed:${unnamedCounter++}';
        byKey[key] = Map<String, dynamic>.from(entry);
      }
    }

    final keys = byKey.keys.toList(growable: false)..sort();
    final merged = <Map<String, dynamic>>[];
    for (final key in keys) {
      final entry = byKey[key];
      if (entry != null) {
        merged.add(entry);
      }
    }

    sharedOpsFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(merged)}\n',
    );
    if (!instanceOpsLinkedToShared) {
      _replaceWithSymlink(instanceOpsPath, sharedOpsPath);
    }
  }

  void _instanceCreateBlank(
    ConsumerProfile profile,
    String name, {
    _NativeIoBuffer? io,
  }) {
    if (name.trim().isEmpty) {
      throw _NativeCommandException('Instance name required', 2);
    }

    final instancePath = _instanceDir(profile, name);
    final existingType = FileSystemEntity.typeSync(
      instancePath,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.directory) {
      throw _NativeCommandException('Instance already exists: $name', 2);
    }
    if (existingType != FileSystemEntityType.notFound) {
      _deletePathEntity(instancePath, recursive: true);
    }
    final dir = Directory(instancePath);

    Directory(p.join(dir.path, 'plugins')).createSync(recursive: true);
    Directory(p.join(dir.path, 'mods')).createSync(recursive: true);
    Directory(p.join(dir.path, 'logs')).createSync(recursive: true);

    final properties = File(p.join(dir.path, 'server.properties'));
    properties.writeAsStringSync('server-port=25565\n');

    File(p.join(dir.path, 'eula.txt')).writeAsStringSync('eula=true\n');
    _instanceApplyStyledMotd(profile, name, force: true);

    if (_isPluginConsumer(profile)) {
      _irisPacksLinkInstance(profile, name);
    }
    _configLinkInstance(profile, name);
    _instanceEnsureSharedPluginOps(profile, name, io: io);
  }

  void _instanceClone(
    ConsumerProfile profile,
    String source,
    String target, {
    _NativeIoBuffer? io,
  }) {
    if (!_instanceExists(profile, source)) {
      throw _NativeCommandException('Source instance not found: $source', 2);
    }
    if (_instanceExists(profile, target)) {
      throw _NativeCommandException('Destination already exists: $target', 2);
    }

    _copyDirectory(
      Directory(_instanceDir(profile, source)),
      Directory(_instanceDir(profile, target)),
    );
    if (_isPluginConsumer(profile)) {
      _irisPacksLinkInstance(profile, target);
    }
    _configLinkInstance(profile, target);
    _instanceEnsureSharedPluginOps(profile, target, io: io);
  }

  void _instanceDelete(ConsumerProfile profile, String name) {
    final instancePath = _instanceDir(profile, name);
    final existingType = FileSystemEntity.typeSync(
      instancePath,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.notFound) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }

    final serverPid = _readPid(_runtimeServerPidFile(profile, name));
    if (serverPid != null) {
      try {
        Process.killPid(serverPid, ProcessSignal.sigkill);
      } catch (_) {}
    }

    final consolePid = _readPid(_runtimeConsolePidFile(profile, name));
    if (consolePid != null) {
      try {
        Process.killPid(consolePid, ProcessSignal.sigkill);
      } catch (_) {}
    }

    try {
      Process.runSync('tmux', <String>[
        'kill-session',
        '-t',
        _tmuxSessionName(profile, name),
      ], runInShell: true);
    } catch (_) {}

    _deletePathEntity(instancePath, recursive: true);
    File(_runtimeServerPidFile(profile, name)).deleteSyncSafe();
    File(_runtimeConsolePidFile(profile, name)).deleteSyncSafe();

    final active = _currentInstance(profile);
    if (active == name) {
      File(_activeInstanceFile(profile)).deleteSyncSafe();
      File(_activeInstanceLink(profile)).deleteSyncSafe();
      File(_rootActiveInstanceLink()).deleteSyncSafe();
    }
  }

  void _instanceDeleteAll(
    ConsumerProfile profile, {
    required bool interactive,
  }) {
    final entriesDir = Directory(_instancesDir(profile));
    if (!entriesDir.existsSync()) {
      return;
    }
    final entries = entriesDir
        .listSync(recursive: false, followLinks: false)
        .toList(growable: false);
    if (entries.isEmpty) {
      return;
    }
    final names =
        entries.map((entry) => p.basename(entry.path)).toList(growable: false)
          ..sort();

    if (interactive) {
      stdout.write('Type DELETE to remove ALL server instances: ');
      final answer = stdin.readLineSync()?.trim() ?? '';
      if (answer != 'DELETE') {
        throw _NativeCommandException('Delete cancelled', 1);
      }
    }

    for (final instance in names) {
      _instanceDelete(profile, instance);
    }

    File(_activeInstanceFile(profile)).deleteSyncSafe();
    File(_activeInstanceLink(profile)).deleteSyncSafe();
    File(_rootActiveInstanceLink()).deleteSyncSafe();
  }

  Future<void> _instanceReset(
    ConsumerProfile profile,
    String name,
    _NativeIoBuffer io,
  ) async {
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }

    if (await _runtimeRunning(profile, name)) {
      await _runtimeStop(profile, name, io);
    }

    final instancePath = _instanceDir(profile, name);
    final backupPath =
        '$instancePath.reset-backup.${DateTime.now().millisecondsSinceEpoch}';

    final instanceDir = Directory(instancePath);
    try {
      instanceDir.renameSync(backupPath);
    } catch (_) {
      _copyDirectory(instanceDir, Directory(backupPath));
      _deletePathEntity(instancePath, recursive: true);
    }

    try {
      _instanceCreateBlank(profile, name, io: io);
      _restoreFactoryArtifactsFromBackup(profile, name, backupPath: backupPath);
      _instanceEnsureSharedPluginOps(profile, name, io: io);
      _deletePathEntity(backupPath, recursive: true);
    } catch (e) {
      try {
        _deletePathEntity(instancePath, recursive: true);
      } catch (_) {}
      try {
        Directory(backupPath).renameSync(instancePath);
      } catch (_) {
        if (Directory(backupPath).existsSync()) {
          _copyDirectory(Directory(backupPath), Directory(instancePath));
          _deletePathEntity(backupPath, recursive: true);
        }
      }
      if (e is _NativeCommandException) {
        rethrow;
      }
      throw _NativeCommandException('Failed to reset $name: $e', 1);
    }
  }

  void _restoreFactoryArtifactsFromBackup(
    ConsumerProfile profile,
    String instance, {
    required String backupPath,
  }) {
    final backupDir = Directory(backupPath);
    if (!backupDir.existsSync()) {
      return;
    }

    final targetDir = _instanceDir(profile, instance);
    for (final entity in backupDir.listSync(
      recursive: false,
      followLinks: false,
    )) {
      final base = p.basename(entity.path);
      final baseLower = base.toLowerCase();
      final isDir = entity is Directory;
      if (_shouldFactoryResetRootEntry(baseLower, isDirectory: isDir)) {
        continue;
      }

      final destination = p.join(targetDir, base);
      if (entity is Directory) {
        _copyDirectory(entity, Directory(destination));
      } else if (entity is File) {
        File(destination).createSync(recursive: true);
        entity.copySync(destination);
      } else if (entity is Link) {
        _replaceWithSymlink(destination, entity.targetSync());
      }
    }
  }

  bool _shouldFactoryResetRootEntry(String name, {required bool isDirectory}) {
    if (isDirectory) {
      if (name == 'plugins' ||
          name == 'mods' ||
          name == 'logs' ||
          name == 'config' ||
          name == 'crash-reports') {
        return true;
      }
      return name == 'world' || name.startsWith('world_');
    }

    if (name.endsWith('.yml') || name.endsWith('.yaml')) {
      return true;
    }

    return name == 'server.properties' ||
        name == 'eula.txt' ||
        name == 'ops.json' ||
        name == 'whitelist.json' ||
        name == 'banned-ips.json' ||
        name == 'banned-players.json' ||
        name == 'usercache.json';
  }

  void _instanceActivate(ConsumerProfile profile, String name) {
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }

    final activeFile = File(_activeInstanceFile(profile));
    activeFile
      ..createSync(recursive: true)
      ..writeAsStringSync('$name\n');

    _replaceWithSymlink(
      _activeInstanceLink(profile),
      _instanceDir(profile, name),
    );
    _replaceWithSymlink(_rootActiveInstanceLink(), _instanceDir(profile, name));
  }

  String? _findCachedJar(
    ConsumerProfile profile, {
    required String type,
    required String mc,
  }) {
    final dir = Directory(_buildDir(profile, type));
    if (!dir.existsSync()) {
      return null;
    }

    final jars =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jar'))
            .where((f) => p.basename(f.path).contains(mc))
            .toList(growable: false)
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );

    if (jars.isNotEmpty) {
      return jars.first.path;
    }

    final latest = File(p.join(dir.path, 'latest.jar'));
    if (latest.existsSync()) {
      return latest.path;
    }

    return null;
  }

  String? _buildLatestJarPath(ConsumerProfile profile, String type) {
    final dir = Directory(_buildDir(profile, type));
    if (!dir.existsSync()) {
      return null;
    }

    final latest = File(p.join(dir.path, 'latest.jar'));
    if (latest.existsSync()) {
      return latest.path;
    }

    final jars =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jar'))
            .toList(growable: false)
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );

    return jars.isEmpty ? null : jars.first.path;
  }

  bool _instanceExists(ConsumerProfile profile, String name) {
    return Directory(_instanceDir(profile, name)).existsSync();
  }

  List<String> _instanceNames(ConsumerProfile profile) {
    final dir = Directory(_instancesDir(profile));
    if (!dir.existsSync()) {
      return const <String>[];
    }

    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList(growable: false)
      ..sort();
  }

  String? _currentInstance(ConsumerProfile profile) {
    final file = File(_activeInstanceFile(profile));
    if (!file.existsSync()) {
      return null;
    }
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  int _instanceGetServerPort(ConsumerProfile profile, String instance) {
    _ensureLocalServerProperties(profile, instance);
    final file = File(_instanceServerProperties(profile, instance));
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (!line.startsWith('server-port=')) {
        continue;
      }
      final value = line.substring('server-port='.length).trim();
      final port = int.tryParse(value);
      if (port != null && port >= 1 && port <= 65535) {
        return port;
      }
    }
    return 25565;
  }

  void _instanceSetServerPort(
    ConsumerProfile profile,
    String instance,
    int port,
  ) {
    if (port < 1 || port > 65535) {
      throw _NativeCommandException('Port must be between 1 and 65535', 2);
    }

    _ensureLocalServerProperties(profile, instance);

    final file = File(_instanceServerProperties(profile, instance));
    final lines = file.readAsLinesSync();
    var replaced = false;

    final next = <String>[];
    for (final raw in lines) {
      if (raw.trim().startsWith('server-port=')) {
        next.add('server-port=$port');
        replaced = true;
      } else {
        next.add(raw);
      }
    }

    if (!replaced) {
      next.add('server-port=$port');
    }

    file.writeAsStringSync('${next.join('\n')}\n');
  }

  void _ensureLocalServerProperties(ConsumerProfile profile, String instance) {
    final path = _instanceServerProperties(profile, instance);

    if (_isLink(path)) {
      final link = Link(path);
      final target = link.targetSync();
      final absoluteTarget = p.isAbsolute(target)
          ? target
          : p.normalize(p.join(p.dirname(path), target));
      final tmp = '$path.tmp.${DateTime.now().millisecondsSinceEpoch}';

      if (File(absoluteTarget).existsSync()) {
        File(absoluteTarget).copySync(tmp);
      } else {
        File(tmp).createSync(recursive: true);
      }

      link.deleteSync();
      File(tmp).renameSync(path);
    }

    final file = File(path);
    if (!file.existsSync()) {
      file.writeAsStringSync('motd=$instance\nserver-port=25565\n');
    }
  }

  bool _isModdedType(String type) {
    return type == 'forge' || type == 'fabric' || type == 'neoforge';
  }

  bool _isPluginConsumer(ConsumerProfile profile) {
    return profile == ConsumerProfile.plugin;
  }

  String _repoUrl(String type) {
    return switch (type) {
      'paper' => 'https://github.com/PaperMC/Paper.git',
      'purpur' => 'https://github.com/PurpurMC/Purpur.git',
      'folia' => 'https://github.com/PaperMC/Folia.git',
      'canvas' => 'https://github.com/CraftCanvasMC/Canvas.git',
      _ => throw _NativeCommandException('Unknown repo type: $type', 2),
    };
  }

  Future<ProcessResult> _runProcess(String executable, List<String> args) {
    return Process.run(
      executable,
      args,
      workingDirectory: context.rootDir,
      runInShell: true,
    );
  }

  Future<void> _runAndRequireSuccess(
    String executable,
    List<String> args,
    String message,
    _NativeIoBuffer io,
  ) async {
    final result = await _runProcess(executable, args);
    if (result.stdout != null && result.stdout.toString().trim().isNotEmpty) {
      for (final line in result.stdout.toString().trimRight().split('\n')) {
        io.write(line);
      }
    }
    if (result.stderr != null && result.stderr.toString().trim().isNotEmpty) {
      for (final line in result.stderr.toString().trimRight().split('\n')) {
        io.error(line);
      }
    }
    if (result.exitCode != 0) {
      throw _NativeCommandException(message, 1);
    }
  }

  void _copyDirectory(Directory src, Directory dst) {
    if (!src.existsSync()) {
      return;
    }
    dst.createSync(recursive: true);

    for (final entity in src.listSync(recursive: false, followLinks: false)) {
      final base = p.basename(entity.path);
      final nextPath = p.join(dst.path, base);

      if (entity is Directory) {
        _copyDirectory(entity, Directory(nextPath));
      } else if (entity is File) {
        File(nextPath).createSync(recursive: true);
        entity.copySync(nextPath);
      } else if (entity is Link) {
        final target = entity.targetSync();
        _replaceWithSymlink(nextPath, target);
      }
    }
  }

  void _replaceWithSymlink(String linkPath, String targetPath) {
    final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        File(linkPath).deleteSync();
        break;
      case FileSystemEntityType.directory:
        Directory(linkPath).deleteSync(recursive: true);
        break;
      case FileSystemEntityType.link:
        Link(linkPath).deleteSync();
        break;
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        break;
    }

    Directory(p.dirname(linkPath)).createSync(recursive: true);
    Link(linkPath).createSync(targetPath, recursive: true);
  }

  void _deletePathEntity(String path, {required bool recursive}) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        File(path).deleteSync();
        break;
      case FileSystemEntityType.directory:
        if (recursive) {
          _deleteDirectoryTree(path);
        } else {
          Directory(path).deleteSync(recursive: false);
        }
        break;
      case FileSystemEntityType.link:
        Link(path).deleteSync();
        break;
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        File(path).deleteSync();
        break;
      case FileSystemEntityType.notFound:
        break;
    }
  }

  void _deleteDirectoryTree(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      return;
    }

    for (final entity in directory.listSync(
      recursive: false,
      followLinks: false,
    )) {
      _deletePathEntity(entity.path, recursive: true);
    }

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        directory.deleteSync(recursive: false);
        return;
      } on FileSystemException {
        if (attempt == 3) {
          rethrow;
        }
        sleep(Duration(milliseconds: 75 * attempt));
        for (final entity in directory.listSync(
          recursive: false,
          followLinks: false,
        )) {
          _deletePathEntity(entity.path, recursive: true);
        }
      }
    }
  }

  bool _isLink(String path) {
    return FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link;
  }

  String? _resolveLinkTargetAbsolute(String linkPath) {
    if (!_isLink(linkPath)) {
      return null;
    }
    final target = Link(linkPath).targetSync();
    return p.isAbsolute(target)
        ? target
        : p.normalize(p.join(p.dirname(linkPath), target));
  }

  bool _looksNumeric(String value) {
    return RegExp(r'^\d+$').hasMatch(value);
  }

  String _shellQuote(String input) {
    final escaped = input.replaceAll("'", "'\\''");
    return "'$escaped'";
  }

  String _selfInvocationCommand({
    required ConsumerProfile profile,
    required List<String> args,
  }) {
    final executable = Platform.resolvedExecutable;
    final base = p.basename(executable).toLowerCase();
    final coreArgs = <String>['--consumer', profile.shortName, ...args];
    final commandParts = <String>[_shellQuote(executable)];

    if (base == 'dart' || base == 'dart.exe' || base.startsWith('dart')) {
      final script = p.join(
        context.rootDir,
        'MultiplexorApp',
        'bin',
        'main.dart',
      );
      commandParts.add('run');
      commandParts.add(_shellQuote(script));
    }

    for (final arg in coreArgs) {
      commandParts.add(_shellQuote(arg));
    }

    return commandParts.join(' ');
  }

  String _requireValue(List<String> args, String usage) {
    if (args.isEmpty || args.first.trim().isEmpty) {
      throw _NativeCommandException(usage, 2);
    }
    return args.first.trim();
  }

  void _printHelp(_NativeIoBuffer io) {
    io.write('Minecraft Dev Wizard (native mode)');
    io.write('');
    io.write('Default:');
    io.write('  multiplexor                # open wizard');
    io.write(
      '  multiplexor --consumer <plugin|forge|fabric|neoforge> <command>',
    );
    io.write('  multiplexor --root <path> <command>');
    io.write('');
    io.write('Consumer commands:');
    io.write('  consumer list|show|use|path');
    io.write('');
    io.write('Instance commands:');
    io.write(
      '  instance list|create|clone|delete|reset|activate|path|port|motd-style|current|delete-all',
    );
    io.write('');
    io.write('Server commands:');
    io.write('  server create <name> --jar <path> [--type label]');
    io.write(
      '  server create <name> --type <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>]',
    );
    io.write('');
    io.write('Runtime commands:');
    io.write('  runtime start [instance] [--instance <name>] [--no-console]');
    io.write(
      '  runtime console [instance] [--instance <name>]  # auto-picks if one running',
    );
    io.write('  runtime consoles|consoles-lateral|stop|status|list [instance]');
    io.write('  runtime settings <show|presets|set-heap|set-preset|reset>');
    io.write('');
    io.write('Dropins commands:');
    io.write('  plugins show-source');
    io.write('  plugins sync [instance|--all] [--clean]');
    io.write('  plugins watch-status|watch-start|watch-stop');
    io.write('  mods show-source');
    io.write('  mods sync [instance|--all] [--clean]');
    io.write('');
    io.write('Config commands:');
    io.write('  config localize [instance|--all]');
    io.write('  config status [instance]');
    io.write('');
    io.write('Build/repos commands:');
    io.write('  repos sync [all|paper|purpur|folia|canvas]');
    io.write(
      '  build <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>] [--loader <version>] [--installer <version>]',
    );
    io.write('  build test-latest [--spigot-mc <version>]');
    io.write('  build latest <type>');
    io.write('  build list');
    io.write('  build list-all [type]');
    io.write('  build versions [type]');
  }

  ConsumerProfile get _activeConsumer {
    return context.requestedConsumer ?? consumerService.readActive();
  }

  String _consumerRoot(ConsumerProfile profile) {
    consumerService.ensureConsumerDirs(profile);
    return consumerService.rootFor(profile);
  }

  String _repoDir(ConsumerProfile profile, String type) {
    return p.join(_consumerRoot(profile), 'repos', type);
  }

  String _buildDir(ConsumerProfile profile, String type) {
    return p.join(_consumerRoot(profile), 'builds', type);
  }

  String _instancesDir(ConsumerProfile profile) {
    final legacyDir = p.join(_consumerRoot(profile), 'instances');
    if (!_shouldUseExternalInstanceStore(profile)) {
      return legacyDir;
    }

    final externalDir = p.join(
      _externalInstanceStoreRoot(),
      'instance-store',
      _stablePathHash(context.rootDir),
      profile.shortName,
    );
    Directory(externalDir).createSync(recursive: true);
    _migrateLegacyInstancesDirectory(legacyDir, externalDir);
    return externalDir;
  }

  String _stateDir(ConsumerProfile profile) {
    return p.join(_consumerRoot(profile), 'state');
  }

  String _runtimeDir(ConsumerProfile profile) {
    return p.join(_stateDir(profile), 'runtime');
  }

  String _irisSharedPacksDir(ConsumerProfile profile) {
    return p.join(
      _consumerRoot(profile),
      'shared-plugin-data',
      'iris',
      'packs',
    );
  }

  String _dropinsSource(ConsumerProfile profile, {required bool mods}) {
    final name = mods || !_isPluginConsumer(profile) ? 'mods' : 'plugins';
    final path = p.join(_consumerRoot(profile), 'dropins', name);
    Directory(path).createSync(recursive: true);
    return path;
  }

  String _instanceDir(ConsumerProfile profile, String name) {
    return p.join(_instancesDir(profile), name);
  }

  String _instanceServerProperties(ConsumerProfile profile, String instance) {
    return p.join(_instanceDir(profile, instance), 'server.properties');
  }

  String _activeInstanceFile(ConsumerProfile profile) {
    return p.join(_stateDir(profile), 'active-instance.txt');
  }

  String _activeInstanceLink(ConsumerProfile profile) {
    return p.join(_consumerRoot(profile), 'active-instance');
  }

  String _rootActiveInstanceLink() {
    return p.join(context.rootDir, 'active-instance');
  }

  String _runtimeServerPidFile(ConsumerProfile profile, String instance) {
    return p.join(_runtimeDir(profile), '$instance.server.pid');
  }

  String _runtimeConsolePidFile(ConsumerProfile profile, String instance) {
    return p.join(_runtimeDir(profile), '$instance.console.pid');
  }

  String _runtimeLogFile(ConsumerProfile profile, String instance) {
    return p.join(_runtimeDir(profile), '$instance.log');
  }

  String _pluginsWatchPidFile(ConsumerProfile profile, {required bool mods}) {
    return p.join(
      _stateDir(profile),
      mods ? 'mods-watch.pid' : 'plugins-watch.pid',
    );
  }

  String _pluginsWatchLogFile(ConsumerProfile profile, {required bool mods}) {
    return p.join(
      _stateDir(profile),
      mods ? 'mods-watch.log' : 'plugins-watch.log',
    );
  }

  int? _readPid(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return null;
    }
    final raw = file.readAsStringSync().trim();
    final pid = int.tryParse(raw);
    if (pid == null || pid <= 0) {
      file.deleteSyncSafe();
      return null;
    }
    return pid;
  }

  List<String> _sharedConfigFilesForInstance(
    ConsumerProfile profile,
    String instance,
  ) {
    final fileNames = <String>{..._sharedConfigFilesBase};
    final dir = Directory(_instanceDir(profile, instance));

    if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: false, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        final name = p.basename(entity.path);
        if (name.endsWith('.yml') || name.endsWith('.yaml')) {
          fileNames.add(name);
        }
      }
    }

    return fileNames.toList(growable: false)..sort();
  }

  static const List<String> _allBuildTypes = <String>[
    'paper',
    'purpur',
    'spigot',
    'folia',
    'canvas',
    'forge',
    'fabric',
    'neoforge',
  ];

  static const Map<String, String> _runtimeSettingsPresets = <String, String>{
    'aikar':
        '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 '
        '-XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapRegionSize=8M '
        '-XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 '
        '-XX:+UseStringDeduplication -XX:+PerfDisableSharedMem -Dfile.encoding=UTF-8',
    'vanilla': '-Dfile.encoding=UTF-8',
    'conservative':
        '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=300 '
        '-XX:+DisableExplicitGC -XX:+UseStringDeduplication -Dfile.encoding=UTF-8',
  };

  static const List<String> _sharedConfigFilesBase = <String>[
    'banned-ips.json',
    'banned-players.json',
    'whitelist.json',
    'bukkit.yml',
    'commands.yml',
    'help.yml',
    'permissions.yml',
    'purpur.yml',
    'spigot.yml',
    'eula.txt',
  ];

  static const List<String> _sharedConfigDirsBase = <String>['config'];
}

class _NativeIoBuffer {
  _NativeIoBuffer({required this.stream});

  final bool stream;
  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();

  void write(String line) {
    _stdout.writeln(line);
    if (stream) {
      stdout.writeln(line);
    }
  }

  void error(String line) {
    _stderr.writeln(line);
    if (stream) {
      stderr.writeln(line);
    }
  }

  CapturedResult result(int exitCode) {
    return CapturedResult(
      exitCode: exitCode,
      stdout: _stdout.toString(),
      stderr: _stderr.toString(),
    );
  }
}

class _NativeCommandException implements Exception {
  _NativeCommandException(this.message, this.exitCode);

  final String message;
  final int exitCode;

  @override
  String toString() => message;
}

enum _LaunchKind { jar, argsFile }

class _LaunchTarget {
  _LaunchTarget({required this.kind, required this.path});

  final _LaunchKind kind;
  final String path;
}

class _RuntimeSettingsData {
  const _RuntimeSettingsData({
    this.heap = '4G',
    this.jvmArgs =
        '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 '
        '-XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapRegionSize=8M '
        '-XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 '
        '-XX:+UseStringDeduplication -XX:+PerfDisableSharedMem -Dfile.encoding=UTF-8',
    this.profile = 'aikar',
  });

  static const _RuntimeSettingsData defaults = _RuntimeSettingsData();

  final String heap;
  final String jvmArgs;
  final String profile;

  _RuntimeSettingsData copyWith({
    String? heap,
    String? jvmArgs,
    String? profile,
  }) {
    return _RuntimeSettingsData(
      heap: heap ?? this.heap,
      jvmArgs: jvmArgs ?? this.jvmArgs,
      profile: profile ?? this.profile,
    );
  }
}

class _RuntimeTargetArgs {
  const _RuntimeTargetArgs({required this.instance, required this.noConsole});

  final String? instance;
  final bool noConsole;
}

class _DropinSyncReport {
  const _DropinSyncReport({required this.copiedJars, required this.failedJars});

  final List<String> copiedJars;
  final List<String> failedJars;
}

class _Version implements Comparable<_Version> {
  _Version({required this.major, required this.minor, required this.patch});

  final int major;
  final int minor;
  final int patch;

  factory _Version.parse(String value) {
    final parts = value.split('.').map(int.tryParse).toList(growable: false);
    return _Version(
      major: parts.isNotEmpty && parts[0] != null ? parts[0]! : 0,
      minor: parts.length > 1 && parts[1] != null ? parts[1]! : 0,
      patch: parts.length > 2 && parts[2] != null ? parts[2]! : 0,
    );
  }

  @override
  int compareTo(_Version other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    return patch.compareTo(other.patch);
  }
}

extension on File {
  void deleteSyncSafe() {
    if (existsSync()) {
      deleteSync();
    }
  }
}
