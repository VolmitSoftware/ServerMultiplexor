import 'dart:collection';

typedef JsonObject = Map<String, Object?>;

final class PterodactylPage<T> {
  PterodactylPage({required List<T> items, required this.pagination})
    : items = List<T>.unmodifiable(items);

  final List<T> items;
  final PterodactylPagination pagination;
}

final class PterodactylPagination {
  const PterodactylPagination({
    required this.total,
    required this.count,
    required this.perPage,
    required this.currentPage,
    required this.totalPages,
  });

  final int total;
  final int count;
  final int perPage;
  final int currentPage;
  final int totalPages;

  bool get hasNextPage => currentPage < totalPages;
}

enum PterodactylPowerSignal {
  start,
  stop,
  restart,
  kill;

  String get wireValue => name;
}

/// Short-lived credentials returned by the Panel for a Wings WebSocket.
///
/// [token] remains accessible to the eventual session transport, but is never
/// included in diagnostics. Only encrypted WebSocket endpoints are accepted.
final class PterodactylWebsocketCredentials {
  PterodactylWebsocketCredentials._({
    required this.token,
    required this.socketUri,
  });

  factory PterodactylWebsocketCredentials.fromJson(JsonObject json) {
    final String token = _requiredString(json, 'token');
    if (token.isEmpty || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(token)) {
      throw const FormatException('Expected "token" to be a valid credential.');
    }

    final String rawSocket = _requiredString(json, 'socket');
    final Uri? socketUri = Uri.tryParse(rawSocket);
    if (socketUri == null ||
        socketUri.scheme != 'wss' ||
        socketUri.host.isEmpty ||
        socketUri.userInfo.isNotEmpty ||
        socketUri.hasQuery ||
        socketUri.hasFragment ||
        (socketUri.hasPort && (socketUri.port < 1 || socketUri.port > 65535))) {
      throw const FormatException(
        'Expected "socket" to be a secure WebSocket URL.',
      );
    }

    return PterodactylWebsocketCredentials._(
      token: token,
      socketUri: socketUri,
    );
  }

  final String token;
  final Uri socketUri;

  @override
  String toString() =>
      'PterodactylWebsocketCredentials(socketUri: $socketUri, token: [REDACTED])';
}

final class PterodactylAllocation {
  const PterodactylAllocation({
    required this.id,
    required this.ip,
    required this.port,
    this.alias,
    this.notes,
    this.isDefault = false,
    this.isAssigned,
  });

  factory PterodactylAllocation.fromClientJson(JsonObject json) {
    return PterodactylAllocation(
      id: _requiredInt(json, 'id'),
      ip: _requiredString(json, 'ip'),
      port: _requiredInt(json, 'port'),
      alias: _nullableString(json, 'ip_alias'),
      notes: _nullableString(json, 'notes'),
      isDefault: _optionalBool(json, 'is_default'),
    );
  }

  factory PterodactylAllocation.fromApplicationJson(JsonObject json) {
    return PterodactylAllocation(
      id: _requiredInt(json, 'id'),
      ip: _requiredString(json, 'ip'),
      port: _requiredInt(json, 'port'),
      alias: _nullableString(json, 'alias'),
      notes: _nullableString(json, 'notes'),
      isAssigned: _optionalBool(json, 'assigned'),
    );
  }

  final int id;
  final String ip;
  final int port;
  final String? alias;
  final String? notes;
  final bool isDefault;
  final bool? isAssigned;

  /// Whether the Application API reports this allocation as available.
  bool get isFree => isAssigned == false;

  /// The operator-facing host, preferring Pterodactyl's configured alias.
  String get displayHost => alias?.trim().isNotEmpty == true ? alias! : ip;

  String get endpoint {
    final String host = displayHost.contains(':')
        ? '[$displayHost]'
        : displayHost;
    return '$host:$port';
  }
}

final class PterodactylResourceUsage {
  const PterodactylResourceUsage({
    required this.currentState,
    required this.isSuspended,
    required this.memoryBytes,
    required this.cpuAbsolute,
    required this.diskBytes,
    required this.networkRxBytes,
    required this.networkTxBytes,
    required this.uptime,
  });

  factory PterodactylResourceUsage.fromJson(JsonObject json) {
    final JsonObject resources = _requiredObject(json, 'resources');
    return PterodactylResourceUsage(
      currentState: _requiredString(json, 'current_state'),
      isSuspended: _optionalBool(json, 'is_suspended'),
      memoryBytes: _requiredInt(resources, 'memory_bytes'),
      cpuAbsolute: _requiredDouble(resources, 'cpu_absolute'),
      diskBytes: _requiredInt(resources, 'disk_bytes'),
      networkRxBytes: _requiredInt(resources, 'network_rx_bytes'),
      networkTxBytes: _requiredInt(resources, 'network_tx_bytes'),
      uptime: Duration(milliseconds: _requiredInt(resources, 'uptime')),
    );
  }

  final String currentState;
  final bool isSuspended;
  final int memoryBytes;
  final double cpuAbsolute;
  final int diskBytes;
  final int networkRxBytes;
  final int networkTxBytes;
  final Duration uptime;
}

final class PterodactylClientServer {
  PterodactylClientServer({
    required this.identifier,
    required this.internalId,
    required this.uuid,
    required this.name,
    required this.nodeName,
    required this.description,
    required this.isOwner,
    required this.isNodeUnderMaintenance,
    required this.status,
    required this.sftpHost,
    required this.sftpPort,
    required this.limits,
    required this.featureLimits,
    required List<PterodactylAllocation> allocations,
  }) : allocations = List<PterodactylAllocation>.unmodifiable(allocations);

  factory PterodactylClientServer.fromJson(JsonObject json) {
    final JsonObject sftp = _requiredObject(json, 'sftp_details');
    final JsonObject relationships = _optionalObject(json, 'relationships');
    final List<PterodactylAllocation> allocations = _relationshipItems(
      relationships,
      'allocations',
    ).map(PterodactylAllocation.fromClientJson).toList(growable: false);

    return PterodactylClientServer(
      identifier: _requiredString(json, 'identifier'),
      internalId: _requiredInt(json, 'internal_id'),
      uuid: _requiredString(json, 'uuid'),
      name: _requiredString(json, 'name'),
      nodeName: _requiredString(json, 'node'),
      description: _nullableString(json, 'description') ?? '',
      isOwner: _optionalBool(json, 'server_owner'),
      isNodeUnderMaintenance: _optionalBool(json, 'is_node_under_maintenance'),
      status: _nullableString(json, 'status'),
      sftpHost: _requiredString(sftp, 'ip'),
      sftpPort: _requiredInt(sftp, 'port'),
      limits: PterodactylServerLimits.fromJson(_requiredObject(json, 'limits')),
      featureLimits: PterodactylFeatureLimits.fromJson(
        _requiredObject(json, 'feature_limits'),
      ),
      allocations: allocations,
    );
  }

  final String identifier;
  final int internalId;
  final String uuid;
  final String name;
  final String nodeName;
  final String description;
  final bool isOwner;
  final bool isNodeUnderMaintenance;
  final String? status;
  final String sftpHost;
  final int sftpPort;
  final PterodactylServerLimits limits;
  final PterodactylFeatureLimits featureLimits;
  final List<PterodactylAllocation> allocations;

  PterodactylAllocation? get primaryAllocation {
    for (final PterodactylAllocation allocation in allocations) {
      if (allocation.isDefault) {
        return allocation;
      }
    }
    return allocations.isEmpty ? null : allocations.first;
  }
}

final class PterodactylServerLimits {
  const PterodactylServerLimits({
    required this.memoryMiB,
    required this.swapMiB,
    required this.diskMiB,
    required this.ioWeight,
    required this.cpuPercent,
    required this.threads,
    required this.oomDisabled,
  });

  factory PterodactylServerLimits.fromJson(JsonObject json) {
    return PterodactylServerLimits(
      memoryMiB: _requiredInt(json, 'memory'),
      swapMiB: _requiredInt(json, 'swap'),
      diskMiB: _requiredInt(json, 'disk'),
      ioWeight: _requiredInt(json, 'io'),
      cpuPercent: _requiredInt(json, 'cpu'),
      threads: _nullableString(json, 'threads'),
      oomDisabled: _optionalBool(json, 'oom_disabled'),
    );
  }

  final int memoryMiB;
  final int swapMiB;
  final int diskMiB;
  final int ioWeight;
  final int cpuPercent;
  final String? threads;
  final bool oomDisabled;

  JsonObject toJson() => <String, Object?>{
    'memory': memoryMiB,
    'swap': swapMiB,
    'disk': diskMiB,
    'io': ioWeight,
    'cpu': cpuPercent,
    if (threads != null) 'threads': threads,
  };
}

final class PterodactylFeatureLimits {
  const PterodactylFeatureLimits({
    required this.databases,
    required this.allocations,
    required this.backups,
  });

  factory PterodactylFeatureLimits.fromJson(JsonObject json) {
    return PterodactylFeatureLimits(
      databases: _nullableInt(json, 'databases'),
      allocations: _nullableInt(json, 'allocations'),
      backups: _nullableInt(json, 'backups'),
    );
  }

  final int? databases;
  final int? allocations;
  final int? backups;

  JsonObject toJson() => <String, Object?>{
    'databases': databases,
    'allocations': allocations,
    'backups': backups,
  };
}

final class PterodactylApplicationServer {
  PterodactylApplicationServer({
    required this.id,
    required this.uuid,
    required this.identifier,
    required this.name,
    required this.description,
    required this.status,
    required this.ownerId,
    required this.nodeId,
    required this.allocationId,
    required this.nestId,
    required this.eggId,
    required this.limits,
    required this.featureLimits,
    required this.image,
    required this.startup,
    required Map<String, String> environment,
    this.externalId,
  }) : environment = UnmodifiableMapView<String, String>(
         Map<String, String>.from(environment),
       );

  factory PterodactylApplicationServer.fromJson(JsonObject json) {
    final JsonObject container = _requiredObject(json, 'container');
    return PterodactylApplicationServer(
      id: _requiredInt(json, 'id'),
      externalId: _nullableString(json, 'external_id'),
      uuid: _requiredString(json, 'uuid'),
      identifier: _requiredString(json, 'identifier'),
      name: _requiredString(json, 'name'),
      description: _nullableString(json, 'description') ?? '',
      status: _nullableString(json, 'status'),
      ownerId: _requiredInt(json, 'user'),
      nodeId: _requiredInt(json, 'node'),
      allocationId: _requiredInt(json, 'allocation'),
      nestId: _requiredInt(json, 'nest'),
      eggId: _requiredInt(json, 'egg'),
      limits: PterodactylServerLimits.fromJson(_requiredObject(json, 'limits')),
      featureLimits: PterodactylFeatureLimits.fromJson(
        _requiredObject(json, 'feature_limits'),
      ),
      image: _requiredString(container, 'image'),
      startup: _requiredString(container, 'startup_command'),
      environment: _requiredEnvironmentMap(container, 'environment'),
    );
  }

  final int id;
  final String? externalId;
  final String uuid;
  final String identifier;
  final String name;
  final String description;
  final String? status;
  final int ownerId;
  final int nodeId;
  final int allocationId;
  final int nestId;
  final int eggId;
  final PterodactylServerLimits limits;
  final PterodactylFeatureLimits featureLimits;
  final String image;
  final String startup;
  final Map<String, String> environment;
}

final class PterodactylNode {
  const PterodactylNode({
    required this.id,
    required this.uuid,
    required this.name,
    required this.fqdn,
    required this.scheme,
    required this.public,
    required this.behindProxy,
    required this.maintenanceMode,
    required this.memoryMiB,
    required this.diskMiB,
    required this.allocatedMemoryMiB,
    required this.allocatedDiskMiB,
    required this.daemonPort,
    required this.sftpPort,
    this.description,
  });

  factory PterodactylNode.fromJson(JsonObject json) {
    final JsonObject allocated = _requiredObject(json, 'allocated_resources');
    return PterodactylNode(
      id: _requiredInt(json, 'id'),
      uuid: _requiredString(json, 'uuid'),
      name: _requiredString(json, 'name'),
      description: _nullableString(json, 'description'),
      fqdn: _requiredString(json, 'fqdn'),
      scheme: _requiredString(json, 'scheme'),
      public: _optionalBool(json, 'public'),
      behindProxy: _optionalBool(json, 'behind_proxy'),
      maintenanceMode: _optionalBool(json, 'maintenance_mode'),
      memoryMiB: _requiredInt(json, 'memory'),
      diskMiB: _requiredInt(json, 'disk'),
      allocatedMemoryMiB: _requiredInt(allocated, 'memory'),
      allocatedDiskMiB: _requiredInt(allocated, 'disk'),
      daemonPort: _requiredInt(json, 'daemon_listen'),
      sftpPort: _requiredInt(json, 'daemon_sftp'),
    );
  }

  final int id;
  final String uuid;
  final String name;
  final String? description;
  final String fqdn;
  final String scheme;
  final bool public;
  final bool behindProxy;
  final bool maintenanceMode;
  final int memoryMiB;
  final int diskMiB;
  final int allocatedMemoryMiB;
  final int allocatedDiskMiB;
  final int daemonPort;
  final int sftpPort;
}

final class PterodactylUser {
  const PterodactylUser({
    required this.id,
    required this.uuid,
    required this.username,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.isRootAdmin,
    this.externalId,
  });

  factory PterodactylUser.fromJson(JsonObject json) {
    return PterodactylUser(
      id: _requiredInt(json, 'id'),
      externalId: _nullableString(json, 'external_id'),
      uuid: _requiredString(json, 'uuid'),
      username: _requiredString(json, 'username'),
      email: _requiredString(json, 'email'),
      firstName: _requiredString(json, 'first_name'),
      lastName: _requiredString(json, 'last_name'),
      isRootAdmin: _optionalBool(json, 'root_admin'),
    );
  }

  final int id;
  final String? externalId;
  final String uuid;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final bool isRootAdmin;
}

final class PterodactylNest {
  const PterodactylNest({
    required this.id,
    required this.uuid,
    required this.name,
    required this.author,
    this.description,
  });

  factory PterodactylNest.fromJson(JsonObject json) {
    return PterodactylNest(
      id: _requiredInt(json, 'id'),
      uuid: _requiredString(json, 'uuid'),
      name: _requiredString(json, 'name'),
      author: _requiredString(json, 'author'),
      description: _nullableString(json, 'description'),
    );
  }

  final int id;
  final String uuid;
  final String name;
  final String author;
  final String? description;
}

final class PterodactylEgg {
  PterodactylEgg({
    required this.id,
    required this.uuid,
    required this.name,
    required this.nestId,
    required this.author,
    required this.startup,
    required Map<String, String> dockerImages,
    this.description,
  }) : dockerImages = UnmodifiableMapView<String, String>(
         Map<String, String>.from(dockerImages),
       );

  factory PterodactylEgg.fromJson(JsonObject json) {
    final Object? imagesValue = json['docker_images'];
    final Map<String, String> images = <String, String>{};
    if (imagesValue is Map<Object?, Object?>) {
      for (final MapEntry<Object?, Object?> entry in imagesValue.entries) {
        if (entry.key is String && entry.value is String) {
          images[entry.key! as String] = entry.value! as String;
        }
      }
    }
    return PterodactylEgg(
      id: _requiredInt(json, 'id'),
      uuid: _requiredString(json, 'uuid'),
      name: _requiredString(json, 'name'),
      nestId: _requiredInt(json, 'nest'),
      author: _requiredString(json, 'author'),
      description: _nullableString(json, 'description'),
      startup: _requiredString(json, 'startup'),
      dockerImages: images,
    );
  }

  final int id;
  final String uuid;
  final String name;
  final int nestId;
  final String author;
  final String? description;
  final String startup;
  final Map<String, String> dockerImages;
}

final class PterodactylServerDeployment {
  PterodactylServerDeployment({
    required List<int> locationIds,
    required this.dedicatedIp,
    required List<String> portRanges,
  }) : locationIds = List<int>.unmodifiable(locationIds),
       portRanges = List<String>.unmodifiable(portRanges);

  final List<int> locationIds;
  final bool dedicatedIp;
  final List<String> portRanges;

  JsonObject toJson() => <String, Object?>{
    'locations': locationIds,
    'dedicated_ip': dedicatedIp,
    'port_range': portRanges,
  };
}

final class PterodactylCreateServerRequest {
  PterodactylCreateServerRequest({
    required this.name,
    required this.ownerId,
    required this.eggId,
    required this.dockerImage,
    required this.startup,
    required Map<String, String> environment,
    required this.limits,
    required this.featureLimits,
    this.description,
    this.externalId,
    this.defaultAllocationId,
    List<int> additionalAllocationIds = const <int>[],
    this.deployment,
    this.startOnCompletion = false,
    this.skipScripts = false,
    this.oomDisabled = false,
  }) : environment = UnmodifiableMapView<String, String>(
         Map<String, String>.from(environment),
       ),
       additionalAllocationIds = List<int>.unmodifiable(
         additionalAllocationIds,
       ) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if ((defaultAllocationId == null) == (deployment == null)) {
      throw ArgumentError(
        'Provide exactly one of defaultAllocationId or deployment.',
      );
    }
  }

  final String name;
  final String? description;
  final String? externalId;
  final int ownerId;
  final int eggId;
  final String dockerImage;
  final String startup;
  final Map<String, String> environment;
  final PterodactylServerLimits limits;
  final PterodactylFeatureLimits featureLimits;
  final int? defaultAllocationId;
  final List<int> additionalAllocationIds;
  final PterodactylServerDeployment? deployment;
  final bool startOnCompletion;
  final bool skipScripts;
  final bool oomDisabled;

  JsonObject toJson() => <String, Object?>{
    if (externalId != null) 'external_id': externalId,
    'name': name,
    if (description != null) 'description': description,
    'user': ownerId,
    'egg': eggId,
    'docker_image': dockerImage,
    'startup': startup,
    'environment': environment,
    'limits': limits.toJson(),
    'feature_limits': featureLimits.toJson(),
    if (defaultAllocationId != null)
      'allocation': <String, Object?>{
        'default': defaultAllocationId,
        if (additionalAllocationIds.isNotEmpty)
          'additional': additionalAllocationIds,
      },
    if (deployment != null) 'deploy': deployment!.toJson(),
    'start_on_completion': startOnCompletion,
    'skip_scripts': skipScripts,
    'oom_disabled': oomDisabled,
  };
}

Map<String, String> _requiredEnvironmentMap(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is! Map<Object?, Object?>) {
    throw FormatException('Expected "$key" to be an object.');
  }
  final Map<String, String> result = <String, String>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('Expected "$key" keys to be strings.');
    }
    final Object? value = entry.value;
    if (value is String) {
      result[entry.key! as String] = value;
    } else if (value is num || value is bool) {
      // Current Panels expose a handful of generated P_SERVER_* values as
      // JSON numbers even though create requests accept environment strings.
      // Preserve scalar meaning while keeping the creation model strongly
      // typed; structured and null values remain protocol errors.
      result[entry.key! as String] = value.toString();
    } else {
      throw FormatException('Expected "$key" values to be scalar.');
    }
  }
  return result;
}

JsonObject _requiredObject(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is Map<Object?, Object?>) {
    return value.map<String, Object?>(
      (Object? key, Object? value) => MapEntry<String, Object?>(
        key is String ? key : key.toString(),
        value,
      ),
    );
  }
  throw FormatException('Expected "$key" to be an object.');
}

JsonObject _optionalObject(JsonObject json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return <String, Object?>{};
  }
  return _requiredObject(json, key);
}

String _requiredString(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected "$key" to be a string.');
}

String? _nullableString(JsonObject json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('Expected "$key" to be a string or null.');
}

int _requiredInt(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is num) {
    return value.toInt();
  }
  throw FormatException('Expected "$key" to be a number.');
}

int? _nullableInt(JsonObject json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toInt();
  }
  throw FormatException('Expected "$key" to be a number or null.');
}

double _requiredDouble(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('Expected "$key" to be a number.');
}

bool _optionalBool(JsonObject json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return false;
  }
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected "$key" to be a boolean.');
}

List<JsonObject> _relationshipItems(
  JsonObject relationships,
  String relationship,
) {
  final Object? resourceValue = relationships[relationship];
  if (resourceValue == null) {
    return const <JsonObject>[];
  }
  if (resourceValue is! Map<Object?, Object?>) {
    throw FormatException('Expected "$relationship" relationship object.');
  }
  final Object? dataValue = resourceValue['data'];
  if (dataValue is! List<Object?>) {
    throw FormatException('Expected "$relationship.data" to be a list.');
  }
  return dataValue
      .map<JsonObject>((Object? resource) {
        if (resource is! Map<Object?, Object?>) {
          throw FormatException(
            'Expected relationship resource to be an object.',
          );
        }
        final Object? attributes = resource['attributes'];
        if (attributes is! Map<Object?, Object?>) {
          throw FormatException('Expected relationship attributes object.');
        }
        return attributes.map<String, Object?>(
          (Object? key, Object? value) => MapEntry<String, Object?>(
            key is String ? key : key.toString(),
            value,
          ),
        );
      })
      .toList(growable: false);
}
