import 'dart:collection';
import 'dart:convert';

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

enum PterodactylBulkAction {
  start,
  stop,
  restart,
  kill,
  reinstall,
  delete,
  create,
}

enum PterodactylBulkServerState { running, offline }

final class PterodactylBulkItemResult {
  const PterodactylBulkItemResult({
    required this.target,
    required this.name,
    required this.identifier,
    required this.succeeded,
    this.error,
  });

  /// Stable input for this item: an identifier for existing servers or the
  /// requested name for a create operation.
  final String target;
  final String name;
  final String? identifier;
  final bool succeeded;
  final String? error;
}

final class PterodactylBulkResult {
  PterodactylBulkResult({
    required this.action,
    required List<PterodactylBulkItemResult> items,
  }) : items = List<PterodactylBulkItemResult>.unmodifiable(items);

  final PterodactylBulkAction action;
  final List<PterodactylBulkItemResult> items;

  int get totalCount => items.length;
  int get succeededCount =>
      items.where((PterodactylBulkItemResult item) => item.succeeded).length;
  int get failedCount => totalCount - succeededCount;
  bool get isSuccess => items.isNotEmpty && failedCount == 0;
}

enum PterodactylServerPermission {
  activityRead('activity.read'),
  settingsRename('settings.rename'),
  settingsReinstall('settings.reinstall'),
  startupRead('startup.read'),
  startupUpdate('startup.update'),
  startupDockerImage('startup.docker-image');

  const PterodactylServerPermission(this.wireValue);

  final String wireValue;
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
    this.invocation = '',
    this.dockerImage = '',
    this.skipScripts = false,
    List<PterodactylStartupVariable> variables =
        const <PterodactylStartupVariable>[],
  }) : allocations = List<PterodactylAllocation>.unmodifiable(allocations),
       variables = List<PterodactylStartupVariable>.unmodifiable(variables);

  factory PterodactylClientServer.fromJson(JsonObject json) {
    final JsonObject sftp = _requiredObject(json, 'sftp_details');
    final JsonObject relationships = _optionalObject(json, 'relationships');
    final List<PterodactylAllocation> allocations = _relationshipItems(
      relationships,
      'allocations',
    ).map(PterodactylAllocation.fromClientJson).toList(growable: false);
    final List<PterodactylStartupVariable> variables = _relationshipItems(
      relationships,
      'variables',
    ).map(PterodactylStartupVariable.fromJson).toList(growable: false);

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
      invocation: _nullableString(json, 'invocation') ?? '',
      dockerImage: _nullableString(json, 'docker_image') ?? '',
      skipScripts: _optionalBool(json, 'skip_scripts'),
      variables: variables,
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
  final String invocation;
  final String dockerImage;
  final bool skipScripts;
  final List<PterodactylStartupVariable> variables;

  PterodactylAllocation? get primaryAllocation {
    for (final PterodactylAllocation allocation in allocations) {
      if (allocation.isDefault) {
        return allocation;
      }
    }
    return allocations.isEmpty ? null : allocations.first;
  }
}

final class PterodactylClientServerAccess {
  PterodactylClientServerAccess({
    required this.server,
    required this.isOwner,
    required Iterable<String> permissions,
  }) : permissions = Set<String>.unmodifiable(permissions);

  final PterodactylClientServer server;
  final bool isOwner;
  final Set<String> permissions;

  bool allows(PterodactylServerPermission permission) =>
      isOwner ||
      permissions.contains('*') ||
      permissions.contains(permission.wireValue);
}

final class PterodactylStartupVariable {
  const PterodactylStartupVariable({
    required this.name,
    required this.environmentVariable,
    required this.isEditable,
    required this.rules,
    this.description,
    this.defaultValue,
    this.serverValue,
  });

  factory PterodactylStartupVariable.fromJson(JsonObject json) {
    return PterodactylStartupVariable(
      name: _requiredString(json, 'name'),
      description: _nullableString(json, 'description'),
      environmentVariable: _requiredString(json, 'env_variable'),
      defaultValue: _nullableString(json, 'default_value'),
      serverValue: _nullableString(json, 'server_value'),
      isEditable: _optionalBool(json, 'is_editable'),
      rules: _requiredString(json, 'rules'),
    );
  }

  final String name;
  final String? description;
  final String environmentVariable;
  final String? defaultValue;
  final String? serverValue;
  final bool isEditable;
  final String rules;
}

final class PterodactylServerStartup {
  PterodactylServerStartup({
    required this.startupCommand,
    required this.rawStartupCommand,
    required Map<String, String> dockerImages,
    required List<PterodactylStartupVariable> variables,
  }) : dockerImages = UnmodifiableMapView<String, String>(
         Map<String, String>.from(dockerImages),
       ),
       variables = List<PterodactylStartupVariable>.unmodifiable(variables);

  factory PterodactylServerStartup.fromJson(
    JsonObject meta,
    List<JsonObject> variables,
  ) {
    return PterodactylServerStartup(
      startupCommand: _requiredString(meta, 'startup_command'),
      rawStartupCommand: _requiredString(meta, 'raw_startup_command'),
      dockerImages: _requiredStringMap(meta, 'docker_images'),
      variables: variables
          .map(PterodactylStartupVariable.fromJson)
          .toList(growable: false),
    );
  }

  final String startupCommand;
  final String rawStartupCommand;
  final Map<String, String> dockerImages;
  final List<PterodactylStartupVariable> variables;
}

final class PterodactylActivity {
  PterodactylActivity({
    required this.id,
    required this.event,
    required this.isApi,
    required this.description,
    required Map<String, Object?> properties,
    required this.hasAdditionalMetadata,
    required this.timestamp,
    this.batch,
    this.ip,
  }) : properties = UnmodifiableMapView<String, Object?>(
         Map<String, Object?>.from(properties),
       );

  factory PterodactylActivity.fromJson(JsonObject json) {
    final String timestamp = _requiredString(json, 'timestamp');
    final DateTime? parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException('Expected "timestamp" to be ISO-8601.');
    }
    return PterodactylActivity(
      id: _requiredString(json, 'id'),
      batch: _nullableString(json, 'batch'),
      event: _requiredString(json, 'event'),
      isApi: _optionalBool(json, 'is_api'),
      ip: _nullableString(json, 'ip'),
      description: _nullableString(json, 'description') ?? '',
      properties: _optionalObject(json, 'properties'),
      hasAdditionalMetadata: _optionalBool(json, 'has_additional_metadata'),
      timestamp: parsedTimestamp,
    );
  }

  final String id;
  final String? batch;
  final String event;
  final bool isApi;
  final String? ip;
  final String description;
  final Map<String, Object?> properties;
  final bool hasAdditionalMetadata;
  final DateTime timestamp;
}

/// Minimal account identity returned by the Client API. Multiplexor only
/// retains the username needed to address this account over SFTP.
final class PterodactylAccount {
  const PterodactylAccount({required this.username});

  factory PterodactylAccount.fromJson(JsonObject json) =>
      PterodactylAccount(username: _requiredString(json, 'username'));

  final String username;
}

final class PterodactylAccountSshKey {
  PterodactylAccountSshKey({
    required this.name,
    required this.fingerprint,
    required String publicKey,
    required this.createdAt,
  }) : publicKey = normalizePublicKey(publicKey);

  factory PterodactylAccountSshKey.fromJson(JsonObject json) {
    final DateTime? createdAt = DateTime.tryParse(
      _requiredString(json, 'created_at'),
    );
    if (createdAt == null) {
      throw const FormatException('Expected "created_at" to be ISO-8601.');
    }
    return PterodactylAccountSshKey(
      name: _requiredString(json, 'name'),
      fingerprint: _requiredString(json, 'fingerprint'),
      publicKey: _requiredString(json, 'public_key'),
      createdAt: createdAt,
    );
  }

  final String name;
  final String fingerprint;
  final String publicKey;
  final DateTime createdAt;

  /// Normalizes transport-only whitespace without trying to reinterpret key
  /// material. Pterodactyl performs the cryptographic validation and returns
  /// the canonical public key used for future idempotence checks.
  static String normalizePublicKey(String value) {
    final String normalized = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (normalized.isEmpty ||
        normalized.length > 16384 ||
        normalized.contains('\u0000')) {
      throw ArgumentError(
        'publicKey must be non-empty valid public key material.',
      );
    }
    final RegExpMatch? ed25519 = RegExp(
      r'^ssh-ed25519[ \t]+([A-Za-z0-9+/]+={0,2})(?:[ \t]+.*)?$',
    ).firstMatch(normalized);
    if (normalized.startsWith('ssh-ed25519') && ed25519 == null) {
      throw ArgumentError('publicKey is not valid ed25519 key material.');
    }
    if (ed25519 != null) {
      try {
        return _ed25519Pkcs8(base64.decode(ed25519.group(1)!));
      } on FormatException {
        throw ArgumentError('publicKey is not valid ed25519 key material.');
      } on RangeError {
        throw ArgumentError('publicKey is not valid ed25519 key material.');
      }
    }
    return normalized;
  }

  static String _ed25519Pkcs8(List<int> blob) {
    int readLength(int offset) {
      if (offset + 4 > blob.length) throw RangeError('invalid key');
      return (blob[offset] << 24) |
          (blob[offset + 1] << 16) |
          (blob[offset + 2] << 8) |
          blob[offset + 3];
    }

    final int typeLength = readLength(0);
    final int typeStart = 4;
    final int typeEnd = typeStart + typeLength;
    if (typeLength != 11 ||
        typeEnd + 4 > blob.length ||
        ascii.decode(blob.sublist(typeStart, typeEnd)) != 'ssh-ed25519') {
      throw const FormatException();
    }
    final int keyLength = readLength(typeEnd);
    final int keyStart = typeEnd + 4;
    if (keyLength != 32 || keyStart + keyLength != blob.length) {
      throw const FormatException();
    }
    final List<int> der = <int>[
      0x30,
      0x2a,
      0x30,
      0x05,
      0x06,
      0x03,
      0x2b,
      0x65,
      0x70,
      0x03,
      0x21,
      0x00,
      ...blob.sublist(keyStart),
    ];
    return '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n'
        '-----END PUBLIC KEY-----';
  }

  @override
  String toString() =>
      'PterodactylAccountSshKey(name: $name, fingerprint: $fingerprint, '
      'publicKey: [REDACTED], createdAt: $createdAt)';
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
    required this.skipScripts,
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
      skipScripts: _optionalBool(container, 'skip_scripts'),
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
  final bool skipScripts;
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
    this.memoryOverallocatePercent = 0,
    this.diskOverallocatePercent = 0,
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
      memoryOverallocatePercent: _nullableInt(json, 'memory_overallocate') ?? 0,
      diskOverallocatePercent: _nullableInt(json, 'disk_overallocate') ?? 0,
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
  final int memoryOverallocatePercent;
  final int diskOverallocatePercent;
  final int allocatedMemoryMiB;
  final int allocatedDiskMiB;
  final int daemonPort;
  final int sftpPort;

  /// Null mirrors the Panel's `-1` setting, which disables memory capacity
  /// checks for automatic placement.
  int? get maximumAllocatedMemoryMiB => memoryOverallocatePercent == -1
      ? null
      : memoryMiB * (100 + memoryOverallocatePercent) ~/ 100;

  /// Null mirrors the Panel's `-1` setting, which disables disk capacity
  /// checks for automatic placement.
  int? get maximumAllocatedDiskMiB => diskOverallocatePercent == -1
      ? null
      : diskMiB * (100 + diskOverallocatePercent) ~/ 100;
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
    List<PterodactylEggVariable> variables = const <PterodactylEggVariable>[],
    this.description,
  }) : dockerImages = UnmodifiableMapView<String, String>(
         Map<String, String>.from(dockerImages),
       ),
       variables = List<PterodactylEggVariable>.unmodifiable(variables);

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
    final JsonObject relationships = _optionalObject(json, 'relationships');
    final List<PterodactylEggVariable> variables = _relationshipItems(
      relationships,
      'variables',
    ).map(PterodactylEggVariable.fromJson).toList(growable: false);
    return PterodactylEgg(
      id: _requiredInt(json, 'id'),
      uuid: _requiredString(json, 'uuid'),
      name: _requiredString(json, 'name'),
      nestId: _requiredInt(json, 'nest'),
      author: _requiredString(json, 'author'),
      description: _nullableString(json, 'description'),
      startup: _nullableString(json, 'startup'),
      dockerImages: images,
      variables: variables,
    );
  }

  final int id;
  final String uuid;
  final String name;
  final int nestId;
  final String author;
  final String? description;

  /// Null means the egg cannot be used for server creation until an
  /// administrator configures a startup command on the Panel.
  final String? startup;
  final Map<String, String> dockerImages;
  final List<PterodactylEggVariable> variables;
}

final class PterodactylEggVariable {
  const PterodactylEggVariable({
    required this.name,
    required this.environmentVariable,
    required this.defaultValue,
    required this.rules,
    required this.userEditable,
    required this.userViewable,
    this.description,
  });

  factory PterodactylEggVariable.fromJson(JsonObject json) {
    return PterodactylEggVariable(
      name: _requiredString(json, 'name'),
      description: _nullableString(json, 'description'),
      environmentVariable: _requiredString(json, 'env_variable'),
      defaultValue: _nullableString(json, 'default_value') ?? '',
      rules: _requiredString(json, 'rules'),
      userEditable: _optionalBool(json, 'user_editable'),
      userViewable: _optionalBool(json, 'user_viewable'),
    );
  }

  final String name;
  final String? description;
  final String environmentVariable;
  final String defaultValue;
  final String rules;
  final bool userEditable;
  final bool userViewable;

  bool get isRequired => rules.split('|').contains('required');
}

final class PterodactylCreationCatalog {
  PterodactylCreationCatalog({
    required List<PterodactylApplicationServer> templates,
    required List<PterodactylUser> users,
    required List<PterodactylNode> nodes,
    required List<PterodactylNest> nests,
    required List<PterodactylEgg> eggs,
    required Map<int, List<PterodactylAllocation>> freeAllocationsByNode,
    this.recommendedOwnerId,
    this.eggInventoryUnavailablePermission,
  }) : templates = List<PterodactylApplicationServer>.unmodifiable(templates),
       users = List<PterodactylUser>.unmodifiable(users),
       nodes = List<PterodactylNode>.unmodifiable(nodes),
       nests = List<PterodactylNest>.unmodifiable(nests),
       eggs = List<PterodactylEgg>.unmodifiable(eggs),
       freeAllocationsByNode =
           UnmodifiableMapView<int, List<PterodactylAllocation>>(<
             int,
             List<PterodactylAllocation>
           >{
             for (final MapEntry<int, List<PterodactylAllocation>> entry
                 in freeAllocationsByNode.entries)
               entry.key: List<PterodactylAllocation>.unmodifiable(entry.value),
           });

  final List<PterodactylApplicationServer> templates;
  final List<PterodactylUser> users;
  final List<PterodactylNode> nodes;
  final List<PterodactylNest> nests;
  final List<PterodactylEgg> eggs;
  final Map<int, List<PterodactylAllocation>> freeAllocationsByNode;
  final int? recommendedOwnerId;

  /// The missing Application READ permission when an explicitly partial
  /// clone-capable catalog could not load nest/egg inventory.
  final String? eggInventoryUnavailablePermission;

  int freeAllocationCount(int nodeId) =>
      freeAllocationsByNode[nodeId]?.length ?? 0;
}

final class PterodactylEggCreatePlan {
  PterodactylEggCreatePlan({
    required this.ownerId,
    required this.nodeId,
    required this.eggId,
    required this.dockerImage,
    required this.startup,
    required Map<String, String> environment,
    this.memoryMiB = 4096,
    this.swapMiB = 0,
    this.diskMiB = 0,
    this.ioWeight = 500,
    this.cpuPercent = 0,
    this.databaseLimit = 0,
    this.allocationLimit = 0,
    this.backupLimit = 0,
    this.startOnCompletion = false,
  }) : environment = UnmodifiableMapView<String, String>(
         Map<String, String>.from(environment),
       ) {
    if (ownerId < 1 || nodeId < 1 || eggId < 1) {
      throw ArgumentError('Owner, node, and egg IDs must be positive.');
    }
    if (dockerImage.trim().isEmpty || startup.trim().isEmpty) {
      throw ArgumentError('Docker image and startup command are required.');
    }
    if (memoryMiB < 0 ||
        swapMiB < -1 ||
        diskMiB < 0 ||
        ioWeight < 10 ||
        ioWeight > 1000 ||
        cpuPercent < 0 ||
        databaseLimit < 0 ||
        allocationLimit < 0 ||
        backupLimit < 0) {
      throw ArgumentError('Creation resource limits are invalid.');
    }
  }

  final int ownerId;
  final int nodeId;
  final int eggId;
  final String dockerImage;
  final String startup;
  final Map<String, String> environment;
  final int memoryMiB;
  final int swapMiB;
  final int diskMiB;
  final int ioWeight;
  final int cpuPercent;
  final int databaseLimit;
  final int allocationLimit;
  final int backupLimit;
  final bool startOnCompletion;
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

final class PterodactylUpdateServerDetailsRequest {
  PterodactylUpdateServerDetailsRequest({
    required this.name,
    required this.ownerId,
    required this.description,
    required this.externalId,
  }) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if (ownerId < 1) {
      throw RangeError.range(ownerId, 1, null, 'ownerId');
    }
  }

  factory PterodactylUpdateServerDetailsRequest.fromServer(
    PterodactylApplicationServer server, {
    String? name,
    String? description,
  }) => PterodactylUpdateServerDetailsRequest(
    name: name ?? server.name,
    ownerId: server.ownerId,
    description: description ?? server.description,
    externalId: server.externalId,
  );

  final String name;
  final int ownerId;
  final String? description;
  final String? externalId;

  JsonObject toJson() => <String, Object?>{
    'external_id': externalId,
    'name': name,
    'user': ownerId,
    'description': description,
  };
}

final class PterodactylUpdateServerBuildRequest {
  PterodactylUpdateServerBuildRequest({
    required this.defaultAllocationId,
    required this.limits,
    required this.featureLimits,
    required this.oomDisabled,
    List<int> addAllocationIds = const <int>[],
    List<int> removeAllocationIds = const <int>[],
  }) : addAllocationIds = List<int>.unmodifiable(addAllocationIds),
       removeAllocationIds = List<int>.unmodifiable(removeAllocationIds) {
    if (defaultAllocationId < 1) {
      throw RangeError.range(
        defaultAllocationId,
        1,
        null,
        'defaultAllocationId',
      );
    }
    _validateLimits(limits);
    _validateFeatureLimit(featureLimits.databases, 'databases');
    _validateFeatureLimit(featureLimits.allocations, 'allocations');
    _validateFeatureLimit(featureLimits.backups, 'backups');
    _validateAllocationIds(addAllocationIds, 'addAllocationIds');
    _validateAllocationIds(removeAllocationIds, 'removeAllocationIds');
    if (addAllocationIds
        .toSet()
        .intersection(removeAllocationIds.toSet())
        .isNotEmpty) {
      throw ArgumentError(
        'An allocation cannot be added and removed in the same update.',
      );
    }
  }

  final int defaultAllocationId;
  final PterodactylServerLimits limits;
  final PterodactylFeatureLimits featureLimits;
  final bool oomDisabled;
  final List<int> addAllocationIds;
  final List<int> removeAllocationIds;

  JsonObject toJson() => <String, Object?>{
    'allocation': defaultAllocationId,
    'oom_disabled': oomDisabled,
    'limits': <String, Object?>{
      'memory': limits.memoryMiB,
      'swap': limits.swapMiB,
      'disk': limits.diskMiB,
      'io': limits.ioWeight,
      'cpu': limits.cpuPercent,
      'threads': limits.threads,
    },
    'feature_limits': featureLimits.toJson(),
    if (addAllocationIds.isNotEmpty) 'add_allocations': addAllocationIds,
    if (removeAllocationIds.isNotEmpty)
      'remove_allocations': removeAllocationIds,
  };

  static void _validateLimits(PterodactylServerLimits limits) {
    if (limits.memoryMiB < 0) {
      throw RangeError.range(limits.memoryMiB, 0, null, 'memoryMiB');
    }
    if (limits.swapMiB < -1) {
      throw RangeError.range(limits.swapMiB, -1, null, 'swapMiB');
    }
    if (limits.diskMiB < 0) {
      throw RangeError.range(limits.diskMiB, 0, null, 'diskMiB');
    }
    if (limits.ioWeight < 10 || limits.ioWeight > 1000) {
      throw RangeError.range(limits.ioWeight, 10, 1000, 'ioWeight');
    }
    if (limits.cpuPercent < 0) {
      throw RangeError.range(limits.cpuPercent, 0, null, 'cpuPercent');
    }
  }

  static void _validateAllocationIds(List<int> values, String name) {
    for (final int value in values) {
      if (value < 1) throw RangeError.range(value, 1, null, name);
    }
    if (values.toSet().length != values.length) {
      throw ArgumentError.value(values, name, 'must not contain duplicates');
    }
  }

  static void _validateFeatureLimit(int? value, String name) {
    if (value != null && value < 0) {
      throw RangeError.range(value, 0, null, name);
    }
  }
}

final class PterodactylUpdateServerStartupRequest {
  PterodactylUpdateServerStartupRequest({
    required this.startup,
    required Map<String, String> environment,
    required this.eggId,
    required this.dockerImage,
    required this.skipScripts,
  }) : environment = UnmodifiableMapView<String, String>(
         Map<String, String>.from(environment),
       ) {
    if (startup.trim().isEmpty) {
      throw ArgumentError.value(startup, 'startup', 'must not be empty');
    }
    if (eggId < 1) throw RangeError.range(eggId, 1, null, 'eggId');
    if (dockerImage.trim().isEmpty) {
      throw ArgumentError.value(
        dockerImage,
        'dockerImage',
        'must not be empty',
      );
    }
  }

  final String startup;
  final Map<String, String> environment;
  final int eggId;
  final String dockerImage;
  final bool skipScripts;

  JsonObject toJson() => <String, Object?>{
    'startup': startup,
    'environment': environment,
    'egg': eggId,
    'image': dockerImage,
    'skip_scripts': skipScripts,
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

Map<String, String> _requiredStringMap(JsonObject json, String key) {
  final Object? rawValue = json[key];
  if (rawValue is List<Object?> && rawValue.isEmpty) {
    return <String, String>{};
  }
  final JsonObject value = _requiredObject(json, key);
  final Map<String, String> result = <String, String>{};
  for (final MapEntry<String, Object?> entry in value.entries) {
    if (entry.value is! String) {
      throw FormatException('Expected "$key" values to be strings.');
    }
    result[entry.key] = entry.value! as String;
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
