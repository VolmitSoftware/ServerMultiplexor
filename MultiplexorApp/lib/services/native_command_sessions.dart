part of 'native_command_service.dart';

extension _NativeSessionCommands on NativeCommandService {
  String get _sessionsDirectory =>
      p.join(_stateDir(_activeConsumer), 'gameplay-sessions');

  Directory _sessionDirectory(String run) {
    if (!RegExp(r'^session-[a-zA-Z0-9-]{1,80}$').hasMatch(run)) {
      throw const FormatException('Invalid session run ID.');
    }
    return Directory(p.join(_sessionsDirectory, run));
  }

  Future<GameplaySessionValidation> _sessionValidateProfile(
    GameplayTestService harness,
    String profilePath, {
    String? configurationPath,
  }) async {
    if (!File(profilePath).existsSync()) {
      throw FormatException('Session profile not found: $profilePath');
    }
    final List<String> output = <String>[];
    final List<String> errors = <String>[];
    final int result = await harness.sessionsValidate(
      profilePath: profilePath,
      configurationPath: configurationPath,
      write: output.add,
      error: errors.add,
    );
    if (result != 0) {
      String? structuredError;
      try {
        final Object? decoded = jsonDecode(output.join('\n'));
        if (decoded is Map<String, Object?> && decoded['error'] is String) {
          final String message = (decoded['error']! as String).trim();
          if (message.isNotEmpty) structuredError = message;
        }
      } on FormatException {
        structuredError = null;
      }
      final Set<String> diagnostics = <String>{
        ?structuredError,
        ...errors
            .map((String message) => message.trim())
            .where((String message) => message.isNotEmpty),
      };
      throw _NativeCommandException(
        'Session profile validation failed: ${diagnostics.isEmpty ? 'worker exited with code $result' : diagnostics.join('\n')}',
        result,
      );
    }
    return GameplaySessionValidation.decode(output.join('\n'));
  }

  GameplaySessionTarget _sessionResolveTarget({
    String? instance,
    String? network,
    bool allowPreparation = false,
  }) {
    if ((instance == null) == (network == null)) {
      throw const FormatException(
        'Specify exactly one --instance or --network.',
      );
    }
    final ConsumerProfile profile = _activeConsumer;
    GameplaySessionBackend backend(String name, String alias, int port) =>
        GameplaySessionBackend(
          alias: alias,
          instance: name,
          port: port,
          logPath: _runtimeLogFile(profile, name),
          observerPath: p.join(
            _instanceDir(profile, name),
            'plugins',
            'MultiplexorObserver',
            'metrics.json',
          ),
        );
    if (network != null) {
      if (profile != ConsumerProfile.plugin) {
        throw const FormatException(
          'Velocity sessions require --consumer plugin.',
        );
      }
      if (allowPreparation) {
        throw const FormatException(
          '--prepare is only for standalone instances. Create an isolated offline network with network create --offline.',
        );
      }
      final NetworkDefinition definition = _networkStore.load(network);
      if (definition.onlineMode || definition.bind != '127.0.0.1') {
        throw const FormatException(
          'Sessions require an offline loopback Velocity network.',
        );
      }
      _validateNetworkRuntime(profile, definition.proxy);
      for (final String name in <String>[
        definition.proxy,
        ...definition.members.map((NetworkMember member) => member.instance),
      ]) {
        if (!_instanceIsolated(profile, name)) {
          throw FormatException(
            'Sessions require every network instance to be isolated: $name',
          );
        }
      }
      final List<GameplaySessionBackend> backends = definition.members
          .map(
            (NetworkMember member) =>
                backend(member.instance, member.alias, member.port),
          )
          .toList();
      final GameplaySessionBackend entry = backends.firstWhere(
        (GameplaySessionBackend value) =>
            value.alias == definition.defaultServer,
      );
      return GameplaySessionTarget(
        kind: 'network',
        name: network,
        host: definition.bind,
        port: definition.port,
        proxy: definition.proxy,
        defaultBackend: definition.defaultServer,
        backends: backends,
        version: _serverSource(profile, entry.instance)['mc'],
        proxyLogPath: _runtimeLogFile(profile, definition.proxy),
        observerPath: p.join(
          _instanceDir(profile, definition.proxy),
          'plugins',
          'MultiplexorObserver',
          'metrics.json',
        ),
      );
    }
    final String name = _validateSimpleName(instance!, label: 'instance');
    if (!_instanceExists(profile, name)) {
      throw FormatException('Instance not found: $name');
    }
    _ensureGameInstance(profile, name, 'run sessions on');
    _ensureNetworkDetached(profile, name, action: 'run standalone sessions');
    if (!_instanceIsolated(profile, name)) {
      throw FormatException('Sessions require an isolated instance: $name');
    }
    final String host = _instanceGetServerIp(profile, name);
    if (!allowPreparation &&
        (_instanceGetProperty(profile, name, 'online-mode') != 'false' ||
            !const <String>{'127.0.0.1', '::1'}.contains(host))) {
      throw const FormatException(
        'Sessions require offline authentication and a loopback bind. Stop the isolated instance and use --prepare --start.',
      );
    }
    final int port = _instanceGetServerPort(profile, name);
    return GameplaySessionTarget(
      kind: 'instance',
      name: name,
      host: allowPreparation ? '127.0.0.1' : host,
      port: port,
      backends: <GameplaySessionBackend>[backend(name, name, port)],
      defaultBackend: name,
      version: _serverSource(profile, name)['mc'],
    );
  }

  Future<int> _dispatchGameplaySessions(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
  ) async {
    if (args.isNotEmpty &&
        const <String>{'stop', 'resume'}.contains(args.first)) {
      if (args.length < 2) {
        throw const FormatException('A session run ID is required.');
      }
      final Directory directory = _sessionDirectory(args[1]);
      if (!File(p.join(directory.path, 'configuration.json')).existsSync()) {
        throw const FormatException('Session run not found.');
      }
      final String path = p.join(directory.path, 'command.lock');
      return _sessionWithLocks(<String>[
        path,
      ], () => _dispatchGameplaySessionsUnlocked(args, harness, io));
    }
    return _dispatchGameplaySessionsUnlocked(args, harness, io);
  }

  Future<T> _sessionWithLocks<T>(
    List<String> paths,
    Future<T> Function() action,
  ) async {
    final Map<String, RandomAccessFile> handles = <String, RandomAccessFile>{};
    try {
      for (final String path in paths) {
        if (!_activeSwarmLocks.add(path)) {
          throw const FormatException(
            'Another session operation owns this target.',
          );
        }
        RandomAccessFile? handle;
        try {
          final File file = File(path)..parent.createSync(recursive: true);
          handle = file.openSync(mode: FileMode.append);
          handle.lockSync(FileLock.exclusive);
          handles[path] = handle;
        } catch (_) {
          handle?.closeSync();
          _activeSwarmLocks.remove(path);
          throw const FormatException(
            'Another session operation owns this target.',
          );
        }
      }
      return await action();
    } finally {
      for (final MapEntry<String, RandomAccessFile> entry
          in handles.entries.toList().reversed) {
        entry.value.closeSync();
        _activeSwarmLocks.remove(entry.key);
      }
    }
  }

  Future<int> _dispatchGameplaySessionsUnlocked(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
  ) async {
    final String action = args.isEmpty ? 'list' : args.first;
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args.skip(1).toList(),
      booleanFlags: const <String>{
        'json',
        'prepare',
        'start',
        'stop-after',
        'no-viewer',
      },
    );
    final bool json = parsed.flag('json');
    if (action == 'list') {
      final Directory directory = Directory(_sessionsDirectory);
      final List<Map<String, Object?>> runs = directory.existsSync()
          ? directory
                .listSync()
                .whereType<Directory>()
                .where(
                  (Directory entry) =>
                      p.basename(entry.path).startsWith('session-') &&
                      File(
                        p.join(entry.path, 'configuration.json'),
                      ).existsSync(),
                )
                .map(_sessionSummary)
                .toList()
          : <Map<String, Object?>>[];
      runs.sort(
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (b['runId']! as String).compareTo(a['runId']! as String),
      );
      if (json) {
        io.write(jsonEncode(runs));
      } else if (runs.isEmpty) {
        io.write('(no session runs)');
      } else {
        for (final Map<String, Object?> run in runs) {
          _sessionPrintSummary(run, io);
        }
      }
      return 0;
    }
    if (action == 'validate' || action == 'start') {
      if (parsed.positionals.length != 1) {
        throw const FormatException('A session profile JSON path is required.');
      }
      final String sourcePath = File(parsed.positionals.single).absolute.path;
      final GameplaySessionValidation validation =
          await _sessionValidateProfile(harness, sourcePath);
      final GameplaySessionTarget target = _sessionResolveTarget(
        instance: parsed.option('instance'),
        network: parsed.option('network'),
        allowPreparation: parsed.flag('prepare'),
      );
      _sessionCheckNames(target, validation, null);
      if (action == 'validate') {
        if (parsed.flag('prepare') &&
            await _recoveryIsRunning(_activeConsumer, target.name)) {
          throw const FormatException(
            'Stop the standalone instance before planning preparation.',
          );
        }
        final Directory temporary = Directory.systemTemp.createTempSync(
          'multiplexor-session-validation-',
        );
        try {
          final File configFile = File(
            p.join(temporary.path, 'configuration.json'),
          );
          writeSessionObject(configFile, <String, Object?>{
            'schemaVersion': 1,
            'runId': 'session-validation',
            'artifactsDirectory': temporary.path,
            'profilePath': sourcePath,
            'resume': false,
            'target': target.toJson(),
            'viewerEnabled': false,
            if (validation.requiresController)
              'controller': <String, Object?>{'username': 'PcValidation'},
          });
          await _sessionValidateProfile(
            harness,
            sourcePath,
            configurationPath: configFile.path,
          );
        } finally {
          temporary.deleteSync(recursive: true);
        }
        io.write(
          json
              ? jsonEncode(<String, Object?>{
                  'status': 'passed',
                  'profile': validation.profile,
                  'playerNames': validation.playerNames,
                  'maximumPopulation': validation.maximumPopulation,
                  'target': target.toJson(),
                })
              : '[OK] Session profile and target validated: ${target.name}; ${validation.playerNames.length} identities.',
        );
        return 0;
      }
      if (!harness.installed) {
        throw const FormatException(
          'Install the Mineflayer harness first: gameplay setup',
        );
      }
      _sessionRequireCleanTarget(target);
      final int? viewerPort = _gameplayOptionalPort(
        parsed.option('viewer-port'),
        option: '--viewer-port',
      );
      if (viewerPort != null && parsed.flag('no-viewer')) {
        throw const FormatException(
          '--viewer-port cannot be combined with --no-viewer.',
        );
      }
      final int timeout = _gameplayPositiveSeconds(
        parsed.option('startup-timeout'),
        fallback: 180,
        option: '--startup-timeout',
      );
      for (final String instance in target.instances) {
        final bool running = await _recoveryIsRunning(
          _activeConsumer,
          instance,
        );
        if (parsed.flag('prepare') && running) {
          throw FormatException('Stop $instance before using --prepare.');
        }
        if (!running && !parsed.flag('start')) {
          throw FormatException(
            '$instance is stopped. Start it first or use --start.',
          );
        }
        _sessionRequireFree(_sessionTargetLock(instance));
      }
      final String runId =
          'session-${DateTime.now().toUtc().millisecondsSinceEpoch}-${_swarmRandomHex(3)}';
      final Directory directory = _sessionDirectory(runId)
        ..createSync(recursive: true);
      final File profileFile = File(p.join(directory.path, 'profile.json'));
      writeSessionObject(profileFile, validation.profile);
      final String controller = 'Pc${_swarmRandomHex(6)}';
      final Map<String, Object?> configuration = <String, Object?>{
        'schemaVersion': 1,
        'runId': runId,
        'artifactsDirectory': directory.path,
        'profilePath': profileFile.path,
        'resume': false,
        'target': target.toJson(),
        if (validation.requiresController)
          'controller': <String, Object?>{'username': controller},
        'viewerEnabled': !parsed.flag('no-viewer'),
        'viewerPort': ?viewerPort,
      };
      writeSessionObject(
        File(p.join(directory.path, 'configuration.json')),
        configuration,
      );
      writeSessionObject(File(p.join(directory.path, 'request.json')), <
        String,
        Object?
      >{
        'schemaVersion': 1,
        'prepare': parsed.flag('prepare'),
        'start': parsed.flag('start'),
        'stopAfter': parsed.flag('stop-after'),
        'startupTimeoutSeconds': timeout,
        'profileHash': sha256.convert(profileFile.readAsBytesSync()).toString(),
      });
      try {
        await _sessionValidateProfile(
          harness,
          profileFile.path,
          configurationPath: p.join(directory.path, 'configuration.json'),
        );
        await _sessionLaunch(directory);
      } catch (error) {
        if (!File(p.join(directory.path, 'host.json')).existsSync()) {
          writeSessionObject(
            File(p.join(directory.path, 'host.json')),
            <String, Object?>{
              'state': 'failed',
              'error': '$error',
              'cleanupComplete': true,
            },
          );
        }
        rethrow;
      }
      final Map<String, Object?> summary = _sessionSummary(directory);
      if (json) {
        io.write(jsonEncode(summary));
      } else {
        _sessionPrintSummary(summary, io);
      }
      return 0;
    }
    if (parsed.positionals.length != 1) {
      throw const FormatException('A session run ID is required.');
    }
    final Directory directory = _sessionDirectory(parsed.positionals.single);
    if (!File(p.join(directory.path, 'configuration.json')).existsSync()) {
      throw const FormatException('Session run not found.');
    }
    if (action == 'stop') {
      final File stop = File(p.join(directory.path, 'stop.request'));
      stop.writeAsStringSync(
        '${DateTime.now().toUtc().toIso8601String()}\n',
        flush: true,
      );
      if (!_sessionLocked(p.join(directory.path, 'host.lock'))) {
        await _sessionRecoverOrphan(directory, io);
      }
      final Stopwatch elapsed = Stopwatch()..start();
      while (_sessionLocked(p.join(directory.path, 'host.lock')) &&
          elapsed.elapsed < const Duration(seconds: 45)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } else if (action == 'resume') {
      _sessionRequireFree(p.join(directory.path, 'host.lock'));
      await _sessionRecoverOrphan(directory, io);
      final File checkpoint = File(p.join(directory.path, 'checkpoint.json'));
      if (!checkpoint.existsSync()) {
        throw const FormatException('No checkpoint is available to resume.');
      }
      final File configFile = File(
        p.join(directory.path, 'configuration.json'),
      );
      final Map<String, Object?> configuration = readSessionObject(configFile);
      _sessionCheckProfileHash(directory);
      await _sessionValidateProfile(
        harness,
        configuration['profilePath']! as String,
      );
      final GameplaySessionTarget saved = GameplaySessionTarget.fromJson(
        sessionObject(configuration['target']),
      );
      final GameplaySessionTarget current = _sessionResolveTarget(
        instance: saved.kind == 'instance' ? saved.name : null,
        network: saved.kind == 'network' ? saved.name : null,
      );
      if (jsonEncode(current.toJson()) != jsonEncode(saved.toJson())) {
        throw const FormatException('Session target changed. Start a new run.');
      }
      _sessionVerifyWorldIdentities(directory, saved, resume: true);
      configuration['resume'] = true;
      writeSessionObject(configFile, configuration);
      File(p.join(directory.path, 'stop.request')).deleteSyncSafe();
      await _sessionLaunch(directory);
    } else if (action == 'report') {
      final File report = File(p.join(directory.path, 'report.json'));
      if (!report.existsSync()) {
        throw const FormatException(
          'The run has no final report yet. Use sessions status.',
        );
      }
      final Map<String, Object?> result = <String, Object?>{
        ...readSessionObject(report),
        'host': _sessionSummary(directory)['host'],
      };
      io.write(
        json
            ? jsonEncode(result)
            : const JsonEncoder.withIndent('  ').convert(result),
      );
      return 0;
    } else if (action != 'status') {
      throw FormatException('Unknown sessions command: $action');
    }
    final Map<String, Object?> summary = _sessionSummary(directory);
    if (json) {
      io.write(jsonEncode(summary));
    } else {
      _sessionPrintSummary(summary, io);
    }
    if (!json && action == 'status') {
      _sessionPrintWorkload(sessionObject(summary['workload']), io);
    }
    return action == 'stop' && summary['active'] == true ? 1 : 0;
  }

  void _sessionCheckProfileHash(Directory directory) {
    final Map<String, Object?> request = readSessionObject(
      File(p.join(directory.path, 'request.json')),
    );
    final String hash = sha256
        .convert(File(p.join(directory.path, 'profile.json')).readAsBytesSync())
        .toString();
    if (request['profileHash'] != hash) {
      throw const FormatException(
        'The saved session profile changed. Start a new run.',
      );
    }
  }

  void _sessionCheckNames(
    GameplaySessionTarget target,
    GameplaySessionValidation validation,
    String? controller,
  ) {
    for (final GameplaySessionBackend backend in target.backends) {
      _swarmCheckOperatorNames(_activeConsumer, backend.instance, <String>[
        ...validation.playerNames,
        ?controller,
      ]);
    }
  }

  void _sessionVerifyWorldIdentities(
    Directory directory,
    GameplaySessionTarget target, {
    required bool resume,
  }) {
    final File requestFile = File(p.join(directory.path, 'request.json'));
    final Map<String, Object?> request = readSessionObject(requestFile);
    final Map<String, Object?> saved =
        request['worldIdentities'] is Map<String, Object?>
        ? sessionObject(request['worldIdentities'])
        : <String, Object?>{};
    for (final GameplaySessionBackend backend in target.backends) {
      final String instancePath = _instanceDir(
        _activeConsumer,
        backend.instance,
      );
      final String worldName =
          _instanceGetProperty(
            _activeConsumer,
            backend.instance,
            'level-name',
          ) ??
          'world';
      final String worldPath = p.normalize(p.join(instancePath, worldName));
      if (!p.isWithin(instancePath, worldPath)) {
        throw const FormatException(
          'Session world must be inside its isolated instance directory.',
        );
      }
      final File identity = File(p.join(worldPath, '.multiplexor-world-id'));
      if (resume) {
        if (!identity.existsSync() ||
            saved[backend.instance] != identity.readAsStringSync().trim()) {
          throw FormatException(
            'World identity changed on ${backend.instance}. Start a new run after a reset or restore.',
          );
        }
      } else {
        if (!identity.existsSync()) {
          identity.parent.createSync(recursive: true);
          identity.writeAsStringSync('${_swarmRandomHex(16)}\n', flush: true);
        }
        saved[backend.instance] = identity.readAsStringSync().trim();
      }
    }
    request['worldIdentities'] = saved;
    writeSessionObject(requestFile, request);
  }

  void _sessionRequireCleanTarget(GameplaySessionTarget target) {
    final Directory runs = Directory(_sessionsDirectory);
    if (!runs.existsSync()) return;
    for (final Directory run in runs.listSync().whereType<Directory>()) {
      final File configFile = File(p.join(run.path, 'configuration.json'));
      if (!configFile.existsSync()) continue;
      final File hostFile = File(p.join(run.path, 'host.json'));
      if (hostFile.existsSync() &&
          readSessionObject(hostFile)['cleanupComplete'] == true) {
        continue;
      }
      final GameplaySessionTarget previous = GameplaySessionTarget.fromJson(
        sessionObject(readSessionObject(configFile)['target']),
      );
      if (previous.instances.any(target.instances.contains)) {
        throw FormatException(
          'A session already owns this target or needs cleanup: ${p.basename(run.path)}. Run sessions stop ${p.basename(run.path)} first.',
        );
      }
    }
  }

  String _sessionTargetLock(String instance) => p.join(
    _stateDir(_activeConsumer),
    'gameplay-tests',
    instance,
    'swarm.lock',
  );

  void _sessionRequireFree(String path) {
    if (_sessionLocked(path)) {
      throw const FormatException(
        'A session or swarm already owns this target. Stop it before starting another run.',
      );
    }
  }

  bool _sessionLocked(String path) {
    if (_activeSwarmLocks.contains(path)) return true;
    final File file = File(path);
    if (!file.existsSync()) return false;
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.append);
      handle.lockSync(FileLock.exclusive);
      return false;
    } on FileSystemException {
      return true;
    } finally {
      handle?.closeSync();
    }
  }

  Map<String, Object?> _sessionSummary(Directory directory) {
    Map<String, Object?> read(String name) {
      final File file = File(p.join(directory.path, name));
      return file.existsSync() ? readSessionObject(file) : <String, Object?>{};
    }

    final Map<String, Object?> host = read('host.json');
    final Map<String, Object?> status = read('status.json');
    final Map<String, Object?> configuration = read('configuration.json');
    final bool active = _sessionLocked(p.join(directory.path, 'host.lock'));
    final String state = !active && host['cleanupComplete'] != true
        ? 'interrupted'
        : host['state'] as String? ?? 'pending';
    return <String, Object?>{
      'runId': p.basename(directory.path),
      'state': state,
      'active': active,
      'target': configuration['target'],
      'host': host,
      'workload': status,
      'artifactsDirectory': directory.path,
      'reportPath': p.join(directory.path, 'report.json'),
    };
  }

  void _sessionPrintSummary(Map<String, Object?> summary, _NativeIoBuffer io) {
    final Map<String, Object?> target = sessionObject(summary['target']);
    final Map<String, Object?> workload = sessionObject(summary['workload']);
    io.write(
      '${summary['runId']}  ${summary['state']}  ${target['name']}:${target['port']}  players ${workload['connectedPopulation'] ?? 0}/${workload['desiredPopulation'] ?? 0}',
    );
    io.write('Artifacts: ${summary['artifactsDirectory']}');
    final Object? viewer = workload['viewer'];
    if (viewer is Map<String, Object?> &&
        viewer['url'] is String &&
        viewer['status'] == 'active') {
      io.write('Viewer: ${viewer['url']}');
    }
    final Map<String, Object?> host = sessionObject(summary['host']);
    if (host['error'] != null) io.write('Error: ${host['error']}');
  }

  void _sessionPrintWorkload(
    Map<String, Object?> workload,
    _NativeIoBuffer io,
  ) {
    io.write('Workload: ${workload['status'] ?? 'pending'}');
    final Object? goals = workload['goalSummary'];
    if (goals is Map<String, Object?>) {
      io.write(
        'Projects: ${goals['projectsCompleted'] ?? 0}/${goals['projectsTotal'] ?? 0}; verified blocks: ${goals['blocksVerified'] ?? 0}; resource transfers: ${goals['resourceTransfers'] ?? 0}',
      );
    }
    final Object? performance = workload['performance'];
    if (performance is Map<String, Object?>) {
      io.write('Performance: ${performance['status'] ?? 'unavailable'}');
    }
    final Object? players = workload['players'];
    if (players is List<Object?>) {
      for (final Map<String, Object?> player
          in players.whereType<Map<String, Object?>>().take(32)) {
        io.write(
          '${player['username']}  ${player['lifecycle']}  ${player['backend'] ?? '-'}  ${player['role']}  ${player['activity'] ?? ''}',
        );
      }
      if (players.length > 32) {
        io.write(
          '${players.length - 32} more identities; use --json for the complete roster.',
        );
      }
    }
  }

  Future<void> _sessionLaunch(Directory directory) async {
    final String token = _swarmRandomHex(12);
    final File requestFile = File(p.join(directory.path, 'request.json'));
    final Map<String, Object?> request = readSessionObject(requestFile)
      ..['token'] = token;
    writeSessionObject(requestFile, request);
    final List<String> args = <String>[
      'gameplay',
      'sessions-host',
      p.basename(directory.path),
      token,
    ];
    if (sessionHostLauncher != null) {
      await sessionHostLauncher!(args);
    } else {
      final _SelfInvocation invocation = _selfInvocation(
        profile: _activeConsumer,
        args: args,
      );
      await Process.start(
        invocation.executable,
        invocation.arguments,
        workingDirectory: context.rootDir,
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
    }
    final Stopwatch elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(seconds: 15)) {
      final File hostFile = File(p.join(directory.path, 'host.json'));
      if (hostFile.existsSync()) {
        final Map<String, Object?> host = readSessionObject(hostFile);
        if (host['token'] == token) {
          if (host['state'] == 'failed') {
            throw _NativeCommandException('${host['error']}', 1);
          }
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    File(
      p.join(directory.path, 'stop.request'),
    ).writeAsStringSync('Host handshake timed out.\n');
    throw const FormatException(
      'Session host did not acknowledge startup. A stop request was saved; inspect sessions status.',
    );
  }

  Future<void> _sessionRecoverOrphan(
    Directory directory,
    _NativeIoBuffer io,
  ) async {
    final File hostFile = File(p.join(directory.path, 'host.json'));
    if (!hostFile.existsSync()) {
      writeSessionObject(hostFile, <String, Object?>{
        'state': 'stopped',
        'cleanupComplete': true,
      });
      return;
    }
    final Map<String, Object?> host = readSessionObject(hostFile);
    if (host['cleanupComplete'] == true) return;
    final Map<String, Object?> saved = readSessionObject(
      File(p.join(directory.path, 'configuration.json')),
    );
    final GameplaySessionTarget target = GameplaySessionTarget.fromJson(
      sessionObject(saved['target']),
    );
    await _sessionWithLocks(<String>[
      p.join(directory.path, 'host.lock'),
      ...(target.instances.toList()..sort()).map(_sessionTargetLock),
    ], () => _sessionRecoverOrphanLocked(directory, io));
  }

  Future<void> _sessionRecoverOrphanLocked(
    Directory directory,
    _NativeIoBuffer io,
  ) async {
    final File hostFile = File(p.join(directory.path, 'host.json'));
    final Map<String, Object?> host = readSessionObject(hostFile);
    final File nodeStatus = File(p.join(directory.path, 'status.json'));
    if (nodeStatus.existsSync()) {
      final Object? nodePid = readSessionObject(nodeStatus)['pid'];
      if (nodePid is int && await _pidRunning(nodePid)) {
        throw const FormatException(
          'The session worker is still alive after its host stopped. The stop request remains pending; wait for worker cleanup before retrying.',
        );
      }
    }
    final Map<String, Object?> configuration = readSessionObject(
      File(p.join(directory.path, 'configuration.json')),
    );
    final Map<String, Object?> request = readSessionObject(
      File(p.join(directory.path, 'request.json')),
    );
    final List<String> failures = await _sessionCleanup(
      configuration,
      request,
      host,
      io,
    );
    host['cleanupComplete'] = failures.isEmpty;
    host['state'] = failures.isEmpty ? 'stopped' : 'failed';
    if (failures.isNotEmpty) host['error'] = failures.join('; ');
    writeSessionObject(hostFile, host);
    if (failures.isNotEmpty) throw FormatException(failures.join('; '));
  }

  Future<List<String>> _sessionCleanup(
    Map<String, Object?> configuration,
    Map<String, Object?> request,
    Map<String, Object?> host,
    _NativeIoBuffer io,
  ) async {
    final List<String> failures = <String>[];
    final Object? controllerObject = configuration['controller'];
    if (controllerObject is Map<String, Object?>) {
      final String controller = controllerObject['username']! as String;
      for (final String instance
          in (host['operatorGrants'] as List<Object?>? ?? <Object?>[])
              .cast<String>()) {
        try {
          if (!await _swarmRevokeController(
            _activeConsumer,
            instance,
            controller,
          )) {
            failures.add(
              'Could not revoke controller $controller on $instance',
            );
          }
        } catch (error) {
          failures.add('Controller cleanup on $instance: $error');
        }
      }
    }
    if (request['stopAfter'] == true || host['workloadStarted'] != true) {
      for (final String instance
          in (host['startedInstances'] as List<Object?>? ?? <Object?>[])
              .cast<String>()
              .reversed) {
        try {
          if (await _recoveryIsRunning(_activeConsumer, instance)) {
            await _recoveryStop(_activeConsumer, instance, io);
          }
        } catch (error) {
          failures.add('Runtime cleanup on $instance: $error');
        }
      }
    }
    return failures;
  }

  Future<int> _sessionHost(
    List<String> args,
    GameplayTestService harness,
    _NativeIoBuffer io,
  ) async {
    if (args.length != 2) {
      throw const FormatException(
        'Internal session host requires a run ID and owner token.',
      );
    }
    final Directory directory = _sessionDirectory(args[0]);
    final Map<String, Object?> request = readSessionObject(
      File(p.join(directory.path, 'request.json')),
    );
    if (request['token'] != args[1]) {
      throw const FormatException('Session host token does not match.');
    }
    final File configFile = File(p.join(directory.path, 'configuration.json'));
    final Map<String, Object?> configuration = readSessionObject(configFile);
    final GameplaySessionTarget target = GameplaySessionTarget.fromJson(
      sessionObject(configuration['target']),
    );
    final List<String> paths = <String>[
      p.join(directory.path, 'host.lock'),
      ...(target.instances.toList()..sort()).map(_sessionTargetLock),
    ];
    final Map<String, RandomAccessFile> locks = <String, RandomAccessFile>{};
    final File hostFile = File(p.join(directory.path, 'host.json'));
    final Map<String, Object?> host = <String, Object?>{
      'schemaVersion': 1,
      'pid': pid,
      'token': args[1],
      'state': 'starting',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'cleanupComplete': false,
      'startedInstances': <String>[],
      'operatorGrants': <String>[],
      'workloadStarted': false,
    };
    final List<String> started = host['startedInstances']! as List<String>;
    final List<String> grants = host['operatorGrants']! as List<String>;
    void persist() => writeSessionObject(hostFile, host);
    void log(String line) => File(
      p.join(directory.path, 'host.log'),
    ).writeAsStringSync('$line\n', mode: FileMode.append);
    final _NativeIoBuffer operationIo = _NativeIoBuffer(
      stream: false,
      logFile: File(p.join(directory.path, 'host.log')),
    );
    bool claimed = false;
    int result = 1;
    final _SwarmInterruptGuard interrupt = _SwarmInterruptGuard();
    void check() {
      interrupt.check();
      if (File(p.join(directory.path, 'stop.request')).existsSync()) {
        throw const _SessionStopRequested();
      }
    }

    try {
      for (final String path in paths) {
        if (!_activeSwarmLocks.add(path)) {
          throw const FormatException(
            'A session or swarm already owns this target.',
          );
        }
        RandomAccessFile? handle;
        try {
          final File file = File(path)..parent.createSync(recursive: true);
          handle = file.openSync(mode: FileMode.append);
          handle.lockSync(FileLock.exclusive);
          locks[path] = handle;
        } catch (_) {
          handle?.closeSync();
          _activeSwarmLocks.remove(path);
          rethrow;
        }
      }
      claimed = true;
      await _withNetworkRuntimeStart(() async {
        _sessionCheckProfileHash(directory);
        check();
        configuration['parentPid'] = pid;
        writeSessionObject(configFile, configuration);
        final GameplaySessionValidation validation =
            await _sessionValidateProfile(
              harness,
              configuration['profilePath']! as String,
              configurationPath: configFile.path,
            );
        final bool resume = configuration['resume'] == true;
        final String? controller =
            configuration['controller'] is Map<String, Object?>
            ? (configuration['controller']! as Map<String, Object?>)['username']
                  as String?
            : null;
        final GameplaySessionTarget current = _sessionResolveTarget(
          instance: target.kind == 'instance' ? target.name : null,
          network: target.kind == 'network' ? target.name : null,
          allowPreparation: request['prepare'] == true && !resume,
        );
        if (jsonEncode(current.toJson()) != jsonEncode(target.toJson())) {
          throw const FormatException('Session target changed before startup.');
        }
        _sessionCheckNames(target, validation, controller);
        if (resume) {
          _sessionVerifyWorldIdentities(directory, target, resume: true);
        }
        for (final String instance in target.instances) {
          final bool running = await _recoveryIsRunning(
            _activeConsumer,
            instance,
          );
          if (!running && request['start'] != true) {
            throw FormatException(
              '$instance is stopped; this run does not own startup.',
            );
          }
          if (running && request['prepare'] == true && !resume) {
            throw FormatException('Stop $instance before preparation.');
          }
        }
        persist();
        if (request['prepare'] == true && !resume) {
          check();
          await _prepareGameplayInstance(
            _activeConsumer,
            target.name,
            operationIo,
          );
        }
        final Duration timeout = Duration(
          seconds: request['startupTimeoutSeconds']! as int,
        );
        for (final String instance in target.instances) {
          check();
          if (!await _recoveryIsRunning(_activeConsumer, instance)) {
            started.add(instance);
            persist();
            await _recoveryStart(_activeConsumer, instance, operationIo);
          }
          final MinecraftPingResult ping = await _requireRecoveryReadiness(
            _activeConsumer,
            instance,
            timeout,
          );
          if (instance != target.proxy &&
              ping.max - ping.online <
                  validation.maximumPopulation +
                      (validation.requiresController && !resume ? 1 : 0)) {
            throw FormatException(
              'Insufficient free player slots on $instance for this session population.',
            );
          }
        }
        _sessionVerifyWorldIdentities(directory, target, resume: resume);
        if (validation.requiresController && !resume && controller != null) {
          for (final GameplaySessionBackend backend in target.backends) {
            check();
            grants.add(backend.instance);
            persist();
            if (!await _swarmConsoleCommand(
                  _activeConsumer,
                  backend.instance,
                  'op $controller',
                ) ||
                !await _swarmWaitOperator(
                  _activeConsumer,
                  backend.instance,
                  controller,
                  present: true,
                )) {
              throw FormatException(
                'Could not grant temporary setup controller on ${backend.instance}.',
              );
            }
          }
        }
        check();
        host['state'] = 'running';
        host['workloadStarted'] = true;
        persist();
      });
      result = await harness.sessionsRun(
        configurationPath: configFile.path,
        write: log,
        error: log,
      );
      host['state'] = result == 0 ? 'stopped' : 'failed';
      if (result != 0) {
        host['error'] =
            'Session worker exited with code $result. See host.log and report.json.';
      }
    } on _SessionStopRequested {
      host['state'] = 'stopped';
      result = 0;
    } catch (error) {
      host['state'] = 'failed';
      host['error'] = '$error';
      log('$error');
    } finally {
      if (claimed) {
        host['state'] = host['state'] == 'failed' ? 'failed' : 'stopping';
        persist();
        final List<String> failures = await _sessionCleanup(
          configuration,
          request,
          host,
          operationIo,
        );
        host['cleanupComplete'] = failures.isEmpty;
        if (failures.isNotEmpty) {
          host['error'] = failures.join('; ');
          result = 1;
        }
      } else {
        host['cleanupComplete'] = true;
      }
      host['state'] = result == 0 ? 'stopped' : 'failed';
      host['finishedAt'] = DateTime.now().toUtc().toIso8601String();
      if (locks.containsKey(p.join(directory.path, 'host.lock'))) persist();
      for (final MapEntry<String, RandomAccessFile> entry
          in locks.entries.toList().reversed) {
        entry.value.closeSync();
        _activeSwarmLocks.remove(entry.key);
      }
      await interrupt.close();
    }
    return result;
  }
}

final class _SessionStopRequested implements Exception {
  const _SessionStopRequested();
}
