part of 'native_command_service.dart';

const Symbol _networkOperationZone = #multiplexorNetworkOperation;
final Map<String, NetworkOperationLock> _networkOperationLocks =
    <String, NetworkOperationLock>{};
const Set<String> _networkBackendTypes = <String>{
  'paper',
  'purpur',
  'folia',
  'canvas',
  'leaf',
};

extension _NativeNetworkCommands on NativeCommandService {
  NetworkStore get _networkStore => NetworkStore(
    stateDirectory: Directory(
      p.join(_stateDir(ConsumerProfile.plugin), 'networks'),
    ),
    instancePath: _instanceDir,
  );

  Future<T> _withNetworkOperation<T>(Future<T> Function() operation) =>
      _lockNetworkOperation(operation, exclusive: true);

  Future<T> _withNetworkRuntimeStart<T>(Future<T> Function() operation) =>
      _lockNetworkOperation(operation, exclusive: false);

  Future<T> _lockNetworkOperation<T>(
    Future<T> Function() operation, {
    required bool exclusive,
  }) async {
    final String path = p.join(
      _stateDir(ConsumerProfile.plugin),
      'network-operation.lock',
    );
    if (Zone.current[_networkOperationZone] == path) return operation();
    final NetworkOperationLock lock = _networkOperationLocks.putIfAbsent(
      path,
      () => NetworkOperationLock(path),
    );
    return lock.run(
      () => runZoned(
        operation,
        zoneValues: <Object, Object>{_networkOperationZone: path},
      ),
      exclusive: exclusive,
    );
  }

  String? _networkMembership(ConsumerProfile profile, String instance) {
    if (profile != ConsumerProfile.plugin) return null;
    final String? marker = _serverSource(profile, instance)['network'];
    if (marker != null && marker.isNotEmpty) return marker;
    for (final NetworkDefinition network in _networkStore.list()) {
      if (network.proxy == instance ||
          network.members.any(
            (NetworkMember member) =>
                member.consumer == profile && member.instance == instance,
          )) {
        return network.name;
      }
    }
    return null;
  }

  void _ensureNetworkDetached(
    ConsumerProfile profile,
    String instance, {
    required String action,
  }) {
    final String? network = _networkMembership(profile, instance);
    if (network != null) {
      throw _NativeCommandException(
        '$instance belongs to network $network. Detach it before $action.',
        2,
      );
    }
  }

  Future<void> _networkDetachForDeletion(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) async {
    final String? name = _networkMembership(profile, instance);
    if (name == null) return;
    final NetworkDefinition network = _networkStore.load(name);
    await _networkStop(network, io);
    if (network.proxy == instance) {
      _networkStore.delete(name);
    } else {
      final NetworkMember member = network.members.firstWhere(
        (NetworkMember member) =>
            member.consumer == profile && member.instance == instance,
      );
      _networkStore.removeMember(name, member.alias);
    }
    io.write('[OK] Removed $instance from network $name.');
  }

  void _validateNetworkRuntime(ConsumerProfile profile, String instance) {
    final String? name = _networkMembership(profile, instance);
    if (name == null) {
      if (_serverSource(profile, instance)['type'] == 'velocity') {
        throw _NativeCommandException(
          'Velocity instance $instance is detached. Create a network to configure its routes.',
          2,
        );
      }
      return;
    }
    final NetworkDefinition network = _networkStore.load(name);
    final List<String> issues = _networkStore.validateConfiguration(network);
    if (issues.isNotEmpty) {
      throw _NativeCommandException(
        'Network $name configuration is invalid: ${issues.join('; ')}. Run network check $name.',
        2,
      );
    }
  }

  Future<int> _dispatchNetwork(List<String> args, _NativeIoBuffer io) async {
    if (_activeConsumer != ConsumerProfile.plugin) {
      throw _NativeCommandException('Networks require --consumer plugin.', 2);
    }
    final String action = args.isEmpty ? 'list' : args.first;
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args.skip(1).toList(),
      booleanFlags: const <String>{'json', 'offline'},
    );
    if (action == 'list') {
      final List<NetworkDefinition> networks = _networkStore.list();
      if (parsed.flag('json')) {
        io.write(
          jsonEncode(
            networks.map((NetworkDefinition value) => value.toJson()).toList(),
          ),
        );
      } else if (networks.isEmpty) {
        io.write('(none)');
      } else {
        for (final NetworkDefinition network in networks) {
          io.write(
            '${network.name}\t${network.bind}:${network.port}\t${network.members.map((NetworkMember member) => member.alias).join(',')}',
          );
        }
      }
      return 0;
    }
    if (action == 'candidates') {
      return _networkCandidates(parsed.flag('json'), io);
    }
    if (action == 'recover') {
      return _withNetworkOperation(() async {
        final List<NetworkDefinition> affected = _networkStore
            .pendingRecoveryDefinitions();
        for (final NetworkDefinition network in affected) {
          await _networkRequireStopped(network);
        }
        _networkStore.recover();
        io.write(
          '[OK] ${affected.isEmpty ? 'No interrupted network operation.' : 'Restored the interrupted network configuration.'}',
        );
        return 0;
      });
    }
    if (parsed.positionals.isEmpty) {
      throw _NativeCommandException('Network name required.', 2);
    }
    final String name = _validateSimpleName(
      parsed.positionals.first,
      label: 'network',
    );
    if (action == 'status' || action == 'check') {
      return _networkStatus(
        _networkStore.load(name),
        io,
        json: parsed.flag('json'),
        checkOnly: action == 'check',
      );
    }
    if (action == 'console') {
      final NetworkDefinition network = _networkStore.load(name);
      if (!await _recoveryIsRunning(ConsumerProfile.plugin, network.proxy)) {
        throw _NativeCommandException(
          'Network proxy is stopped. Run network start $name first.',
          2,
        );
      }
      return _dispatchRuntime(<String>['console', network.proxy], io);
    }
    return _withNetworkOperation(() async {
      if (action == 'create') return _networkCreate(name, parsed, io);
      final NetworkDefinition network = _networkStore.load(name);
      switch (action) {
        case 'start':
          await _networkStart(network, _networkTimeout(parsed), io);
        case 'stop':
          await _networkStop(network, io);
        case 'restart':
          final Duration timeout = _networkTimeout(parsed);
          await _networkStop(network, io);
          await _networkStart(network, timeout, io);
        case 'repair':
          await _networkRequireStopped(network);
          _networkStore.repair(name);
          io.write('[OK] Reapplied network $name configuration.');
        case 'add':
          await _networkRequireStopped(network);
          final String instance = _validateSimpleName(
            parsed.positionals[1],
            label: 'instance',
          );
          await _networkValidateBackend(instance, offline: !network.onlineMode);
          final Set<int> reserved = <int>{
            network.port,
            ...network.members.map((NetworkMember member) => member.port),
          };
          final int port = await _networkChooseBackendPort(
            instance,
            reserved,
            requested: parsed.option('port'),
          );
          final NetworkMember member = NetworkMember(
            consumer: ConsumerProfile.plugin,
            instance: instance,
            alias: parsed.option('alias') ?? instance,
            port: port,
          );
          _networkStore.update(
            _networkCopy(
              network,
              members: <NetworkMember>[...network.members, member],
            ),
          );
          io.write('[OK] Added $instance to $name at 127.0.0.1:$port');
        case 'remove':
          final String alias = parsed.positionals[1];
          if (!network.members.any(
            (NetworkMember member) => member.alias == alias,
          )) {
            throw _NativeCommandException(
              'No backend alias $alias in $name.',
              2,
            );
          }
          await _networkStop(network, io);
          _networkStore.removeMember(name, alias);
          io.write('[OK] Detached $alias and restored its network settings.');
        case 'configure':
          await _networkRequireStopped(network);
          final int port = parsed.option('port') == null
              ? network.port
              : _networkPort(parsed.option('port')!);
          if (network.members.any(
            (NetworkMember member) => member.port == port,
          )) {
            throw _NativeCommandException(
              'Proxy port $port is already assigned to a backend.',
              2,
            );
          }
          await _networkCheckPort(port, excluding: network.name);
          _networkStore.update(
            _networkCopy(
              network,
              port: port,
              bind: parsed.option('bind'),
              defaultServer: parsed.option('default'),
              fallbackServers: parsed.option('fallback') == null
                  ? null
                  : _networkCsv(parsed.option('fallback')!, allowNone: true),
            ),
          );
          io.write('[OK] Updated network $name.');
        case 'delete':
          if (parsed.option('confirm') != name) {
            throw _NativeCommandException(
              'Deleting network $name requires --confirm $name.',
              2,
            );
          }
          await _networkStop(network, io);
          _networkStore.delete(name);
          io.write(
            '[OK] Removed network $name and restored backend settings. Instance files were kept.',
          );
        case 'plugins-sync':
          if (await _recoveryIsRunning(ConsumerProfile.plugin, network.proxy)) {
            throw _NativeCommandException(
              'Stop the proxy before syncing its plugins.',
              2,
            );
          }
          final _DropinSyncReport result = _syncVelocityDropinsInstance(
            ConsumerProfile.plugin,
            network.proxy,
            clean: false,
            strict: true,
            preserveLocalChanges: false,
          );
          io.write(
            '[OK] Synced ${result.copiedJars.length} Velocity plugins to ${network.proxy}.',
          );
        default:
          throw _NativeCommandException('Unknown network action: $action', 2);
      }
      return 0;
    });
  }

  Future<int> _networkCandidates(bool json, _NativeIoBuffer io) async {
    final List<Map<String, Object?>> candidates = <Map<String, Object?>>[];
    for (final String instance in _instanceNames(ConsumerProfile.plugin)) {
      if (!NetworkDefinition.validName(instance) ||
          instance.toLowerCase() == 'try') {
        continue;
      }
      try {
        await _networkValidateBackend(instance, offline: false);
      } on _NativeCommandException {
        continue;
      }
      final Map<String, String> source = _serverSource(
        ConsumerProfile.plugin,
        instance,
      );
      candidates.add(<String, Object?>{
        'instance': instance,
        'type': source['type'],
        'minecraft': _networkMinecraft(instance),
        'port': _instanceGetServerPort(ConsumerProfile.plugin, instance),
        'isolated': _instanceIsolated(ConsumerProfile.plugin, instance),
      });
    }
    if (json) {
      io.write(jsonEncode(candidates));
    } else {
      if (candidates.isEmpty) io.write('(none)');
      for (final Map<String, Object?> candidate in candidates) {
        io.write(
          '${candidate['instance']}\t${candidate['type']}\t${candidate['minecraft']}',
        );
      }
    }
    return 0;
  }

  String? _networkMinecraft(String instance) {
    final Map<String, String> source = _serverSource(
      ConsumerProfile.plugin,
      instance,
    );
    return inferServerMinecraftVersion(
      serverType: source['type'] ?? '',
      minecraft: source['mc'],
      jarPaths: <String>[source['jar'] ?? ''],
    );
  }

  Future<void> _networkValidateBackend(
    String instance, {
    required bool offline,
  }) async {
    const ConsumerProfile profile = ConsumerProfile.plugin;
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }
    _ensureNetworkDetached(
      profile,
      instance,
      action: 'adding it to another network',
    );
    if (await _recoveryIsRunning(profile, instance)) {
      throw _NativeCommandException(
        'Stop $instance before adding it to a network.',
        2,
      );
    }
    final Map<String, String> source = _serverSource(profile, instance);
    final String? minecraft = _networkMinecraft(instance);
    final RegExpMatch? match = RegExp(
      r'^(\d+)\.(\d+)(?:\.\d+)?$',
    ).firstMatch(minecraft ?? '');
    final bool supportedVersion =
        match != null &&
        (int.parse(match[1]!) >= 26 ||
            int.parse(match[1]!) == 1 && int.parse(match[2]!) >= 19);
    if (!_networkBackendTypes.contains(source['type']) || !supportedVersion) {
      throw _NativeCommandException(
        '$instance requires Paper, Purpur, Folia, Canvas, or Leaf on Minecraft 1.19 or newer with known version metadata.',
        2,
      );
    }
    if (offline && !_instanceIsolated(profile, instance)) {
      throw _NativeCommandException(
        'Offline networks require isolated backends: $instance is shared.',
        2,
      );
    }
  }

  Future<int> _networkCreate(
    String name,
    _FlexibleArgs parsed,
    _NativeIoBuffer io, {
    Map<String, String> aliases = const <String, String>{},
    String? instanceCreationToken,
    bool retainCreationOwner = false,
    void Function(String instance)? configureProxy,
  }) async {
    if (parsed.option('proxy') != null &&
        parsed.option('proxy') != 'velocity') {
      throw _NativeCommandException('Only --proxy velocity is supported.', 2);
    }
    if (_networkStore.list().any(
      (NetworkDefinition item) => item.name == name,
    )) {
      throw _NativeCommandException('Network already exists: $name', 2);
    }
    final String proxy = _validateSimpleName(
      '$name-proxy',
      label: 'proxy instance',
    );
    if (_instanceExists(ConsumerProfile.plugin, proxy)) {
      throw _NativeCommandException('Instance already exists: $proxy', 2);
    }
    final bool offline = parsed.flag('offline');
    final String bind = parsed.option('bind') ?? '127.0.0.1';
    if (!const <String>{'127.0.0.1', '0.0.0.0'}.contains(bind) ||
        offline && bind != '127.0.0.1') {
      throw _NativeCommandException(
        'Use --bind 127.0.0.1 or 0.0.0.0; offline networks require 127.0.0.1.',
        2,
      );
    }
    final List<String> names = _networkCsv(parsed.option('members') ?? '');
    if (names.isEmpty) {
      throw _NativeCommandException(
        'At least one --members instance is required.',
        2,
      );
    }
    for (final String instance in names) {
      _validateSimpleName(instance, label: 'instance');
      await _networkValidateBackend(instance, offline: offline);
    }
    final Set<String> routes = names
        .map((String instance) => aliases[instance] ?? instance)
        .toSet();
    if (routes.length != names.length ||
        routes.any(
          (String alias) =>
              !NetworkDefinition.validName(alias) ||
              alias.toLowerCase() == 'try',
        )) {
      throw _NativeCommandException(
        'Backend aliases must be unique valid route names.',
        2,
      );
    }
    final String defaultServer = parsed.option('default') ?? '';
    final List<String> fallback = _networkCsv(
      parsed.option('fallback') ?? '',
      allowNone: true,
    );
    if (!routes.contains(defaultServer) ||
        fallback.any((String alias) => !routes.contains(alias))) {
      throw _NativeCommandException(
        'The entry server and fallback aliases must be listed in --members.',
        2,
      );
    }
    final int port = _networkPort(parsed.option('port') ?? '25565');
    await _networkCheckPort(port);
    final Set<int> reserved = <int>{port};
    final List<NetworkMember> members = <NetworkMember>[];
    for (final String instance in names) {
      final int backendPort = await _networkChooseBackendPort(
        instance,
        reserved,
      );
      reserved.add(backendPort);
      members.add(
        NetworkMember(
          consumer: ConsumerProfile.plugin,
          instance: instance,
          alias: aliases[instance] ?? instance,
          port: backendPort,
        ),
      );
    }
    final NetworkDefinition network = NetworkDefinition(
      name: name,
      proxy: proxy,
      bind: bind,
      port: port,
      onlineMode: !offline,
      defaultServer: defaultServer,
      fallbackServers: fallback,
      members: members,
    );
    final List<String> validation = network.validate();
    if (validation.isNotEmpty) throw FormatException(validation.join(' '));
    final String jarPath;
    String? version = parsed.option('proxy-version');
    if (version != null &&
        !RegExp(r'^[34]\.\d+\.\d+(?:-SNAPSHOT)?$').hasMatch(version)) {
      throw const FormatException('Use a Velocity 3.x or 4.x proxy version.');
    }
    if (parsed.option('jar') case final String customJar) {
      final File jar = File(customJar);
      if (!jar.existsSync()) {
        throw _NativeCommandException('Velocity jar not found: $customJar', 2);
      }
      jarPath = jar.absolute.path;
    } else {
      final VelocityDownloads downloads = VelocityDownloads();
      io.write('[INFO] Resolving ${version ?? 'stable'} Velocity build.');
      final VelocityArtifact artifact = await downloads.resolve(
        version: version,
      );
      version = artifact.version;
      jarPath = (await downloads.download(
        artifact,
        Directory(_buildDir(ConsumerProfile.plugin, 'velocity')),
      )).path;
    }
    final Directory directory = Directory(
      _instanceDir(ConsumerProfile.plugin, proxy),
    );
    final String creationToken = instanceCreationToken ?? _newPinSalt();
    try {
      await _serverCreateFromJar(
        ConsumerProfile.plugin,
        proxy,
        type: 'velocity',
        jarPath: jarPath,
        isolated: offline,
        creationToken: creationToken,
        io: io,
      );
      final Map<String, String> source = _serverSource(
        ConsumerProfile.plugin,
        proxy,
      );
      if (version != null) source['velocity_version'] = version;
      _writeServerSource(directory.path, fields: source);
      configureProxy?.call(proxy);
      _networkStore.create(network);
      final File owner = File(
        p.join(directory.path, NativeCommandService._instanceCreationOwnerFile),
      );
      if (!retainCreationOwner &&
          owner.existsSync() &&
          owner.readAsStringSync().trim() == creationToken) {
        owner.deleteSync();
      }
    } catch (_) {
      if (_networkStore.pendingRecoveryDefinitions().isEmpty &&
          !_networkStore.list().any(
            (NetworkDefinition item) => item.name == name,
          )) {
        _deleteOwnedPartialInstance(directory.path, creationToken);
      }
      rethrow;
    }
    io.write(
      '[OK] Created network $name at $bind:$port. Entry server: $defaultServer.',
    );
    io.write(
      '[INFO] Velocity plugins: ${p.join(_consumerRoot(ConsumerProfile.plugin), 'dropins', 'velocity')}',
    );
    return 0;
  }

  Future<void> _networkCheckPort(int port, {String? excluding}) async {
    for (final NetworkDefinition network in _networkStore.list()) {
      if (network.name == excluding) continue;
      if (network.port == port ||
          network.members.any((NetworkMember member) => member.port == port)) {
        throw _NativeCommandException(
          'Port $port is reserved by network ${network.name}.',
          2,
        );
      }
    }
    if (await _runtimeSocketPortInUse(port)) {
      throw _NativeCommandException(
        'Port $port is in use. Choose another port.',
        2,
      );
    }
  }

  Future<int> _networkChooseBackendPort(
    String instance,
    Set<int> reserved, {
    String? requested,
  }) async {
    if (requested != null) {
      final int port = _networkPort(requested);
      if (reserved.contains(port)) {
        throw _NativeCommandException(
          'Port $port is already assigned in this network.',
          2,
        );
      }
      await _networkCheckPort(port);
      return port;
    }
    final Set<int> assigned = <int>{...reserved};
    for (final NetworkDefinition network in _networkStore.list()) {
      assigned.add(network.port);
      assigned.addAll(
        network.members.map((NetworkMember member) => member.port),
      );
    }
    final int current = _instanceGetServerPort(
      ConsumerProfile.plugin,
      instance,
    );
    final Map<int, List<String>> configuredOwners = configuredInstancePorts();
    final bool currentOwnedOnlyByTarget =
        (configuredOwners[current] ?? const <String>[]).every(
          (String owner) => owner == 'plugin/$instance',
        );
    if (!assigned.contains(current) &&
        currentOwnedOnlyByTarget &&
        !await _runtimeSocketPortInUse(current)) {
      return current;
    }
    final Set<int> configured = configuredOwners.keys.toSet();
    for (int port = 25566; port <= 65535; port++) {
      if (!assigned.contains(port) &&
          !configured.contains(port) &&
          !await _runtimeSocketPortInUse(port)) {
        return port;
      }
    }
    throw _NativeCommandException('No available backend port found.', 2);
  }

  Future<void> _networkRequireStopped(NetworkDefinition network) async {
    for (final String instance in <String>[
      network.proxy,
      ...network.members.map((NetworkMember member) => member.instance),
    ]) {
      if (await _recoveryIsRunning(ConsumerProfile.plugin, instance)) {
        throw _NativeCommandException(
          'Stop network ${network.name} before changing its configuration ($instance is running).',
          2,
        );
      }
    }
  }

  Future<void> _networkStart(
    NetworkDefinition network,
    Duration timeout,
    _NativeIoBuffer io,
  ) async {
    _validateNetworkRuntime(ConsumerProfile.plugin, network.proxy);
    final List<String> order = <String>[
      network.members
          .firstWhere(
            (NetworkMember member) => member.alias == network.defaultServer,
          )
          .instance,
      ...network.members
          .where(
            (NetworkMember member) => member.alias != network.defaultServer,
          )
          .map((NetworkMember member) => member.instance),
      network.proxy,
    ];
    for (final String instance in order) {
      if (!await _recoveryIsRunning(ConsumerProfile.plugin, instance)) {
        final int port = instance == network.proxy
            ? network.port
            : network.members
                  .firstWhere(
                    (NetworkMember member) => member.instance == instance,
                  )
                  .port;
        await _networkCheckPort(port, excluding: network.name);
      }
    }
    final List<String> started = <String>[];
    try {
      for (final String instance in order) {
        if (!await _recoveryIsRunning(ConsumerProfile.plugin, instance)) {
          started.add(instance);
          await _recoveryStart(ConsumerProfile.plugin, instance, io);
        }
        await _requireRecoveryReadiness(
          ConsumerProfile.plugin,
          instance,
          timeout,
        );
      }
    } catch (error) {
      final List<String> failures = <String>[];
      for (final String instance in started.reversed) {
        try {
          if (await _recoveryIsRunning(ConsumerProfile.plugin, instance)) {
            await _recoveryStop(ConsumerProfile.plugin, instance, io);
          }
        } catch (_) {
          failures.add(instance);
        }
      }
      if (failures.isNotEmpty) {
        throw _NativeCommandException(
          'Network start failed: $error. Could not stop ${failures.join(', ')}; inspect their runtime status.',
          1,
        );
      }
      rethrow;
    }
    io.write(
      '[OK] Network ${network.name} is ready at ${network.bind}:${network.port}.',
    );
  }

  Future<void> _networkStop(
    NetworkDefinition network,
    _NativeIoBuffer io,
  ) async {
    if (await _recoveryIsRunning(ConsumerProfile.plugin, network.proxy)) {
      await _recoveryStop(ConsumerProfile.plugin, network.proxy, io);
    }
    final List<String> failures = <String>[];
    for (final NetworkMember member in network.members.reversed) {
      try {
        if (await _recoveryIsRunning(member.consumer, member.instance)) {
          await _recoveryStop(member.consumer, member.instance, io);
        }
      } catch (_) {
        failures.add(member.instance);
      }
    }
    if (failures.isNotEmpty) {
      throw _NativeCommandException(
        'Could not stop ${failures.join(', ')}. Inspect runtime status.',
        1,
      );
    }
    io.write('[OK] Stopped network ${network.name}.');
  }

  Future<int> _networkStatus(
    NetworkDefinition network,
    _NativeIoBuffer io, {
    required bool json,
    required bool checkOnly,
  }) async {
    final List<String> issues = _networkStore.validateConfiguration(network);
    final List<Map<String, Object?>> instances = <Map<String, Object?>>[];
    for (final String instance in <String>[
      network.proxy,
      ...network.members.map((NetworkMember member) => member.instance),
    ]) {
      final RuntimeState state = _recoveryRuntimeOverride == null
          ? await _runtimeStateOf(ConsumerProfile.plugin, instance)
          : await _recoveryIsRunning(ConsumerProfile.plugin, instance)
          ? RuntimeState.running
          : RuntimeState.stopped;
      instances.add(<String, Object?>{
        'name': instance,
        'role': instance == network.proxy ? 'proxy' : 'backend',
        'state': state.name,
        'port': instance == network.proxy
            ? network.port
            : network.members
                  .firstWhere(
                    (NetworkMember member) => member.instance == instance,
                  )
                  .port,
      });
    }
    final String state =
        instances.every(
          (Map<String, Object?> item) => item['state'] == 'stopped',
        )
        ? 'stopped'
        : issues.isEmpty &&
              instances.every(
                (Map<String, Object?> item) => item['state'] == 'running',
              )
        ? 'running'
        : 'degraded';
    final MinecraftPingResult? proxyPing =
        !checkOnly && instances.first['state'] == 'running'
        ? await pingMinecraftServer(
            '127.0.0.1',
            network.port,
            timeout: const Duration(seconds: 2),
          )
        : null;
    final int? playersOnline = proxyPing?.online;
    if (json) {
      io.write(
        jsonEncode(<String, Object?>{
          'network': network.toJson(),
          'state': state,
          'playersOnline': playersOnline,
          'instances': instances,
          'issues': issues,
        }),
      );
    } else {
      io.write(
        '${network.name}: $state | ${network.bind}:${network.port} | entry ${network.defaultServer}'
        '${checkOnly ? '' : ' | players ${playersOnline ?? 'unavailable'}'}',
      );
      for (final Map<String, Object?> instance in instances) {
        io.write(
          '${instance['name']}\t${instance['role']}\t${instance['state']}\t${instance['port']}',
        );
      }
      for (final String issue in issues) {
        io.error('[ERROR] $issue');
      }
      if (checkOnly && issues.isEmpty) {
        io.write('[OK] Network configuration is valid.');
      }
    }
    return issues.isEmpty ? 0 : 1;
  }
}

int _networkPort(String value) {
  final int? port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('Port must be between 1 and 65535.');
  }
  return port;
}

List<String> _networkCsv(String value, {bool allowNone = false}) {
  if (value.isEmpty || allowNone && value == 'none') return <String>[];
  final List<String> items = value
      .split(',')
      .map((String item) => item.trim())
      .toList();
  if (items.any((String item) => item.isEmpty) ||
      items.toSet().length != items.length) {
    throw const FormatException('Use a comma-separated list of unique names.');
  }
  return items;
}

Duration _networkTimeout(_FlexibleArgs parsed) {
  final int? seconds = int.tryParse(parsed.option('timeout') ?? '180');
  if (seconds == null || seconds < 5 || seconds > 600) {
    throw const FormatException('--timeout must be between 5 and 600 seconds.');
  }
  return Duration(seconds: seconds);
}

NetworkDefinition _networkCopy(
  NetworkDefinition network, {
  int? port,
  String? bind,
  String? defaultServer,
  List<String>? fallbackServers,
  List<NetworkMember>? members,
}) => NetworkDefinition(
  name: network.name,
  proxy: network.proxy,
  bind: bind ?? network.bind,
  port: port ?? network.port,
  onlineMode: network.onlineMode,
  defaultServer: defaultServer ?? network.defaultServer,
  fallbackServers: fallbackServers ?? network.fallbackServers,
  members: members ?? network.members,
);
