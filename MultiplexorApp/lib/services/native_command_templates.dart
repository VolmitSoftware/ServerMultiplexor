part of 'native_command_service.dart';

extension _NativeTemplateCommands on NativeCommandService {
  BundledTemplate? _bundledTemplate(String name) {
    for (final BundledTemplate template in bundledTemplates) {
      if (template.name == name) return template;
    }
    return null;
  }

  void _ensureWritableTemplateName(String name) {
    if (_bundledTemplate(name) != null) {
      throw _NativeCommandException(
        'Bundled template $name is read-only. Use a different name for a custom template.',
        2,
      );
    }
  }

  void _templateValidateTarget(ConsumerProfile profile, String name) {
    _validateSimpleName(name, label: 'instance');
    if (FileSystemEntity.typeSync(
          _instanceDir(profile, name),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw _NativeCommandException(
        'Instance path already exists and was not changed: $name',
        2,
      );
    }
  }

  void _templateValidateRuntime(Map<String, dynamic> template) {
    final String? heap = template['heap']?.toString().trim();
    if (heap != null && heap.isNotEmpty && !_runtimeHeapLooksValid(heap)) {
      throw _NativeCommandException('Invalid template heap value: $heap', 2);
    }
    final String? preset = template['jvm_preset']
        ?.toString()
        .trim()
        .toLowerCase();
    if (preset != null &&
        preset.isNotEmpty &&
        !NativeCommandService._runtimeSettingsPresets.containsKey(preset)) {
      throw _NativeCommandException('Unknown template JVM preset: $preset', 2);
    }
  }

  void _templateValidateServer(
    ConsumerProfile profile,
    Map<String, dynamic> template,
    _FlexibleArgs options, {
    bool network = false,
  }) {
    if ((template['kind'] ?? 'server') != 'server') {
      throw _NativeCommandException(
        'Each backend must be a server template.',
        2,
      );
    }
    final String type =
        template['type']?.toString().trim().toLowerCase() ?? 'purpur';
    if ((!_isKnownServerType(type) && type != 'custom') || type == 'velocity') {
      throw _NativeCommandException(
        'Unsupported server template type: $type',
        2,
      );
    }
    _ensureConsumerOwnsServerType(profile, type, command: 'template apply');
    _templateValidateRuntime(template);
    if (template['server_properties'] != null &&
        template['server_properties'] is! Map) {
      throw _NativeCommandException('server_properties must be a YAML map.', 2);
    }
    final Map<String, String> properties = _stringMap(
      template['server_properties'],
    );
    for (final MapEntry<String, String> property in properties.entries) {
      if (property.key.isEmpty ||
          RegExp(r'[\r\n=]').hasMatch(property.key) ||
          RegExp(r'[\r\n]').hasMatch(property.value)) {
        throw _NativeCommandException(
          'Invalid server property: ${property.key}',
          2,
        );
      }
    }
    if (properties['server-port'] case final String port) _networkPort(port);
    if (network) {
      final String minecraft = template['mc']?.toString() ?? '';
      final RegExpMatch? match = RegExp(
        r'^(\d+)\.(\d+)(?:\.\d+)?$',
      ).firstMatch(minecraft);
      if (!_networkBackendTypes.contains(type) ||
          match == null ||
          !(int.parse(match[1]!) >= 26 ||
              int.parse(match[1]!) == 1 && int.parse(match[2]!) >= 19)) {
        throw _NativeCommandException(
          'Network templates require Paper-compatible backends with explicit Minecraft 1.19 or newer versions.',
          2,
        );
      }
    }
    final String? jar = template['jar']?.toString();
    if (jar != null && jar.isNotEmpty) {
      if (!File(jar).existsSync()) {
        throw _NativeCommandException('Jar not found: $jar', 2);
      }
    } else if (type == 'custom') {
      throw _NativeCommandException('Custom server templates require jar.', 2);
    } else if (!options.flag('auto-build') &&
        !_truthy(template['auto_build'])) {
      final String? minecraft = template['mc']?.toString();
      if (minecraft != null &&
          _findCachedJar(
                profile,
                type: type,
                mc: minecraft,
                allowLatestFallback: false,
              ) ==
              null) {
        throw _NativeCommandException(
          'No cached $type jar for Minecraft $minecraft. Apply the template with --auto-build to download it.',
          2,
        );
      }
    }
  }

  Future<int> _templateAvailablePort({int start = 25565}) async {
    final Set<int> configured = configuredInstancePorts().keys.toSet();
    for (int port = start; port <= 65535; port++) {
      if (configured.contains(port)) continue;
      try {
        await _networkCheckPort(port);
        return port;
      } on _NativeCommandException {
        continue;
      }
    }
    throw _NativeCommandException('No available template port found.', 2);
  }

  void _templateSaveProxyRuntime(String instance, Map<String, dynamic> proxy) {
    _RuntimeSettingsData settings = _runtimeSettingsLoad(
      ConsumerProfile.plugin,
      includeEnvironment: false,
    );
    final Set<String> keys = <String>{};
    if (proxy['heap'] case final Object heap) {
      settings = settings.copyWith(heap: heap.toString().trim().toUpperCase());
      keys.add('HEAP_SIZE');
    }
    if (proxy['jvm_preset'] case final Object preset) {
      final String name = preset.toString().trim().toLowerCase();
      settings = settings.copyWith(
        profile: name,
        jvmArgs: NativeCommandService._runtimeSettingsPresets[name]!,
      );
      keys.addAll(<String>{'JVM_PROFILE', 'JVM_ARGS'});
    }
    if (keys.isNotEmpty) {
      _runtimeSettingsSave(
        ConsumerProfile.plugin,
        settings,
        instance: instance,
        keys: keys,
      );
    }
  }

  Future<void> _applyTemplateTransaction(
    ConsumerProfile profile,
    String templateName,
    Map<String, dynamic> template,
    String instance,
    _FlexibleArgs options,
    _NativeIoBuffer io,
  ) async {
    final String kind = template['kind']?.toString() ?? 'server';
    if (!const <String>{'server', 'network'}.contains(kind)) {
      throw _NativeCommandException('Unsupported template kind: $kind', 2);
    }
    final bool network = kind == 'network';
    if (network && profile != ConsumerProfile.plugin) {
      throw _NativeCommandException(
        'Network templates require --consumer plugin.',
        2,
      );
    }
    final Map<String, Map<String, dynamic>> servers =
        <String, Map<String, dynamic>>{};
    final Map<String, String> aliases = <String, String>{};
    final Map<String, dynamic> proxy = _mapValue(template['proxy']);
    final List<String> networkArgs = <String>[];
    if (network) {
      if (!NetworkDefinition.validName(instance)) {
        throw _NativeCommandException('Invalid network name: $instance', 2);
      }
      if (_networkStore.list().any(
        (NetworkDefinition item) => item.name == instance,
      )) {
        throw _NativeCommandException('Network already exists: $instance', 2);
      }
      _templateValidateTarget(profile, '$instance-proxy');
      final Map<String, dynamic> backends = _mapValue(template['backends']);
      if (backends.isEmpty || backends.length > 32) {
        throw _NativeCommandException(
          'Network templates require 1 to 32 backends.',
          2,
        );
      }
      if ((proxy['type'] ?? 'velocity') != 'velocity') {
        throw _NativeCommandException(
          'Network templates require a Velocity proxy.',
          2,
        );
      }
      _templateValidateRuntime(proxy);
      final bool offline = _truthy(proxy['offline']);
      final String bind = proxy['bind']?.toString() ?? '127.0.0.1';
      if (!const <String>{'127.0.0.1', '0.0.0.0'}.contains(bind) ||
          offline && bind != '127.0.0.1') {
        throw _NativeCommandException(
          'Offline networks require loopback; bind must be 127.0.0.1 or 0.0.0.0.',
          2,
        );
      }
      final Set<String> routeNames = <String>{};
      for (final MapEntry<String, dynamic> entry in backends.entries) {
        final String name = '$instance-${entry.key}';
        if (!NetworkDefinition.validName(entry.key) ||
            entry.key.toLowerCase() == 'try' ||
            !NetworkDefinition.validName(name) ||
            entry.key.toLowerCase() == 'proxy' ||
            !routeNames.add(entry.key.toLowerCase())) {
          throw _NativeCommandException(
            'Invalid backend alias or generated instance name: ${entry.key} / $name',
            2,
          );
        }
        _templateValidateTarget(profile, name);
        if (entry.value is! Map) {
          throw _NativeCommandException(
            'Backend ${entry.key} must be a YAML map.',
            2,
          );
        }
        final Map<String, dynamic> backend = Map<String, dynamic>.from(
          _mapValue(entry.value),
        );
        _templateValidateServer(profile, backend, options, network: true);
        if (offline &&
            !_truthy(backend['isolated']) &&
            !options.flag('isolated')) {
          throw _NativeCommandException(
            'Offline network backends must be isolated: ${entry.key}',
            2,
          );
        }
        servers[name] = backend;
        aliases[name] = entry.key;
      }
      final String entry = proxy['default']?.toString() ?? backends.keys.first;
      if (proxy['fallback'] != null && proxy['fallback'] is! List) {
        throw _NativeCommandException('Proxy fallback must be a YAML list.', 2);
      }
      final List<String> fallback =
          (proxy['fallback'] as List? ?? const <Object>[])
              .map((Object? value) => value.toString())
              .toList();
      if (!backends.containsKey(entry) ||
          fallback.contains(entry) ||
          fallback.any((String alias) => !backends.containsKey(alias)) ||
          fallback.toSet().length != fallback.length) {
        throw _NativeCommandException(
          'Entry and fallback routes must name distinct configured backends.',
          2,
        );
      }
      final String? version = proxy['version']?.toString();
      if (version != null &&
          !RegExp(r'^[34]\.\d+\.\d+(?:-SNAPSHOT)?$').hasMatch(version)) {
        throw _NativeCommandException(
          'Invalid Velocity proxy version: $version',
          2,
        );
      }
      String? jar = proxy['jar']?.toString();
      if (jar == null && !options.flag('auto-build')) {
        jar = version == null
            ? _buildLatestJarPath(profile, 'velocity')
            : _findCachedJar(
                profile,
                type: 'velocity',
                mc: version,
                allowLatestFallback: false,
              );
      }
      if (jar != null && !File(jar).existsSync()) {
        throw _NativeCommandException('Velocity jar not found: $jar', 2);
      }
      final String portText = proxy['port']?.toString() ?? 'auto';
      final int port = portText == 'auto'
          ? await _templateAvailablePort()
          : _networkPort(portText);
      await _networkCheckPort(port);
      networkArgs.addAll(<String>[
        '--members',
        servers.keys.join(','),
        '--default',
        entry,
        '--fallback',
        fallback.isEmpty ? 'none' : fallback.join(','),
        '--bind',
        bind,
        '--port',
        '$port',
        if (offline) '--offline',
        if (jar != null) ...<String>['--jar', jar],
        if (version != null) ...<String>['--proxy-version', version],
      ]);
    } else {
      _templateValidateTarget(profile, instance);
      _templateValidateServer(profile, template, options);
      servers[instance] = template;
    }

    final String token = _newPinSalt();
    final List<String> allocated = <String>[];
    bool networkCreated = false;
    try {
      for (final MapEntry<String, Map<String, dynamic>> server
          in servers.entries) {
        allocated.add(server.key);
        final Map<String, dynamic> definition = Map<String, dynamic>.from(
          server.value,
        );
        final Map<String, String> properties = _stringMap(
          definition['server_properties'],
        );
        if (!network && !properties.containsKey('server-port')) {
          properties['server-port'] = '${await _templateAvailablePort()}';
          definition['server_properties'] = properties;
        }
        await _templateApply(
          profile,
          templateName,
          definition,
          server.key,
          options,
          io,
          creationToken: token,
        );
      }
      if (network) {
        allocated.add('$instance-proxy');
        await _networkCreate(
          instance,
          _parseFlexibleArgs(
            networkArgs,
            booleanFlags: const <String>{'offline'},
          ),
          io,
          aliases: aliases,
          instanceCreationToken: token,
          retainCreationOwner: true,
          configureProxy: (String name) =>
              _templateSaveProxyRuntime(name, proxy),
        );
        networkCreated = true;
      }
      for (final String name in allocated) {
        final File owner = File(
          p.join(
            _instanceDir(profile, name),
            NativeCommandService._instanceCreationOwnerFile,
          ),
        );
        if (owner.existsSync() && owner.readAsStringSync().trim() == token) {
          owner.deleteSync();
        }
      }
      io.write(
        '[INFO] Created ${allocated.length} stopped instance(s). ${network ? 'Start with: network start $instance' : 'Start with: runtime start $instance'}',
      );
    } catch (error) {
      final List<String> retained = <String>[];
      bool safe = true;
      if (network) {
        try {
          if (_networkStore.pendingRecoveryDefinitions().isNotEmpty) {
            safe = false;
          } else if (networkCreated) {
            final NetworkDefinition created = _networkStore.load(instance);
            await _networkRequireStopped(created);
            _networkStore.delete(instance);
          }
        } catch (_) {
          safe = false;
        }
      }
      for (final String name in allocated.reversed) {
        if (FileSystemEntity.typeSync(
              _instanceDir(profile, name),
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound) {
          continue;
        }
        try {
          if (!safe ||
              await _recoveryIsRunning(profile, name) ||
              !_deleteOwnedPartialInstance(
                _instanceDir(profile, name),
                token,
              )) {
            retained.add(name);
          }
        } catch (_) {
          retained.add(name);
        }
      }
      if (retained.isNotEmpty) {
        io.error(
          '[RECOVERY] Retained template resources: ${retained.join(', ')}. ${network ? 'Keep them stopped; run network recover, then network list. If $instance exists, run network delete $instance --confirm $instance before deleting these instances.' : 'Inspect these stopped instances before deleting them.'} Instance directory: ${_instancesDir(profile)}',
        );
      } else {
        io.write(
          '[INFO] Removed only instances created by this failed template application. Downloaded jars were kept.',
        );
      }
      rethrow;
    }
  }
}
