import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../models/consumer_profile.dart';
import '../../models/server_minecraft_version.dart';
import 'network_configuration.dart';
import 'network_definition.dart';

class NetworkStore {
  NetworkStore({
    required this.stateDirectory,
    required this.instancePath,
    this.beforeWrite,
  });

  final Directory stateDirectory;
  final String Function(ConsumerProfile consumer, String instance) instancePath;
  final void Function(String path)? beforeWrite;

  static const Set<String> backendTypes = <String>{
    'paper',
    'purpur',
    'folia',
    'canvas',
    'leaf',
  };
  static const String secretFile = 'forwarding.secret';
  static final Random _random = Random.secure();
  static final Set<String> _heldLocks = <String>{};

  List<NetworkDefinition> list() => _locked(_list);

  List<NetworkDefinition> pendingRecoveryDefinitions() =>
      _locked(_pendingRecoveryDefinitions, allowPendingRecovery: true);

  /// The caller must first stop every instance in [pendingRecoveryDefinitions].
  void recover() => _locked(_recover, allowPendingRecovery: true);

  NetworkDefinition load(String name) =>
      _locked(() => _record(name).definition);

  void create(NetworkDefinition definition) => _locked(() {
    _checkDefinition(definition);
    if (File(_recordPath(definition.name)).existsSync()) {
      throw StateError('Network already exists: ${definition.name}');
    }
    _checkEnrollment(definition, updating: false);
    final _NetworkRecord record = _NetworkRecord(
      definition,
      <String, Object?>{},
    );
    final Map<String, String?> changes = <String, String?>{};
    final String secret = _newSecret();
    for (final NetworkMember member in definition.members) {
      _attach(record, member, secret, changes);
    }
    _configureProxy(definition, secret, changes);
    changes[_recordPath(definition.name)] = _encode(record.toJson());
    _transaction(changes, <NetworkDefinition>[definition]);
  });

  void update(NetworkDefinition definition) =>
      _locked(() => _update(definition));

  void repair(String name) =>
      _locked(() => _update(_record(name).definition, repair: true));

  void _update(NetworkDefinition definition, {bool repair = false}) {
    _checkDefinition(definition);
    final _NetworkRecord previous = _record(definition.name);
    if (previous.definition.proxy != definition.proxy) {
      throw StateError('A network proxy cannot be changed.');
    }
    if (!repair) _requireValid(previous.definition);
    _checkEnrollment(definition);
    final _NetworkRecord record = _NetworkRecord(
      definition,
      Map<String, Object?>.from(previous.originals),
    );
    final Map<String, String?> changes = <String, String?>{};
    final Set<String> desired = definition.members
        .map((NetworkMember member) => member.identity)
        .toSet();
    for (final NetworkMember member in previous.definition.members) {
      if (!desired.contains(member.identity)) _detach(record, member, changes);
    }
    final String secret = _readSecret(definition);
    for (final NetworkMember member in definition.members) {
      _attach(record, member, secret, changes);
    }
    _configureProxy(definition, secret, changes);
    changes[_recordPath(definition.name)] = _encode(record.toJson());
    _transaction(changes, <NetworkDefinition>[previous.definition, definition]);
  }

  void delete(String name) => _locked(() {
    final _NetworkRecord record = _record(name);
    _requireValid(record.definition);
    final Map<String, String?> changes = <String, String?>{};
    for (final NetworkMember member in record.definition.members) {
      _detach(record, member, changes);
    }
    final String sourcePath = _proxyPath(record.definition, '.server-source');
    final NetworkConfigDocument source = _document(sourcePath);
    source.remove('network');
    changes[sourcePath] = source.render();
    changes[_recordPath(name)] = null;
    _transaction(changes, <NetworkDefinition>[record.definition]);
  });

  List<String> validateConfiguration(NetworkDefinition definition) =>
      _locked(() => _validateConfiguration(definition));

  void _requireValid(NetworkDefinition definition) {
    final List<String> errors = _validateConfiguration(definition);
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
  }

  List<String> _validateConfiguration(NetworkDefinition definition) {
    final List<String> errors = definition.validate();
    if (errors.isNotEmpty) return errors;
    try {
      _checkEnrollment(definition);
      final String secret = _readSecret(definition);
      final NetworkConfigDocument proxy = _document(
        _proxyPath(definition, 'velocity.toml'),
      );
      final Map<String, Object?> expected = _proxyValues(definition);
      for (final MapEntry<String, Object?> entry in expected.entries) {
        if (!_equal(proxy.value(entry.key), entry.value)) {
          errors.add(
            'Proxy ${definition.proxy}: ${entry.key} differs from network settings.',
          );
        }
      }
      errors.addAll(_forcedHostErrors(definition, proxy));
      final NetworkConfigDocument source = _document(
        _proxyPath(definition, '.server-source'),
      );
      if (source.value('network') != definition.name) {
        errors.add('Proxy ${definition.proxy}: network membership differs.');
      }
      for (final NetworkMember member in definition.members) {
        for (final MapEntry<String, Map<String, Object?>> config
            in _backendValues(definition, member, secret).entries) {
          final NetworkConfigDocument document = _document(
            _memberPath(member, config.key),
          );
          for (final MapEntry<String, Object?> entry in config.value.entries) {
            if (!_equal(document.value(entry.key), entry.value)) {
              errors.add(
                'Backend ${member.instance}: ${config.key} ${entry.key} differs from network settings.',
              );
            }
          }
        }
      }
    } on StateError catch (error) {
      errors.add(error.message.toString());
    } on FileSystemException {
      errors.add('Network configuration files are unreadable.');
    }
    return errors;
  }

  static bool _equal(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.entries.every(
            (MapEntry<Object?, Object?> entry) =>
                right.containsKey(entry.key) &&
                _equal(entry.value, right[entry.key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List<int>.generate(
            left.length,
            (int index) => index,
          ).every((int index) => _equal(left[index], right[index]));
    }
    return left == right;
  }

  void _checkDefinition(NetworkDefinition definition) {
    final List<String> errors = definition.validate();
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
  }

  void _checkEnrollment(NetworkDefinition definition, {bool updating = true}) {
    _checkDefinition(definition);
    final String proxyRoot = instancePath(
      ConsumerProfile.plugin,
      definition.proxy,
    );
    _checkInstance(proxyRoot);
    final NetworkConfigDocument proxy = _document(
      p.join(proxyRoot, '.server-source'),
    );
    if (proxy.value('type') != 'velocity') {
      throw StateError('${definition.proxy} is not a Velocity proxy.');
    }
    _checkMembership(
      proxy,
      definition.name,
      definition.proxy,
      updating: updating,
    );
    if (!definition.onlineMode && proxy.value('isolated') != 'true') {
      throw StateError('Offline networks require an isolated proxy.');
    }
    for (final NetworkDefinition existing in _list()) {
      if (existing.name == definition.name) continue;
      if (existing.name.toLowerCase() == definition.name.toLowerCase()) {
        throw StateError(
          'A network already uses this name with different casing.',
        );
      }
      if (existing.proxy.toLowerCase() == definition.proxy.toLowerCase()) {
        throw StateError(
          'Proxy ${definition.proxy} already belongs to ${existing.name}.',
        );
      }
      final Set<String> identities = existing.members
          .map((NetworkMember member) => member.identity.toLowerCase())
          .toSet();
      final Set<int> occupied = <int>{
        existing.port,
        ...existing.members.map((NetworkMember member) => member.port),
      };
      if (occupied.contains(definition.port) ||
          definition.members.any(
            (NetworkMember member) => occupied.contains(member.port),
          )) {
        throw StateError(
          'A configured port is already reserved by network ${existing.name}.',
        );
      }
      for (final NetworkMember member in definition.members) {
        if (identities.contains(member.identity.toLowerCase())) {
          throw StateError(
            'Backend ${member.instance} already belongs to ${existing.name}.',
          );
        }
      }
    }
    for (final NetworkMember member in definition.members) {
      final String root = instancePath(member.consumer, member.instance);
      _checkInstance(root);
      final NetworkConfigDocument source = _document(
        p.join(root, '.server-source'),
      );
      _checkMembership(
        source,
        definition.name,
        member.instance,
        updating: updating,
      );
      if (!backendTypes.contains(source.value('type'))) {
        throw StateError(
          'Backend ${member.instance} requires Paper, Purpur, Folia, Canvas, or Leaf.',
        );
      }
      final String version =
          inferServerMinecraftVersion(
            serverType: source.value('type') as String,
            minecraft: source.value('mc') as String?,
            jarPaths: <String>[
              if (source.value('jar') is String) source.value('jar') as String,
              p.join(root, 'server.jar'),
            ],
          ) ??
          '';
      if (!supportsMinecraft(version)) {
        throw StateError(
          'Backend ${member.instance} requires a recorded Minecraft version of 1.19 or newer.',
        );
      }
      if (!definition.onlineMode && source.value('isolated') != 'true') {
        throw StateError(
          'Offline networks require isolated backend ${member.instance}.',
        );
      }
    }
  }

  static bool supportsMinecraft(String version) {
    final RegExpMatch? match = RegExp(
      r'^(\d+)\.(\d+)(?:\.\d+)?$',
    ).firstMatch(version);
    if (match == null) return false;
    final int major = int.parse(match.group(1)!);
    final int minor = int.parse(match.group(2)!);
    return (major == 1 && minor >= 19) || major >= 26;
  }

  void _checkMembership(
    NetworkConfigDocument source,
    String name,
    String instance, {
    required bool updating,
  }) {
    final Object? current = source.value('network');
    if (current != null && (!updating || current != name)) {
      throw StateError(
        'Instance $instance already belongs to network $current.',
      );
    }
  }

  void _checkInstance(String root) {
    _safePath(root, root);
    if (!Directory(root).existsSync()) {
      throw StateError('Instance directory is missing: $root');
    }
  }

  Map<String, Map<String, Object?>> _backendValues(
    NetworkDefinition definition,
    NetworkMember member,
    String secret,
  ) => <String, Map<String, Object?>>{
    'server.properties': <String, Object?>{
      'online-mode': 'false',
      'server-ip': '127.0.0.1',
      'server-port': member.port.toString(),
    },
    'spigot.yml': <String, Object?>{'settings.bungeecord': false},
    'config/paper-global.yml': <String, Object?>{
      'proxies.velocity.enabled': true,
      'proxies.velocity.secret': secret,
      'proxies.velocity.online-mode': definition.onlineMode,
    },
    '.server-source': <String, Object?>{'network': definition.name},
  };

  Map<String, Object?> _proxyValues(NetworkDefinition definition) =>
      <String, Object?>{
        'bind': '${definition.bind}:${definition.port}',
        'online-mode': definition.onlineMode,
        'player-info-forwarding-mode': 'MODERN',
        'forwarding-secret-file': secretFile,
        'servers': <String, Object?>{
          for (final NetworkMember member in definition.members)
            member.alias: '127.0.0.1:${member.port}',
          'try': definition.connectionOrder,
        },
      };

  void _attach(
    _NetworkRecord record,
    NetworkMember member,
    String secret,
    Map<String, String?> changes,
  ) {
    final bool enrolled = record.originals.containsKey(member.identity);
    final Map<String, Object?> originals = enrolled
        ? Map<String, Object?>.from(record.originals[member.identity] as Map)
        : <String, Object?>{};
    for (final MapEntry<String, Map<String, Object?>> config in _backendValues(
      record.definition,
      member,
      secret,
    ).entries) {
      final String path = _memberPath(member, config.key);
      final NetworkConfigDocument document = _document(path);
      if (!enrolled) {
        originals[config.key] = <String, Object?>{
          for (final String key in config.value.keys)
            key: document.snapshot(key),
        };
      }
      for (final MapEntry<String, Object?> entry in config.value.entries) {
        document.set(entry.key, entry.value);
      }
      changes[path] = document.render();
    }
    record.originals[member.identity] = originals;
  }

  void _detach(
    _NetworkRecord record,
    NetworkMember member,
    Map<String, String?> changes,
  ) {
    final Object? saved = record.originals[member.identity];
    if (saved is! Map) {
      throw StateError(
        'Original backend settings are missing: ${member.instance}.',
      );
    }
    for (final MapEntry<Object?, Object?> config in saved.entries) {
      final String relative = config.key as String;
      if (!_backendValues(
        record.definition,
        member,
        '',
      ).containsKey(relative)) {
        throw StateError('Invalid saved backend configuration path.');
      }
      final String path = _memberPath(member, relative);
      final NetworkConfigDocument document = _document(path);
      for (final MapEntry<Object?, Object?> entry
          in (config.value as Map).entries) {
        final String key = entry.key as String;
        if (!_backendValues(
          record.definition,
          member,
          '',
        )[relative]!.containsKey(key)) {
          throw StateError('Invalid saved backend configuration key.');
        }
        document.restore(key, Map<String, Object?>.from(entry.value as Map));
      }
      changes[path] = document.render();
    }
    record.originals.remove(member.identity);
  }

  void _configureProxy(
    NetworkDefinition definition,
    String secret,
    Map<String, String?> changes,
  ) {
    final String configPath = _proxyPath(definition, 'velocity.toml');
    final NetworkConfigDocument config = _document(configPath);
    if (!config.contains('config-version')) config.set('config-version', '2.8');
    if (!config.contains('motd')) {
      config.set('motd', 'Multiplexor ${definition.name}');
    }
    if (!config.contains('show-max-players')) {
      config.set('show-max-players', 100);
    }
    if (!config.contains('forced-hosts')) {
      config.set('forced-hosts', <String, Object?>{});
    }
    for (final MapEntry<String, Object?> entry in _proxyValues(
      definition,
    ).entries) {
      config.set(entry.key, entry.value);
    }
    final List<String> errors = _forcedHostErrors(definition, config);
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    changes[configPath] = config.render();
    changes[_proxyPath(definition, secretFile)] = '$secret\n';
    final String sourcePath = _proxyPath(definition, '.server-source');
    final NetworkConfigDocument source = _document(sourcePath);
    source.set('network', definition.name);
    changes[sourcePath] = source.render();
  }

  List<String> _forcedHostErrors(
    NetworkDefinition definition,
    NetworkConfigDocument config,
  ) {
    final Object? forcedHosts = config.value('forced-hosts');
    if (forcedHosts is! Map) {
      return <String>['Proxy forced-hosts must be a TOML table.'];
    }
    final Set<String> aliases = definition.members
        .map((NetworkMember member) => member.alias)
        .toSet();
    for (final Object? value in forcedHosts.values) {
      final List<Object?>? routes = switch (value) {
        String route => <Object?>[route],
        List<Object?> routes => routes,
        _ => null,
      };
      if (routes == null || routes.isEmpty) {
        return <String>[
          'Proxy forced-hosts entries must contain a backend alias or a nonempty list of aliases.',
        ];
      }
      if (routes.any((Object? route) => !aliases.contains(route))) {
        return <String>[
          'Proxy forced-hosts references a backend outside this network. Update forced-hosts before changing membership.',
        ];
      }
    }
    return <String>[];
  }

  String _readSecret(NetworkDefinition definition) {
    final String? contents = _read(_proxyPath(definition, secretFile));
    final String secret = contents?.trim() ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      throw StateError('Proxy forwarding secret is missing or invalid.');
    }
    return secret;
  }

  static String _newSecret() => List<String>.generate(
    32,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  NetworkConfigDocument _document(String path) {
    final String? contents = _read(path);
    final NetworkConfigFormat format = path.endsWith('.yml')
        ? NetworkConfigFormat.yaml
        : path.endsWith('.toml')
        ? NetworkConfigFormat.toml
        : NetworkConfigFormat.properties;
    try {
      return NetworkConfigDocument(format, contents ?? '');
    } catch (_) {
      throw StateError('Invalid network configuration: $path');
    }
  }

  String _proxyPath(NetworkDefinition definition, String relative) =>
      _checkedInstancePath(ConsumerProfile.plugin, definition.proxy, relative);

  String _memberPath(NetworkMember member, String relative) =>
      _checkedInstancePath(member.consumer, member.instance, relative);

  String _checkedInstancePath(
    ConsumerProfile profile,
    String instance,
    String relative,
  ) {
    final String root = p.normalize(
      p.absolute(instancePath(profile, instance)),
    );
    final String path = p.join(root, relative);
    _safePath(path, root);
    return path;
  }

  String _recordPath(String name) {
    if (!NetworkDefinition.validName(name)) {
      throw StateError('Invalid network name.');
    }
    final String path = p.join(stateDirectory.absolute.path, '$name.json');
    _safePath(path, stateDirectory.absolute.path);
    return path;
  }

  List<NetworkDefinition> _list() {
    if (!stateDirectory.existsSync()) return <NetworkDefinition>[];
    final List<NetworkDefinition> result = <NetworkDefinition>[];
    for (final FileSystemEntity entry in stateDirectory.listSync(
      followLinks: false,
    )) {
      final String filename = p.basename(entry.path);
      if (!filename.endsWith('.json') || filename.startsWith('.')) continue;
      result.add(
        _record(filename.substring(0, filename.length - 5)).definition,
      );
    }
    result.sort(
      (NetworkDefinition a, NetworkDefinition b) => a.name.compareTo(b.name),
    );
    return result;
  }

  _NetworkRecord _record(String name) {
    final String? contents = _read(_recordPath(name));
    if (contents == null) throw StateError('Network not found: $name');
    try {
      final Map<String, Object?> data = Map<String, Object?>.from(
        jsonDecode(contents) as Map,
      );
      if (data['version'] != 1) throw const FormatException();
      final NetworkDefinition definition = NetworkDefinition.fromJson(
        Map<String, Object?>.from(data['definition'] as Map),
      );
      if (definition.name != name || definition.validate().isNotEmpty) {
        throw const FormatException();
      }
      final Map<String, Object?> originals = Map<String, Object?>.from(
        data['originals'] as Map,
      );
      _validateOriginals(definition, originals);
      return _NetworkRecord(definition, originals);
    } catch (_) {
      throw StateError('Invalid network record: $name');
    }
  }

  void _validateOriginals(
    NetworkDefinition definition,
    Map<String, Object?> originals,
  ) {
    if (originals.length != definition.members.length) {
      throw const FormatException();
    }
    for (final NetworkMember member in definition.members) {
      final Map<String, Object?> files = Map<String, Object?>.from(
        originals[member.identity] as Map,
      );
      final Map<String, Map<String, Object?>> expected = _backendValues(
        definition,
        member,
        '',
      );
      if (files.length != expected.length) throw const FormatException();
      for (final MapEntry<String, Map<String, Object?>> config
          in expected.entries) {
        final Map<String, Object?> keys = Map<String, Object?>.from(
          files[config.key] as Map,
        );
        if (keys.length != config.value.length) throw const FormatException();
        for (final String key in config.value.keys) {
          final Map<String, Object?> snapshot = Map<String, Object?>.from(
            keys[key] as Map,
          );
          if (snapshot['present'] is! bool ||
              snapshot['absentParents'] is! List) {
            throw const FormatException();
          }
          for (final Object? parent in snapshot['absentParents'] as List) {
            if (parent is! String || !key.startsWith('$parent.')) {
              throw const FormatException();
            }
          }
        }
      }
    }
  }

  static String _encode(Object value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  static String? _read(String path) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw StateError('Network configuration must be a regular file: $path');
    }
    return File(path).readAsStringSync();
  }

  static void _safePath(String path, String root) {
    final String normalizedRoot = p.normalize(p.absolute(root));
    String current = p.normalize(p.absolute(path));
    if (current != normalizedRoot && !p.isWithin(normalizedRoot, current)) {
      throw StateError('Network configuration path leaves its instance.');
    }
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError(
          'Network configuration uses a symlink: $current. Localize this file or directory before attaching the instance.',
        );
      }
      if (current == normalizedRoot) break;
      current = p.dirname(current);
    }
  }

  T _locked<T>(T Function() action, {bool allowPendingRecovery = false}) {
    final String identity = p.normalize(stateDirectory.absolute.path);
    if (_heldLocks.contains(identity)) {
      throw StateError(
        'Another network command is running. Retry after it finishes.',
      );
    }
    _safePath(stateDirectory.path, stateDirectory.path);
    stateDirectory.createSync(recursive: true);
    _restrict(stateDirectory.path, directory: true);
    final String lockPath = p.join(stateDirectory.path, '.lock');
    _safePath(lockPath, stateDirectory.path);
    final RandomAccessFile lock = File(
      lockPath,
    ).openSync(mode: FileMode.append);
    bool acquired = false;
    try {
      try {
        lock.lockSync(FileLock.exclusive);
        acquired = true;
        _heldLocks.add(identity);
      } on FileSystemException {
        throw StateError(
          'Another network command is running. Retry after it finishes.',
        );
      }
      if (!allowPendingRecovery && _pendingRecoveryDefinitions().isNotEmpty) {
        throw StateError(
          'Network transaction recovery is pending. Stop the affected instances and run network recover.',
        );
      }
      return action();
    } finally {
      _heldLocks.remove(identity);
      if (acquired) lock.unlockSync();
      lock.closeSync();
    }
  }

  String get _journalPath =>
      p.join(stateDirectory.absolute.path, '.transaction.json');

  List<NetworkDefinition> _pendingRecoveryDefinitions() {
    _safePath(_journalPath, stateDirectory.path);
    final String? contents = _read(_journalPath);
    if (contents == null) return <NetworkDefinition>[];
    try {
      final Map<String, Object?> journal = Map<String, Object?>.from(
        jsonDecode(contents) as Map,
      );
      if (journal['version'] != 1 || journal['committed'] is! bool) {
        throw const FormatException();
      }
      if (journal['committed'] == true) return <NetworkDefinition>[];
      final List<NetworkDefinition> definitions =
          (journal['definitions'] as List<Object?>)
              .map(
                (Object? value) => NetworkDefinition.fromJson(
                  Map<String, Object?>.from(value as Map),
                ),
              )
              .toList();
      if (definitions.isEmpty ||
          definitions.any(
            (NetworkDefinition definition) => definition.validate().isNotEmpty,
          )) {
        throw const FormatException();
      }
      return definitions;
    } catch (_) {
      throw StateError('Invalid network transaction journal: $_journalPath');
    }
  }

  void _transaction(
    Map<String, String?> changes,
    List<NetworkDefinition> definitions,
  ) {
    final Map<String, Object?> files = <String, Object?>{};
    for (final MapEntry<String, String?> entry in changes.entries) {
      files[entry.key] = <String, Object?>{
        'before': _read(entry.key),
        'after': entry.value,
      };
    }
    final Map<String, Object?> journal = <String, Object?>{
      'version': 1,
      'committed': false,
      'definitions': definitions
          .map((NetworkDefinition definition) => definition.toJson())
          .toList(),
      'files': files,
    };
    _atomicWrite(_journalPath, _encode(journal));
    try {
      for (final MapEntry<String, String?> entry in changes.entries) {
        beforeWrite?.call(entry.key);
        _atomicWrite(entry.key, entry.value);
      }
      journal['committed'] = true;
      _atomicWrite(_journalPath, _encode(journal));
    } catch (_) {
      try {
        _recover();
      } catch (_) {
        throw StateError(
          'Network update failed and rollback is incomplete. The recovery journal is retained; restore access to the affected files before retrying.',
        );
      }
      throw StateError(
        'Network update failed; original configuration was restored.',
      );
    }
    try {
      File(_journalPath).deleteSync();
    } on FileSystemException {
      // The committed journal can be removed by a later explicit recovery.
    }
  }

  void _recover() {
    _safePath(_journalPath, stateDirectory.path);
    final String? contents = _read(_journalPath);
    if (contents == null) return;
    try {
      final Map<String, Object?> journal = Map<String, Object?>.from(
        jsonDecode(contents) as Map,
      );
      if (journal['version'] != 1 || journal['committed'] is! bool) {
        throw const FormatException();
      }
      final List<NetworkDefinition> definitions =
          (journal['definitions'] as List<Object?>)
              .map(
                (Object? value) => NetworkDefinition.fromJson(
                  Map<String, Object?>.from(value as Map),
                ),
              )
              .toList();
      final Set<String> allowed = <String>{};
      for (final NetworkDefinition definition in definitions) {
        _checkDefinition(definition);
        allowed.add(_recordPath(definition.name));
        for (final String relative in <String>[
          'velocity.toml',
          secretFile,
          '.server-source',
        ]) {
          allowed.add(_proxyPath(definition, relative));
        }
        for (final NetworkMember member in definition.members) {
          for (final String relative in _backendValues(
            definition,
            member,
            '',
          ).keys) {
            allowed.add(_memberPath(member, relative));
          }
        }
      }
      final Map<String, Object?> files = Map<String, Object?>.from(
        journal['files'] as Map,
      );
      for (final MapEntry<String, Object?> entry in files.entries) {
        if (!allowed.contains(entry.key)) throw const FormatException();
        final Map<String, Object?> data = Map<String, Object?>.from(
          entry.value as Map,
        );
        final String? before = data['before'] as String?;
        final String? after = data['after'] as String?;
        final String? current = _read(entry.key);
        if (journal['committed'] == false &&
            current != before &&
            current != after) {
          throw StateError(
            'A configuration file changed after the interrupted transaction.',
          );
        }
      }
      if (journal['committed'] == false) {
        for (final MapEntry<String, Object?> entry
            in files.entries.toList().reversed) {
          final Map<String, Object?> data = Map<String, Object?>.from(
            entry.value as Map,
          );
          _atomicWrite(entry.key, data['before'] as String?);
        }
      }
      File(_journalPath).deleteSync();
    } catch (_) {
      throw StateError(
        'Network transaction recovery is pending. Restore access to unchanged configuration files and retry; journal: $_journalPath',
      );
    }
  }

  static void _restrict(String path, {bool directory = false}) {
    if (Platform.isWindows) return;
    final ProcessResult result = Process.runSync('chmod', <String>[
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Cannot secure network configuration permissions.');
    }
  }

  static void _atomicWrite(String path, String? contents) {
    if (contents == null) {
      if (File(path).existsSync()) File(path).deleteSync();
      return;
    }
    final File file = File(path);
    file.parent.createSync(recursive: true);
    final File temporary = File(
      '$path.network-${_newSecret().substring(0, 16)}',
    );
    try {
      temporary.createSync(exclusive: true);
      _restrict(temporary.path);
      temporary.writeAsStringSync(contents, flush: true);
      temporary.renameSync(path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}

class _NetworkRecord {
  _NetworkRecord(this.definition, this.originals);

  final NetworkDefinition definition;
  final Map<String, Object?> originals;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'definition': definition.toJson(),
    'originals': originals,
  };
}
