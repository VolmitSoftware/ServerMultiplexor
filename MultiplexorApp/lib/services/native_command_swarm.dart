part of 'native_command_service.dart';

final Set<String> _activeSwarmLocks = <String>{};

extension _NativeSwarmCommands on NativeCommandService {
  Future<int> _dispatchGameplaySwarm(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
  ) async {
    final _SwarmInterruptGuard interrupt = _SwarmInterruptGuard();
    try {
      final int result = await _dispatchGameplaySwarmGuarded(
        args,
        harness,
        io,
        interrupt,
      );
      interrupt.check();
      return result;
    } finally {
      await interrupt.close();
    }
  }

  Future<int> _dispatchGameplaySwarmGuarded(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
    _SwarmInterruptGuard interrupt,
  ) async {
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args,
      booleanFlags: const <String>{
        'json',
        'build-arena',
        'chat',
        'no-viewer',
        'prepare',
        'start',
        'stop-after',
      },
    );
    if (parsed.positionals.isEmpty) {
      throw const FormatException('A swarm profile or JSON plan is required.');
    }
    if (parsed.positionals.length > 1 && parsed.option('instance') != null) {
      throw const FormatException(
        'Specify the instance once, positionally or with --instance.',
      );
    }
    final String requestedProfile = parsed.positionals.first;
    final String swarmProfile = requestedProfile.toLowerCase().endsWith('.json')
        ? File(requestedProfile).absolute.path
        : requestedProfile;
    final GameplaySwarmSettings settings = GameplaySwarmSettings.parse(
      profile: swarmProfile,
      options: <String, String>{
        ...parsed.options,
        if (parsed.option('workload') != null)
          'workload': File(parsed.option('workload')!).absolute.path,
      },
      flags: parsed.flags.entries
          .where((MapEntry<String, bool> flag) => flag.value)
          .map((MapEntry<String, bool> flag) => flag.key)
          .toSet(),
      generatedPrefix: 'Sw${_swarmRandomHex(3)}',
    );
    final int? viewerPort = _gameplayOptionalPort(
      parsed.option('viewer-port'),
      option: '--viewer-port',
    );
    if (viewerPort != null && parsed.flag('no-viewer')) {
      throw const FormatException(
        '--viewer-port cannot be combined with --no-viewer.',
      );
    }
    final String? version = parsed.option('version');
    if (version != null && !RegExp(r'^\d+\.\d+(?:\.\d+)?$').hasMatch(version)) {
      throw const FormatException(
        '--version must be a Minecraft version such as 1.21.11 or 26.1.',
      );
    }
    if (settings.customPlan) {
      if (!File(swarmProfile).existsSync()) {
        throw FormatException('Swarm plan not found: $swarmProfile');
      }
      final int validation = await harness.swarmValidate(
        swarmProfile,
        bots: settings.bots,
        origin: settings.origin,
        write: (String line) {},
        error: io.error,
      );
      interrupt.check();
      if (validation != 0) return validation;
    }
    if (settings.profile == 'stress') {
      if (settings.workload != null && !File(settings.workload!).existsSync()) {
        throw FormatException('Swarm workload not found: ${settings.workload}');
      }
      final int validation = await harness.swarmWorkloadValidate(
        settings: settings,
        write: (String line) {},
        error: io.error,
      );
      interrupt.check();
      if (validation != 0) return validation;
    }
    final String instance = _resolveGameplayInstance(
      parsed.option('instance') ??
          (parsed.positionals.length > 1 ? parsed.positionals[1] : null),
    );
    final ConsumerProfile profile = _activeConsumer;
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }
    _ensureGameInstance(profile, instance, 'run a swarm on');
    _ensureNetworkDetached(profile, instance, action: 'run a swarm');
    if (!_instanceIsolated(profile, instance)) {
      throw _NativeCommandException(
        'Swarms require an isolated instance: $instance',
        2,
      );
    }
    if (!harness.installed) {
      throw _NativeCommandException(
        'Install the Mineflayer harness first: gameplay setup',
        2,
      );
    }
    final String path = p.join(
      _stateDir(profile),
      'gameplay-tests',
      instance,
      'swarm.lock',
    );
    if (!_activeSwarmLocks.add(path)) {
      throw _NativeCommandException(
        'A swarm is already running for $instance.',
        2,
      );
    }
    RandomAccessFile? lock;
    try {
      final File file = File(path)..parent.createSync(recursive: true);
      lock = file.openSync(mode: FileMode.append);
      try {
        lock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw _NativeCommandException(
          'A swarm is already running for $instance.',
          2,
        );
      }
      return await _runGameplaySwarm(
        profile,
        instance,
        settings,
        parsed,
        harness,
        io,
        viewerPort,
        interrupt,
      );
    } finally {
      lock?.closeSync();
      _activeSwarmLocks.remove(path);
    }
  }

  Future<int> _runGameplaySwarm(
    ConsumerProfile profile,
    String instance,
    GameplaySwarmSettings settings,
    _FlexibleArgs parsed,
    GameplayTestService harness,
    _NativeIoBuffer io,
    int? viewerPort,
    _SwarmInterruptGuard interrupt,
  ) async {
    final bool json = parsed.flag('json');
    final _NativeIoBuffer operationIo = json
        ? _NativeIoBuffer(stream: false)
        : io;
    final bool wasRunning = _recoveryRuntimeOverride == null
        ? await _runtimeStateOf(profile, instance) != RuntimeState.stopped
        : await _recoveryIsRunning(profile, instance);
    if (parsed.flag('prepare') && wasRunning) {
      throw _NativeCommandException(
        'Stop $instance before using --prepare.',
        2,
      );
    }
    if (!wasRunning && !parsed.flag('start')) {
      throw _NativeCommandException(
        '$instance is stopped. Start it first or pass --start.',
        2,
      );
    }
    final String controller = 'Sc${_swarmRandomHex(6)}';
    _swarmCheckOperatorNames(profile, instance, <String>[
      ...settings.workerNames,
      if (settings.requiresController) controller,
    ]);
    if (parsed.flag('prepare')) {
      interrupt.check();
      await _prepareGameplayInstance(profile, instance, operationIo);
    }
    interrupt.check();
    final String host = _instanceGetServerIp(profile, instance);
    if (_instanceGetProperty(profile, instance, 'online-mode') != 'false' ||
        !const <String>{'127.0.0.1', '::1'}.contains(host)) {
      throw _NativeCommandException(
        'Swarms require offline authentication and a loopback bind. Stop the isolated instance and pass --prepare.',
        2,
      );
    }
    bool startedHere = false;
    bool controllerGranted = false;
    int result = 1;
    try {
      if (!wasRunning) {
        await _recoveryStart(profile, instance, operationIo);
        startedHere = true;
      }
      interrupt.check();
      final MinecraftPingResult ping = await _requireRecoveryReadiness(
        profile,
        instance,
        Duration(seconds: settings.startupTimeoutSeconds),
      );
      interrupt.check();
      final int requiredSlots =
          settings.bots + (settings.requiresController ? 1 : 0);
      final int availableSlots = ping.max - ping.online;
      if (availableSlots < requiredSlots) {
        throw _NativeCommandException(
          'Swarm needs $requiredSlots free player slots ($availableSlots available). Increase max-players or reduce --bots.',
          2,
        );
      }
      if (!json) {
        io.write(
          '[OK] Swarm target ready: $instance ${ping.versionName}; ${settings.bots} workers.',
        );
      }
      if (settings.requiresController) {
        controllerGranted = true;
        if (!await _swarmConsoleCommand(profile, instance, 'op $controller') ||
            !await _swarmWaitOperator(
              profile,
              instance,
              controller,
              present: true,
            )) {
          throw _NativeCommandException(
            'Could not grant temporary controller operator status.',
            1,
          );
        }
      }
      interrupt.check();
      result = await harness.swarm(
        run: GameplaySwarmRun(
          settings: settings,
          controller: settings.requiresController ? controller : null,
          host: host,
          port: _instanceGetServerPort(profile, instance),
          instance: instance,
          artifactsDirectory: p.join(
            _stateDir(profile),
            'gameplay-tests',
            instance,
          ),
          logPath: _runtimeLogFile(profile, instance),
          version:
              parsed.option('version') ??
              _serverSource(profile, instance)['mc'],
          viewerEnabled: !parsed.flag('no-viewer'),
          viewerPort: viewerPort,
          json: json,
        ),
        write: io.write,
        error: io.error,
      );
      interrupt.check();
    } finally {
      try {
        if (controllerGranted &&
            !await _swarmRevokeController(profile, instance, controller)) {
          throw _NativeCommandException(
            'Could not revoke swarm controller $controller. Remove it from ops.json before using this instance.',
            1,
          );
        }
      } finally {
        if (startedHere && parsed.flag('stop-after')) {
          await _recoveryStop(profile, instance, operationIo);
        } else if (wasRunning && parsed.flag('stop-after') && !json) {
          io.write(
            '[INFO] $instance was already running; --stop-after left it running.',
          );
        }
      }
    }
    return result;
  }

  void _swarmCheckOperatorNames(
    ConsumerProfile profile,
    String instance,
    List<String> names,
  ) {
    final File file = File(p.join(_instanceDir(profile, instance), 'ops.json'));
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const FormatException(
        'Swarm ops.json must be a local regular file.',
      );
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List<Object?>) {
      throw const FormatException('Invalid ops.json.');
    }
    final Set<String> reserved = names
        .map((String value) => value.toLowerCase())
        .toSet();
    final Set<String> reservedUuids = names.map(_swarmOfflineUuid).toSet();
    for (final Object? entry in decoded) {
      if (entry is Map) {
        final Object? name = entry['name'];
        final Object? uuid = entry['uuid'];
        if ((name is String && reserved.contains(name.toLowerCase())) ||
            (uuid is String &&
                reservedUuids.contains(
                  uuid.toLowerCase().replaceAll('-', ''),
                ))) {
          throw FormatException(
            'Swarm worker/controller identity is already an operator: ${name ?? uuid}. Use another --prefix.',
          );
        }
      }
    }
  }

  Future<bool> _swarmConsoleCommand(
    ConsumerProfile profile,
    String instance,
    String command,
  ) async {
    if (Platform.isWindows) {
      return _instanceSendRconCommand(profile, instance, command);
    }
    final String session = _tmuxSessionName(profile, instance);
    if ((await _runProcess('tmux', <String>[
          'send-keys',
          '-l',
          '-t',
          session,
          command,
        ])).exitCode ==
        0) {
      return (await _runProcess('tmux', <String>[
            'send-keys',
            '-t',
            session,
            'Enter',
          ])).exitCode ==
          0;
    }
    return false;
  }

  bool? _swarmOperatorPresent(
    ConsumerProfile profile,
    String instance,
    String controller,
  ) {
    final File file = File(p.join(_instanceDir(profile, instance), 'ops.json'));
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) return null;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List<Object?>) return null;
      return decoded.any(
        (Object? entry) => _swarmControllerMatches(entry, controller),
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> _swarmWaitOperator(
    ConsumerProfile profile,
    String instance,
    String controller, {
    required bool present,
  }) async {
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(seconds: 10)) {
      if (_swarmOperatorPresent(profile, instance, controller) == present) {
        return true;
      }
      if (!await _recoveryIsRunning(profile, instance)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  Future<bool> _swarmRevokeController(
    ConsumerProfile profile,
    String instance,
    String controller,
  ) async {
    if (await _recoveryIsRunning(profile, instance)) {
      if (!await _swarmConsoleCommand(profile, instance, 'deop $controller')) {
        return false;
      }
      if (await _swarmWaitOperator(
        profile,
        instance,
        controller,
        present: false,
      )) {
        return true;
      }
      if (await _recoveryIsRunning(profile, instance)) return false;
    }
    final File file = File(p.join(_instanceDir(profile, instance), 'ops.json'));
    if (!file.existsSync()) return true;
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List<Object?>) return false;
    final List<Object?> remaining = decoded
        .where((Object? entry) => !_swarmControllerMatches(entry, controller))
        .toList();
    if (remaining.length != decoded.length) {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(remaining)}\n',
        flush: true,
      );
    }
    return true;
  }
}

bool _swarmControllerMatches(Object? entry, String controller) {
  if (entry is! Map<Object?, Object?>) return false;
  final Object? name = entry['name'];
  final Object? uuid = entry['uuid'];
  return (name is String && name.toLowerCase() == controller.toLowerCase()) ||
      (uuid is String &&
          uuid.toLowerCase().replaceAll('-', '') ==
              _swarmOfflineUuid(controller));
}

String _swarmRandomHex(int bytes) {
  final Random random = Random.secure();
  return List<String>.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _swarmOfflineUuid(String name) {
  final List<int> bytes = md5
      .convert(utf8.encode('OfflinePlayer:$name'))
      .bytes
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x30;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class _SwarmInterruptGuard {
  _SwarmInterruptGuard() {
    TermIo.instance.deferSignalExit();
    for (final ProcessSignal signal in <ProcessSignal>[
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      _subscriptions.add(
        signal.watch().listen((ProcessSignal received) {
          _signal ??= received;
        }),
      );
    }
  }

  final List<StreamSubscription<ProcessSignal>> _subscriptions =
      <StreamSubscription<ProcessSignal>>[];
  ProcessSignal? _signal;

  void check() {
    if (_signal != null) {
      throw _NativeCommandException(
        'Swarm interrupted; cleanup completed.',
        _signal == ProcessSignal.sigint ? 130 : 143,
      );
    }
  }

  Future<void> close() async {
    try {
      for (final StreamSubscription<ProcessSignal> subscription
          in _subscriptions) {
        await subscription.cancel();
      }
    } finally {
      TermIo.instance.resumeSignalExit();
    }
  }
}
