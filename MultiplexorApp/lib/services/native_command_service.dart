import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/cli/command_help.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../models/build_cache.dart';
import '../models/consumer_profile.dart';
import '../utils/duration_format.dart';
import '../utils/process_runner.dart';
import '../utils/table.dart';
import '../utils/terminal/ansi.dart';
import 'consumer_service.dart';
import 'dropin_sync_policy.dart';
import 'gameplay_test_service.dart';
import 'manager_context.dart';
import 'monitor/metric_sample.dart';
import 'rcon_client.dart';
import 'runtime_state.dart';
import 'server_ping.dart';

part 'native_command_help.dart';
part 'native_cli_output.dart';

class NativeCommandService {
  NativeCommandService({required this.context, required this.consumerService});

  final ManagerContext context;
  final ConsumerService consumerService;
  ConsumerProfile? _consumerOverride;

  /// Persistent RCON connections, reused across dashboard refreshes so the
  /// server log isn't flooded with connect/disconnect lines every tick.
  final RconConnectionPool _rconPool = RconConnectionPool();

  /// Closes every pooled RCON connection. Call on shutdown.
  void disposeRcon() => _rconPool.disposeAll();

  void setConsumerOverride(ConsumerProfile? profile) {
    _consumerOverride = profile;
  }

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

  /// Creates the isolated blank instance used by Remote Pull while attaching
  /// a caller-owned marker during allocation. This intentionally bypasses the
  /// public command parser so the ownership token never becomes CLI surface.
  Future<CapturedResult> createIsolatedTransferInstance(
    String name, {
    required String creationToken,
  }) async {
    final _NativeIoBuffer io = _NativeIoBuffer(stream: false);
    try {
      _instanceCreateBlank(
        _activeConsumer,
        name,
        isolated: true,
        creationToken: creationToken,
        io: io,
      );
      return io.result(0);
    } on _NativeCommandException catch (error) {
      io.error('[ERROR] ${error.message}');
      return io.result(error.exitCode);
    } catch (error, stackTrace) {
      io.error('[ERROR] $error');
      if (context.verbose) io.error('$stackTrace');
      return io.result(1);
    }
  }

  /// Removes only a failed transfer allocation carrying the exact caller
  /// token. Existing or replaced filesystem entities are never removed.
  bool cleanupPartialTransferInstance(
    String name, {
    required String creationToken,
  }) => _deleteOwnedPartialInstance(
    _instanceDir(_activeConsumer, name),
    creationToken,
  );

  Future<int> _dispatch(List<String> args, _NativeIoBuffer io) async {
    if (isCliHelpRequest(args)) {
      return _printHelpForArgs(args, io);
    }
    if (isCliVersionRequest(args)) {
      _printVersion(io);
      return 0;
    }

    final command = args.first;
    final rest = args.sublist(1);

    switch (command) {
      case 'help':
      case '-h':
      case '--help':
        return _printHelpForArgs(args, io);
      case 'version':
        _printVersion(io);
        return 0;
      case 'doctor':
        return _dispatchDoctor(rest, io);
      case 'backup':
        return _dispatchBackup(rest, io);
      case 'template':
        return _dispatchTemplate(rest, io);
      case 'content':
        return _dispatchContent(rest, io);
      case 'gameplay':
        return _dispatchGameplay(rest, io);
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
        final name = _requireValue(
          rest,
          'Usage: instance create <name> [--isolated]',
        );
        final Map<String, String> options = _parseOptions(rest.sublist(1));
        if (options.keys.any((String key) => key != 'isolated')) {
          throw _NativeCommandException(
            'Usage: instance create <name> [--isolated]',
            2,
          );
        }
        final bool isolated = options['isolated'] == 'true';
        _instanceCreateBlank(profile, name, isolated: isolated, io: io);
        io.write(
          '[OK] Instance created: $name (port ${_instanceGetServerPort(profile, name)}${isolated ? ', isolated' : ''})',
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
      case 'open':
        return _dispatchInstanceOpen(profile, rest, io);
      case 'safe-update':
        return _dispatchInstanceSafeUpdate(profile, rest, io);
      case 'update':
        return _dispatchInstanceUpdate(profile, rest, io);
      case 'isolated':
        return _dispatchInstanceIsolated(profile, rest, io);
      case 'lock':
        return _dispatchInstanceLock(profile, rest, io);
      case 'unlock':
        return _dispatchInstanceUnlock(profile, rest, io);
      case 'locked':
        return _dispatchInstanceLocked(profile, rest, io);
      case 'port':
        return _dispatchInstancePort(profile, rest, io);
      case 'motd-style':
        _instanceStyleMotd(profile, rest.isEmpty ? null : rest.first);
        io.write('[OK] Styled MOTD updated');
        return 0;
      case 'delete-all':
        return _dispatchInstanceDeleteAll(profile, rest, io);
      default:
        throw _NativeCommandException(
          'Usage: instance <list|create|clone|delete|reset|activate|path|open|update|safe-update|isolated|lock|unlock|locked|port|motd-style|current|delete-all>',
          2,
        );
    }
  }

  Future<int> _dispatchGameplay(List<String> args, _NativeIoBuffer io) async {
    final String sub = args.isEmpty ? 'doctor' : args.first;
    final List<String> rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final GameplayTestService harness = GameplayTestService(context: context);

    switch (sub) {
      case 'setup':
        return harness.setup(write: io.write, error: io.error);
      case 'doctor':
        final _FlexibleArgs parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'json'},
        );
        return harness.doctor(
          json: parsed.flag('json'),
          write: io.write,
          error: io.error,
        );
      case 'list':
        final _FlexibleArgs parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'json'},
        );
        return harness.list(
          json: parsed.flag('json'),
          write: io.write,
          error: io.error,
        );
      case 'prepare':
        final _FlexibleArgs parsed = _parseFlexibleArgs(rest);
        final String instance = _resolveGameplayInstance(
          parsed.option('instance') ??
              (parsed.positionals.isEmpty ? null : parsed.positionals.first),
        );
        await _prepareGameplayInstance(_activeConsumer, instance, io);
        return 0;
      case 'run':
        return _dispatchGameplayRun(rest, harness, io);
      default:
        throw _NativeCommandException(
          'Usage: gameplay <setup|doctor|list|prepare|run> ...',
          2,
        );
    }
  }

  Future<int> _dispatchGameplayRun(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
  ) async {
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args,
      booleanFlags: const <String>{
        'json',
        'no-op',
        'no-viewer',
        'prepare',
        'start',
        'stop-after',
      },
    );
    final bool json = parsed.flag('json');
    final _NativeIoBuffer operationIo = json
        ? _NativeIoBuffer(stream: false)
        : io;
    final String? scenario =
        parsed.option('scenario') ??
        (parsed.positionals.isEmpty ? null : parsed.positionals.first);
    if (scenario == null || scenario.trim().isEmpty) {
      throw _NativeCommandException(
        'Usage: gameplay run <scenario> [instance] [--start] [--stop-after]',
        2,
      );
    }
    final String? positionalInstance = parsed.positionals.length > 1
        ? parsed.positionals[1]
        : null;
    final String instance = _resolveGameplayInstance(
      parsed.option('instance') ?? positionalInstance,
    );
    final ConsumerProfile profile = _activeConsumer;
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final String auth = (parsed.option('auth') ?? 'offline').toLowerCase();
    if (auth != 'offline' && auth != 'microsoft') {
      throw _NativeCommandException('--auth must be offline or microsoft', 2);
    }
    if (auth == 'offline' && !_instanceIsolated(profile, instance)) {
      throw _NativeCommandException(
        'Offline gameplay testing is restricted to isolated instances: $instance',
        2,
      );
    }

    RuntimeState state = await _runtimeStateOf(profile, instance);
    if (parsed.flag('prepare')) {
      if (state != RuntimeState.stopped) {
        throw _NativeCommandException(
          'Stop $instance before using --prepare',
          2,
        );
      }
      await _prepareGameplayInstance(profile, instance, operationIo);
    }
    if (auth == 'offline' &&
        _instanceGetProperty(profile, instance, 'online-mode') != 'false') {
      throw _NativeCommandException(
        'Offline gameplay auth is not prepared. Run: gameplay prepare $instance',
        2,
      );
    }

    final int startupTimeout = _gameplayPositiveSeconds(
      parsed.option('startup-timeout'),
      fallback: 180,
      option: '--startup-timeout',
    );
    final int assertionTimeout = _gameplayPositiveSeconds(
      parsed.option('assertion-timeout'),
      fallback: 10,
      option: '--assertion-timeout',
    );
    final int connectTimeout = _gameplayPositiveSeconds(
      parsed.option('connect-timeout'),
      fallback: 30,
      option: '--connect-timeout',
    );
    final int scenarioTimeout = _gameplayPositiveSeconds(
      parsed.option('timeout'),
      fallback: 30,
      option: '--timeout',
    );
    final int? viewerPort = _gameplayOptionalPort(
      parsed.option('viewer-port'),
      option: '--viewer-port',
    );
    final String username =
        parsed.option('username') ??
        'VolmitQA${_instanceGetServerPort(profile, instance) % 10000}';
    if (auth == 'offline' &&
        !RegExp(r'^[A-Za-z0-9_]{1,16}$').hasMatch(username)) {
      throw _NativeCommandException(
        'Offline --username must be 1-16 letters, numbers, or underscores',
        2,
      );
    }
    if (state == RuntimeState.stopped && !parsed.flag('start')) {
      throw _NativeCommandException(
        '$instance is stopped. Start it first or pass --start.',
        2,
      );
    }

    final bool wasRunning = state != RuntimeState.stopped;
    bool startedHere = false;
    try {
      if (state == RuntimeState.stopped) {
        await _runtimeStart(profile, instance, operationIo);
        startedHere = true;
      }

      final MinecraftPingResult? ping = await _awaitMinecraftPing(
        profile,
        instance,
        timeout: Duration(seconds: startupTimeout),
      );
      if (ping == null) {
        throw _NativeCommandException(
          '$instance did not become ready within ${startupTimeout}s',
          1,
        );
      }
      if (!json) {
        io.write(
          '[OK] Gameplay target ready: $instance ${ping.versionName} '
          '(${ping.online}/${ping.max} players)',
        );
      }

      if (auth == 'offline' && !parsed.flag('no-op')) {
        final ProcessResult opResult = await _runProcess('tmux', <String>[
          'send-keys',
          '-t',
          _tmuxSessionName(profile, instance),
          'op $username',
          'Enter',
        ]);
        if (opResult.exitCode != 0) {
          throw _NativeCommandException(
            'Failed to grant operator status to $username: ${opResult.stderr}',
            1,
          );
        }
        if (!json) {
          io.write('[OK] Gameplay bot operator enabled: $username');
        }
      }

      final String configuredHost = _instanceGetServerIp(profile, instance);
      final String host =
          configuredHost == '0.0.0.0' ||
              configuredHost == '::' ||
              configuredHost.trim().isEmpty
          ? '127.0.0.1'
          : configuredHost;
      final String? sourceVersion = _serverSource(profile, instance)['mc'];
      final String profilesFolder =
          parsed.option('profiles-folder') ??
          p.join(
            Platform.environment['HOME'] ?? context.rootDir,
            '.multiplexor',
            'mineflayer-profiles',
          );
      final GameplayTestRun run = GameplayTestRun(
        artifactsDirectory: p.join(
          _consumerRoot(profile),
          'state',
          'gameplay-tests',
          instance,
        ),
        assertionTimeoutSeconds: assertionTimeout,
        auth: auth,
        command: parsed.option('command'),
        connectTimeoutSeconds: connectTimeout,
        effect: parsed.option('effect'),
        expected: parsed.option('expect'),
        host: host,
        instance: instance,
        json: json,
        logPath: _runtimeLogFile(profile, instance),
        port: _instanceGetServerPort(profile, instance),
        profilesFolder: auth == 'microsoft' ? profilesFolder : null,
        scenario: File(scenario).existsSync()
            ? File(scenario).absolute.path
            : scenario,
        timeoutSeconds: scenarioTimeout,
        username: username,
        version: parsed.option('version') ?? sourceVersion,
        viewerEnabled: !parsed.flag('no-viewer'),
        viewerPort: viewerPort,
      );
      return await harness.run(run: run, write: io.write, error: io.error);
    } finally {
      if (startedHere && parsed.flag('stop-after')) {
        await _runtimeGracefulStop(profile, instance, operationIo);
      } else if (parsed.flag('stop-after') && wasRunning && !json) {
        io.write(
          '[INFO] $instance was already running; --stop-after left it running',
        );
      }
    }
  }

  String _resolveGameplayInstance(String? input) {
    final String? instance = input?.trim().isNotEmpty == true
        ? input!.trim()
        : _currentInstance(_activeConsumer);
    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }
    return instance;
  }

  Future<void> _prepareGameplayInstance(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) async {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }
    if (!_instanceIsolated(profile, instance)) {
      throw _NativeCommandException(
        'Gameplay preparation is restricted to isolated instances: $instance',
        2,
      );
    }
    if (await _runtimeStateOf(profile, instance) != RuntimeState.stopped) {
      throw _NativeCommandException(
        'Stop $instance before gameplay preparation',
        2,
      );
    }
    _instanceSetProperties(profile, instance, const <String, String>{
      'enforce-secure-profile': 'false',
      'enforce-whitelist': 'false',
      'online-mode': 'false',
      'server-ip': '127.0.0.1',
      'spawn-protection': '0',
      'white-list': 'false',
    });
    io.write(
      '[OK] Gameplay auth prepared: $instance '
      '(isolated, loopback-only, offline auth)',
    );
  }

  int _gameplayPositiveSeconds(
    String? raw, {
    required int fallback,
    required String option,
  }) {
    if (raw == null) {
      return fallback;
    }
    final int? value = int.tryParse(raw);
    if (value == null || value < 1) {
      throw _NativeCommandException('$option must be a positive integer', 2);
    }
    return value;
  }

  int? _gameplayOptionalPort(String? raw, {required String option}) {
    if (raw == null) {
      return null;
    }
    final int? value = int.tryParse(raw);
    if (value == null || value < 1 || value > 65535) {
      throw _NativeCommandException('$option must be between 1 and 65535', 2);
    }
    return value;
  }

  Future<int> _dispatchInstanceDeleteAll(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final everywhere = args.contains('--everywhere');
    final force = args.contains('--force');
    final extras = args
        .where((a) => a != '--everywhere' && a != '--force')
        .toList();
    if (extras.isNotEmpty) {
      throw _NativeCommandException(
        'Usage: instance delete-all [--everywhere] [--force]',
        2,
      );
    }

    if (!everywhere) {
      _instanceDeleteAll(profile, interactive: io.stream && !force);
      io.write('[OK] Deleted all instances');
      return 0;
    }

    // Double confirmation gate for the cross-consumer wipe.
    if (io.stream && !force) {
      stdout.write(
        'Delete EVERY instance across plugin/forge/fabric/neoforge? [y/N]: ',
      );
      final String answer = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (answer != 'y' && answer != 'yes') {
        throw _NativeCommandException('Wipe cancelled', 1);
      }
      stdout.write('Are you sure? [y/N]: ');
      final String again = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (again != 'y' && again != 'yes') {
        throw _NativeCommandException('Wipe cancelled', 1);
      }
    }

    final profiles = <ConsumerProfile>[
      ConsumerProfile.plugin,
      ConsumerProfile.forge,
      ConsumerProfile.fabric,
      ConsumerProfile.neoforge,
    ];
    for (final p in profiles) {
      try {
        _instanceDeleteAll(p, interactive: false);
        io.write('[OK] Deleted all instances in ${p.shortName}');
      } catch (e) {
        io.error('[WARN] Failed wiping ${p.shortName}: $e');
      }
    }
    io.write('[OK] Wipe complete across all consumers');
    return 0;
  }

  Future<int> _dispatchInstanceOpen(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final name = args.isNotEmpty ? args.first : _currentInstance(profile);
    if (name == null || name.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    final dir = _instanceDir(profile, name);
    final opener = _folderOpenerCommand();
    if (opener == null) {
      throw _NativeCommandException(
        'No file-manager opener found for this platform',
        1,
      );
    }
    final result = await Process.run(opener.executable, <String>[
      ...opener.prefixArgs,
      dir,
    ]);
    // Windows explorer.exe returns 1 even on success; treat that as fine.
    final ok = result.exitCode == 0 || Platform.isWindows;
    if (!ok) {
      throw _NativeCommandException(
        'Failed to open folder ($dir): ${result.stderr}',
        result.exitCode == 0 ? 1 : result.exitCode,
      );
    }
    io.write('[OK] Opened: $dir');
    return 0;
  }

  Future<int> _dispatchInstanceIsolated(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    if (args.isEmpty) {
      final current = _currentInstance(profile);
      if (current == null) {
        throw _NativeCommandException('No active instance set', 2);
      }
      io.write(_instanceIsolated(profile, current) ? 'true' : 'false');
      return 0;
    }
    final name = args.first;
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }

    if (args.length == 1) {
      io.write(_instanceIsolated(profile, name) ? 'true' : 'false');
      return 0;
    }

    final raw = args[1].trim().toLowerCase();
    final bool? requested = raw == 'true'
        ? true
        : raw == 'false'
        ? false
        : null;
    if (requested == null) {
      throw _NativeCommandException(
        'Usage: instance isolated [name] [true|false]',
        2,
      );
    }

    final source = Map<String, String>.from(_serverSource(profile, name));
    if (requested) {
      source['isolated'] = 'true';
    } else {
      source.remove('isolated');
    }
    _writeServerSource(_instanceDir(profile, name), fields: source);
    if (requested) {
      io.write('[OK] $name is now isolated (dropins + iris + shared ops off)');
    } else {
      // Rewire shared state for de-isolated plugin consumers.
      if (_isPluginConsumer(profile)) {
        _irisPacksLinkInstance(profile, name);
      }
      _instanceEnsureSharedPluginOps(profile, name);
      io.write('[OK] $name is no longer isolated');
    }
    return 0;
  }

  (String?, String?) _parseNameAndPin(List<String> args) {
    String? name;
    String? pin;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--pin') {
        if (i + 1 < args.length) {
          pin = args[++i].trim();
        }
      } else if (a.startsWith('--pin=')) {
        pin = a.substring('--pin='.length).trim();
      } else if (!a.startsWith('-') && name == null) {
        name = a;
      }
    }
    return (name, pin);
  }

  String? _validatePin(String pin) {
    if (pin.length < 4 || pin.length > 12) {
      return 'PIN must be 4-12 digits';
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      return 'PIN must contain digits only';
    }
    return null;
  }

  /// Reads a line with terminal echo suppressed so the PIN is not shown.
  String _promptHidden(String message) {
    stdout.write(message);
    bool? previous;
    try {
      previous = stdin.echoMode;
      stdin.echoMode = false;
    } catch (_) {}
    final line = stdin.readLineSync() ?? '';
    try {
      if (previous != null) {
        stdin.echoMode = previous;
      }
    } catch (_) {}
    stdout.writeln();
    return line.trim();
  }

  String _promptPinTwice() {
    final first = _promptHidden('Set a PIN (4-12 digits): ');
    final err = _validatePin(first);
    if (err != null) {
      throw _NativeCommandException(err, 2);
    }
    final second = _promptHidden('Confirm PIN: ');
    if (first != second) {
      throw _NativeCommandException('PINs do not match', 2);
    }
    return first;
  }

  Future<int> _dispatchInstanceLocked(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final name = args.isNotEmpty ? args.first : _currentInstance(profile);
    if (name == null || name.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    io.write(_instanceLocked(profile, name) ? 'true' : 'false');
    return 0;
  }

  Future<int> _dispatchInstanceLock(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final (parsedName, parsedPin) = _parseNameAndPin(args);
    final name = parsedName ?? _currentInstance(profile);
    if (name == null || name.isEmpty) {
      throw _NativeCommandException(
        'Usage: instance lock <name> [--pin <digits>]',
        2,
      );
    }
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    if (_instanceLocked(profile, name)) {
      throw _NativeCommandException('Instance "$name" is already locked', 2);
    }

    var pin = parsedPin;
    if ((pin == null || pin.isEmpty) && io.stream) {
      pin = _promptPinTwice();
    }
    if (pin == null || pin.isEmpty) {
      throw _NativeCommandException(
        'A PIN is required to lock. Pass --pin <digits> (4-12 digits).',
        2,
      );
    }
    final err = _validatePin(pin);
    if (err != null) {
      throw _NativeCommandException(err, 2);
    }
    _instanceLock(profile, name, pin);
    io.write(
      '[OK] $name is locked; delete and factory reset are blocked. '
      'Unlock with: instance unlock $name',
    );
    return 0;
  }

  Future<int> _dispatchInstanceUnlock(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final (parsedName, parsedPin) = _parseNameAndPin(args);
    final name = parsedName ?? _currentInstance(profile);
    if (name == null || name.isEmpty) {
      throw _NativeCommandException(
        'Usage: instance unlock <name> [--pin <digits>]',
        2,
      );
    }
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    if (!_instanceLocked(profile, name)) {
      throw _NativeCommandException('Instance "$name" is not locked', 2);
    }

    var pin = parsedPin;
    if ((pin == null || pin.isEmpty) && io.stream) {
      pin = _promptHidden('Enter PIN to unlock $name: ');
    }
    if (pin == null || pin.isEmpty) {
      throw _NativeCommandException(
        'A PIN is required to unlock. Pass --pin <digits>.',
        2,
      );
    }
    if (!_instancePinMatches(profile, name, pin)) {
      throw _NativeCommandException('Incorrect PIN', 2);
    }
    _instanceUnlock(profile, name);
    io.write('[OK] $name is unlocked');
    return 0;
  }

  Future<int> _dispatchInstanceUpdate(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    if (args.isEmpty) {
      throw _NativeCommandException(
        'Usage: instance update <name> [--mc <version>] [--jar <path>] [--auto-build]',
        2,
      );
    }
    final name = args.first;
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }

    final options = _parseOptions(args.sublist(1));
    final source = _serverSource(profile, name);
    final launch = source['launch'] ?? 'jar';
    if (launch != 'jar') {
      throw _NativeCommandException(
        'instance update only supports jar-launch servers; $name uses launch=$launch. Clone + delete is the safer path.',
        2,
      );
    }
    final type = (options['type'] ?? source['type'] ?? 'purpur').toLowerCase();
    final jarOverride = options['jar'];

    if (await _runtimeRunning(profile, name)) {
      io.write('[INFO] Stopping $name before update');
      await _runtimeStop(profile, name, io);
    }

    String resolvedJarPath;
    String? mcLabel;
    bool explicitInstaller = false;
    if (jarOverride != null && jarOverride.isNotEmpty) {
      final file = File(jarOverride);
      if (!file.existsSync()) {
        throw _NativeCommandException('Jar not found: $jarOverride', 2);
      }
      resolvedJarPath = file.absolute.path;
      try {
        resolvedJarPath = file.resolveSymbolicLinksSync();
      } catch (_) {}
      explicitInstaller = _looksLikeInstallerJar(resolvedJarPath);
      resolvedJarPath = await _importManagedLaunchJar(profile, resolvedJarPath);
    } else {
      final requestedMc = options['mc'];
      final mc = requestedMc?.trim().isNotEmpty == true
          ? requestedMc!
          : await _resolveLatestMcVersion(type);
      mcLabel = mc;
      final autoBuild = options['auto-build'] == 'true';
      String? jarPath = _findCachedJar(
        profile,
        type: type,
        mc: mc,
        allowLatestFallback: requestedMc == null,
      );
      if (autoBuild || jarPath == null) {
        io.write('[INFO] Refreshing $type for mc=$mc from upstream sources');
        jarPath = await _buildTarget(
          profile,
          type,
          _serverCreateBuildOptions(options, mc),
          io,
        );
      }
      resolvedJarPath = jarPath;
    }

    final installerBased =
        (type == 'forge' || type == 'neoforge') &&
        (explicitInstaller || _looksLikeInstallerJar(resolvedJarPath));
    if (installerBased) {
      throw _NativeCommandException(
        'instance update only supports jar-launch updates; $resolvedJarPath looks like an installer. Recreate the instance from the installer instead.',
        2,
      );
    }

    final instanceDir = _instanceDir(profile, name);
    final serverJar = p.join(instanceDir, 'server.jar');
    _replaceWithSymlink(serverJar, resolvedJarPath);

    final nextSource = Map<String, String>.from(source);
    nextSource
      ..['type'] = type
      ..['launch'] = 'jar'
      ..['jar'] = resolvedJarPath
      ..remove('args_file_rel')
      ..remove('installer')
      ..remove('jar_rel');
    if (mcLabel != null) {
      nextSource['mc'] = mcLabel;
    }
    final preservedIsolated = source['isolated']?.toLowerCase() == 'true';
    if (preservedIsolated) {
      nextSource['isolated'] = 'true';
    } else {
      nextSource.remove('isolated');
    }
    _writeServerSource(instanceDir, fields: nextSource);
    io.write(
      '[OK] $name updated to $type${mcLabel != null ? ' mc=$mcLabel' : ''}',
    );
    io.write('[INFO] server.jar -> $resolvedJarPath');
    return 0;
  }

  Future<int> _dispatchInstanceSafeUpdate(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final parsed = _parseFlexibleArgs(
      args,
      booleanFlags: const <String>{
        'auto-build',
        'promote',
        'cleanup',
        'keep-staging',
      },
    );
    if (parsed.positionals.length != 1) {
      throw _NativeCommandException(
        'Usage: instance safe-update <name> [--mc <version>] [--type <type>] [--jar <path>] [--auto-build] [--promote] [--cleanup] [--timeout <seconds>]',
        2,
      );
    }

    final name = parsed.positionals.first;
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    _ensureUnlocked(profile, name, action: 'safe-updated');

    final timeoutSeconds = int.tryParse(parsed.option('timeout') ?? '90');
    if (timeoutSeconds == null || timeoutSeconds < 5) {
      throw _NativeCommandException('--timeout must be at least 5 seconds', 2);
    }

    final promote = parsed.flag('promote');
    final cleanup =
        parsed.flag('cleanup') || (promote && !parsed.flag('keep-staging'));
    List<String> updateArgsFor(String target) {
      final out = <String>[target];
      for (final key in const <String>[
        'type',
        'mc',
        'jar',
        'loader',
        'installer',
      ]) {
        final value = parsed.option(key);
        if (value != null && value.trim().isNotEmpty) {
          out.addAll(<String>['--$key', value.trim()]);
        }
      }
      if (parsed.flag('auto-build')) {
        out.add('--auto-build');
      }
      return out;
    }

    final originalPort = _instanceGetServerPort(profile, name);
    final wasRunning = await _runtimeRunning(profile, name);
    if (wasRunning) {
      io.write(
        '[INFO] Stopping $name for a consistent backup and staging clone',
      );
      await _runtimeStop(profile, name, io);
    }

    final backupId = await _backupCreate(
      profile,
      name,
      io,
      label: parsed.option('label') ?? 'safe-update',
      includeLogs: false,
      reason: 'safe-update',
    );

    final stagingBase = _sanitizeSimpleName(
      '$name-safe-update-${_timestampId()}',
    );
    final staging = _uniqueInstanceName(profile, stagingBase);
    _instanceClone(profile, name, staging, io: io);
    final stagingPort = await _findAvailableServerPort(
      profile,
      staging,
      avoidPorts: <int>{originalPort},
    );
    _instanceSetServerPort(profile, staging, stagingPort);
    io.write('[INFO] Staging clone: $staging (port $stagingPort)');
    io.write('[INFO] Safety backup: $backupId');

    if (wasRunning) {
      try {
        await _runtimeStart(profile, name, io);
      } catch (e) {
        io.error(
          '[WARN] Original instance was stopped for cloning but could not be restarted: $e',
        );
      }
    }

    var originalTouched = false;
    try {
      await _dispatchInstanceUpdate(profile, updateArgsFor(staging), io);
      await _runtimeStart(profile, staging, io);
      final ping = await _awaitMinecraftPing(
        profile,
        staging,
        timeout: Duration(seconds: timeoutSeconds),
      );
      if (ping == null) {
        io.error(
          '[WARN] Staging server did not answer Minecraft ping within ${timeoutSeconds}s',
        );
        io.write('[INFO] Staging instance kept for inspection: $staging');
        io.write('[INFO] Restore point: backup restore $name $backupId');
        return 1;
      }

      io.write(
        '[OK] Staging smoke test passed: ${ping.versionName} '
        '(${ping.online}/${ping.max} players)',
      );

      if (promote) {
        io.write('[INFO] Promoting update to $name');
        if (await _runtimeRunning(profile, name)) {
          await _runtimeStop(profile, name, io);
        }
        originalTouched = true;
        await _dispatchInstanceUpdate(profile, updateArgsFor(name), io);
        if (wasRunning) {
          await _runtimeStart(profile, name, io);
        }
        io.write('[OK] Promoted safe update to $name');
      } else {
        io.write(
          '[INFO] Original instance was not changed. Promote manually with:',
        );
        io.write(
          '       ./start.sh instance safe-update $name --promote${_safeUpdateOptionSummary(parsed)}',
        );
      }

      if (cleanup) {
        if (await _runtimeRunning(profile, staging)) {
          await _runtimeStop(profile, staging, io);
        }
        _instanceDelete(profile, staging);
        io.write('[OK] Removed staging instance: $staging');
      } else {
        io.write('[INFO] Staging instance kept: $staging');
      }
      io.write('[INFO] Restore point: backup restore $name $backupId');
      return 0;
    } catch (e) {
      if (originalTouched) {
        io.error(
          '[WARN] Promotion failed; restoring $name from backup $backupId',
        );
        await _backupRestore(profile, name, backupId, io);
        if (wasRunning) {
          await _runtimeStart(profile, name, io);
        }
      }
      if (e is _NativeCommandException) {
        rethrow;
      }
      throw _NativeCommandException('Safe update failed: $e', 1);
    }
  }

  _FolderOpener? _folderOpenerCommand() {
    if (Platform.isMacOS) {
      return const _FolderOpener('open');
    }
    if (Platform.isLinux) {
      return const _FolderOpener('xdg-open');
    }
    if (Platform.isWindows) {
      return const _FolderOpener('explorer', prefixArgs: <String>[]);
    }
    return null;
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
    if (args.isEmpty) {
      throw _NativeCommandException(
        'Usage: server <create|create-many> ...',
        2,
      );
    }
    if (args.first == 'create-many') {
      return _dispatchServerCreateMany(args.sublist(1), io);
    }
    if (args.first != 'create') {
      throw _NativeCommandException(
        'Usage: server <create|create-many> ...',
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
    final _ServerCreateArguments createArguments = _parseServerCreateArguments(
      rest.sublist(1),
    );
    final Map<String, String> options = createArguments.options;

    final type = (options['type'] ?? 'purpur').toLowerCase();
    final jar = options['jar'];
    final profile = _activeConsumer;
    final isolated = options['isolated'] == 'true';
    final List<String> artifacts = createArguments.artifacts;

    if (artifacts.isNotEmpty && !isolated) {
      throw _NativeCommandException(
        '--artifact is only valid with --isolated; subscribed instances receive drop-ins through sync.',
        2,
      );
    }
    final List<File> artifactSources = _resolveSelectedDropinArtifacts(
      profile,
      artifacts,
    );

    if (!_isKnownServerType(type) && (jar == null || jar.isEmpty)) {
      throw _NativeCommandException(
        'Unknown server type: $type. Use --jar <path> for custom server jars.',
        2,
      );
    }
    _ensureConsumerOwnsServerType(profile, type, command: 'server create');

    if (jar != null && jar.isNotEmpty) {
      await _serverCreateFromJar(
        profile,
        name,
        type: type,
        jarPath: jar,
        importJar: true,
        isolated: isolated,
        io: io,
      );
      _copySelectedDropinArtifacts(profile, name, artifactSources, io);
      io.write(
        '[OK] Server instance created: $name ($type, port ${_instanceGetServerPort(profile, name)}${isolated ? ', isolated' : ''})',
      );
      return 0;
    }

    final requestedMc = options['mc'];
    final mc = requestedMc?.trim().isNotEmpty == true
        ? requestedMc!
        : await _resolveLatestMcVersion(type);

    final autoBuild = options['auto-build'] == 'true';
    var jarPath = _findCachedJar(
      profile,
      type: type,
      mc: mc,
      allowLatestFallback: requestedMc == null,
    );
    if (autoBuild) {
      io.write('[INFO] Refreshing $type for mc=$mc from upstream sources');
      jarPath = await _buildTarget(
        profile,
        type,
        _serverCreateBuildOptions(options, mc),
        io,
      );
    }
    if (jarPath == null) {
      throw _NativeCommandException(
        'No cached jar for $type mc=$mc in ${_buildDir(profile, type)}. Run build $type --mc $mc, use server create $name --type $type --mc $mc --auto-build, or use --jar <path>.',
        2,
      );
    }

    await _serverCreateFromJar(
      profile,
      name,
      type: type,
      jarPath: jarPath,
      isolated: isolated,
      io: io,
    );
    _copySelectedDropinArtifacts(profile, name, artifactSources, io);
    io.write(
      '[OK] Server instance created: $name ($type mc=$mc, port ${_instanceGetServerPort(profile, name)}${isolated ? ', isolated' : ''})',
    );
    return 0;
  }

  Future<int> _dispatchServerCreateMany(
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final options = _parseOptions(args);
    final typesRaw = options['types'];
    if (typesRaw == null || typesRaw.trim().isEmpty) {
      throw _NativeCommandException(
        'Usage: server create-many --types <a,b,c> [--prefix N] [--mc v] [--auto-build] [--isolated]',
        2,
      );
    }
    final types = typesRaw
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (types.isEmpty) {
      throw _NativeCommandException('--types list is empty', 2);
    }

    final prefix = options['prefix']?.trim() ?? '';
    final mcOverride = options['mc']?.trim();
    final autoBuild = options['auto-build'] == 'true';
    final isolated = options['isolated'] == 'true';

    int succeeded = 0;
    int skipped = 0;
    for (final type in types) {
      final String name = prefix.isEmpty ? type : '$prefix-$type';
      try {
        final profile = _consumerForServerType(type);
        if (_instanceExists(profile, name)) {
          io.write('[SKIP] $name already exists in ${profile.shortName}');
          skipped++;
          continue;
        }
        final mc = mcOverride != null && mcOverride.isNotEmpty
            ? mcOverride
            : await _resolveLatestMcVersion(type);

        var jarPath = _findCachedJar(
          profile,
          type: type,
          mc: mc,
          allowLatestFallback: mcOverride == null,
        );
        if (autoBuild || jarPath == null) {
          io.write('[INFO] Refreshing $type for mc=$mc from upstream sources');
          jarPath = await _buildTarget(
            profile,
            type,
            _serverCreateBuildOptions(<String, String>{'mc': mc}, mc),
            io,
          );
        }
        await _serverCreateFromJar(
          profile,
          name,
          type: type,
          jarPath: jarPath,
          isolated: isolated,
          io: io,
        );
        io.write(
          '[OK] Created $name ($type mc=$mc, port ${_instanceGetServerPort(profile, name)}, ${profile.shortName}${isolated ? ', isolated' : ''})',
        );
        succeeded++;
      } on _NativeCommandException catch (e) {
        io.error('[WARN] $type failed: ${e.message}');
        skipped++;
      } catch (e) {
        io.error('[WARN] $type failed: $e');
        skipped++;
      }
    }
    io.write('[OK] create-many done: $succeeded created, $skipped skipped');
    return succeeded > 0 ? 0 : 1;
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
        final bool graceful = rest.contains('--graceful');
        final List<String> stopPositional = rest
            .where((String a) => a != '--graceful')
            .toList(growable: false);
        final String? stopTarget = stopPositional.isNotEmpty
            ? stopPositional.first
            : null;
        if (graceful) {
          await _runtimeGracefulStop(profile, stopTarget, io);
        } else {
          await _runtimeStop(profile, stopTarget, io);
        }
        return 0;
      case 'restart':
        final restartParsed = _parseRuntimeTargetArgs(
          rest,
          allowNoConsole: true,
        );
        final target = restartParsed.instance ?? _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        await _runtimeStop(profile, target, io);
        await _runtimeStart(profile, target, io);
        if (!restartParsed.noConsole) {
          await _runtimeConsole(profile, target, io);
        }
        return 0;
      case 'status':
        await _runtimeStatus(profile, rest.isNotEmpty ? rest.first : null, io);
        return 0;
      case 'stats':
        await _runtimeStats(profile, rest.isNotEmpty ? rest.first : null, io);
        return 0;
      case 'list':
        for (final name in await _runtimeListRunning(profile)) {
          io.write(name);
        }
        return 0;
      case 'states':
        for (final name in _instanceNames(profile)) {
          final state = await _runtimeStateOf(profile, name);
          final port = _instanceGetServerPort(profile, name);
          final pid = _readPid(_runtimeServerPidFile(profile, name));
          final locked = _instanceLocked(profile, name) ? 'locked' : 'unlocked';
          final isolated = _instanceIsolated(profile, name)
              ? 'isolated'
              : 'shared';
          io.write(
            '$name\t${state.name}\t$port\t${pid ?? '-'}\t$locked\t$isolated',
          );
        }
        return 0;
      case 'metrics':
        return _runtimeMetrics(profile, io);
      case 'settings':
        return _dispatchRuntimeSettings(profile, rest, io);
      default:
        throw _NativeCommandException(
          'Usage: runtime <console|consoles|consoles-lateral|start|stop|restart|status|stats|states|metrics|list|settings> [instance|args] (start/restart support --instance/--no-console; stop supports --graceful)',
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
        io.write(
          'console wrap:   ${settings.noLineWrap ? 'off (long lines clip)' : 'on (default terminal wrap)'}',
        );
        io.write('console log:    ${settings.consoleLogFormat}');
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
      case 'set-wrap':
        if (rest.isEmpty) {
          throw _NativeCommandException(
            'Usage: runtime settings set-wrap <on|off>',
            2,
          );
        }
        final raw = rest.first.toLowerCase();
        final wrapOn = raw == 'on' || raw == 'true' || raw == 'yes';
        final wrapOff = raw == 'off' || raw == 'false' || raw == 'no';
        if (!wrapOn && !wrapOff) {
          throw _NativeCommandException(
            'Usage: runtime settings set-wrap <on|off>',
            2,
          );
        }
        settings = settings.copyWith(noLineWrap: !wrapOn);
        _runtimeSettingsSave(profile, settings);
        io.write(
          '[OK] Console line wrap ${wrapOn ? 'on' : 'off'} '
          '(takes effect on next runtime start)',
        );
        return 0;
      case 'set-log-format':
        if (rest.isEmpty) {
          throw _NativeCommandException(
            'Usage: runtime settings set-log-format <minimal|default>',
            2,
          );
        }
        final fmt = rest.first.toLowerCase();
        if (fmt != 'minimal' && fmt != 'default') {
          throw _NativeCommandException(
            'Usage: runtime settings set-log-format <minimal|default>',
            2,
          );
        }
        settings = settings.copyWith(consoleLogFormat: fmt);
        _runtimeSettingsSave(profile, settings);
        io.write(
          '[OK] Console log format set to: $fmt '
          '(log file always keeps full format; takes effect on next runtime start)',
        );
        return 0;
      case 'reset':
        settings = const _RuntimeSettingsData();
        _runtimeSettingsSave(profile, settings);
        io.write('[OK] Runtime settings reset to defaults');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: runtime settings <show|presets|set-heap|set-preset|set-wrap|set-log-format|reset>',
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

    if (mods && _isPluginConsumer(profile)) {
      throw _NativeCommandException(
        'The plugin consumer uses plugin drop-ins. Use: plugins <show-source|sync|watch-start|watch-stop|watch-status>',
        2,
      );
    }
    if (!mods && !_isPluginConsumer(profile)) {
      throw _NativeCommandException(
        'The ${profile.shortName} consumer uses mod drop-ins. Use: mods <show-source|sync|watch-start|watch-stop|watch-status>',
        2,
      );
    }

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
            if (_instanceIsolated(profile, instance)) {
              io.write('[SKIP] $instance is isolated');
              continue;
            }
            final report = _pluginsSyncInstance(
              profile,
              instance,
              clean: clean,
              sourceModsOverride: mods,
              strict: true,
              preserveLocalChanges: false,
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
        if (_instanceIsolated(profile, target)) {
          io.write('[SKIP] $target is isolated; nothing to sync');
          return 0;
        }
        final report = _pluginsSyncInstance(
          profile,
          target,
          clean: clean,
          sourceModsOverride: mods,
          strict: true,
          preserveLocalChanges: false,
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
            if (_instanceIsolated(profile, instance)) {
              io.write('[SKIP] Iris packs: $instance is isolated');
              continue;
            }
            _irisPacksLinkInstance(profile, instance);
            io.write('[OK] Iris packs linked: $instance');
          }
          return 0;
        }
        final target = rest.isNotEmpty ? rest.first : _currentInstance(profile);
        if (target == null || target.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        if (_instanceIsolated(profile, target)) {
          throw _NativeCommandException(
            '$target is isolated; cannot link shared Iris packs',
            2,
          );
        }
        _irisPacksLinkInstance(profile, target);
        io.write('[OK] Iris packs linked: $target');
        return 0;
      case 'watch-start':
        return _pluginsWatchStart(profile, io, mods: mods);
      case 'watch-stop':
        return _pluginsWatchStop(profile, io, mods: mods);
      case 'watch-status':
        return _pluginsWatchStatus(profile, io, mods: mods);
      case 'watch-daemon':
        return _pluginsWatchDaemon(profile, io, mods: mods);
      default:
        throw _NativeCommandException(
          mods
              ? 'Usage: mods <show-source|sync|watch-start|watch-stop|watch-status>'
              : 'Usage: plugins <show-source|sync|iris-packs-path|iris-packs-link|watch-start|watch-stop|watch-status>',
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
            'Usage: build latest <paper|purpur|folia|canvas|leaf|forge|fabric|neoforge|spigot>',
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
      case 'cache-info':
        final parsed = _parseFlexibleArgs(rest);
        final target = parsed.positionals.isEmpty
            ? 'all'
            : parsed.positionals.first;
        _buildCacheInfo(profile, target, parsed.option('mc'), io);
        return 0;
      case 'test-latest':
        final testOptions = _parseOptions(rest);
        await _buildTestLatest(profile, testOptions, io);
        return 0;
      case 'prune':
        final parsed = _parseFlexibleArgs(rest);
        final target = parsed.positionals.isEmpty
            ? 'all'
            : parsed.positionals.first;
        await _buildPrune(target, io);
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
        final buildOptions = _parseOptions(rest);
        _ensureConsumerOwnsServerType(profile, sub, command: 'build $sub');
        await _buildTarget(profile, sub, buildOptions, io);
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: build <paper|purpur|folia|canvas|leaf|spigot|forge|fabric|neoforge|latest|list|list-all|versions|cache-info|test-latest|prune>',
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
          'Usage: repos sync [all|paper|purpur|folia|canvas|leaf]',
          2,
        );
    }
  }

  Future<int> _dispatchDoctor(List<String> args, _NativeIoBuffer io) async {
    final parsed = _parseFlexibleArgs(
      args,
      booleanFlags: const <String>{'fix', 'json'},
    );
    if (parsed.positionals.isNotEmpty) {
      throw _NativeCommandException('Usage: doctor [--fix] [--json]', 2);
    }

    final fix = parsed.flag('fix');
    final json = parsed.flag('json');
    final checks = <_DoctorCheck>[];

    void add(String level, String name, String detail) {
      checks.add(_DoctorCheck(level: level, name: name, detail: detail));
    }

    Future<void> requireTool(
      String executable,
      List<String> versionArgs,
    ) async {
      try {
        // Through the shell on Windows: the tools most worth reporting on
        // (dart, npm) are installed there as .bat/.cmd shims, which
        // CreateProcess cannot launch by itself, so a direct spawn calls
        // every one of them missing on a machine that has them all.
        final result = await Process.run(
          executable,
          versionArgs,
          runInShell: Platform.isWindows,
        );
        final output = '${result.stdout}\n${result.stderr}'
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join(' ');
        if (result.exitCode == 0) {
          add('PASS', executable, output.isEmpty ? 'available' : output);
        } else {
          // A shell reports a missing command by failing rather than by
          // refusing to start, so its output is the only account of what
          // actually went wrong.
          add(
            'FAIL',
            executable,
            output.isEmpty ? 'command exited ${result.exitCode}' : output,
          );
        }
      } on ProcessException catch (e) {
        add('FAIL', executable, e.message);
      } catch (e) {
        add('FAIL', executable, '$e');
      }
    }

    if (fix) {
      for (final profile in ConsumerProfile.values) {
        consumerService.ensureConsumerDirs(profile);
        final active = _currentInstance(profile);
        if (active != null && _instanceExists(profile, active)) {
          _instanceActivate(profile, active);
        }
      }
    }

    final root = Directory(context.rootDir);
    add(root.existsSync() ? 'PASS' : 'FAIL', 'workspace root', context.rootDir);

    final marker = File(
      p.join(context.rootDir, '.multiplexor', 'workspace.yaml'),
    );
    add(
      marker.existsSync() ? 'PASS' : 'WARN',
      'workspace marker',
      marker.existsSync() ? marker.path : 'missing .multiplexor/workspace.yaml',
    );

    final stateDir = Directory(p.join(context.rootDir, '.manager-state'));
    add(
      stateDir.existsSync() ? 'PASS' : 'FAIL',
      'manager state',
      stateDir.path,
    );

    final activeProfile = _activeConsumer;
    add('PASS', 'active consumer', activeProfile.shortName);
    final consumerRoot = Directory(_consumerRoot(activeProfile));
    add(
      consumerRoot.existsSync() ? 'PASS' : 'FAIL',
      'consumer root',
      consumerRoot.path,
    );

    for (final profile in ConsumerProfile.values) {
      final instances = Directory(_instancesDir(profile));
      add(
        instances.existsSync() ? 'PASS' : 'WARN',
        '${profile.shortName} instances',
        instances.path,
      );
      final current = _currentInstance(profile);
      if (current != null && current.isNotEmpty) {
        add(
          _instanceExists(profile, current) ? 'PASS' : 'FAIL',
          '${profile.shortName} active instance',
          current,
        );
      }
    }

    await requireTool('dart', const <String>['--version']);
    await requireTool('java', const <String>['-version']);
    await requireTool('git', const <String>['--version']);
    await requireTool('tmux', const <String>['-V']);
    await requireTool('node', const <String>['--version']);
    await requireTool('npm', const <String>['--version']);
    final GameplayTestService gameplayHarness = GameplayTestService(
      context: context,
    );
    add(
      gameplayHarness.installed ? 'PASS' : 'FAIL',
      'Mineflayer harness',
      gameplayHarness.installed
          ? gameplayHarness.harnessDirectory
          : 'not installed; run gameplay setup',
    );

    final seenPorts = <int, String>{};
    for (final profile in ConsumerProfile.values) {
      for (final instance in _instanceNames(profile)) {
        final sourceFile = File(
          p.join(_instanceDir(profile, instance), '.server-source'),
        );
        add(
          sourceFile.existsSync() ? 'PASS' : 'WARN',
          '${profile.shortName}/$instance source metadata',
          sourceFile.existsSync() ? sourceFile.path : 'missing .server-source',
        );

        final port = _instanceGetServerPort(profile, instance);
        final owner = seenPorts[port];
        if (owner == null) {
          seenPorts[port] = '${profile.shortName}/$instance';
        } else {
          add(
            'WARN',
            'duplicate configured port',
            '$port used by $owner and ${profile.shortName}/$instance',
          );
        }

        if (await _runtimeRunning(profile, instance) &&
            await _runtimeSocketPortInUse(port)) {
          add('PASS', '${profile.shortName}/$instance port', '$port is bound');
        }
      }
    }

    final rootActiveLink = _rootActiveInstanceLink();
    if (_isLink(rootActiveLink)) {
      final target = _resolveLinkTargetAbsolute(rootActiveLink);
      add(
        target != null && Directory(target).existsSync() ? 'PASS' : 'WARN',
        'root active-instance link',
        target ?? 'unresolved',
      );
    }

    if (json) {
      io.write(
        jsonEncode(<String, dynamic>{
          'root': context.rootDir,
          'active_consumer': activeProfile.shortName,
          'checks': checks
              .map(
                (check) => <String, String>{
                  'level': check.level,
                  'name': check.name,
                  'detail': check.detail,
                },
              )
              .toList(growable: false),
        }),
      );
    } else {
      io.write('Multiplexor doctor');
      io.write('workspace: ${context.rootDir}');
      io.write('consumer:  ${activeProfile.shortName}');
      io.write('');
      for (final check in checks) {
        io.write('[${check.level}] ${check.name}: ${check.detail}');
      }
    }

    return checks.any((check) => check.level == 'FAIL') ? 1 : 0;
  }

  Future<int> _dispatchBackup(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'create':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'include-logs'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: backup create [instance] [--label <label>] [--include-logs]',
            2,
          );
        }
        final instance = parsed.positionals.isNotEmpty
            ? parsed.positionals.first
            : _currentInstance(profile);
        if (instance == null || instance.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        final id = await _backupCreate(
          profile,
          instance,
          io,
          label: parsed.option('label'),
          includeLogs: parsed.flag('include-logs'),
          reason: 'manual',
        );
        io.write('[OK] Backup created: $id');
        return 0;
      case 'list':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'all'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: backup list [instance|--all]',
            2,
          );
        }
        final target = parsed.flag('all')
            ? null
            : (parsed.positionals.isNotEmpty ? parsed.positionals.first : null);
        _backupList(profile, target, io);
        return 0;
      case 'restore':
        final parsed = _parseFlexibleArgs(rest);
        String? instance;
        String? id;
        if (parsed.positionals.length == 1) {
          id = parsed.positionals[0];
          instance = parsed.option('instance') ?? _currentInstance(profile);
        } else if (parsed.positionals.length == 2) {
          instance = parsed.positionals[0];
          id = parsed.positionals[1];
        }
        if (instance == null || id == null) {
          throw _NativeCommandException(
            'Usage: backup restore [instance] <backup-id>',
            2,
          );
        }
        await _backupRestore(profile, instance, id, io);
        io.write('[OK] Restored $instance from backup $id');
        return 0;
      case 'delete':
        final parsed = _parseFlexibleArgs(rest);
        final (instance, id) = _backupResolveInstanceAndId(parsed);
        final backup = _findBackup(profile, id, instance: instance);
        _deletePathEntity(backup.path, recursive: true);
        io.write('[OK] Deleted backup: ${backup.instance}/${backup.id}');
        return 0;
      case 'verify':
        final parsed = _parseFlexibleArgs(rest);
        final (instance, id) = _backupResolveInstanceAndId(parsed);
        final backup = _findBackup(profile, id, instance: instance);
        _backupVerify(backup);
        io.write('[OK] Backup verified: ${backup.instance}/${backup.id}');
        return 0;
      case 'prune':
        final parsed = _parseFlexibleArgs(rest);
        final keepRaw = parsed.option('keep') ?? '10';
        final keep = int.tryParse(keepRaw);
        if (keep == null || keep < 0) {
          throw _NativeCommandException(
            '--keep must be a non-negative integer',
            2,
          );
        }
        final instance = parsed.positionals.isEmpty
            ? null
            : parsed.positionals.first;
        final deleted = _backupPrune(profile, keep: keep, instance: instance);
        io.write('[OK] Pruned $deleted backup(s)');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: backup <create|list|restore|delete|prune|verify> ...',
          2,
        );
    }
  }

  Future<int> _dispatchTemplate(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'list':
        final dir = Directory(_templatesDir());
        if (!dir.existsSync()) {
          io.write('(none)');
          return 0;
        }
        final names =
            dir
                .listSync()
                .whereType<File>()
                .where((file) => file.path.endsWith('.yaml'))
                .map((file) => p.basenameWithoutExtension(file.path))
                .toList(growable: false)
              ..sort();
        if (names.isEmpty) {
          io.write('(none)');
        } else {
          for (final name in names) {
            io.write(name);
          }
        }
        return 0;
      case 'init':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'isolated'},
        );
        if (parsed.positionals.length != 1) {
          throw _NativeCommandException(
            'Usage: template init <name> [--type <type>] [--mc <version>] [--heap <size>] [--preset <name>] [--isolated]',
            2,
          );
        }
        final name = _validateSimpleName(
          parsed.positionals.first,
          label: 'template',
        );
        final path = _templatePath(name);
        if (File(path).existsSync()) {
          throw _NativeCommandException('Template already exists: $name', 2);
        }
        final template = <String, dynamic>{
          'name': name,
          'type': parsed.option('type') ?? 'purpur',
          if (parsed.option('mc') != null) 'mc': parsed.option('mc'),
          if (parsed.option('heap') != null) 'heap': parsed.option('heap'),
          if (parsed.option('preset') != null)
            'jvm_preset': parsed.option('preset'),
          'isolated': parsed.flag('isolated'),
          'server_properties': <String, String>{'server-port': '25565'},
          'dropins': <String, dynamic>{'clean': false},
        };
        _writeYamlMap(File(path), template);
        io.write('[OK] Template created: $name');
        io.write('[INFO] $path');
        return 0;
      case 'show':
        final name = _requireTemplateName(rest, 'Usage: template show <name>');
        final file = File(_templatePath(name));
        if (!file.existsSync()) {
          throw _NativeCommandException('Template not found: $name', 2);
        }
        io.write(file.readAsStringSync().trimRight());
        return 0;
      case 'delete':
        final name = _requireTemplateName(
          rest,
          'Usage: template delete <name>',
        );
        final file = File(_templatePath(name));
        if (!file.existsSync()) {
          throw _NativeCommandException('Template not found: $name', 2);
        }
        file.deleteSync();
        io.write('[OK] Template deleted: $name');
        return 0;
      case 'export':
        if (rest.length != 2) {
          throw _NativeCommandException(
            'Usage: template export <instance> <template-name>',
            2,
          );
        }
        final instance = rest[0];
        final name = _validateSimpleName(rest[1], label: 'template');
        if (!_instanceExists(profile, instance)) {
          throw _NativeCommandException('Instance not found: $instance', 2);
        }
        final template = _templateFromInstance(profile, instance, name);
        final path = _templatePath(name);
        _writeYamlMap(File(path), template);
        io.write('[OK] Exported template: $name');
        io.write('[INFO] $path');
        return 0;
      case 'apply':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'auto-build', 'sync'},
        );
        if (parsed.positionals.length != 2) {
          throw _NativeCommandException(
            'Usage: template apply <template-name> <instance> [--auto-build] [--sync]',
            2,
          );
        }
        final name = _validateSimpleName(
          parsed.positionals[0],
          label: 'template',
        );
        final instance = parsed.positionals[1];
        final template = _loadTemplate(name);
        await _templateApply(profile, name, template, instance, parsed, io);
        io.write('[OK] Template applied: $name -> $instance');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: template <list|init|show|apply|export|delete> ...',
          2,
        );
    }
  }

  Future<int> _dispatchContent(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'search':
        final parsed = _parseFlexibleArgs(rest);
        final query = parsed.positionals.join(' ').trim();
        if (query.isEmpty) {
          throw _NativeCommandException('Usage: content search <query>', 2);
        }
        await _contentSearch(profile, query, io);
        return 0;
      case 'install':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'sync'},
        );
        if (parsed.positionals.length != 1) {
          throw _NativeCommandException(
            'Usage: content install <modrinth-slug|url> [--mc <version>] [--loader <loader>] [--name <alias>] [--sync]',
            2,
          );
        }
        final input = parsed.positionals.first;
        if (_looksLikeUrl(input) || parsed.option('source') == 'url') {
          await _contentInstallUrl(profile, input, parsed, io);
        } else {
          await _contentInstallModrinth(profile, input, parsed, io);
        }
        if (parsed.flag('sync')) {
          await _contentSync(profile, null, all: true, clean: false, io: io);
        }
        return 0;
      case 'list':
        _contentList(profile, io);
        return 0;
      case 'remove':
        final parsed = _parseFlexibleArgs(rest);
        if (parsed.positionals.length != 1) {
          throw _NativeCommandException('Usage: content remove <name>', 2);
        }
        _contentRemove(profile, parsed.positionals.first, io);
        return 0;
      case 'update':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'all', 'sync'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: content update [name|--all] [--sync]',
            2,
          );
        }
        await _contentUpdate(
          profile,
          parsed.flag('all') || parsed.positionals.isEmpty
              ? null
              : parsed.positionals.first,
          io,
        );
        if (parsed.flag('sync')) {
          await _contentSync(profile, null, all: true, clean: false, io: io);
        }
        return 0;
      case 'sync':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'all', 'clean'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: content sync [instance|--all] [--clean]',
            2,
          );
        }
        await _contentSync(
          profile,
          parsed.positionals.isEmpty ? null : parsed.positionals.first,
          all: parsed.flag('all'),
          clean: parsed.flag('clean'),
          io: io,
        );
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: content <search|install|list|update|remove|sync> ...',
          2,
        );
    }
  }

  _FlexibleArgs _parseFlexibleArgs(
    List<String> args, {
    Set<String> booleanFlags = const <String>{},
  }) {
    final options = <String, String>{};
    final flags = <String, bool>{};
    final positionals = <String>[];

    for (var i = 0; i < args.length; i++) {
      final token = args[i];
      if (!token.startsWith('--')) {
        positionals.add(token);
        continue;
      }

      final raw = token.substring(2);
      if (raw.contains('=')) {
        final eq = raw.indexOf('=');
        final key = raw.substring(0, eq);
        final value = raw.substring(eq + 1);
        if (booleanFlags.contains(key)) {
          flags[key] = _parseFlagValue(value);
        } else {
          options[key] = value;
        }
        continue;
      }

      if (booleanFlags.contains(raw)) {
        flags[raw] = true;
        continue;
      }

      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        options[raw] = args[i + 1];
        i++;
      } else {
        flags[raw] = true;
      }
    }

    return _FlexibleArgs(
      options: options,
      flags: flags,
      positionals: positionals,
    );
  }

  bool _parseFlagValue(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized != 'false' &&
        normalized != '0' &&
        normalized != 'no' &&
        normalized != 'off';
  }

  String _timestampId() {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}T'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${three(now.millisecond)}Z';
  }

  String _sanitizeSimpleName(String value, {String fallback = 'item'}) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    return sanitized.isEmpty ? fallback : sanitized;
  }

  String _validateSimpleName(String value, {required String label}) {
    final name = value.trim();
    if (name.isEmpty || name != _sanitizeSimpleName(name)) {
      throw _NativeCommandException(
        '$label name must contain only letters, numbers, dot, underscore, or dash',
        2,
      );
    }
    return name;
  }

  String _uniqueInstanceName(ConsumerProfile profile, String base) {
    var candidate = _sanitizeSimpleName(base, fallback: 'instance');
    if (!_instanceExists(profile, candidate)) {
      return candidate;
    }
    for (var i = 2; i < 1000; i++) {
      final next = '$candidate-$i';
      if (!_instanceExists(profile, next)) {
        return next;
      }
    }
    throw _NativeCommandException('Could not find a free instance name', 1);
  }

  String _safeUpdateOptionSummary(_FlexibleArgs parsed) {
    final out = <String>[];
    for (final key in const <String>[
      'type',
      'mc',
      'jar',
      'loader',
      'installer',
      'timeout',
    ]) {
      final value = parsed.option(key);
      if (value != null && value.trim().isNotEmpty) {
        out.add('--$key ${_shellQuote(value.trim())}');
      }
    }
    if (parsed.flag('auto-build')) {
      out.add('--auto-build');
    }
    return out.isEmpty ? '' : ' ${out.join(' ')}';
  }

  Future<int> _findAvailableServerPort(
    ConsumerProfile profile,
    String instance, {
    Set<int> avoidPorts = const <int>{},
  }) async {
    final configured = <int>{...avoidPorts};
    for (final candidateProfile in ConsumerProfile.values) {
      for (final other in _instanceNames(candidateProfile)) {
        if (candidateProfile == profile && other == instance) {
          continue;
        }
        configured.add(_instanceGetServerPort(candidateProfile, other));
      }
    }

    for (var port = 25565; port <= 65535; port++) {
      if (configured.contains(port)) {
        continue;
      }
      if (!await _runtimeSocketPortInUse(port)) {
        return port;
      }
    }
    throw _NativeCommandException('No available port found in 25565-65535', 2);
  }

  Future<MinecraftPingResult?> _awaitMinecraftPing(
    ConsumerProfile profile,
    String instance, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final host = _instanceGetServerIp(profile, instance);
      final port = _instanceGetServerPort(profile, instance);
      final ping = await pingMinecraftServer(
        host == '0.0.0.0' ? '127.0.0.1' : host,
        port,
        timeout: const Duration(milliseconds: 1200),
      );
      if (ping != null) {
        return ping;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  String _backupsDir(ConsumerProfile profile) {
    return p.join(_consumerRoot(profile), 'backups');
  }

  Future<String> _backupCreate(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io, {
    String? label,
    required bool includeLogs,
    required String reason,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final safeLabel = label == null || label.trim().isEmpty
        ? ''
        : '-${_sanitizeSimpleName(label, fallback: 'backup')}';
    final id = '${_timestampId()}$safeLabel';
    final backupDir = p.join(_backupsDir(profile), instance, id);
    final snapshotDir = p.join(backupDir, 'snapshot');
    Directory(snapshotDir).createSync(recursive: true);

    _copyDirectoryFilteredForBackup(
      Directory(_instanceDir(profile, instance)),
      Directory(snapshotDir),
      includeLogs: includeLogs,
    );

    final manifest = <String, dynamic>{
      'version': 1,
      'id': id,
      'consumer': profile.shortName,
      'instance': instance,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'label': label?.trim() ?? '',
      'reason': reason,
      'include_logs': includeLogs,
      'snapshot': 'snapshot',
      'entries': _backupManifestEntries(snapshotDir),
    };
    File(p.join(backupDir, 'manifest.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    io.write('[INFO] Backup path: $backupDir');
    return Future<String>.value(id);
  }

  void _copyDirectoryFilteredForBackup(
    Directory src,
    Directory dst, {
    required bool includeLogs,
  }) {
    if (!src.existsSync()) {
      return;
    }
    dst.createSync(recursive: true);
    for (final entity in src.listSync(recursive: false, followLinks: false)) {
      final base = p.basename(entity.path);
      if (!includeLogs && base == 'logs') {
        continue;
      }
      final target = p.join(dst.path, base);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          _copyDirectoryFilteredForBackup(
            Directory(entity.path),
            Directory(target),
            includeLogs: includeLogs,
          );
          break;
        case FileSystemEntityType.file:
          File(target).createSync(recursive: true);
          File(entity.path).copySync(target);
          break;
        case FileSystemEntityType.link:
          _replaceWithSymlink(target, Link(entity.path).targetSync());
          break;
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
        case FileSystemEntityType.notFound:
          break;
      }
    }
  }

  List<Map<String, dynamic>> _backupManifestEntries(String snapshotDir) {
    final entries = <Map<String, dynamic>>[];
    void walk(String dirPath) {
      for (final entity in Directory(dirPath).listSync(followLinks: false)) {
        final rel = p.relative(entity.path, from: snapshotDir);
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        switch (type) {
          case FileSystemEntityType.file:
            final file = File(entity.path);
            final stat = file.statSync();
            entries.add(<String, dynamic>{
              'path': rel,
              'type': 'file',
              'size': stat.size,
              'sha256': _sha256File(file),
            });
            break;
          case FileSystemEntityType.link:
            entries.add(<String, dynamic>{
              'path': rel,
              'type': 'link',
              'target': Link(entity.path).targetSync(),
            });
            break;
          case FileSystemEntityType.directory:
            walk(entity.path);
            break;
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
          case FileSystemEntityType.notFound:
            break;
        }
      }
    }

    walk(snapshotDir);
    entries.sort(
      (a, b) => a['path'].toString().compareTo(b['path'].toString()),
    );
    return entries;
  }

  String _sha256File(File file) {
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  List<_BackupEntry> _backupEntries(
    ConsumerProfile profile, {
    String? instance,
  }) {
    final root = Directory(_backupsDir(profile));
    if (!root.existsSync()) {
      return const <_BackupEntry>[];
    }
    final entries = <_BackupEntry>[];
    final instanceDirs = instance != null
        ? <Directory>[Directory(p.join(root.path, instance))]
        : root.listSync(followLinks: false).whereType<Directory>().toList();
    for (final instanceDir in instanceDirs) {
      if (!instanceDir.existsSync()) {
        continue;
      }
      final instanceName = p.basename(instanceDir.path);
      for (final backupDir
          in instanceDir.listSync(followLinks: false).whereType<Directory>()) {
        entries.add(
          _BackupEntry(
            profile: profile,
            instance: instanceName,
            id: p.basename(backupDir.path),
            path: backupDir.path,
          ),
        );
      }
    }
    entries.sort((a, b) {
      final byInstance = a.instance.compareTo(b.instance);
      return byInstance != 0 ? byInstance : b.id.compareTo(a.id);
    });
    return entries;
  }

  void _backupList(
    ConsumerProfile profile,
    String? instance,
    _NativeIoBuffer io,
  ) {
    final entries = _backupEntries(profile, instance: instance);
    if (entries.isEmpty) {
      io.write('(none)');
      return;
    }
    for (final entry in entries) {
      final manifest = entry.manifest;
      final label = manifest['label']?.toString().trim() ?? '';
      final created = manifest['created_at']?.toString().trim() ?? entry.id;
      final suffix = label.isEmpty ? '' : ' label=$label';
      io.write('${entry.instance}/${entry.id}  $created$suffix');
    }
  }

  (String?, String) _backupResolveInstanceAndId(_FlexibleArgs parsed) {
    if (parsed.positionals.length == 1) {
      return (parsed.option('instance'), parsed.positionals.first);
    }
    if (parsed.positionals.length == 2) {
      return (parsed.positionals.first, parsed.positionals[1]);
    }
    throw _NativeCommandException(
      'Usage: backup <delete|verify> [instance] <backup-id>',
      2,
    );
  }

  _BackupEntry _findBackup(
    ConsumerProfile profile,
    String id, {
    String? instance,
  }) {
    if (id.contains('/') || id.contains('\\') || id.contains('..')) {
      throw _NativeCommandException('Invalid backup id: $id', 2);
    }
    final matches = _backupEntries(
      profile,
      instance: instance,
    ).where((entry) => entry.id == id).toList(growable: false);
    if (matches.isEmpty) {
      throw _NativeCommandException('Backup not found: $id', 2);
    }
    if (matches.length > 1) {
      throw _NativeCommandException(
        'Backup id $id exists for multiple instances. Use: backup <command> <instance> $id',
        2,
      );
    }
    return matches.single;
  }

  Future<void> _backupRestore(
    ConsumerProfile profile,
    String instance,
    String id,
    _NativeIoBuffer io,
  ) async {
    final backup = _findBackup(profile, id, instance: instance);
    final snapshot = Directory(p.join(backup.path, 'snapshot'));
    if (!snapshot.existsSync()) {
      throw _NativeCommandException(
        'Backup snapshot is missing: ${backup.path}',
        1,
      );
    }

    if (_instanceExists(profile, instance)) {
      _ensureUnlocked(profile, instance, action: 'restored');
      if (await _runtimeRunning(profile, instance)) {
        await _runtimeStop(profile, instance, io);
      }
    }

    _backupVerify(backup);

    final target = _instanceDir(profile, instance);
    final tmp = '$target.restore-${DateTime.now().millisecondsSinceEpoch}';
    _deletePathEntity(tmp, recursive: true);
    _copyDirectory(snapshot, Directory(tmp));
    _deletePathEntity(target, recursive: true);
    try {
      Directory(tmp).renameSync(target);
    } catch (_) {
      _copyDirectory(Directory(tmp), Directory(target));
      _deletePathEntity(tmp, recursive: true);
    }
    _instanceEnsureRestartScript(profile, instance);
    if (!_instanceIsolated(profile, instance)) {
      _instanceEnsureSharedPluginOps(profile, instance, io: io);
    }
    if (_currentInstance(profile) == instance) {
      _instanceActivate(profile, instance);
    }
  }

  void _backupVerify(_BackupEntry backup) {
    final manifest = backup.manifest;
    final snapshotDir = p.join(
      backup.path,
      manifest['snapshot']?.toString() ?? 'snapshot',
    );
    final entries = manifest['entries'];
    if (entries is! List) {
      throw _NativeCommandException(
        'Invalid backup manifest: ${backup.path}',
        1,
      );
    }
    for (final raw in entries) {
      if (raw is! Map) {
        continue;
      }
      final rel = raw['path']?.toString() ?? '';
      final type = raw['type']?.toString() ?? '';
      if (rel.isEmpty) {
        continue;
      }
      final path = p.join(snapshotDir, rel);
      if (type == 'file') {
        final file = File(path);
        if (!file.existsSync()) {
          throw _NativeCommandException('Backup file missing: $rel', 1);
        }
        final expected = raw['sha256']?.toString() ?? '';
        if (expected.isNotEmpty && _sha256File(file) != expected) {
          throw _NativeCommandException('Backup checksum mismatch: $rel', 1);
        }
      } else if (type == 'link') {
        if (!_isLink(path)) {
          throw _NativeCommandException('Backup link missing: $rel', 1);
        }
      }
    }
  }

  int _backupPrune(
    ConsumerProfile profile, {
    required int keep,
    String? instance,
  }) {
    final byInstance = <String, List<_BackupEntry>>{};
    for (final entry in _backupEntries(profile, instance: instance)) {
      byInstance.putIfAbsent(entry.instance, () => <_BackupEntry>[]).add(entry);
    }
    var deleted = 0;
    for (final entries in byInstance.values) {
      entries.sort((a, b) => b.id.compareTo(a.id));
      for (final entry in entries.skip(keep)) {
        _deletePathEntity(entry.path, recursive: true);
        deleted++;
      }
    }
    return deleted;
  }

  String _templatesDir() {
    return p.join(context.rootDir, '.multiplexor', 'templates');
  }

  String _templatePath(String name) {
    return p.join(_templatesDir(), '$name.yaml');
  }

  String _requireTemplateName(List<String> args, String usage) {
    if (args.length != 1) {
      throw _NativeCommandException(usage, 2);
    }
    return _validateSimpleName(args.first, label: 'template');
  }

  Map<String, dynamic> _loadTemplate(String name) {
    final file = File(_templatePath(name));
    if (!file.existsSync()) {
      throw _NativeCommandException('Template not found: $name', 2);
    }
    final parsed = _yamlToDart(loadYaml(file.readAsStringSync()));
    if (parsed is! Map) {
      throw _NativeCommandException('Template must be a YAML map: $name', 2);
    }
    return Map<String, dynamic>.from(parsed);
  }

  dynamic _yamlToDart(dynamic value) {
    if (value is YamlMap) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _yamlToDart(entry.value),
      };
    }
    if (value is YamlList) {
      return value.map(_yamlToDart).toList(growable: false);
    }
    return value;
  }

  void _writeYamlMap(File file, Map<String, dynamic> map) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${_yamlFormatMap(map, 0)}\n');
  }

  String _yamlFormatMap(Map<String, dynamic> map, int indent) {
    if (map.isEmpty) {
      return '${''.padLeft(indent)}{}';
    }
    final lines = <String>[];
    final spaces = ''.padLeft(indent);
    for (final entry in map.entries) {
      final key = _yamlKey(entry.key);
      final value = entry.value;
      if (_yamlIsScalar(value)) {
        lines.add('$spaces$key: ${_yamlScalar(value)}');
      } else {
        lines.add('$spaces$key:');
        lines.add(_yamlFormat(value, indent + 2));
      }
    }
    return lines.join('\n');
  }

  String _yamlFormat(dynamic value, int indent) {
    final spaces = ''.padLeft(indent);
    if (value is Map) {
      return _yamlFormatMap(Map<String, dynamic>.from(value), indent);
    }
    if (value is List) {
      if (value.isEmpty) {
        return '$spaces[]';
      }
      final lines = <String>[];
      for (final item in value) {
        if (_yamlIsScalar(item)) {
          lines.add('$spaces- ${_yamlScalar(item)}');
        } else {
          lines.add('$spaces-');
          lines.add(_yamlFormat(item, indent + 2));
        }
      }
      return lines.join('\n');
    }
    return '$spaces${_yamlScalar(value)}';
  }

  bool _yamlIsScalar(dynamic value) {
    return value == null || value is String || value is num || value is bool;
  }

  String _yamlScalar(dynamic value) {
    if (value == null) {
      return 'null';
    }
    if (value is bool || value is num) {
      return value.toString();
    }
    final text = value.toString();
    if (RegExp(r'^[A-Za-z0-9._/@:+-]+$').hasMatch(text) &&
        text != 'null' &&
        text != 'true' &&
        text != 'false') {
      return text;
    }
    return jsonEncode(text);
  }

  String _yamlKey(String key) {
    return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key) ? key : jsonEncode(key);
  }

  Map<String, dynamic> _templateFromInstance(
    ConsumerProfile profile,
    String instance,
    String name,
  ) {
    final source = _serverSource(profile, instance);
    final settings = _runtimeSettingsLoad(profile);
    final jar = source['jar'] ?? source['installer'];
    return <String, dynamic>{
      'name': name,
      'type': source['type'] ?? 'custom',
      if (source['mc'] != null) 'mc': source['mc'],
      if (jar != null && (source['type'] ?? '') == 'custom') 'jar': jar,
      'heap': settings.heap,
      'jvm_preset': settings.profile,
      'isolated': _instanceIsolated(profile, instance),
      'server_properties': _readServerPropertiesMap(profile, instance),
      'dropins': <String, dynamic>{'clean': false},
    };
  }

  Map<String, String> _readServerPropertiesMap(
    ConsumerProfile profile,
    String instance,
  ) {
    final file = File(_instanceServerProperties(profile, instance));
    if (!file.existsSync()) {
      return const <String, String>{};
    }
    final out = <String, String>{};
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) {
        continue;
      }
      final idx = line.indexOf('=');
      out[line.substring(0, idx)] = line.substring(idx + 1);
    }
    return out;
  }

  Future<void> _templateApply(
    ConsumerProfile profile,
    String templateName,
    Map<String, dynamic> template,
    String instance,
    _FlexibleArgs parsed,
    _NativeIoBuffer io,
  ) async {
    final type =
        (template['type']?.toString().trim().toLowerCase() ?? 'purpur');
    if (type != 'custom') {
      final expected = _consumerForServerType(type);
      if (expected != profile) {
        throw _NativeCommandException(
          'Template $templateName targets $type. Switch consumer first: consumer use ${expected.shortName}',
          2,
        );
      }
    }

    final createArgs = <String>['create', instance, '--type', type];
    void addOption(String key, String cliName) {
      final value = template[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        createArgs.addAll(<String>['--$cliName', value]);
      }
    }

    addOption('mc', 'mc');
    addOption('loader', 'loader');
    addOption('installer', 'installer');
    addOption('jar', 'jar');
    if (_truthy(template['isolated']) || parsed.flag('isolated')) {
      createArgs.add('--isolated');
    }
    if (_truthy(template['auto_build']) || parsed.flag('auto-build')) {
      createArgs.add('--auto-build');
    }

    await _dispatchServer(createArgs, io);

    final properties = _stringMap(template['server_properties']);
    if (properties.isNotEmpty) {
      _applyServerProperties(profile, instance, properties);
    }

    final settings = _runtimeSettingsLoad(profile);
    var nextSettings = settings;
    final heap = template['heap']?.toString().trim();
    if (heap != null && heap.isNotEmpty) {
      if (!_runtimeHeapLooksValid(heap)) {
        throw _NativeCommandException('Invalid template heap value: $heap', 2);
      }
      nextSettings = nextSettings.copyWith(heap: heap.toUpperCase());
    }
    final preset = template['jvm_preset']?.toString().trim().toLowerCase();
    if (preset != null && preset.isNotEmpty) {
      final args = _runtimeSettingsPresets[preset];
      if (args == null) {
        throw _NativeCommandException(
          'Unknown template JVM preset: $preset',
          2,
        );
      }
      nextSettings = nextSettings.copyWith(profile: preset, jvmArgs: args);
    }
    if (nextSettings.heap != settings.heap ||
        nextSettings.profile != settings.profile ||
        nextSettings.jvmArgs != settings.jvmArgs) {
      _runtimeSettingsSave(profile, nextSettings);
      io.write('[INFO] Runtime settings updated for ${profile.shortName}');
    }

    final dropins = _mapValue(template['dropins']);
    final cleanDropins = _truthy(dropins['clean']);
    if (parsed.flag('sync') || cleanDropins) {
      final report = _pluginsSyncInstance(
        profile,
        instance,
        clean: cleanDropins,
        sourceModsOverride: !_isPluginConsumer(profile),
        strict: true,
        preserveLocalChanges: false,
      );
      io.write('[SYNC] ${report.copiedJars.length} jar(s) synced to $instance');
    }
  }

  bool _truthy(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  Map<String, dynamic> _mapValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return const <String, dynamic>{};
  }

  Map<String, String> _stringMap(dynamic value) {
    final map = _mapValue(value);
    return <String, String>{
      for (final entry in map.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  void _applyServerProperties(
    ConsumerProfile profile,
    String instance,
    Map<String, String> overrides,
  ) {
    _ensureLocalServerProperties(profile, instance);
    final file = File(_instanceServerProperties(profile, instance));
    final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
    final remaining = Map<String, String>.from(overrides);
    final next = <String>[];
    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('#') || !trimmed.contains('=')) {
        next.add(raw);
        continue;
      }
      final key = trimmed.substring(0, trimmed.indexOf('=')).trim();
      if (remaining.containsKey(key)) {
        next.add('$key=${remaining.remove(key)}');
      } else {
        next.add(raw);
      }
    }
    for (final entry in remaining.entries) {
      next.add('${entry.key}=${entry.value}');
    }
    file.writeAsStringSync('${next.join('\n')}\n');
  }

  String _contentManifestFile(ConsumerProfile profile) {
    return p.join(_stateDir(profile), 'content-lock.yaml');
  }

  Map<String, dynamic> _contentManifestLoad(ConsumerProfile profile) {
    final file = File(_contentManifestFile(profile));
    if (!file.existsSync()) {
      return <String, dynamic>{
        'version': 1,
        'consumer': profile.shortName,
        'entries': <Map<String, dynamic>>[],
      };
    }
    final parsed = _yamlToDart(loadYaml(file.readAsStringSync()));
    if (parsed is! Map) {
      throw _NativeCommandException(
        'Invalid content lockfile: ${file.path}',
        1,
      );
    }
    final manifest = Map<String, dynamic>.from(parsed);
    manifest['entries'] = _contentEntriesFromManifest(manifest);
    return manifest;
  }

  List<Map<String, dynamic>> _contentEntriesFromManifest(
    Map<String, dynamic> manifest,
  ) {
    final raw = manifest['entries'];
    if (raw is! List) {
      return <Map<String, dynamic>>[];
    }
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: true);
  }

  void _contentManifestSave(
    ConsumerProfile profile,
    List<Map<String, dynamic>> entries,
  ) {
    entries.sort(
      (a, b) => a['name'].toString().compareTo(b['name'].toString()),
    );
    _writeYamlMap(File(_contentManifestFile(profile)), <String, dynamic>{
      'version': 1,
      'consumer': profile.shortName,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'entries': entries,
    });
  }

  Future<void> _contentSearch(
    ConsumerProfile profile,
    String query,
    _NativeIoBuffer io,
  ) async {
    final facets = <List<String>>[
      <String>['project_type:${_contentProjectType(profile)}'],
    ];
    final uri = Uri.https('api.modrinth.com', '/v2/search', <String, String>{
      'query': query,
      'limit': '10',
      'facets': jsonEncode(facets),
    });
    final payload = await _httpGetJsonObject(uri.toString());
    final hits = payload['hits'];
    if (hits is! List || hits.isEmpty) {
      io.write('(none)');
      return;
    }
    for (final raw in hits) {
      if (raw is! Map) {
        continue;
      }
      final title = raw['title']?.toString() ?? 'Untitled';
      final slug =
          raw['slug']?.toString() ?? raw['project_id']?.toString() ?? '-';
      final downloads = raw['downloads']?.toString() ?? '0';
      final versions = raw['versions'] is List
          ? (raw['versions'] as List).take(4).join(',')
          : '';
      io.write(
        '$slug  $title  downloads=$downloads${versions.isEmpty ? '' : '  versions=$versions'}',
      );
    }
  }

  String _contentProjectType(ConsumerProfile profile) {
    return _isPluginConsumer(profile) ? 'plugin' : 'mod';
  }

  bool _looksLikeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Future<void> _contentInstallUrl(
    ConsumerProfile profile,
    String url,
    _FlexibleArgs parsed,
    _NativeIoBuffer io,
  ) async {
    if (!_looksLikeUrl(url)) {
      throw _NativeCommandException('Invalid URL: $url', 2);
    }
    final uri = Uri.parse(url);
    final rawName =
        parsed.option('name') ?? p.basenameWithoutExtension(uri.path);
    final name = _sanitizeSimpleName(rawName, fallback: 'content');
    final fileName = _sanitizeJarFileName(
      parsed.option('file') ?? p.basename(uri.path),
      fallback: '$name.jar',
    );
    final output = p.join(
      _dropinsSource(profile, mods: !_isPluginConsumer(profile)),
      fileName,
    );
    await _downloadToFile(url, output, io: io);
    final entry = <String, dynamic>{
      'name': name,
      'source': 'url',
      'url': url,
      'file': fileName,
      'sha256': _sha256File(File(output)),
      'installed_at': DateTime.now().toUtc().toIso8601String(),
    };
    _contentSaveOrReplace(profile, entry, io);
    io.write('[OK] Installed content: $name -> $fileName');
  }

  Future<void> _contentInstallModrinth(
    ConsumerProfile profile,
    String slug,
    _FlexibleArgs parsed,
    _NativeIoBuffer io,
  ) async {
    final entry = await _contentResolveAndDownloadModrinth(
      profile,
      slug: slug,
      name: parsed.option('name'),
      mc: await _contentMinecraftVersion(profile, parsed),
      loader: _contentLoader(profile, parsed),
      io: io,
    );
    _contentSaveOrReplace(profile, entry, io);
    io.write(
      '[OK] Installed ${entry['name']} ${entry['version_number']} -> ${entry['file']}',
    );
  }

  Future<Map<String, dynamic>> _contentResolveAndDownloadModrinth(
    ConsumerProfile profile, {
    required String slug,
    required String? name,
    required String mc,
    required String loader,
    required _NativeIoBuffer io,
  }) async {
    final project = await _httpGetJsonObject(
      Uri.https('api.modrinth.com', '/v2/project/$slug').toString(),
    );
    final projectType = project['project_type']?.toString() ?? '';
    final expectedType = _contentProjectType(profile);
    if (projectType.isNotEmpty && projectType != expectedType) {
      throw _NativeCommandException(
        '$slug is a Modrinth $projectType, but ${profile.shortName} expects $expectedType content',
        2,
      );
    }
    final projectId = project['id']?.toString() ?? slug;
    final title = project['title']?.toString() ?? slug;
    final version = await _contentResolveModrinthVersion(projectId, mc, loader);
    final files = version['files'];
    if (files is! List || files.isEmpty) {
      throw _NativeCommandException('No downloadable files for $slug', 1);
    }
    Map<String, dynamic>? selectedFile;
    for (final raw in files.whereType<Map>()) {
      final file = Map<String, dynamic>.from(raw);
      final filename = file['filename']?.toString().toLowerCase() ?? '';
      if (filename.endsWith('.jar') && file['primary'] == true) {
        selectedFile = file;
        break;
      }
      if (filename.endsWith('.jar')) {
        selectedFile ??= file;
      }
    }
    if (selectedFile == null) {
      throw _NativeCommandException('No jar file found for $slug', 1);
    }
    final url = selectedFile['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw _NativeCommandException('No download URL found for $slug', 1);
    }
    final fileName = _sanitizeJarFileName(
      selectedFile['filename']?.toString() ?? '$slug.jar',
      fallback: '$slug.jar',
    );
    final output = p.join(
      _dropinsSource(profile, mods: !_isPluginConsumer(profile)),
      fileName,
    );
    await _downloadToFile(url, output, io: io);
    final hashes = _mapValue(selectedFile['hashes']);
    return <String, dynamic>{
      'name': _sanitizeSimpleName(name ?? slug, fallback: slug),
      'source': 'modrinth',
      'slug': slug,
      'project_id': projectId,
      'title': title,
      'mc': mc,
      'loader': loader,
      'version_id': version['id']?.toString() ?? '',
      'version_number': version['version_number']?.toString() ?? '',
      'file': fileName,
      'url': url,
      if (hashes['sha512'] != null)
        'upstream_sha512': hashes['sha512'].toString(),
      if (hashes['sha1'] != null) 'upstream_sha1': hashes['sha1'].toString(),
      'sha256': _sha256File(File(output)),
      'installed_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _contentResolveModrinthVersion(
    String projectId,
    String mc,
    String loader,
  ) async {
    Future<List<dynamic>> fetch({required String? loaderFilter}) {
      final query = <String, String>{
        'game_versions': jsonEncode(<String>[mc]),
        if (loaderFilter != null && loaderFilter.isNotEmpty)
          'loaders': jsonEncode(<String>[loaderFilter]),
      };
      final uri = Uri.https(
        'api.modrinth.com',
        '/v2/project/$projectId/version',
        query,
      );
      return _httpGetJsonList(uri.toString());
    }

    var versions = await fetch(loaderFilter: loader);
    if (versions.isEmpty &&
        _isPluginConsumer(_activeConsumer) &&
        loader != 'paper') {
      versions = await fetch(loaderFilter: 'paper');
    }
    if (versions.isEmpty) {
      versions = await fetch(loaderFilter: null);
    }
    for (final raw in versions) {
      if (raw is! Map) {
        continue;
      }
      final version = Map<String, dynamic>.from(raw);
      final files = version['files'];
      if (files is List &&
          files.whereType<Map>().any(
            (file) => (file['filename']?.toString().toLowerCase() ?? '')
                .endsWith('.jar'),
          )) {
        return version;
      }
    }
    throw _NativeCommandException(
      'No compatible Modrinth version found for project=$projectId mc=$mc loader=$loader',
      1,
    );
  }

  Future<String> _contentMinecraftVersion(
    ConsumerProfile profile,
    _FlexibleArgs parsed,
  ) async {
    final explicit = parsed.option('mc')?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final current = _currentInstance(profile);
    if (current != null && _instanceExists(profile, current)) {
      final source = _serverSource(profile, current);
      final mc = source['mc']?.trim();
      if (mc != null && mc.isNotEmpty) {
        return mc;
      }
    }
    final latest = await _latestMinecraftRelease();
    if (latest.isNotEmpty) {
      return latest;
    }
    throw _NativeCommandException(
      'Use --mc <version> to select content compatibility',
      2,
    );
  }

  String _contentLoader(ConsumerProfile profile, _FlexibleArgs parsed) {
    final explicit = parsed.option('loader')?.trim().toLowerCase();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    if (!_isPluginConsumer(profile)) {
      return profile.shortName;
    }
    final current = _currentInstance(profile);
    if (current != null && _instanceExists(profile, current)) {
      final type = _instanceSourceType(profile, current);
      if (type == 'paper' ||
          type == 'purpur' ||
          type == 'folia' ||
          type == 'spigot') {
        return type;
      }
    }
    return 'paper';
  }

  String _sanitizeJarFileName(String value, {required String fallback}) {
    var name = p.basename(value.trim());
    if (name.isEmpty || name == '.' || name == '..') {
      name = fallback;
    }
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    if (!name.toLowerCase().endsWith('.jar')) {
      name = '$name.jar';
    }
    return name;
  }

  void _contentSaveOrReplace(
    ConsumerProfile profile,
    Map<String, dynamic> entry,
    _NativeIoBuffer io,
  ) {
    final manifest = _contentManifestLoad(profile);
    final entries = _contentEntriesFromManifest(manifest);
    final name = entry['name']?.toString() ?? '';
    final source = entry['source']?.toString() ?? '';
    final identity =
        entry[source == 'modrinth' ? 'slug' : 'url']?.toString() ?? '';
    final dropins = _dropinsSource(profile, mods: !_isPluginConsumer(profile));
    entries.removeWhere((existing) {
      final sameName = existing['name']?.toString() == name;
      final sameIdentity =
          existing['source']?.toString() == source &&
          (existing[source == 'modrinth' ? 'slug' : 'url']?.toString() ?? '') ==
              identity;
      if (sameName || sameIdentity) {
        final oldFile = existing['file']?.toString() ?? '';
        final nextFile = entry['file']?.toString() ?? '';
        if (oldFile.isNotEmpty && oldFile != nextFile) {
          File(p.join(dropins, oldFile)).deleteSyncSafe();
          io.write('[INFO] Removed old content file: $oldFile');
        }
        return true;
      }
      return false;
    });
    entries.add(entry);
    _contentManifestSave(profile, entries);
  }

  void _contentList(ConsumerProfile profile, _NativeIoBuffer io) {
    final entries = _contentEntriesFromManifest(_contentManifestLoad(profile));
    if (entries.isEmpty) {
      io.write('(none)');
      return;
    }
    for (final entry in entries) {
      final name = entry['name']?.toString() ?? '-';
      final source = entry['source']?.toString() ?? '-';
      final version =
          entry['version_number']?.toString() ??
          entry['url']?.toString() ??
          '-';
      final file = entry['file']?.toString() ?? '-';
      io.write('$name  $source  $version  $file');
    }
  }

  void _contentRemove(
    ConsumerProfile profile,
    String name,
    _NativeIoBuffer io,
  ) {
    final manifest = _contentManifestLoad(profile);
    final entries = _contentEntriesFromManifest(manifest);
    final dropins = _dropinsSource(profile, mods: !_isPluginConsumer(profile));
    Map<String, dynamic>? removed;
    entries.removeWhere((entry) {
      final matches =
          entry['name']?.toString() == name ||
          entry['slug']?.toString() == name;
      if (matches) {
        removed = entry;
      }
      return matches;
    });
    if (removed == null) {
      throw _NativeCommandException('Content entry not found: $name', 2);
    }
    final file = removed!['file']?.toString() ?? '';
    if (file.isNotEmpty) {
      File(p.join(dropins, file)).deleteSyncSafe();
    }
    _contentManifestSave(profile, entries);
    io.write('[OK] Removed content: $name');
  }

  Future<void> _contentUpdate(
    ConsumerProfile profile,
    String? target,
    _NativeIoBuffer io,
  ) async {
    final manifest = _contentManifestLoad(profile);
    final entries = _contentEntriesFromManifest(manifest);
    if (entries.isEmpty) {
      io.write('(none)');
      return;
    }
    var matched = 0;
    final nextEntries = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final name = entry['name']?.toString() ?? '';
      final slug = entry['slug']?.toString() ?? '';
      final shouldUpdate = target == null || target == name || target == slug;
      if (!shouldUpdate) {
        nextEntries.add(entry);
        continue;
      }
      matched++;
      final source = entry['source']?.toString() ?? '';
      if (source == 'modrinth') {
        final updated = await _contentResolveAndDownloadModrinth(
          profile,
          slug: slug,
          name: name,
          mc: entry['mc']?.toString() ?? await _latestMinecraftRelease(),
          loader:
              entry['loader']?.toString() ??
              _contentLoader(profile, _FlexibleArgs.empty),
          io: io,
        );
        _contentDeleteOldFileIfChanged(profile, entry, updated);
        nextEntries.add(updated);
        io.write('[OK] Updated $name -> ${updated['version_number']}');
      } else if (source == 'url') {
        final url = entry['url']?.toString() ?? '';
        if (url.isEmpty) {
          throw _NativeCommandException(
            'URL content entry missing url: $name',
            1,
          );
        }
        final file = entry['file']?.toString() ?? '$name.jar';
        final output = p.join(
          _dropinsSource(profile, mods: !_isPluginConsumer(profile)),
          file,
        );
        await _downloadToFile(url, output, io: io);
        final updated = Map<String, dynamic>.from(entry)
          ..['sha256'] = _sha256File(File(output))
          ..['installed_at'] = DateTime.now().toUtc().toIso8601String();
        nextEntries.add(updated);
        io.write('[OK] Updated $name');
      } else {
        nextEntries.add(entry);
        io.write('[WARN] Unknown content source for $name; skipped');
      }
    }
    if (matched == 0) {
      throw _NativeCommandException('Content entry not found: $target', 2);
    }
    _contentManifestSave(profile, nextEntries);
  }

  void _contentDeleteOldFileIfChanged(
    ConsumerProfile profile,
    Map<String, dynamic> oldEntry,
    Map<String, dynamic> newEntry,
  ) {
    final oldFile = oldEntry['file']?.toString() ?? '';
    final newFile = newEntry['file']?.toString() ?? '';
    if (oldFile.isEmpty || oldFile == newFile) {
      return;
    }
    File(
      p.join(
        _dropinsSource(profile, mods: !_isPluginConsumer(profile)),
        oldFile,
      ),
    ).deleteSyncSafe();
  }

  Future<void> _contentSync(
    ConsumerProfile profile,
    String? target, {
    required bool all,
    required bool clean,
    required _NativeIoBuffer io,
  }) {
    final instances = all
        ? _instanceNames(profile)
        : <String>[target ?? _currentInstance(profile) ?? ''];
    if (instances.isEmpty || instances.first.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }
    for (final instance in instances) {
      final report = _pluginsSyncInstance(
        profile,
        instance,
        clean: clean,
        sourceModsOverride: !_isPluginConsumer(profile),
        strict: true,
        preserveLocalChanges: false,
      );
      io.write('[SYNC] $instance copied ${report.copiedJars.length} jar(s)');
    }
    return Future<void>.value();
  }

  Future<void> _reposSync(
    ConsumerProfile profile,
    String target,
    _NativeIoBuffer io,
  ) async {
    if (target == 'all' && !_isPluginConsumer(profile)) {
      io.write(
        '[INFO] ${profile.shortName} resolves versions from upstream metadata APIs at build time.',
      );
      io.write('[INFO] No upstream repos to sync for this consumer.');
      return;
    }

    final types = switch (target) {
      'all' => const <String>['paper', 'purpur', 'folia', 'canvas', 'leaf'],
      'paper' || 'purpur' || 'folia' || 'canvas' || 'leaf' => <String>[target],
      'forge' || 'fabric' || 'neoforge' => throw _NativeCommandException(
        '$target resolves versions from upstream metadata APIs; there is no repo to sync. Use: build $target [--mc <version>]',
        2,
      ),
      _ => throw _NativeCommandException(
        'Usage: repos sync [all|paper|purpur|folia|canvas|leaf]',
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
    final String daemonShellCommand =
        'cd ${_shellQuote(context.rootDir)} && $daemonCommand >> ${_shellQuote(logFilePath)} 2>&1';

    final result = await _runProcess('tmux', <String>[
      'new-session',
      '-d',
      '-s',
      session,
      'sh -lc ${_shellQuote(daemonShellCommand)}',
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
            preserveLocalChanges: true,
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
          if (report.preservedJars.isNotEmpty) {
            io.error(
              '[WARN] Watch sync preserved local jar(s) in $instance: ${report.preservedJars.join(', ')}',
            );
            io.error(
              '[WARN] Run ${mods ? 'mods' : 'plugins'} sync $instance to replace them from dropins.',
            );
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
            preserveLocalChanges: true,
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
          if (report.preservedJars.isNotEmpty) {
            io.error(
              '[WARN] Watch sync preserved local jar(s) in $instance: ${report.preservedJars.join(', ')}',
            );
            io.error(
              '[WARN] Run ${mods ? 'mods' : 'plugins'} sync $instance to replace them from dropins.',
            );
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
    // spigot is always included: it only reaches BuildTools when its upstream
    // Jenkins build is newer than the cached jar, so covering it costs nothing
    // on the common path. `--spigot-mc` pins it to a version of its own,
    // because spigot lags the other platforms on a fresh Minecraft release.
    final targets = <String>[
      'paper',
      'purpur',
      'folia',
      'canvas',
      'leaf',
      'spigot',
    ];
    final failures = <String>[];
    final spigotMc = options['spigot-mc']?.trim();

    for (final type in targets) {
      final pinned =
          type == 'spigot' && spigotMc != null && spigotMc.isNotEmpty;
      try {
        await _buildTarget(
          profile,
          type,
          pinned ? <String, String>{'mc': spigotMc} : const <String, String>{},
          io,
        );
      } catch (e) {
        failures.add('$type: $e');
      }
    }

    if (failures.isNotEmpty) {
      throw _NativeCommandException(
        'test-latest completed with failures:\n${failures.join('\n')}',
        1,
      );
    }
  }

  Future<String> _buildTarget(
    ConsumerProfile profile,
    String type,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    final normalized = type.toLowerCase();
    final requestedMc = options['mc']?.trim();
    if (requestedMc != null && requestedMc.isNotEmpty) {
      return _buildTargetVersion(profile, normalized, requestedMc, options, io);
    }

    final latest = await _resolveLatestMcVersion(normalized);
    try {
      return await _buildTargetVersion(
        profile,
        normalized,
        latest,
        options,
        io,
      );
    } on _NativeCommandException catch (firstFailure) {
      // BuildTools compiles are minutes long and fail for reasons a different
      // Minecraft version will not fix, so only downloaded platforms retry.
      if (BuildCachePolicy.expensiveRebuild.contains(normalized)) {
        rethrow;
      }

      final fallbacks = buildVersionCandidates(
        latest: latest,
        supported: await _buildSupportedVersions(profile, normalized),
      ).skip(1).toList(growable: false);
      if (fallbacks.isEmpty) {
        rethrow;
      }

      final failures = <String>['mc=$latest: ${firstFailure.message}'];
      var attempted = latest;
      for (final fallback in fallbacks) {
        io.error(
          '[WARN] No $normalized build for mc=$attempted; '
          'trying mc=$fallback instead',
        );
        attempted = fallback;
        try {
          return await _buildTargetVersion(
            profile,
            normalized,
            fallback,
            options,
            io,
          );
        } on _NativeCommandException catch (e) {
          failures.add('mc=$fallback: ${e.message}');
        }
      }

      throw _NativeCommandException(
        'No downloadable $normalized build found:\n${failures.join('\n')}',
        1,
      );
    }
  }

  Future<String> _buildTargetVersion(
    ConsumerProfile profile,
    String normalized,
    String mc,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    final String jar = await _buildTargetJar(
      profile,
      normalized,
      mc,
      options,
      io,
    );
    _pruneBuildCache(profile, normalized, io);
    return jar;
  }

  Future<String> _buildTargetJar(
    ConsumerProfile profile,
    String normalized,
    String mc,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    switch (normalized) {
      case 'paper':
      case 'folia':
        return _buildDownloadPaperLike(profile, normalized, mc, io);
      case 'purpur':
        return _buildDownloadPurpur(profile, mc, io);
      case 'leaf':
        return _buildDownloadLeaf(profile, mc, io);
      case 'canvas':
        return _buildDownloadCanvas(profile, mc, io);
      case 'fabric':
        return _buildDownloadFabric(
          profile,
          mc,
          options['loader']?.trim(),
          options['installer']?.trim(),
          io,
        );
      case 'forge':
        return _buildDownloadForge(profile, mc, options['loader']?.trim(), io);
      case 'neoforge':
        return _buildDownloadNeoForge(
          profile,
          mc,
          options['loader']?.trim(),
          io,
        );
      case 'spigot':
        return _buildWithBuildTools(
          profile,
          mc,
          io,
          force: options['force'] == 'true',
        );
      default:
        throw _NativeCommandException('Unknown build target: $normalized', 2);
    }
  }

  Future<String> _buildDownloadPaperLike(
    ConsumerProfile profile,
    String type,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final buildsUrl =
        'https://fill.papermc.io/v3/projects/$type/versions/$mc/builds';
    final buildsRaw = await _httpGetJsonList(buildsUrl);

    // Prefer the highest STABLE build, falling back to the highest build of any
    // channel when a freshly released Minecraft version only has experimental
    // builds. Fill v3 exposes the ready-to-use download URL directly.
    var bestStableBuild = -1;
    String? stableDownloadUrl;
    var bestAnyBuild = -1;
    String? anyDownloadUrl;
    for (final raw in buildsRaw) {
      if (raw is! Map) {
        continue;
      }
      final build = raw['id'];
      final downloads = raw['downloads'];
      if (build is! num || downloads is! Map) {
        continue;
      }
      final primary = downloads['server:default'];
      if (primary is! Map) {
        continue;
      }
      final url = primary['url'];
      if (url is! String || url.trim().isEmpty) {
        continue;
      }
      final buildNumber = build.toInt();
      if (buildNumber > bestAnyBuild) {
        bestAnyBuild = buildNumber;
        anyDownloadUrl = url.trim();
      }
      final isStable =
          raw['channel']?.toString().trim().toUpperCase() == 'STABLE';
      if (isStable && buildNumber > bestStableBuild) {
        bestStableBuild = buildNumber;
        stableDownloadUrl = url.trim();
      }
    }

    final bestBuild = bestStableBuild > 0 ? bestStableBuild : bestAnyBuild;
    final downloadUrl = bestStableBuild > 0
        ? stableDownloadUrl
        : anyDownloadUrl;
    if (bestBuild <= 0 || downloadUrl == null) {
      throw _NativeCommandException(
        'No downloadable $type build found for mc=$mc',
        1,
      );
    }

    final output = p.join(_buildDir(profile, type), '$type-$mc-$bestBuild.jar');
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, type, output);
    io.write('[OK] Cached $type build $bestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildDownloadPurpur(
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
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'purpur', output);
    io.write('[OK] Cached purpur build $latestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildDownloadLeaf(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final payload = await _httpGetJsonObject(
      'https://api.leafmc.one/v2/projects/leaf/versions/$mc/builds',
    );
    final builds = payload['builds'];
    if (builds is! List || builds.isEmpty) {
      throw _NativeCommandException('No Leaf builds available for mc=$mc', 1);
    }

    // Prefer the highest stable ("default" channel) build, falling back to the
    // highest build of any channel when a version only has experimental builds.
    // Leaf's v2 API exposes the jar name under downloads.primary.name (Paper
    // uses downloads.application), so the URL is assembled explicitly.
    var bestStableBuild = -1;
    String? stableJarName;
    var bestAnyBuild = -1;
    String? anyJarName;
    for (final raw in builds) {
      if (raw is! Map) {
        continue;
      }
      final build = raw['build'];
      final downloads = raw['downloads'];
      if (build is! num || downloads is! Map) {
        continue;
      }
      final primary = downloads['primary'];
      if (primary is! Map) {
        continue;
      }
      final jarName = primary['name'];
      if (jarName is! String || jarName.trim().isEmpty) {
        continue;
      }
      final buildNumber = build.toInt();
      if (buildNumber > bestAnyBuild) {
        bestAnyBuild = buildNumber;
        anyJarName = jarName.trim();
      }
      final isStable =
          raw['channel']?.toString().trim().toLowerCase() == 'default';
      if (isStable && buildNumber > bestStableBuild) {
        bestStableBuild = buildNumber;
        stableJarName = jarName.trim();
      }
    }

    final bestBuild = bestStableBuild > 0 ? bestStableBuild : bestAnyBuild;
    final jarName = bestStableBuild > 0 ? stableJarName : anyJarName;
    if (bestBuild <= 0 || jarName == null) {
      throw _NativeCommandException(
        'No downloadable Leaf build found for mc=$mc',
        1,
      );
    }

    final downloadUrl =
        'https://api.leafmc.one/v2/projects/leaf/versions/$mc/builds/$bestBuild/downloads/$jarName';
    final output = p.join(
      _buildDir(profile, 'leaf'),
      'leaf-$mc-$bestBuild.jar',
    );
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'leaf', output);
    io.write('[OK] Cached leaf build $bestBuild for mc=$mc');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildDownloadCanvas(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io,
  ) async {
    final payload = await _httpGetJsonObject(
      'https://canvasmc.io/api/v2/builds/all?project=canvas&channel=$mc&experimental=true',
    );
    final builds = payload['builds'];
    if (builds is! List || builds.isEmpty) {
      throw _NativeCommandException('No Canvas builds available for mc=$mc', 1);
    }

    Map<String, dynamic>? selectedStable;
    Map<String, dynamic>? selectedAny;
    for (final raw in builds) {
      if (raw is! Map) {
        continue;
      }
      final candidate = Map<String, dynamic>.from(raw);
      // Failed Jenkins builds are listed without artifacts, so they have no
      // download URL and must be skipped.
      final candidateUrl = candidate['downloadUrl']?.toString().trim() ?? '';
      if (candidateUrl.isEmpty) {
        continue;
      }
      final experimental = candidate['isExperimental'] == true;
      if (!experimental) {
        selectedStable = _newerCanvasBuild(selectedStable, candidate);
      }
      selectedAny = _newerCanvasBuild(selectedAny, candidate);
    }
    final selected = selectedStable ?? selectedAny;
    if (selected == null) {
      throw _NativeCommandException(
        'No downloadable Canvas build found for mc=$mc',
        1,
      );
    }

    final downloadUrl = selected['downloadUrl'].toString().trim();
    final buildNumber = selected['buildNumber']?.toString().trim() ?? 'unknown';
    final channel =
        selected['channelVersion']?.toString().trim().isNotEmpty == true
        ? selected['channelVersion'].toString().trim()
        : mc;
    final output = p.join(
      _buildDir(profile, 'canvas'),
      'canvas-$channel-$buildNumber.jar',
    );
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'canvas', output);
    io.write('[OK] Cached canvas build $buildNumber for mc=$channel');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Map<String, dynamic> _newerCanvasBuild(
    Map<String, dynamic>? current,
    Map<String, dynamic> candidate,
  ) {
    if (current == null) {
      return candidate;
    }

    final currentNumber = int.tryParse(
      current['buildNumber']?.toString().trim() ?? '',
    );
    final candidateNumber = int.tryParse(
      candidate['buildNumber']?.toString().trim() ?? '',
    );
    if (candidateNumber == null) {
      return current;
    }
    if (currentNumber == null || candidateNumber > currentNumber) {
      return candidate;
    }
    return current;
  }

  Future<String> _buildDownloadFabric(
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
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'fabric', output);
    io.write(
      '[OK] Cached fabric server launcher for mc=$mc loader=$loader installer=$installer',
    );
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildDownloadForge(
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
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'forge', output);
    io.write('[OK] Cached forge installer for mc=$mc loader=$loader');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildDownloadNeoForge(
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
    await _downloadToFile(downloadUrl, output, io: io);
    _registerBuiltJar(profile, 'neoforge', output);
    io.write('[OK] Cached neoforge installer for loader=$loader');
    io.write('[INFO] Jar: $output');
    return output;
  }

  Future<String> _buildWithBuildTools(
    ConsumerProfile profile,
    String mc,
    _NativeIoBuffer io, {
    bool force = false,
  }) async {
    final buildDir = _buildDir(profile, 'spigot');
    final toolsDir = p.join(buildDir, 'tools');
    Directory(buildDir).createSync(recursive: true);
    Directory(toolsDir).createSync(recursive: true);

    // Spigot has no build API, but the version manifest carries the Jenkins
    // build the refs point at. Naming the jar after it makes "is this the
    // newest Spigot?" answerable without a ten-minute BuildTools compile.
    final spigotBuild = await _resolveSpigotBuildNumber(mc);
    final output = p.join(
      buildDir,
      spigotBuild == null ? 'spigot-$mc.jar' : 'spigot-$mc-$spigotBuild.jar',
    );
    // Only a positively resolved build number proves the cached jar is the
    // current upstream one. If the lookup failed, compile rather than trust an
    // unnumbered jar of unknown age — otherwise a single network hiccup pins
    // spigot to a stale build forever.
    if (!force && spigotBuild != null && File(output).existsSync()) {
      _registerBuiltJar(profile, 'spigot', output);
      io.write(
        '[OK] spigot build $spigotBuild for mc=$mc is already the newest '
        'upstream build; skipping BuildTools',
      );
      io.write('[INFO] Jar: $output');
      return output;
    }

    final buildToolsUrl =
        Platform.environment['SPIGOT_BUILDTOOLS_URL']?.trim().isNotEmpty == true
        ? Platform.environment['SPIGOT_BUILDTOOLS_URL']!.trim()
        : 'https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar';
    final buildToolsJar = p.join(toolsDir, 'BuildTools.jar');
    final cachedBuildTools = File(buildToolsJar).existsSync();
    try {
      io.write('[INFO] Refreshing BuildTools.jar from upstream');
      await _downloadToFile(buildToolsUrl, buildToolsJar, io: io);
    } on _NativeCommandException catch (e) {
      if (!cachedBuildTools) {
        rethrow;
      }
      io.error('[WARN] ${e.message}');
      io.error('[WARN] Using cached BuildTools.jar: $buildToolsJar');
    }

    final workDir = p.join(
      buildDir,
      'work-$mc-${DateTime.now().millisecondsSinceEpoch}',
    );
    Directory(workDir).createSync(recursive: true);

    io.write(
      '[INFO] Running BuildTools for Spigot mc=$mc (this can take a while)',
    );
    final process = await Process.start(
      'java',
      <String>['-jar', buildToolsJar, '--rev', mc, '--compile', 'SPIGOT'],
      workingDirectory: workDir,
      runInShell: true,
    );
    final stderrTail = <String>[];
    void onStderrLine(String line) {
      stderrTail.add(line);
      if (stderrTail.length > 40) {
        stderrTail.removeAt(0);
      }
      if (io.stream) {
        stdout.writeln('  $line');
      }
    }

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          if (io.stream) {
            stdout.writeln('  $line');
          }
        });
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(onStderrLine);
    final exitCode = await process.exitCode;
    await stdoutDone;
    await stderrDone;
    if (exitCode != 0) {
      throw _NativeCommandException(
        'BuildTools failed for mc=$mc: ${stderrTail.join('\n')}',
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
    newest.copySync(output);
    _registerBuiltJar(profile, 'spigot', output);
    // A BuildTools work dir is ~700 MB of decompiled sources and git clones.
    // Now that spigot is part of the bulk pull, leaving them behind would grow
    // the cache by that much on every run. Failed compiles keep theirs so the
    // logs stay inspectable.
    _removeBuildToolsWorkDir(buildDir, workDir, io);
    io.write(
      '[OK] Cached spigot${spigotBuild == null ? '' : ' build $spigotBuild'} '
      'for mc=$mc',
    );
    io.write('[INFO] Jar: $output');
    return output;
  }

  /// Deletes one BuildTools work dir, guarding on it being a `work-*` child of
  /// [buildDir] so a bad path can never take the jar cache with it.
  ///
  /// `Directory.deleteSync(recursive: true)` gives up with ENOTEMPTY partway
  /// through a BuildTools tree (Spotlight drops `.DS_Store` files back into
  /// directories while the walk is running), so `rm -rf` finishes the job.
  void _removeBuildToolsWorkDir(
    String buildDir,
    String workDir,
    _NativeIoBuffer io,
  ) {
    final resolved = p.normalize(p.absolute(workDir));
    if (p.dirname(resolved) != p.normalize(p.absolute(buildDir)) ||
        !p.basename(resolved).startsWith('work-')) {
      io.error('[WARN] Refusing to remove unexpected work dir $resolved');
      return;
    }

    try {
      Directory(resolved).deleteSync(recursive: true);
      return;
    } catch (_) {
      // Fall through to rm -rf.
    }

    final result = Process.runSync('rm', <String>['-rf', resolved]);
    if (result.exitCode != 0 || Directory(resolved).existsSync()) {
      io.error(
        '[WARN] Could not remove BuildTools work dir $resolved: '
        '${result.stderr.toString().trim()}',
      );
    }
  }

  Future<String?> _resolveSpigotBuildNumber(String mc) async {
    try {
      final payload = await _httpGetJsonObject(
        'https://hub.spigotmc.org/versions/$mc.json',
      );
      final name = payload['name']?.toString().trim() ?? '';
      return RegExp(r'^\d+$').hasMatch(name) ? name : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveLatestFabricLoader(String mc) async {
    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/loader/$mc',
    );
    final versions = <String>[];
    for (final raw in payload) {
      if (raw is! Map) {
        continue;
      }
      final loader = raw['loader'];
      if (loader is! Map || loader['version'] == null) {
        continue;
      }
      final version = loader['version'].toString().trim();
      if (version.isNotEmpty) {
        versions.add(version);
      }
    }
    versions.sort(_compareDottedVersions);
    if (versions.isEmpty) {
      throw _NativeCommandException(
        'Could not resolve Fabric loader for mc=$mc',
        1,
      );
    }
    return versions.last;
  }

  Future<String> _resolveLatestFabricInstaller() async {
    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/installer',
    );
    final versions = <String>[];
    for (final raw in payload) {
      if (raw is! Map) {
        continue;
      }
      final version = raw['version']?.toString().trim() ?? '';
      if (version.isNotEmpty) {
        versions.add(version);
      }
    }
    versions.sort(_compareDottedVersions);
    if (versions.isEmpty) {
      throw _NativeCommandException('Could not resolve Fabric installer', 1);
    }
    return versions.last;
  }

  Future<String> _resolveLatestForgeLoader(String mc) async {
    try {
      final promotions = await _httpGetJsonObject(
        'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json',
      );
      final promosRaw = promotions['promos'];
      if (promosRaw is Map) {
        final promos = Map<String, dynamic>.from(promosRaw);
        for (final key in <String>['$mc-latest', '$mc-recommended']) {
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
    final loaders =
        matches.map((full) => full.substring('$mc-'.length)).toList()
          ..sort(_compareDottedVersions);
    return loaders.last;
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
    matches.sort(_compareDottedVersions);
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

  Future<void> _downloadToFile(
    String url,
    String outputPath, {
    _NativeIoBuffer? io,
  }) async {
    final out = File(outputPath);
    out.parent.createSync(recursive: true);
    Object? lastError;
    final showProgress = (io?.stream ?? false) && stdout.hasTerminal;
    final label = p.basename(outputPath);

    void clearProgressLine() {
      if (showProgress) {
        stdout.write('\r\x1B[2K');
      }
    }

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

        final total = response.contentLength;
        var received = 0;
        var lastDraw = DateTime.fromMillisecondsSinceEpoch(0);
        final sink = tmp.openWrite(mode: FileMode.writeOnly);
        await for (final List<int> chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (showProgress) {
            final now = DateTime.now();
            if (now.difference(lastDraw).inMilliseconds >= 100) {
              lastDraw = now;
              final progress = total > 0
                  ? '${_formatBytes(received)} / ${_formatBytes(total)} '
                        '(${(received * 100 ~/ total)}%)'
                  : _formatBytes(received);
              stdout.write('\r\x1B[2K  downloading $label  $progress');
            }
          }
        }
        await sink.flush();
        await sink.close();
        clearProgressLine();
        if (out.existsSync()) {
          out.deleteSync();
        }
        tmp.renameSync(out.path);
        return;
      } on _NativeCommandException {
        clearProgressLine();
        rethrow;
      } catch (e) {
        clearProgressLine();
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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

  /// Absolute paths of every jar an instance still launches from, across all
  /// consumers, so pruning can never delete a server out from under itself.
  ///
  /// An instance is routinely pinned to an older build than the newest one
  /// cached — it keeps running whatever it was created with until the user
  /// updates it.
  Set<String> _jarsInUse() {
    final inUse = <String>{};
    for (final profile in ConsumerProfile.values) {
      for (final instance in _instanceNames(profile)) {
        final source = _serverSource(profile, instance);
        for (final key in const <String>['jar', 'installer']) {
          final value = source[key]?.trim() ?? '';
          if (value.isNotEmpty) {
            inUse.add(p.normalize(p.absolute(value)));
          }
        }
      }
    }
    return inUse;
  }

  /// Deletes jars a newer build has superseded from one platform's cache,
  /// returning how many went away.
  ///
  /// Runs after every successful build. Failures only warn: a build that
  /// produced a good jar must not be reported as failed just because cleanup
  /// could not remove an old one.
  int _pruneBuildCache(
    ConsumerProfile profile,
    String type,
    _NativeIoBuffer io, {
    bool qualifyConsumer = false,
  }) {
    final label = qualifyConsumer ? '${profile.shortName}/$type' : type;
    final dir = Directory(_buildDir(profile, type));
    if (!dir.existsSync()) {
      return 0;
    }

    final jars = <CachedBuildJar>[];
    try {
      // followLinks: false keeps the latest.jar symlink out of the listing;
      // when it is a copied file instead, the version parser skips it anyway.
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.jar')) {
          continue;
        }
        jars.add(
          CachedBuildJar(
            path: p.normalize(p.absolute(entity.path)),
            name: p.basename(entity.path),
            modified: entity.lastModifiedSync(),
          ),
        );
      }
    } catch (e) {
      io.error('[WARN] Could not read the $label build cache to prune it: $e');
      return 0;
    }

    final stale = planBuildPrune(jars: jars, keepPaths: _jarsInUse());
    var removed = 0;
    var freed = 0;
    for (final jar in stale) {
      try {
        final file = File(jar.path);
        final size = file.lengthSync();
        file.deleteSync();
        removed++;
        freed += size;
      } catch (e) {
        io.error('[WARN] Could not remove superseded build ${jar.name}: $e');
      }
    }

    if (removed > 0) {
      io.write(
        '[OK] Pruned $removed superseded $label build(s), '
        'freeing ${_formatBytes(freed)}',
      );
    }
    return removed;
  }

  /// Removes BuildTools work directories sitting in [type]'s build dir.
  ///
  /// Each holds roughly 700 MB of decompiled sources that BuildTools only
  /// needs while it runs, and an interrupted compile leaves one behind for
  /// good.
  int _pruneBuildToolsWorkDirs(
    ConsumerProfile profile,
    String type,
    _NativeIoBuffer io, {
    bool qualifyConsumer = false,
  }) {
    final label = qualifyConsumer ? '${profile.shortName}/$type' : type;
    final buildDir = _buildDir(profile, type);
    final dir = Directory(buildDir);
    if (!dir.existsSync()) {
      return 0;
    }

    var removed = 0;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory ||
          !p.basename(entity.path).startsWith('work-')) {
        continue;
      }
      _removeBuildToolsWorkDir(buildDir, entity.path, io);
      if (!entity.existsSync()) {
        removed++;
      }
    }

    if (removed > 0) {
      io.write(
        '[OK] Removed $removed leftover BuildTools work dir(s) from $label',
      );
    }
    return removed;
  }

  /// One-shot cleanup of build caches: superseded jars plus any BuildTools
  /// work directory an interrupted spigot compile left behind.
  ///
  /// Unlike the automatic prune that follows a build, this sweeps every
  /// consumer. Cleanup is a housekeeping command, and making the user cycle
  /// the active consumer four times to reclaim their disk would be silly.
  Future<void> _buildPrune(String target, _NativeIoBuffer io) async {
    final normalized = target.toLowerCase();
    if (normalized != 'all' && !_allBuildTypes.contains(normalized)) {
      throw _NativeCommandException(
        'Usage: build prune [all|${_allBuildTypes.join('|')}]',
        2,
      );
    }

    final types = normalized == 'all' ? _allBuildTypes : <String>[normalized];
    var removed = 0;
    for (final consumer in ConsumerProfile.values) {
      for (final type in types) {
        removed += _pruneBuildCache(consumer, type, io, qualifyConsumer: true);
        removed += _pruneBuildToolsWorkDirs(
          consumer,
          type,
          io,
          qualifyConsumer: true,
        );
      }
    }
    if (removed == 0) {
      io.write('[OK] Build caches are already clean');
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
        'Usage: build list-all [paper|purpur|spigot|folia|canvas|leaf|forge|fabric|neoforge]',
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
      for (final type in _allBuildTypes) {
        await _buildVersions(profile, type, io);
        io.write('');
      }
      return;
    }

    if (!_allBuildTypes.contains(target)) {
      throw _NativeCommandException(
        'Usage: build versions [paper|purpur|spigot|folia|canvas|leaf|forge|fabric|neoforge]',
        2,
      );
    }

    io.write('$target supported Minecraft versions:');
    final versions = await _buildSupportedVersions(profile, target);
    if (versions.isEmpty) {
      io.write('  (none: upstream metadata unavailable)');
      return;
    }
    for (final version in versions) {
      io.write('  - $version');
    }
  }

  /// Machine-readable jar-cache report: one `<type>\t<jarBasename>\t<ageSeconds>`
  /// line per cached jar, newest first. Feeds the wizard's automatic
  /// refresh decisions and its "builds updated Xh ago" status footer.
  void _buildCacheInfo(
    ConsumerProfile profile,
    String target,
    String? mcFilter,
    _NativeIoBuffer io,
  ) {
    if (target != 'all' && !_allBuildTypes.contains(target)) {
      throw _NativeCommandException(
        'Usage: build cache-info [all|paper|purpur|spigot|folia|canvas|leaf|forge|fabric|neoforge] [--mc <version>]',
        2,
      );
    }
    final types = target == 'all' ? _allBuildTypes : <String>[target];
    final now = DateTime.now();
    for (final type in types) {
      final dir = Directory(_buildDir(profile, type));
      if (!dir.existsSync()) {
        continue;
      }
      final jars =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jar'))
              .where((f) => p.basename(f.path) != 'latest.jar')
              .where(
                (f) =>
                    mcFilter == null ||
                    mcFilter.isEmpty ||
                    p.basename(f.path).contains(mcFilter),
              )
              .toList(growable: false)
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
      for (final jar in jars) {
        final age = now.difference(jar.lastModifiedSync()).inSeconds;
        io.write('$type\t${p.basename(jar.path)}\t${age < 0 ? 0 : age}');
      }
    }
  }

  Future<String> _resolveLatestMcVersion(String type) async {
    final normalized = type.toLowerCase();
    final profile = _activeConsumer;

    final upstream = await _resolveLatestSupportedMcVersion(normalized);
    if (upstream != null && upstream.isNotEmpty) {
      return upstream;
    }

    if (<String>{
      'paper',
      'purpur',
      'folia',
      'canvas',
      'leaf',
    }.contains(normalized)) {
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

  Future<List<String>> _buildSupportedVersions(
    ConsumerProfile profile,
    String type,
  ) async {
    try {
      final upstream = await _resolveSupportedMcVersions(type);
      if (upstream.isNotEmpty) {
        return upstream;
      }
    } catch (_) {}

    if (<String>{'paper', 'purpur', 'folia', 'canvas', 'leaf'}.contains(type)) {
      return _repoStableVersions(profile, type);
    }

    return const <String>[];
  }

  Future<List<String>> _resolveSupportedMcVersions(String type) {
    switch (type) {
      case 'paper':
      case 'folia':
        return _resolvePaperLikeMcVersions(type);
      case 'purpur':
        return _resolvePurpurMcVersions();
      case 'leaf':
        return _resolveLeafMcVersions();
      case 'canvas':
        return _resolveCanvasMcVersions();
      case 'fabric':
        return _resolveFabricMcVersions();
      case 'forge':
        return _resolveForgeMcVersions();
      case 'neoforge':
        return _resolveNeoForgeMcVersions();
      case 'spigot':
        return _resolveSpigotMcVersions();
      default:
        return Future<List<String>>.value(const <String>[]);
    }
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

  Future<String?> _resolveLatestSupportedMcVersion(String type) async {
    try {
      switch (type) {
        case 'paper':
        case 'folia':
          return _resolveLatestPaperLikeMcVersion(type);
        case 'purpur':
          return _resolveLatestPurpurMcVersion();
        case 'leaf':
          return _resolveLatestLeafMcVersion();
        case 'canvas':
          return _resolveLatestCanvasMcVersion();
        case 'fabric':
          return _resolveLatestFabricMcVersion();
        case 'forge':
          return _resolveLatestForgeMcVersion();
        case 'neoforge':
          return _resolveLatestNeoForgeMcVersion();
        case 'spigot':
          return _resolveLatestSpigotMcVersion();
      }
    } catch (_) {}

    return null;
  }

  Future<String?> _resolveLatestPaperLikeMcVersion(String type) async {
    final versions = await _resolvePaperLikeMcVersions(type);
    return versions.isEmpty ? null : versions.last;
  }

  Future<String?> _resolveLatestPurpurMcVersion() async {
    final versions = await _resolvePurpurMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<String?> _resolveLatestCanvasMcVersion() async {
    final versions = await _resolveCanvasMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<List<String>> _resolvePaperLikeMcVersions(String type) async {
    final payload = await _httpGetJsonObject(
      'https://fill.papermc.io/v3/projects/$type',
    );
    final versionsRaw = payload['versions'];
    if (versionsRaw is! Map) {
      return const <String>[];
    }
    // Fill v3 groups patch releases under their major.minor key, e.g.
    // {"26.1": ["26.1.2", "26.1.1"], "1.21": ["1.21.11", ...]}.
    final flattened = <String>[];
    for (final group in versionsRaw.values) {
      if (group is List) {
        flattened.addAll(group.map((value) => value?.toString() ?? ''));
      }
    }
    return _stableSortedMcVersions(flattened);
  }

  Future<List<String>> _resolvePurpurMcVersions() async {
    final payload = await _httpGetJsonObject(
      'https://api.purpurmc.org/v2/purpur',
    );
    final versionsRaw = payload['versions'];
    if (versionsRaw is! List) {
      return const <String>[];
    }
    return _stableSortedMcVersions(versionsRaw);
  }

  Future<List<String>> _resolveLeafMcVersions() async {
    final payload = await _httpGetJsonObject(
      'https://api.leafmc.one/v2/projects/leaf',
    );
    final versionsRaw = payload['versions'];
    if (versionsRaw is! List) {
      return const <String>[];
    }
    return _stableSortedMcVersions(versionsRaw);
  }

  Future<String?> _resolveLatestLeafMcVersion() async {
    final versions = await _resolveLeafMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<List<String>> _resolveCanvasMcVersions() async {
    final payload = await _httpGetJsonObject(
      'https://canvasmc.io/api/v2/builds/all?project=canvas&experimental=true',
    );
    final buildsRaw = payload['builds'];
    if (buildsRaw is! List) {
      return const <String>[];
    }

    final versions = <String>{};
    for (final raw in buildsRaw) {
      if (raw is! Map) {
        continue;
      }
      final candidate = raw['channelVersion']?.toString().trim() ?? '';
      if (_isStableMcVersion(candidate)) {
        versions.add(candidate);
      }
    }
    return _stableSortedMcVersions(versions);
  }

  Future<String?> _resolveLatestFabricMcVersion() async {
    final latestRelease = await _latestMinecraftRelease();
    if (latestRelease.isNotEmpty &&
        await _fabricSupportsMcVersion(latestRelease)) {
      return latestRelease;
    }

    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/game',
    );
    final versions = <String>{};
    for (final raw in payload) {
      if (raw is! Map) {
        continue;
      }
      if (raw['stable'] != true) {
        continue;
      }
      final version = raw['version']?.toString().trim() ?? '';
      if (_isStableMcVersion(version)) {
        versions.add(version);
      }
    }

    final ordered = versions.toList(growable: false)..sort(_compareVersions);
    for (final version in ordered.reversed) {
      if (await _fabricSupportsMcVersion(version)) {
        return version;
      }
    }
    return null;
  }

  Future<List<String>> _resolveFabricMcVersions() async {
    final payload = await _httpGetJsonList(
      'https://meta.fabricmc.net/v2/versions/game',
    );
    final versions = <String>{};
    for (final raw in payload) {
      if (raw is! Map) {
        continue;
      }
      if (raw['stable'] != true) {
        continue;
      }
      final version = raw['version']?.toString().trim() ?? '';
      if (_isStableMcVersion(version)) {
        versions.add(version);
      }
    }
    return _stableSortedMcVersions(versions);
  }

  Future<String?> _resolveLatestForgeMcVersion() async {
    final versions = await _resolveForgeMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<List<String>> _resolveForgeMcVersions() async {
    final payload = await _httpGetJsonObject(
      'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json',
    );
    final promosRaw = payload['promos'];
    if (promosRaw is! Map) {
      return const <String>[];
    }

    final versions = <String>{};
    for (final entry in promosRaw.entries) {
      final key = entry.key.toString().trim();
      if (!key.endsWith('-latest') && !key.endsWith('-recommended')) {
        continue;
      }
      final version = key.split('-').first.trim();
      if (_isStableMcVersion(version)) {
        versions.add(version);
      }
    }
    return _stableSortedMcVersions(versions);
  }

  Future<String?> _resolveLatestNeoForgeMcVersion() async {
    final versions = await _resolveNeoForgeMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<List<String>> _resolveNeoForgeMcVersions() async {
    final metadata = await _httpGetText(
      'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml',
    );
    final versions = RegExp(r'<version>([^<]+)</version>')
        .allMatches(metadata)
        .map((m) => m.group(1)?.trim() ?? '')
        .map(_minecraftVersionFromNeoForgeLoader)
        .whereType<String>()
        .toSet();
    return _stableSortedMcVersions(versions);
  }

  Future<String?> _resolveLatestSpigotMcVersion() async {
    final versions = await _resolveSpigotMcVersions();
    return versions.isEmpty ? null : versions.last;
  }

  Future<List<String>> _resolveSpigotMcVersions() async {
    final html = await _httpGetText('https://hub.spigotmc.org/versions/');
    final versions = RegExp(r'href="(\d+\.\d+(?:\.\d+)?)\.json"')
        .allMatches(html)
        .map((m) => m.group(1)?.trim() ?? '')
        .where(_isStableMcVersion)
        .toSet();
    return _stableSortedMcVersions(versions);
  }

  Future<bool> _fabricSupportsMcVersion(String mc) async {
    try {
      final payload = await _httpGetJsonList(
        'https://meta.fabricmc.net/v2/versions/loader/$mc',
      );
      return payload.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String? _minecraftVersionFromNeoForgeLoader(String loaderVersion) {
    final match = RegExp(
      r'^(\d+)\.(\d+)(?:\.(\d+))?(?:[.-]|$)',
    ).firstMatch(loaderVersion);
    if (match == null) {
      return null;
    }

    final major = int.tryParse(match.group(1) ?? '');
    final minor = int.tryParse(match.group(2) ?? '');
    final patch = int.tryParse(match.group(3) ?? '');
    if (major == null || minor == null) {
      return null;
    }

    // Older NeoForge loader ids drop the leading "1." from Minecraft releases
    // and use the third segment for the loader build rather than the MC patch.
    if (major < 24) {
      return '1.$major.$minor';
    }

    return '$major.$minor.${patch ?? 0}';
  }

  List<String> _stableSortedMcVersions(Iterable<dynamic> values) {
    return values
        .map((value) => value?.toString().trim() ?? '')
        .where(_isStableMcVersion)
        .toSet()
        .toList(growable: false)
      ..sort(_compareVersions);
  }

  bool _isStableMcVersion(String value) {
    return RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(value.trim());
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

  int _compareDottedVersions(String a, String b) {
    final av = _versionNumberParts(a);
    final bv = _versionNumberParts(b);
    final length = av.length > bv.length ? av.length : bv.length;
    for (var i = 0; i < length; i++) {
      final left = i < av.length ? av[i] : 0;
      final right = i < bv.length ? bv[i] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }
    return a.compareTo(b);
  }

  List<int> _versionNumberParts(String value) {
    return RegExp(r'\d+')
        .allMatches(value)
        .map((match) => int.parse(match.group(0)!))
        .toList(growable: false);
  }

  Map<String, String> _parseOptions(List<String> args) {
    final options = <String, String>{};

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];

      if (!arg.startsWith('--')) {
        throw _NativeCommandException('Unknown argument: $arg', 2);
      }

      final key = arg.substring(2);
      if (key == 'auto-build' || key == 'isolated' || key == 'force') {
        options[key] = 'true';
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

  _ServerCreateArguments _parseServerCreateArguments(List<String> args) {
    final List<String> optionArgs = <String>[];
    final List<String> artifacts = <String>[];
    for (int index = 0; index < args.length; index++) {
      if (args[index] != '--artifact') {
        optionArgs.add(args[index]);
        continue;
      }
      if (index + 1 >= args.length) {
        throw _NativeCommandException('Missing value for --artifact', 2);
      }
      artifacts.add(args[++index]);
    }
    return _ServerCreateArguments(
      options: _parseOptions(optionArgs),
      artifacts: List<String>.unmodifiable(artifacts),
    );
  }

  List<File> _resolveSelectedDropinArtifacts(
    ConsumerProfile profile,
    List<String> names,
  ) {
    final String source = _dropinsSource(
      profile,
      mods: !_isPluginConsumer(profile),
    );
    final List<File> files = <File>[];
    final Set<String> seen = <String>{};
    for (final String rawName in names) {
      final String name = rawName.trim();
      if (name.isEmpty ||
          p.basename(name) != name ||
          p.windows.basename(name) != name ||
          !name.toLowerCase().endsWith('.jar')) {
        throw _NativeCommandException(
          'Invalid drop-in artifact name: $rawName',
          2,
        );
      }
      if (!seen.add(name)) {
        continue;
      }
      final File file = File(p.join(source, name));
      if (FileSystemEntity.typeSync(file.path, followLinks: true) !=
          FileSystemEntityType.file) {
        throw _NativeCommandException(
          'Drop-in artifact not found: $name ($source)',
          2,
        );
      }
      files.add(file);
    }
    return List<File>.unmodifiable(files);
  }

  void _copySelectedDropinArtifacts(
    ConsumerProfile profile,
    String instance,
    List<File> artifacts,
    _NativeIoBuffer io,
  ) {
    if (artifacts.isEmpty) {
      return;
    }
    final String target = p.join(
      _instanceDir(profile, instance),
      _isPluginConsumer(profile) ? 'plugins' : 'mods',
    );
    Directory(target).createSync(recursive: true);
    for (final File artifact in artifacts) {
      artifact.copySync(p.join(target, p.basename(artifact.path)));
    }
    io.write(
      '[OK] Copied ${artifacts.length} selected drop-in artifact(s) -> $instance',
    );
    io.write(
      '[INFO] Local artifacts: ${artifacts.map((File file) => p.basename(file.path)).join(', ')}',
    );
  }

  Map<String, String> _serverCreateBuildOptions(
    Map<String, String> options,
    String mc,
  ) {
    final buildOptions = <String, String>{'mc': mc};
    for (final key in const <String>['loader', 'installer']) {
      final value = options[key]?.trim();
      if (value != null && value.isNotEmpty) {
        buildOptions[key] = value;
      }
    }
    return buildOptions;
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

  Future<void> _serverCreateFromJar(
    ConsumerProfile profile,
    String name, {
    required String type,
    required String jarPath,
    bool importJar = false,
    bool isolated = false,
    _NativeIoBuffer? io,
  }) async {
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
    final bool sourceLooksLikeInstaller = _looksLikeInstallerJar(
      resolvedJarPath,
    );
    if (importJar) {
      resolvedJarPath = await _importManagedLaunchJar(profile, resolvedJarPath);
    }

    _instanceCreateBlank(profile, name, isolated: isolated, io: io);

    final normalizedType = type.toLowerCase().trim();
    final installerBased =
        (normalizedType == 'forge' || normalizedType == 'neoforge') &&
        (sourceLooksLikeInstaller || _looksLikeInstallerJar(resolvedJarPath));
    if (installerBased) {
      _serverCreateFromInstaller(
        profile,
        name,
        normalizedType,
        resolvedJarPath,
        isolated: isolated,
      );
      _instanceApplyStyledMotd(profile, name, force: true);
      return;
    }

    final instanceDir = _instanceDir(profile, name);
    final serverJar = p.join(instanceDir, 'server.jar');
    _replaceWithSymlink(serverJar, resolvedJarPath);

    _writeServerSource(
      instanceDir,
      fields: <String, String>{
        'type': normalizedType,
        'launch': 'jar',
        'jar': resolvedJarPath,
        if (isolated) 'isolated': 'true',
      },
    );
    _instanceApplyStyledMotd(profile, name, force: true);
  }

  Future<String> _importManagedLaunchJar(
    ConsumerProfile profile,
    String sourcePath,
  ) async {
    final String canonicalSource;
    try {
      canonicalSource = File(sourcePath).resolveSymbolicLinksSync();
    } on FileSystemException {
      throw _NativeCommandException(
        'Custom launch jar cannot be resolved: $sourcePath',
        2,
      );
    }
    if (!canonicalSource.toLowerCase().endsWith('.jar') ||
        FileSystemEntity.typeSync(canonicalSource, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _NativeCommandException(
        'Custom launch jar must be a regular .jar file: $sourcePath',
        2,
      );
    }

    final String buildsPath = p.join(_consumerRoot(profile), 'builds');
    if (FileSystemEntity.typeSync(buildsPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw _NativeCommandException(
        'Consumer builds storage is not a real directory: $buildsPath',
        1,
      );
    }
    final String customPath = p.join(buildsPath, 'custom');
    final FileSystemEntityType customType = FileSystemEntity.typeSync(
      customPath,
      followLinks: false,
    );
    if (customType == FileSystemEntityType.notFound) {
      Directory(customPath).createSync();
    } else if (customType != FileSystemEntityType.directory) {
      throw _NativeCommandException(
        'Custom build storage is not a real directory: $customPath',
        1,
      );
    }

    final String digest = await _sha256FileStreamed(File(canonicalSource));
    final String destinationPath = p.join(customPath, '$digest.jar');
    final File destination = File(destinationPath);
    final FileSystemEntityType destinationType = FileSystemEntity.typeSync(
      destinationPath,
      followLinks: false,
    );
    if (destinationType == FileSystemEntityType.file) {
      if (await _sha256FileStreamed(destination) != digest) {
        throw _NativeCommandException(
          'Managed custom jar failed its content-address verification.',
          1,
        );
      }
      return destinationPath;
    }
    if (destinationType != FileSystemEntityType.notFound) {
      throw _NativeCommandException(
        'Managed custom jar destination is not a regular file.',
        1,
      );
    }

    final String temporaryPath = p.join(
      customPath,
      '.$digest.${_newPinSalt()}.part',
    );
    final File temporary = File(temporaryPath);
    try {
      temporary.createSync(exclusive: true);
      final IOSink output = temporary.openWrite(mode: FileMode.writeOnly);
      await File(canonicalSource).openRead().pipe(output);
      if (await _sha256FileStreamed(temporary) != digest) {
        throw _NativeCommandException(
          'Managed custom jar copy verification failed.',
          1,
        );
      }
      final FileSystemEntityType currentDestination = FileSystemEntity.typeSync(
        destinationPath,
        followLinks: false,
      );
      if (currentDestination == FileSystemEntityType.file) {
        if (await _sha256FileStreamed(destination) != digest) {
          throw _NativeCommandException(
            'Managed custom jar destination changed during import.',
            1,
          );
        }
        return destinationPath;
      }
      if (currentDestination != FileSystemEntityType.notFound) {
        throw _NativeCommandException(
          'Managed custom jar destination changed during import.',
          1,
        );
      }
      await temporary.rename(destinationPath);
      if (FileSystemEntity.typeSync(destinationPath, followLinks: false) !=
              FileSystemEntityType.file ||
          await _sha256FileStreamed(destination) != digest) {
        throw _NativeCommandException(
          'Managed custom jar failed final verification.',
          1,
        );
      }
      return destinationPath;
    } finally {
      if (FileSystemEntity.typeSync(temporaryPath, followLinks: false) ==
          FileSystemEntityType.file) {
        temporary.deleteSync();
      }
    }
  }

  Future<String> _sha256FileStreamed(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
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
    String installerJarPath, {
    bool isolated = false,
  }) {
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

    _writeServerSource(
      instanceDir,
      fields: <String, String>{
        'type': type,
        'launch': 'argsfile',
        'args_file_rel': argsRel,
        'installer': File(installerJarPath).absolute.path,
        if (isolated) 'isolated': 'true',
      },
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

    final bool isolatedInstance = _instanceIsolated(profile, instance);
    if (!isolatedInstance) {
      _instanceEnsureSharedPluginOps(profile, instance, io: io);
    }
    _instanceEnsureRestartScript(profile, instance);

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
      preserveLocalChanges: true,
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
    if (startupSync.preservedJars.isNotEmpty) {
      io.error(
        '[WARN] Startup preserved locally modified jar(s) in $instance: ${startupSync.preservedJars.join(', ')}',
      );
      io.error(
        '[WARN] Run ${_isPluginConsumer(profile) ? 'plugins' : 'mods'} sync $instance to replace them from dropins.',
      );
    }

    await _runtimePrepareInstancePort(profile, instance, io);
    _ensureRconConfigured(profile, instance);

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
    String? log4jPath;
    if (settings.consoleLogFormat == 'minimal') {
      log4jPath = _ensureMinimalLog4jConfig(profile, instance);
    }
    final javaCommandParts = <String>[
      'java',
      ..._javaArgsForLaunch(
        launch,
        settings,
        workingDirectory: launchWorkingDir,
        log4jConfigPath: log4jPath,
      ),
    ];
    final javaCommand = javaCommandParts.map(_shellQuote).join(' ');
    final serverPidFile = _runtimeServerPidFile(profile, instance);

    // DECAWM-off prevents tmux's pane from wrapping long server lines. The
    // log file is unaffected since this only touches the terminal renderer.
    final String wrapPrefix = settings.noLineWrap
        ? r'printf '
              "'\\033[?7l'"
              ' && '
        : '';
    final runScript =
        'cd ${_shellQuote(launchWorkingDir)} && '
        'printf "%s\\n" "\$\$" > ${_shellQuote(serverPidFile)} && '
        '$wrapPrefix'
        'exec $javaCommand';
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
    await _tmuxSetRuntimeUiLabel(tmuxSession, 'jvm-starting');

    // The relaunch happened; clear any pending-restart marker so state
    // reporting flips from "restarting" to "starting".
    File(_runtimeRestartPendingFile(profile, instance)).deleteSyncSafe();

    io.write('[OK] Runtime started: $instance');
    io.write('[INFO] tmux session: $tmuxSession');
    final serverPid = await _awaitRuntimeServerPid(profile, instance);
    if (serverPid != null) {
      await _tmuxSetRuntimeUiLabel(tmuxSession, 'jvm-$serverPid');
      io.write('[INFO] server pid: $serverPid');
    }
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
    final bool mods = !_isPluginConsumer(profile);

    final session = _pluginsWatchSessionName(profile, mods: mods);
    if (await _tmuxSessionExists(session)) {
      return;
    }

    try {
      await _pluginsWatchStart(profile, io, mods: mods);
    } catch (e) {
      io.error(
        '[WARN] Could not auto-start ${mods ? 'mods' : 'plugins'} watcher: $e',
      );
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
    io.write('Navigate panes: Left/Right arrows. Type in the focused pane.');
    io.write('Scroll: mouse wheel. Drag-select text to copy it.');
    io.write('Detach: Esc (or Ctrl+B then D). Servers keep running.');

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
    io.write('Detach: Esc (or Ctrl+B then D). The server keeps running.');
    io.write('Scroll: mouse wheel. Drag-select text to copy it.');

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
        'automatic-rename',
        'off',
      ],
      <String>[
        'set-window-option',
        '-t',
        '$tmuxSession:0',
        'allow-rename',
        'off',
      ],
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
    await _tmuxConfigureClipboardIntegration();
  }

  String? _clipboardCommand;
  bool _clipboardCommandResolved = false;

  Future<String?> _resolveClipboardCommand() async {
    if (_clipboardCommandResolved) {
      return _clipboardCommand;
    }
    _clipboardCommandResolved = true;
    const candidates = <List<String>>[
      <String>['pbcopy'],
      <String>['wl-copy'],
      <String>['xclip', '-selection', 'clipboard', '-in'],
      <String>['xsel', '--clipboard', '--input'],
    ];
    for (final candidate in candidates) {
      final result = await _runProcess('sh', <String>[
        '-c',
        'command -v ${candidate.first}',
      ]);
      if (result.exitCode == 0) {
        _clipboardCommand = candidate.join(' ');
        return _clipboardCommand;
      }
    }
    return null;
  }

  /// Makes mouse drag-select copy straight to the system clipboard, so
  /// click-and-drag in a console behaves like a normal terminal.
  Future<void> _tmuxConfigureClipboardIntegration() async {
    await _runProcess('tmux', <String>[
      'set-option',
      '-s',
      'set-clipboard',
      'on',
    ]);
    final clipboard = await _resolveClipboardCommand();
    final copyAction = clipboard == null
        ? <String>['send-keys', '-X', 'copy-selection-and-cancel']
        : <String>['send-keys', '-X', 'copy-pipe-and-cancel', clipboard];
    for (final table in <String>['copy-mode', 'copy-mode-vi']) {
      await _runProcess('tmux', <String>[
        'bind-key',
        '-T',
        table,
        'MouseDragEnd1Pane',
        ...copyAction,
      ]);
    }
  }

  Future<void> _tmuxSetRuntimeUiLabel(String tmuxSession, String label) async {
    final commands = <List<String>>[
      <String>['rename-window', '-t', '$tmuxSession:0', label],
      <String>['select-pane', '-t', '$tmuxSession:0.0', '-T', label],
    ];
    for (final args in commands) {
      for (var attempt = 0; attempt < 5; attempt++) {
        final result = await _runProcess('tmux', args);
        if (result.exitCode == 0) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
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

  Future<void> _runtimeGracefulStop(
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
    if (!await _tmuxSessionExists(tmuxSession)) {
      // No live console to talk to; defer to the hard path so pid files are
      // cleaned up and the result is reported once.
      await _runtimeStop(profile, instance, io);
      return;
    }

    // Ask the server to shut down cleanly (flushes and saves worlds).
    await _runProcess('tmux', <String>[
      'send-keys',
      '-t',
      tmuxSession,
      'stop',
      'Enter',
    ]);

    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var exited = false;
    while (DateTime.now().isBefore(deadline)) {
      final sessionAlive = await _tmuxSessionExists(tmuxSession);
      final pidAlive = serverPid != null && await _pidRunning(serverPid);
      if (!sessionAlive && !pidAlive) {
        exited = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (!exited) {
      io.write('[WARN] Graceful stop timed out; forcing: $instance');
      await _runtimeStop(profile, instance, io);
      return;
    }

    File(_runtimeServerPidFile(profile, instance)).deleteSyncSafe();
    File(_runtimeConsolePidFile(profile, instance)).deleteSyncSafe();
    io.write('[OK] Runtime stopped (graceful): $instance');
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

    final state = await _runtimeStateOf(profile, instance);
    io.write('state:        ${state.name}');
    io.write('mode:         $mode');
    io.write('tmux session: ${tmuxRunning ? tmuxSession : 'none'}');
    io.write('server port:  ${_instanceGetServerPort(profile, instance)}');
    io.write('console pid:  ${consolePid ?? 'none'}');
    io.write('server pid:   ${serverPid ?? 'none'}');
    io.write('log:          ${_runtimeLogFile(profile, instance)}');
  }

  /// Shows live stats (player counts, version, CPU, memory, uptime) for
  /// running servers.
  ///
  /// With no [inputInstance], scans every consumer for running instances so
  /// the user sees all live servers at once. Player counts come from a Server
  /// List Ping against each server's `server-port`, which needs neither query
  /// nor rcon enabled. Uptime is derived from the tmux session start time.
  /// CPU and memory come from one batched `ps` over the tracked server pids;
  /// anything unavailable renders as `n/a` rather than a fabricated zero.
  Future<void> _runtimeStats(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    final targets = <(ConsumerProfile, String)>[];
    if (inputInstance != null && inputInstance.trim().isNotEmpty) {
      final instance = inputInstance.trim();
      if (!_instanceExists(profile, instance)) {
        throw _NativeCommandException('Instance not found: $instance', 2);
      }
      targets.add((profile, instance));
    } else {
      for (final candidate in ConsumerProfile.values) {
        for (final name in _instanceNames(candidate)) {
          if (await _runtimeRunning(candidate, name)) {
            targets.add((candidate, name));
          }
        }
      }
    }

    if (targets.isEmpty) {
      io.write('[INFO] No running servers.');
      return;
    }

    final rows = await Future.wait(
      targets.map((target) async {
        final (consumer, instance) = target;
        final state = await _runtimeStateOf(consumer, instance);
        final port = _instanceGetServerPort(consumer, instance);
        final host = _instanceGetServerIp(consumer, instance);
        final uptime = await _runtimeUptime(consumer, instance);
        // Ping any server that is not stopped/stopping; the ping itself is the
        // ground truth for whether it is accepting players.
        final ping =
            (state != RuntimeState.stopped && state != RuntimeState.stopping)
            ? await pingMinecraftServer(host, port)
            : null;
        return (
          instance: instance,
          consumer: consumer.shortName,
          state: state,
          port: port,
          uptime: uptime,
          ping: ping,
          pid: _readPid(_runtimeServerPidFile(consumer, instance)),
        );
      }),
    );

    final psStats = await _sampleProcessStats(<int>[
      for (final row in rows)
        if (row.pid != null) row.pid!,
    ]);

    final useColor =
        io.stream &&
        stdout.hasTerminal &&
        !Platform.environment.containsKey('NO_COLOR');

    io.write('[OK] ${rows.length} server(s) running');
    io.write('');

    // Column indices are load-bearing: _statsColorCell paints STATE (2) and
    // PLAYERS (3), so new columns go after them.
    const columns = <TableColumn>[
      TableColumn(header: 'SERVER'),
      TableColumn(header: 'CONSUMER'),
      TableColumn(header: 'STATE'),
      TableColumn(header: 'PLAYERS'),
      TableColumn(header: 'CPU'),
      TableColumn(header: 'MEM'),
      TableColumn(header: 'UPTIME'),
      TableColumn(header: 'PORT'),
      TableColumn(header: 'VERSION'),
    ];
    final cells = rows
        .map((r) {
          final pid = r.pid;
          final stat = pid != null ? psStats[pid] : null;
          return <String>[
            r.instance,
            r.consumer,
            r.state.name,
            _statsPlayersCell(r.ping, r.state),
            formatCpuPercent(stat?.cpuPercent),
            formatBytes(stat?.rssBytes),
            r.uptime != null ? formatCompactDuration(r.uptime!) : 'n/a',
            '${r.port}',
            _statsVersionCell(r.ping),
          ];
        })
        .toList(growable: false);

    final lines = renderTable(
      columns: columns,
      rows: cells,
      bold: useColor,
      paintCell: useColor
          ? (int col, int row, String cell) =>
                _statsColorCell(col, cell, rows[row].state, rows[row].ping)
          : null,
    );
    for (final line in lines) {
      io.write(line);
    }

    final withPlayers = rows
        .where((r) => (r.ping?.sample.isNotEmpty ?? false))
        .toList(growable: false);
    if (withPlayers.isNotEmpty) {
      io.write('');
      io.write('Players online:');
      for (final r in withPlayers) {
        io.write('  ${r.instance}  ${r.ping!.sample.join(', ')}');
      }
    }
  }

  /// PLAYERS cell. Unavailable reads `n/a`, matching every other cell in
  /// this table; a running server that did not answer its ping keeps the
  /// distinct `?`, which says the count should have been there.
  String _statsPlayersCell(MinecraftPingResult? ping, RuntimeState state) {
    if (ping != null) {
      return '${ping.online}/${ping.max}';
    }
    return state == RuntimeState.running ? '?' : 'n/a';
  }

  /// VERSION cell: the version the ping reported, or `n/a` when there was no
  /// ping or the server named no version.
  String _statsVersionCell(MinecraftPingResult? ping) {
    final version = ping?.versionName ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String _statsColorCell(
    int col,
    String padded,
    RuntimeState state,
    MinecraftPingResult? ping,
  ) {
    // STATE column.
    if (col == 2) {
      final code = switch (state) {
        RuntimeState.running => Ansi.green,
        RuntimeState.starting ||
        RuntimeState.stopping ||
        RuntimeState.restarting => Ansi.yellow,
        RuntimeState.stopped => Ansi.gray,
      };
      return '$code$padded${Ansi.reset}';
    }
    // PLAYERS column.
    if (col == 3) {
      if (ping == null) {
        return '${Ansi.gray}$padded${Ansi.reset}';
      }
      if (ping.online > 0) {
        return '${Ansi.green}$padded${Ansi.reset}';
      }
    }
    return padded;
  }

  /// Best-effort uptime for a running instance: the tmux session start time,
  /// falling back to the server PID file mtime. Returns null when neither is
  /// available.
  Future<Duration?> _runtimeUptime(
    ConsumerProfile profile,
    String instance,
  ) async {
    final session = _tmuxSessionName(profile, instance);
    if (await _tmuxSessionExists(session)) {
      final result = await _runProcess('tmux', <String>[
        'display-message',
        '-p',
        '-t',
        session,
        '-F',
        '#{session_created}',
      ]);
      if (result.exitCode == 0) {
        final epoch = int.tryParse((result.stdout ?? '').toString().trim());
        if (epoch != null && epoch > 0) {
          final created = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
          final delta = DateTime.now().difference(created);
          if (!delta.isNegative) {
            return delta;
          }
        }
      }
    }

    // A concurrent `runtime stop` deletes the pid file, so it can vanish
    // between the existence check and the mtime read. Uptime is best-effort
    // telemetry: losing that race degrades to "unknown" instead of throwing.
    final pidFile = File(_runtimeServerPidFile(profile, instance));
    try {
      if (pidFile.existsSync()) {
        final delta = DateTime.now().difference(pidFile.lastModifiedSync());
        if (!delta.isNegative) {
          return delta;
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
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

  bool _runtimeRestartPending(ConsumerProfile profile, String instance) {
    final file = File(_runtimeRestartPendingFile(profile, instance));
    if (!file.existsSync()) {
      return false;
    }
    final fresh = runtimeRestartMarkerFresh(
      file.lastModifiedSync(),
      DateTime.now(),
    );
    if (!fresh) {
      file.deleteSyncSafe();
    }
    return fresh;
  }

  String _runtimeLogTail(
    ConsumerProfile profile,
    String instance, {
    int maxBytes = 65536,
  }) {
    final file = File(_runtimeLogFile(profile, instance));
    if (!file.existsSync()) {
      return '';
    }
    final RandomAccessFile raf = file.openSync();
    try {
      final int length = raf.lengthSync();
      final int start = length > maxBytes ? length - maxBytes : 0;
      raf.setPositionSync(start);
      final List<int> bytes = raf.readSync(length - start);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    } finally {
      raf.closeSync();
    }
  }

  /// Whether the startup "Done" marker appears in the head of the log, where
  /// it lives even after it has scrolled out of the tail window read by
  /// [classifyRuntimeLogTail]. Used as a fallback so long-running or busy
  /// servers are not stuck reporting "starting".
  bool _runtimeLogHasReadyMarker(
    ConsumerProfile profile,
    String instance, {
    int maxBytes = 131072,
  }) {
    final file = File(_runtimeLogFile(profile, instance));
    if (!file.existsSync()) {
      return false;
    }
    final RandomAccessFile raf = file.openSync();
    try {
      final int length = raf.lengthSync();
      final int count = length > maxBytes ? maxBytes : length;
      final List<int> bytes = raf.readSync(count);
      return logContainsReadyMarker(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return false;
    } finally {
      raf.closeSync();
    }
  }

  Future<RuntimeState> _runtimeStateOf(
    ConsumerProfile profile,
    String instance,
  ) async {
    final restartPending = _runtimeRestartPending(profile, instance);
    final session = _tmuxSessionName(profile, instance);
    if (await _tmuxSessionExists(session)) {
      if (await _tmuxSessionHasLivePane(session)) {
        final fromLog = classifyRuntimeLogTail(
          _runtimeLogTail(profile, instance),
        );
        if (fromLog == RuntimeState.running) {
          // Restart completed; any leftover marker is stale.
          File(_runtimeRestartPendingFile(profile, instance)).deleteSyncSafe();
          return RuntimeState.running;
        }
        // The "Done" marker can scroll out of the tail window on a busy or
        // long-running server, leaving the tail with no markers. The pane is
        // live, so if the marker is anywhere in the log head, it is running.
        if (fromLog == RuntimeState.starting &&
            _runtimeLogHasReadyMarker(profile, instance)) {
          File(_runtimeRestartPendingFile(profile, instance)).deleteSyncSafe();
          return RuntimeState.running;
        }
        if (restartPending) {
          return RuntimeState.restarting;
        }
        return fromLog;
      }
      await _runProcess('tmux', <String>['kill-session', '-t', session]);
    }

    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    if (serverPid != null && await _pidRunning(serverPid)) {
      return RuntimeState.running;
    }
    final consolePid = _readPid(_runtimeConsolePidFile(profile, instance));
    if (consolePid != null && await _pidRunning(consolePid)) {
      return RuntimeState.running;
    }

    return restartPending ? RuntimeState.restarting : RuntimeState.stopped;
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
    var noLineWrap = _RuntimeSettingsData.defaults.noLineWrap;
    var consoleLogFormat = _RuntimeSettingsData.defaults.consoleLogFormat;
    final file = File(_runtimeSettingsFile(profile));
    var loadedFromFile = false;

    if (file.existsSync()) {
      loadedFromFile = true;
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
          case 'NO_LINE_WRAP':
            noLineWrap = _parseBoolSetting(value, defaultValue: noLineWrap);
            break;
          case 'CONSOLE_LOG_FORMAT':
            final lower = value.toLowerCase();
            if (lower == 'minimal' || lower == 'default') {
              consoleLogFormat = lower;
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

    final normalizedJvmArgs = _runtimeSettingsNormalizeJvmArgs(jvmArgs);
    final shouldRewriteNormalizedSettings =
        loadedFromFile &&
        envHeap == null &&
        envJvmArgs == null &&
        envProfile == null &&
        normalizedJvmArgs != jvmArgs;
    jvmArgs = normalizedJvmArgs;

    if (!_runtimeSettingsPresets.containsKey(runtimeProfile)) {
      runtimeProfile = _runtimeSettingsGuessProfileForArgs(jvmArgs);
    }

    final settings = _RuntimeSettingsData(
      heap: heap,
      jvmArgs: jvmArgs,
      profile: runtimeProfile,
      noLineWrap: noLineWrap,
      consoleLogFormat: consoleLogFormat,
    );
    if (shouldRewriteNormalizedSettings) {
      _runtimeSettingsSave(profile, settings);
    }
    return settings;
  }

  void _runtimeSettingsSave(
    ConsumerProfile profile,
    _RuntimeSettingsData settings,
  ) {
    final file = File(_runtimeSettingsFile(profile));
    file.createSync(recursive: true);
    final normalizedArgs = _runtimeSettingsNormalizeJvmArgs(settings.jvmArgs);
    file.writeAsStringSync(
      '${['# Multiplexor runtime settings (${profile.shortName})', 'HEAP_SIZE=${settings.heap}', 'JVM_PROFILE=${settings.profile}', 'JVM_ARGS=$normalizedArgs', 'NO_LINE_WRAP=${settings.noLineWrap ? 'true' : 'false'}', 'CONSOLE_LOG_FORMAT=${settings.consoleLogFormat}'].join('\n')}\n',
    );
  }

  bool _parseBoolSetting(String value, {required bool defaultValue}) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' ||
        normalized == 'on' ||
        normalized == '1' ||
        normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == 'off' ||
        normalized == '0' ||
        normalized == 'no') {
      return false;
    }
    return defaultValue;
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

  /// Writes (if missing) a per-instance log4j2 config that strips the
  /// `[time level]: ` prefix from the console while keeping a full file
  /// appender targeting `logs/latest.log` — so `cat logs/latest.log` still
  /// shows timestamps and levels. Returns the absolute path to the config.
  ///
  /// The Root logger also carries a [RegexFilter] that drops the RCON client
  /// connect/disconnect lines (`Thread RCON Client /… started` /
  /// `… shutting down`). Those are pure noise from the manager's own live TPS
  /// polling, not the operator's traffic. The filter matches message text
  /// rather than a logger name so it works across server versions and mapping
  /// schemes, and it targets only `RCON Client` thread lifecycle lines so real
  /// RCON warnings and errors still surface. It applies to both the console and
  /// `logs/latest.log`, so the spam is gone from the file too.
  String _ensureMinimalLog4jConfig(ConsumerProfile profile, String instance) {
    final dir = _instanceDir(profile, instance);
    final path = p.join(dir, '.multiplexor-log4j2.xml');
    final body = '''
<?xml version="1.0" encoding="UTF-8"?>
<Configuration status="WARN" monitorInterval="30">
    <Appenders>
        <Console name="MinimalConsole" target="SYSTEM_OUT">
            <PatternLayout>
                <Pattern>%msg%n%xEx</Pattern>
            </PatternLayout>
        </Console>
        <RollingRandomAccessFile name="File"
                                 fileName="logs/latest.log"
                                 filePattern="logs/%d{yyyy-MM-dd}-%i.log.gz">
            <PatternLayout>
                <Pattern>[%d{HH:mm:ss}] [%t/%level]: [%logger] %msg%n</Pattern>
            </PatternLayout>
            <Policies>
                <TimeBasedTriggeringPolicy />
                <OnStartupTriggeringPolicy />
            </Policies>
        </RollingRandomAccessFile>
    </Appenders>
    <Loggers>
        <Root level="info">
            <RegexFilter regex="(?s).*RCON Client.*" useRawMsg="false" onMatch="DENY" onMismatch="NEUTRAL"/>
            <AppenderRef ref="MinimalConsole"/>
            <AppenderRef ref="File"/>
        </Root>
    </Loggers>
</Configuration>
''';
    final file = File(path);
    if (!file.existsSync() || file.readAsStringSync() != body) {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }
    return path;
  }

  String _runtimeSettingsNormalizeJvmArgs(String args) {
    final tokens = args
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .where((token) => token != '-XX:+PerfDisableSharedMem')
        .toList(growable: false);
    return tokens.join(' ');
  }

  List<String> _javaArgsForLaunch(
    _LaunchTarget launch,
    _RuntimeSettingsData settings, {
    String? workingDirectory,
    String? log4jConfigPath,
  }) {
    final heap = settings.heap;
    final jvmArgsRaw = settings.jvmArgs;

    final flags = jvmArgsRaw
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final List<String> extraJvm = <String>[
      if (log4jConfigPath != null && log4jConfigPath.isNotEmpty)
        '-Dlog4j.configurationFile=$log4jConfigPath',
    ];

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
        // Enables the Vector API for servers that use SIMD optimizations
        // (e.g. Pufferfish-derived forks); ignored when nothing uses it.
        '--add-modules=jdk.incubator.vector',
        ...extraJvm,
        ...flags,
        '@$argsFile',
        'nogui',
      ];
    }

    return <String>[
      '-Xms$heap',
      '-Xmx$heap',
      '--add-modules=jdk.incubator.vector',
      ...extraJvm,
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

  Future<int?> _awaitRuntimeServerPid(
    ConsumerProfile profile,
    String instance,
  ) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final pid = _readPid(_runtimeServerPidFile(profile, instance));
      if (pid != null && await _pidRunning(pid)) {
        return pid;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
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
    required bool preserveLocalChanges,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    // Isolated instances opt out of dropin sync entirely.
    if (_instanceIsolated(profile, instance)) {
      return const _DropinSyncReport(
        copiedJars: <String>[],
        preservedJars: <String>[],
        failedJars: <String>[],
      );
    }

    final source = _dropinsSource(profile, mods: sourceModsOverride);
    final sourceDir = Directory(source);
    sourceDir.createSync(recursive: true);

    final targetSubdir = _instanceDropinTargetSubdir(profile, instance);
    final targetDir = Directory(
      p.join(_instanceDir(profile, instance), targetSubdir),
    );
    targetDir.createSync(recursive: true);

    final List<String> copied = <String>[];
    final List<String> preserved = <String>[];
    final List<String> failed = <String>[];
    try {
      _withDropinSyncLock(profile, instance, () {
        if (clean) {
          for (final FileSystemEntity entity in targetDir.listSync()) {
            if (entity is File && entity.path.endsWith('.jar')) {
              entity.deleteSync();
            }
          }
        }

        final Map<String, String> synchronizedHashes = _loadDropinSyncHashes(
          profile,
          instance,
          failed,
        );
        if (clean) {
          synchronizedHashes.clear();
        }
        final List<File> jars =
            sourceDir
                .listSync()
                .whereType<File>()
                .where(
                  (File entity) => entity.path.toLowerCase().endsWith('.jar'),
                )
                .toList(growable: false)
              ..sort(
                (File a, File b) =>
                    p.basename(a.path).compareTo(p.basename(b.path)),
              );

        for (final File entity in jars) {
          try {
            final String jarName = p.basename(entity.path);
            final String syncKey = _dropinSyncJarKey(targetSubdir, jarName);
            final String targetPath = p.join(targetDir.path, jarName);
            final String sourceHash = _sha256File(entity);
            if (preserveLocalChanges) {
              final DropinSyncDecision decision = _automaticDropinSyncDecision(
                sourceHash: sourceHash,
                targetPath: targetPath,
                synchronizedHash: synchronizedHashes[syncKey],
              );
              if (decision == DropinSyncDecision.preserveLocal) {
                preserved.add(jarName);
                continue;
              }
              if (decision == DropinSyncDecision.unchanged) {
                synchronizedHashes[syncKey] = sourceHash;
                continue;
              }
            }
            _copyDropinJar(entity, targetPath);
            synchronizedHashes[syncKey] = sourceHash;
            copied.add(jarName);
          } catch (e) {
            failed.add('${p.basename(entity.path)}: $e');
          }
        }

        _saveDropinSyncHashes(profile, instance, synchronizedHashes, failed);
      });
    } catch (e) {
      failed.add('dropin sync transaction failed: $e');
    }

    if (strict && failed.isNotEmpty) {
      throw _NativeCommandException(
        'Failed to sync ${failed.length} jar(s): ${failed.join('; ')}',
        1,
      );
    }

    return _DropinSyncReport(
      copiedJars: copied,
      preservedJars: preserved,
      failedJars: failed,
    );
  }

  _DropinSyncReport _pluginsSyncOneJarToInstance(
    ConsumerProfile profile,
    String instance,
    String sourceJarPath, {
    required bool strict,
    required bool preserveLocalChanges,
  }) {
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    if (_instanceIsolated(profile, instance)) {
      return const _DropinSyncReport(
        copiedJars: <String>[],
        preservedJars: <String>[],
        failedJars: <String>[],
      );
    }

    final sourceFile = File(sourceJarPath);
    if (!sourceFile.existsSync()) {
      return const _DropinSyncReport(
        copiedJars: <String>[],
        preservedJars: <String>[],
        failedJars: <String>[],
      );
    }

    final targetSubdir = _instanceDropinTargetSubdir(profile, instance);
    final targetDir = Directory(
      p.join(_instanceDir(profile, instance), targetSubdir),
    );
    targetDir.createSync(recursive: true);

    final List<String> copied = <String>[];
    final List<String> preserved = <String>[];
    final List<String> failed = <String>[];
    final String jarName = p.basename(sourceFile.path);
    try {
      _withDropinSyncLock(profile, instance, () {
        final Map<String, String> synchronizedHashes = _loadDropinSyncHashes(
          profile,
          instance,
          failed,
        );
        final String syncKey = _dropinSyncJarKey(targetSubdir, jarName);
        final String targetPath = p.join(targetDir.path, jarName);
        final String sourceHash = _sha256File(sourceFile);
        if (preserveLocalChanges) {
          final DropinSyncDecision decision = _automaticDropinSyncDecision(
            sourceHash: sourceHash,
            targetPath: targetPath,
            synchronizedHash: synchronizedHashes[syncKey],
          );
          if (decision == DropinSyncDecision.preserveLocal) {
            preserved.add(jarName);
          } else if (decision == DropinSyncDecision.unchanged) {
            synchronizedHashes[syncKey] = sourceHash;
          } else {
            _copyDropinJar(sourceFile, targetPath);
            synchronizedHashes[syncKey] = sourceHash;
            copied.add(jarName);
          }
        } else {
          _copyDropinJar(sourceFile, targetPath);
          synchronizedHashes[syncKey] = sourceHash;
          copied.add(jarName);
        }
        _saveDropinSyncHashes(profile, instance, synchronizedHashes, failed);
      });
    } catch (e) {
      failed.add('could not sync $jarName: $e');
    }

    if (strict && failed.isNotEmpty) {
      throw _NativeCommandException(
        'Failed to sync ${failed.length} jar(s): ${failed.join('; ')}',
        1,
      );
    }

    return _DropinSyncReport(
      copiedJars: copied,
      preservedJars: preserved,
      failedJars: failed,
    );
  }

  DropinSyncDecision _automaticDropinSyncDecision({
    required String sourceHash,
    required String targetPath,
    required String? synchronizedHash,
  }) {
    final FileSystemEntityType targetType = FileSystemEntity.typeSync(
      targetPath,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.file) {
      return DropinSyncDecision.preserveLocal;
    }
    final String? targetHash = targetType == FileSystemEntityType.file
        ? _sha256File(File(targetPath))
        : null;
    return DropinSyncPolicy.decide(
      sourceHash: sourceHash,
      targetHash: targetHash,
      synchronizedHash: synchronizedHash,
    );
  }

  void _copyDropinJar(File sourceFile, String targetPath) {
    final FileStat sourceStat = sourceFile.statSync();
    final String temporaryPath =
        '$targetPath.next.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final File temporary = File(temporaryPath);
    try {
      sourceFile.copySync(temporaryPath);
      temporary.setLastModifiedSync(sourceStat.modified);
      final FileSystemEntityType targetType = FileSystemEntity.typeSync(
        targetPath,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.directory) {
        _deletePathEntity(targetPath, recursive: true);
      }
      try {
        temporary.renameSync(targetPath);
      } on FileSystemException {
        if (!Platform.isWindows ||
            FileSystemEntity.typeSync(targetPath, followLinks: false) ==
                FileSystemEntityType.notFound) {
          rethrow;
        }
        _deletePathEntity(targetPath, recursive: true);
        temporary.renameSync(targetPath);
      }
    } finally {
      temporary.deleteSyncSafe();
    }
  }

  T _withDropinSyncLock<T>(
    ConsumerProfile profile,
    String instance,
    T Function() operation,
  ) {
    final String lockPath = _dropinSyncLockPath(profile, instance);
    final FileSystemEntityType lockType = FileSystemEntity.typeSync(
      lockPath,
      followLinks: false,
    );
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Dropin sync lock is not a regular file',
        lockPath,
      );
    }
    final RandomAccessFile lockFile = File(
      lockPath,
    ).openSync(mode: FileMode.append);
    bool locked = false;
    try {
      lockFile.lockSync(FileLock.exclusive);
      locked = true;
      return operation();
    } finally {
      try {
        if (locked) {
          lockFile.unlockSync();
        }
      } finally {
        lockFile.closeSync();
      }
    }
  }

  Map<String, String> _loadDropinSyncHashes(
    ConsumerProfile profile,
    String instance,
    List<String> failures,
  ) {
    final String statePath = _dropinSyncStatePath(profile, instance);
    final FileSystemEntityType stateType = FileSystemEntity.typeSync(
      statePath,
      followLinks: false,
    );
    if (stateType == FileSystemEntityType.notFound) {
      return <String, String>{};
    }
    if (stateType != FileSystemEntityType.file) {
      failures.add('sync state is not a regular file: $statePath');
      return <String, String>{};
    }
    try {
      final Object? decoded = jsonDecode(File(statePath).readAsStringSync());
      if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
        throw const FormatException('unsupported dropin sync state');
      }
      final Object? jarsValue = decoded['jars'];
      if (jarsValue is! Map<String, dynamic>) {
        throw const FormatException('missing dropin sync jar hashes');
      }
      final Map<String, String> hashes = <String, String>{};
      for (final MapEntry<String, dynamic> entry in jarsValue.entries) {
        final Object? value = entry.value;
        if (value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
          hashes[entry.key] = value;
        }
      }
      return hashes;
    } catch (e) {
      failures.add('invalid dropin sync state: $e');
      return <String, String>{};
    }
  }

  void _saveDropinSyncHashes(
    ConsumerProfile profile,
    String instance,
    Map<String, String> hashes,
    List<String> failures,
  ) {
    final String statePath = _dropinSyncStatePath(profile, instance);
    final FileSystemEntityType stateType = FileSystemEntity.typeSync(
      statePath,
      followLinks: false,
    );
    if (stateType != FileSystemEntityType.notFound &&
        stateType != FileSystemEntityType.file) {
      failures.add('sync state is not a regular file: $statePath');
      return;
    }
    final List<String> jarNames = hashes.keys.toList(growable: false)..sort();
    final Map<String, String> sortedHashes = <String, String>{};
    for (final String jarName in jarNames) {
      sortedHashes[jarName] = hashes[jarName]!;
    }
    final String temporaryPath =
        '$statePath.next.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final File temporary = File(temporaryPath);
    try {
      temporary.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'schema': 1, 'jars': sortedHashes})}\n',
        flush: true,
      );
      temporary.renameSync(statePath);
    } catch (e) {
      failures.add('could not save dropin sync state: $e');
    } finally {
      temporary.deleteSyncSafe();
    }
  }

  String _dropinSyncStatePath(ConsumerProfile profile, String instance) {
    return p.join(_instanceDir(profile, instance), '.multiplexor-dropins.json');
  }

  String _dropinSyncLockPath(ConsumerProfile profile, String instance) {
    return p.join(_instanceDir(profile, instance), '.multiplexor-dropins.lock');
  }

  String _dropinSyncJarKey(String targetSubdir, String jarName) {
    return '$targetSubdir/$jarName';
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
      'leaf' => 'Leaf',
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
      'leaf' => '2',
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

  bool _instanceIsolated(ConsumerProfile profile, String instance) {
    final source = _serverSource(profile, instance);
    return source['isolated']?.toLowerCase().trim() == 'true';
  }

  /// Whether [instance] is locked. A locked instance refuses destructive
  /// operations (delete, factory reset) until unlocked with its PIN. This is a
  /// safety guard against accidental loss, not hard security: the lock lives in
  /// the plaintext `.server-source`, so anyone with filesystem access can edit
  /// it out. The PIN is stored salted+hashed so it is never written in clear.
  bool _instanceLocked(ConsumerProfile profile, String instance) {
    final source = _serverSource(profile, instance);
    return source['locked']?.toLowerCase().trim() == 'true';
  }

  String _hashPin(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }

  String _newPinSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  bool _instancePinMatches(
    ConsumerProfile profile,
    String instance,
    String pin,
  ) {
    final source = _serverSource(profile, instance);
    final salt = source['pin_salt'] ?? '';
    final hash = source['pin_hash'] ?? '';
    if (hash.isEmpty) {
      return false;
    }
    return _hashPin(pin, salt) == hash;
  }

  /// Throws if [name] is locked. [action] names the blocked verb for the
  /// message (e.g. 'deleted', 'reset').
  void _ensureUnlocked(
    ConsumerProfile profile,
    String name, {
    required String action,
  }) {
    if (_instanceLocked(profile, name)) {
      throw _NativeCommandException(
        'Instance "$name" is locked and cannot be $action. '
        'Unlock it first: instance unlock $name',
        2,
      );
    }
  }

  void _instanceLock(ConsumerProfile profile, String name, String pin) {
    final source = Map<String, String>.from(_serverSource(profile, name));
    final salt = _newPinSalt();
    source['locked'] = 'true';
    source['pin_salt'] = salt;
    source['pin_hash'] = _hashPin(pin, salt);
    _writeServerSource(_instanceDir(profile, name), fields: source);
  }

  void _instanceUnlock(ConsumerProfile profile, String name) {
    final source = Map<String, String>.from(_serverSource(profile, name));
    source.remove('locked');
    source.remove('pin_salt');
    source.remove('pin_hash');
    _writeServerSource(_instanceDir(profile, name), fields: source);
  }

  void _writeServerSource(
    String instanceDir, {
    required Map<String, String> fields,
  }) {
    final ordered = <String>[];
    for (final entry in fields.entries) {
      ordered.add('${entry.key}=${entry.value}');
    }
    File(
      p.join(instanceDir, '.server-source'),
    ).writeAsStringSync(ordered.join('\n'));
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

  void _instanceEnsureRestartScript(ConsumerProfile profile, String instance) {
    final instanceDir = _instanceDir(profile, instance);
    final instanceDirectory = Directory(instanceDir);
    if (!instanceDirectory.existsSync()) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }

    final scriptName = 'multiplexor-restart.sh';
    final scriptPath = p.join(instanceDir, scriptName);
    final restartLog = _runtimeRestartLogFile(profile, instance);
    Directory(p.dirname(restartLog)).createSync(recursive: true);

    final restartCommand = _selfInvocationCommand(
      profile: profile,
      args: <String>['runtime', 'start', instance, '--no-console'],
    );
    final restartPendingFile = _runtimeRestartPendingFile(profile, instance);
    final waitScript = <String>[
      'printf "%s %s\\n" "\$(date)" '
          '${_shellQuote('Restart requested for ${profile.shortName}/$instance')}',
      'date > ${_shellQuote(restartPendingFile)}',
      'i=0',
      'while command -v tmux >/dev/null 2>&1 && '
          'tmux has-session -t ${_shellQuote(_tmuxSessionName(profile, instance))} '
          '>/dev/null 2>&1 && [ "\$i" -lt 180 ]; do',
      '  i=\$((i + 1))',
      '  sleep 1',
      'done',
      'cd ${_shellQuote(context.rootDir)} || exit 1',
      'exec $restartCommand',
    ].join('\n');

    final script = <String>[
      '#!/bin/sh',
      '# Generated by Multiplexor. Used by Minecraft /restart.',
      'LOG=${_shellQuote(restartLog)}',
      'if command -v nohup >/dev/null 2>&1; then',
      '  nohup sh -c ${_shellQuote(waitScript)} '
          '>> "\$LOG" 2>&1 < /dev/null &',
      'else',
      '  sh -c ${_shellQuote(waitScript)} >> "\$LOG" 2>&1 < /dev/null &',
      'fi',
      'exit 0',
      '',
    ].join('\n');

    File(scriptPath).writeAsStringSync(script);
    final chmod = Process.runSync('chmod', <String>['755', scriptPath]);
    if (chmod.exitCode != 0) {
      throw _NativeCommandException(
        'Failed to make restart script executable: ${chmod.stderr}',
        1,
      );
    }

    final spigotConfig = File(p.join(instanceDir, 'spigot.yml'));
    if (_isPluginConsumer(profile) || spigotConfig.existsSync()) {
      _instanceConfigureSpigotRestartScript(spigotConfig, './$scriptName');
    }
  }

  void _instanceConfigureSpigotRestartScript(
    File spigotConfig,
    String restartScript,
  ) {
    final restartConfigLine = '  restart-script: $restartScript';
    if (!spigotConfig.existsSync()) {
      spigotConfig.writeAsStringSync('settings:\n$restartConfigLine\n');
      return;
    }

    final lines = spigotConfig.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!RegExp(r'^\s*restart-script\s*:').hasMatch(line)) {
        continue;
      }
      final indent = RegExp(r'^(\s*)').firstMatch(line)?.group(1) ?? '';
      lines[i] = '${indent}restart-script: $restartScript';
      spigotConfig.writeAsStringSync('${lines.join('\n')}\n');
      return;
    }

    for (var i = 0; i < lines.length; i++) {
      if (!RegExp(r'^settings\s*:\s*(?:#.*)?$').hasMatch(lines[i])) {
        continue;
      }
      lines.insert(i + 1, restartConfigLine);
      spigotConfig.writeAsStringSync('${lines.join('\n')}\n');
      return;
    }

    final output = <String>[
      ...lines,
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) '',
      'settings:',
      restartConfigLine,
    ];
    spigotConfig.writeAsStringSync('${output.join('\n')}\n');
  }

  void _instanceCreateBlank(
    ConsumerProfile profile,
    String name, {
    bool isolated = false,
    String? creationToken,
    _NativeIoBuffer? io,
  }) {
    if (name.trim().isEmpty ||
        p.basename(name) != name ||
        p.windows.basename(name) != name ||
        name == '.' ||
        name == '..') {
      throw _NativeCommandException('Instance name required', 2);
    }

    final instancePath = _instanceDir(profile, name);
    final existingType = FileSystemEntity.typeSync(
      instancePath,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound) {
      throw _NativeCommandException(
        'Instance path already exists and was not changed: $name',
        2,
      );
    }
    final String ownerToken = creationToken ?? _newPinSalt();
    if (!RegExp(r'^[0-9a-f]{32,128}$').hasMatch(ownerToken)) {
      throw _NativeCommandException('Invalid instance creation token', 2);
    }
    final Directory dir = Directory(instancePath)..createSync();
    final File owner = File(p.join(dir.path, _instanceCreationOwnerFile));
    try {
      owner.createSync(exclusive: true);
      final RandomAccessFile ownerHandle = owner.openSync(
        mode: FileMode.writeOnly,
      );
      try {
        ownerHandle.writeStringSync('$ownerToken\n');
        ownerHandle.flushSync();
      } finally {
        ownerHandle.closeSync();
      }

      final String dropinSubdir = _isPluginConsumer(profile)
          ? 'plugins'
          : 'mods';
      Directory(p.join(dir.path, dropinSubdir)).createSync();
      Directory(p.join(dir.path, 'logs')).createSync();

      final File properties = File(p.join(dir.path, 'server.properties'));
      properties.writeAsStringSync('server-port=25565\n');

      File(p.join(dir.path, 'eula.txt')).writeAsStringSync('eula=true\n');
      _instanceApplyStyledMotd(profile, name, force: true);

      // Isolated instances skip every shared-state hook: no Iris pack symlink,
      // no shared ops merge. Per-instance config still localizes (it's not
      // shared across instances).
      if (!isolated && _isPluginConsumer(profile)) {
        _irisPacksLinkInstance(profile, name);
      }
      _configLinkInstance(profile, name);
      _instanceEnsureRestartScript(profile, name);
      if (!isolated) {
        _instanceEnsureSharedPluginOps(profile, name, io: io);
      } else {
        _writeServerSource(
          dir.path,
          fields: const <String, String>{'isolated': 'true'},
        );
      }
      owner.deleteSync();
    } catch (_) {
      _deleteOwnedPartialInstance(instancePath, ownerToken);
      rethrow;
    }
  }

  static const String _instanceCreationOwnerFile = '.multiplexor-create-owner';

  bool _deleteOwnedPartialInstance(String instancePath, String ownerToken) {
    if (FileSystemEntity.typeSync(instancePath, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final String markerPath = p.join(instancePath, _instanceCreationOwnerFile);
    if (FileSystemEntity.typeSync(markerPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      if (File(markerPath).readAsStringSync().trim() != ownerToken) {
        return false;
      }
      _deletePathEntity(instancePath, recursive: true);
      return FileSystemEntity.typeSync(instancePath, followLinks: false) ==
          FileSystemEntityType.notFound;
    } on FileSystemException {
      return false;
    }
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
    final bool isolated = _instanceIsolated(profile, target);
    if (!isolated && _isPluginConsumer(profile)) {
      _irisPacksLinkInstance(profile, target);
    }
    _configLinkInstance(profile, target);
    _instanceEnsureRestartScript(profile, target);
    if (!isolated) {
      _instanceEnsureSharedPluginOps(profile, target, io: io);
    }
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
    _ensureUnlocked(profile, name, action: 'deleted');

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

    final active = _currentInstance(profile);
    var activeDeleted = false;
    for (final instance in names) {
      if (_instanceLocked(profile, instance)) {
        stdout.writeln('[SKIP] $instance is locked; left untouched');
        continue;
      }
      _instanceDelete(profile, instance);
      if (instance == active) {
        activeDeleted = true;
      }
    }

    // Only clear the active markers if the instance they point at was actually
    // removed; a surviving locked instance keeps its active status.
    if (active == null || activeDeleted) {
      File(_activeInstanceFile(profile)).deleteSyncSafe();
      File(_activeInstanceLink(profile)).deleteSyncSafe();
      File(_rootActiveInstanceLink()).deleteSyncSafe();
    }
  }

  Future<void> _instanceReset(
    ConsumerProfile profile,
    String name,
    _NativeIoBuffer io,
  ) async {
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    _ensureUnlocked(profile, name, action: 'reset');

    if (await _runtimeRunning(profile, name)) {
      await _runtimeStop(profile, name, io);
    }

    final bool wasIsolated = _instanceIsolated(profile, name);
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
      _instanceCreateBlank(profile, name, isolated: wasIsolated, io: io);
      _restoreFactoryArtifactsFromBackup(profile, name, backupPath: backupPath);
      // Factory reset rewrites server.properties to defaults, which drops the
      // MOTD. _instanceCreateBlank already applied a styled MOTD, but it ran
      // before .server-source was restored, so it fell back to the 'custom'
      // type and produced a generic gray MOTD. Now that the real server type is
      // restored, re-apply so the MOTD matches the server (e.g. Purpur).
      _instanceApplyStyledMotd(profile, name, force: true);
      _instanceEnsureRestartScript(profile, name);
      if (!wasIsolated) {
        _instanceEnsureSharedPluginOps(profile, name, io: io);
      }
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
    bool allowLatestFallback = true,
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

    if (allowLatestFallback) {
      final latest = File(p.join(dir.path, 'latest.jar'));
      if (latest.existsSync()) {
        return latest.path;
      }
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

  String _instanceGetServerIp(ConsumerProfile profile, String instance) {
    _ensureLocalServerProperties(profile, instance);
    final file = File(_instanceServerProperties(profile, instance));
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (!line.startsWith('server-ip=')) {
        continue;
      }
      final value = line.substring('server-ip='.length).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '127.0.0.1';
  }

  /// Reads a single `key=value` from the instance's server.properties, or null.
  String? _instanceGetProperty(
    ConsumerProfile profile,
    String instance,
    String key,
  ) {
    final file = File(_instanceServerProperties(profile, instance));
    if (!file.existsSync()) {
      return null;
    }
    final prefix = '$key=';
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.startsWith('#') || !line.startsWith(prefix)) {
        continue;
      }
      return line.substring(prefix.length).trim();
    }
    return null;
  }

  void _instanceSetProperties(
    ConsumerProfile profile,
    String instance,
    Map<String, String> values,
  ) {
    _ensureLocalServerProperties(profile, instance);
    final File file = File(_instanceServerProperties(profile, instance));
    final List<String> lines = file.readAsLinesSync();
    final Set<String> remaining = values.keys.toSet();
    final List<String> next = <String>[];

    for (final String raw in lines) {
      final String trimmed = raw.trim();
      if (trimmed.startsWith('#') || !trimmed.contains('=')) {
        next.add(raw);
        continue;
      }
      final String key = trimmed.substring(0, trimmed.indexOf('='));
      final String? value = values[key];
      if (value == null) {
        next.add(raw);
        continue;
      }
      if (remaining.remove(key)) {
        next.add('$key=$value');
      }
    }
    for (final String key in remaining) {
      next.add('$key=${values[key]}');
    }
    file.writeAsStringSync('${next.join('\n')}\n');
  }

  /// Enables RCON in server.properties for Paper-family instances so the
  /// dashboard can read live TPS. No-op for modded consumers (Forge/Fabric/
  /// NeoForge expose no `tps` command) and for already-configured keys. Runs on
  /// the start path; changes take effect on the next launch. A user-set
  /// rcon.port / rcon.password is preserved.
  void _ensureRconConfigured(ConsumerProfile profile, String instance) {
    if (!_isPluginConsumer(profile)) {
      return;
    }
    _ensureLocalServerProperties(profile, instance);
    final file = File(_instanceServerProperties(profile, instance));
    final lines = file.readAsLinesSync();

    int indexOfKey(String key) {
      final prefix = '$key=';
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!line.startsWith('#') && line.startsWith(prefix)) {
          return i;
        }
      }
      return -1;
    }

    String? valueOf(int index) {
      if (index < 0) {
        return null;
      }
      final line = lines[index].trim();
      final eq = line.indexOf('=');
      return eq < 0 ? '' : line.substring(eq + 1).trim();
    }

    var changed = false;
    void setKey(String key, String value) {
      final idx = indexOfKey(key);
      if (idx < 0) {
        lines.add('$key=$value');
      } else {
        lines[idx] = '$key=$value';
      }
      changed = true;
    }

    if (valueOf(indexOfKey('enable-rcon')) != 'true') {
      setKey('enable-rcon', 'true');
    }
    // Keep chat clean: TPS polling should not echo to ops.
    if (valueOf(indexOfKey('broadcast-rcon-to-ops')) != 'false') {
      setKey('broadcast-rcon-to-ops', 'false');
    }
    final existingPort = valueOf(indexOfKey('rcon.port'));
    // 25575 is the vanilla default shared by every fresh server.properties, so
    // treat it (and empty/0) as "needs a unique port" — otherwise instances
    // collide on the same RCON port when run together. A deliberately-set,
    // non-default port is preserved.
    if (existingPort == null ||
        existingPort.isEmpty ||
        existingPort == '0' ||
        existingPort == '25575') {
      final serverPort = _instanceGetServerPort(profile, instance);
      final rconPort = serverPort + 10000 <= 65535
          ? serverPort + 10000
          : serverPort - 10000;
      setKey('rcon.port', '$rconPort');
    }
    final existingPassword = valueOf(indexOfKey('rcon.password'));
    if (existingPassword == null || existingPassword.isEmpty) {
      setKey('rcon.password', _newRconPassword());
    }

    if (changed) {
      file.writeAsStringSync('${lines.join('\n')}\n');
    }
  }

  String _newRconPassword() {
    final rng = Random.secure();
    final bytes = List<int>.generate(12, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Queries live TPS over RCON. Null when RCON is unreachable, the server is
  /// not Paper-family, or the response can't be parsed.
  Future<double?> _instanceQueryTps(
    ConsumerProfile profile,
    String instance,
  ) async {
    if (!_isPluginConsumer(profile)) {
      return null;
    }
    final portRaw = _instanceGetProperty(profile, instance, 'rcon.port');
    final password = _instanceGetProperty(profile, instance, 'rcon.password');
    final enabled = _instanceGetProperty(profile, instance, 'enable-rcon');
    if (enabled?.toLowerCase() != 'true' ||
        portRaw == null ||
        password == null ||
        password.isEmpty) {
      return null;
    }
    final port = int.tryParse(portRaw);
    if (port == null) {
      return null;
    }
    final host = _instanceGetServerIp(profile, instance);
    final response = await _rconPool.command(
      host == '0.0.0.0' ? '127.0.0.1' : host,
      port,
      password,
      'tps',
      timeout: const Duration(milliseconds: 900),
    );
    return parseTps(response);
  }

  /// Emits one tab-separated line per instance with live metrics for the
  /// dashboard: name, state, port, locked, players, max, version, tps,
  /// isolation, uptimeSeconds, cpuPercent, rssBytes, logPath, latencyMs.
  /// Running servers are pinged (and RCON-queried for TPS) concurrently with
  /// short timeouts, and every live server's resident set and CPU share come
  /// from a single batched `ps`, so the whole sweep stays within ~1s.
  ///
  /// The `cpuPercent` column is BSD `ps %cpu`: a lifetime average, not an
  /// instantaneous load reading.
  Future<int> _runtimeMetrics(
    ConsumerProfile profile,
    _NativeIoBuffer io,
  ) async {
    final names = _instanceNames(profile);
    final samples = await Future.wait(
      names.map((name) async {
        final state = await _runtimeStateOf(profile, name);
        final port = _instanceGetServerPort(profile, name);
        // Probe only fully-started servers. A starting server's accept
        // queue is stalled during world load, so probes just time out and
        // every abandoned connection surfaces as Netty setsockopt noise in
        // its console the moment it begins accepting.
        final live = state == RuntimeState.running;
        // Anything that is not stopped may still own a server process, so
        // uptime and the pid are worth resolving for those states too.
        final stopped = state == RuntimeState.stopped;
        // Launched here but awaited after the ping, so it may complete while
        // nothing is listening. An error at that moment goes to the root zone
        // and tears down the isolate, which would kill the wizard polling this
        // once a second, so it is consumed at the launch site.
        final Future<Duration?> uptimeFuture = stopped
            ? Future<Duration?>.value()
            : _runtimeUptime(profile, name).catchError((Object _) => null);
        MinecraftPingResult? ping;
        double? tps;
        if (live) {
          final host = _instanceGetServerIp(profile, name);
          final pingFuture = pingMinecraftServer(
            host == '0.0.0.0' ? '127.0.0.1' : host,
            port,
            timeout: const Duration(milliseconds: 900),
          );
          final tpsFuture = _instanceQueryTps(profile, name);
          ping = await pingFuture;
          tps = await tpsFuture;
        }
        final uptime = await uptimeFuture;
        return (
          name: name,
          state: state,
          port: port,
          locked: _instanceLocked(profile, name),
          isolated: _instanceIsolated(profile, name),
          ping: ping,
          tps: tps,
          uptime: uptime,
          pid: stopped ? null : _readPid(_runtimeServerPidFile(profile, name)),
          logPath: _runtimeLogFile(profile, name),
        );
      }),
    );

    final psStats = await _sampleProcessStats(<int>[
      for (final sample in samples)
        if (sample.pid != null) sample.pid!,
    ]);

    for (final sample in samples) {
      final pid = sample.pid;
      final stat = pid != null ? psStats[pid] : null;
      final ping = sample.ping;
      io.write(
        metricsTsvRow(
          name: sample.name,
          state: sample.state,
          locked: sample.locked,
          isolated: sample.isolated,
          port: sample.port,
          players: ping?.online,
          maxPlayers: ping?.max,
          version: ping?.versionName,
          tps: sample.tps,
          uptimeSeconds: sample.uptime?.inSeconds,
          cpuPercent: stat?.cpuPercent,
          rssBytes: stat?.rssBytes,
          logPath: sample.logPath,
          latencyMs: ping?.latency.inMilliseconds,
        ),
      );
    }
    return 0;
  }

  /// Samples resident set size and CPU share for [pids] with a single
  /// batched `ps` call.
  ///
  /// Returns an empty map when there is nothing to sample, when `ps` writes
  /// nothing usable, or when the call does not finish within 900 ms. The
  /// timeout deliberately abandons the process rather than killing it: `ps`
  /// is a short-lived local read, so an orphan is harmless, and metrics must
  /// never be able to stall a dashboard refresh.
  Future<Map<int, PsStat>> _sampleProcessStats(List<int> pids) async {
    if (pids.isEmpty) {
      return const <int, PsStat>{};
    }
    try {
      final result = await Process.run(
        'ps',
        psArgsForPids(pids),
      ).timeout(const Duration(milliseconds: 900));
      // Exit code is ignored on purpose: BSD `ps` reports failure when any
      // requested pid has already exited, yet still prints the ones that
      // are alive. Parsing stdout keeps those readings.
      return parsePsOutput((result.stdout ?? '').toString());
    } on TimeoutException {
      return const <int, PsStat>{};
    } on ProcessException {
      return const <int, PsStat>{};
    }
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

  ConsumerProfile _consumerForServerType(String type) {
    switch (type.toLowerCase().trim()) {
      case 'forge':
        return ConsumerProfile.forge;
      case 'fabric':
        return ConsumerProfile.fabric;
      case 'neoforge':
        return ConsumerProfile.neoforge;
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'leaf':
      case 'spigot':
        return ConsumerProfile.plugin;
      default:
        throw _NativeCommandException(
          'Unknown server type for routing: $type',
          2,
        );
    }
  }

  bool _isKnownServerType(String type) {
    switch (type.toLowerCase().trim()) {
      case 'paper':
      case 'purpur':
      case 'folia':
      case 'canvas':
      case 'leaf':
      case 'spigot':
      case 'forge':
      case 'fabric':
      case 'neoforge':
        return true;
      default:
        return false;
    }
  }

  void _ensureConsumerOwnsServerType(
    ConsumerProfile profile,
    String type, {
    required String command,
  }) {
    if (!_isKnownServerType(type)) {
      return;
    }
    final expected = _consumerForServerType(type);
    if (profile == expected) {
      return;
    }
    throw _NativeCommandException(
      'Server type "$type" belongs to the ${expected.shortName} consumer, '
      'but the active consumer is ${profile.shortName}. Use: ./start.sh '
      '--consumer ${expected.shortName} $command ...',
      2,
    );
  }

  String _repoUrl(String type) {
    return switch (type) {
      'paper' => 'https://github.com/PaperMC/Paper.git',
      'purpur' => 'https://github.com/PurpurMC/Purpur.git',
      'folia' => 'https://github.com/PaperMC/Folia.git',
      'canvas' => 'https://github.com/CraftCanvasMC/Canvas.git',
      'leaf' => 'https://github.com/Winds-Studio/Leaf.git',
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

  ConsumerProfile get _activeConsumer {
    return _consumerOverride ??
        context.requestedConsumer ??
        consumerService.readActive();
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

  String _runtimeRestartLogFile(ConsumerProfile profile, String instance) {
    return p.join(_runtimeDir(profile), '$instance.restart.log');
  }

  String _runtimeRestartPendingFile(ConsumerProfile profile, String instance) {
    return p.join(_runtimeDir(profile), '$instance.restart-pending');
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
    'leaf',
    'forge',
    'fabric',
    'neoforge',
  ];

  static const Map<String, String> _runtimeSettingsPresets = <String, String>{
    'aikar':
        '-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 '
        '-XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapRegionSize=8M '
        '-XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 '
        '-XX:+UseStringDeduplication -Dfile.encoding=UTF-8',
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

class _DoctorCheck {
  const _DoctorCheck({
    required this.level,
    required this.name,
    required this.detail,
  });

  final String level;
  final String name;
  final String detail;
}

class _FlexibleArgs {
  const _FlexibleArgs({
    required this.options,
    required this.flags,
    required this.positionals,
  });

  static const empty = _FlexibleArgs(
    options: <String, String>{},
    flags: <String, bool>{},
    positionals: <String>[],
  );

  final Map<String, String> options;
  final Map<String, bool> flags;
  final List<String> positionals;

  String? option(String name) => options[name];

  bool flag(String name) => flags[name] == true;
}

class _BackupEntry {
  const _BackupEntry({
    required this.profile,
    required this.instance,
    required this.id,
    required this.path,
  });

  final ConsumerProfile profile;
  final String instance;
  final String id;
  final String path;

  Map<String, dynamic> get manifest {
    final file = File(p.join(path, 'manifest.json'));
    if (!file.existsSync()) {
      return <String, dynamic>{
        'id': id,
        'consumer': profile.shortName,
        'instance': instance,
        'created_at': id,
        'label': '',
        'snapshot': 'snapshot',
        'entries': <Map<String, dynamic>>[],
      };
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw _NativeCommandException('Invalid backup manifest: ${file.path}', 1);
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
        '-XX:+UseStringDeduplication -Dfile.encoding=UTF-8',
    this.profile = 'aikar',
    this.noLineWrap = true,
    this.consoleLogFormat = 'minimal',
  });

  static const _RuntimeSettingsData defaults = _RuntimeSettingsData();

  final String heap;
  final String jvmArgs;
  final String profile;

  /// When true, the tmux launch script disables DECAWM so long server lines
  /// clip at the pane edge instead of wrapping. The log file is unaffected.
  final bool noLineWrap;

  /// 'minimal' strips the [time level]: prefix from the console only.
  /// 'default' uses the server's bundled log4j2 config.
  final String consoleLogFormat;

  _RuntimeSettingsData copyWith({
    String? heap,
    String? jvmArgs,
    String? profile,
    bool? noLineWrap,
    String? consoleLogFormat,
  }) {
    return _RuntimeSettingsData(
      heap: heap ?? this.heap,
      jvmArgs: jvmArgs ?? this.jvmArgs,
      profile: profile ?? this.profile,
      noLineWrap: noLineWrap ?? this.noLineWrap,
      consoleLogFormat: consoleLogFormat ?? this.consoleLogFormat,
    );
  }
}

class _RuntimeTargetArgs {
  const _RuntimeTargetArgs({required this.instance, required this.noConsole});

  final String? instance;
  final bool noConsole;
}

class _ServerCreateArguments {
  const _ServerCreateArguments({
    required this.options,
    required this.artifacts,
  });

  final Map<String, String> options;
  final List<String> artifacts;
}

class _DropinSyncReport {
  const _DropinSyncReport({
    required this.copiedJars,
    required this.preservedJars,
    required this.failedJars,
  });

  final List<String> copiedJars;
  final List<String> preservedJars;
  final List<String> failedJars;
}

class _FolderOpener {
  const _FolderOpener(this.executable, {this.prefixArgs = const <String>[]});

  final String executable;
  final List<String> prefixArgs;
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
