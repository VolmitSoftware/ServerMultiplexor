import 'pterodactyl_client.dart';
import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_console_session.dart';
import 'pterodactyl_credential.dart';
import 'pterodactyl_credential_store.dart';
import 'pterodactyl_errors.dart';
import 'pterodactyl_models.dart';
import 'pterodactyl_profile.dart';
import 'pterodactyl_profile_store.dart';

enum PterodactylCapability { view, power, console, create }

final class PterodactylVerification {
  const PterodactylVerification({
    required this.profile,
    required this.serverCount,
    required this.capabilities,
    required this.warnings,
    this.nodeCount,
  });

  final PterodactylProfile profile;
  final int serverCount;
  final int? nodeCount;
  final Set<PterodactylCapability> capabilities;
  final List<String> warnings;
}

final class PterodactylFleetSample {
  const PterodactylFleetSample({required this.server, this.resources});

  final PterodactylClientServer server;
  final PterodactylResourceUsage? resources;
}

/// High-level connection boundary used by the CLI and the Remote dashboard.
///
/// Profiles are non-secret files. Bearer values are resolved immediately
/// before a request and are never returned by any public method.
final class PterodactylService {
  PterodactylService({
    required PterodactylProfileStore profileStore,
    required PterodactylCredentialStore credentialStore,
  }) : _profileStore = profileStore,
       _credentialStore = credentialStore;

  final PterodactylProfileStore _profileStore;
  final PterodactylCredentialStore _credentialStore;
  final Map<String, PterodactylClientServerScope> _serverScopes =
      <String, PterodactylClientServerScope>{};

  List<PterodactylProfile> listProfiles() => _profileStore.loadAll();

  PterodactylProfile? profile(String id) => _profileStore.load(id);

  PterodactylProfile saveProfile(PterodactylProfile profile) {
    _forgetScope(profile.id);
    _profileStore.save(profile);
    return profile;
  }

  Future<bool> hasClientCredential(PterodactylProfile profile) =>
      _credentialStore.contains(profile, PterodactylCredentialRole.client);

  Future<bool> hasApplicationCredential(PterodactylProfile profile) =>
      _credentialStore.contains(profile, PterodactylCredentialRole.application);

  Future<void> enrollCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    await _credentialStore.enroll(profile, role);
    _forgetScope(profile.id);
  }

  Future<void> removeCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    await _credentialStore.remove(profile, role);
    _forgetScope(profile.id);
  }

  Future<PterodactylCredential?> credentialForRollback(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) => _credentialStore.read(profile, role);

  Future<void> restoreCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
    PterodactylCredential credential,
  ) async {
    await _credentialStore.restore(profile, role, credential);
    _forgetScope(profile.id);
  }

  Future<void> removeProfile(String id) async {
    final PterodactylProfile? existing = profile(id);
    if (existing != null) {
      await _credentialStore.remove(existing, PterodactylCredentialRole.client);
      await _credentialStore.remove(
        existing,
        PterodactylCredentialRole.application,
      );
    }
    _forgetScope(id);
    _profileStore.remove(id);
  }

  bool canUseAsTemplate(String profileId, PterodactylClientServer server) =>
      server.isOwner ||
      _serverScopes[_scopeKey(_requireProfile(profileId))] ==
          PterodactylClientServerScope.adminAll;

  Future<PterodactylVerification> verify(String id) =>
      verifyProfile(_requireProfile(id));

  /// Verifies an unsaved candidate profile so enrollment can be completed
  /// transactionally before non-secret profile metadata is committed.
  Future<PterodactylVerification> verifyProfile(
    PterodactylProfile target,
  ) async {
    final _ClientHandle handle = await _clientFor(target);
    _ClientHandle? applicationHandle;
    try {
      final List<PterodactylClientServer> servers = await _listServers(
        handle.client,
        target,
      );
      final Set<PterodactylCapability> capabilities = <PterodactylCapability>{
        PterodactylCapability.view,
        PterodactylCapability.power,
        PterodactylCapability.console,
      };
      final List<String> warnings = <String>[];
      int? nodeCount;
      try {
        applicationHandle = await _applicationClientFor(target);
      } on PterodactylApiException catch (error) {
        if (!error.isUnauthorized) rethrow;
        warnings.add(
          'Remote creation needs a root-admin Client key or an Application '
          'key with Servers read/write access.',
        );
      }
      final _ClientHandle? verifiedApplicationHandle = applicationHandle;
      if (verifiedApplicationHandle != null) {
        try {
          final List<PterodactylNode> nodes = await verifiedApplicationHandle
              .client
              .listAllApplicationNodes();
          nodeCount = nodes.length;
          if (nodes.isEmpty) {
            warnings.add('Remote creation needs at least one Panel node.');
          } else {
            // Creation also needs allocation read access. Checking it here
            // prevents a read-only Servers key from being advertised as
            // creation-ready merely because it can list server templates.
            await verifiedApplicationHandle.client.listNodeAllocations(
              nodes.first.id,
              perPage: 1,
            );
            capabilities.add(PterodactylCapability.create);
            if (verifiedApplicationHandle.hasDedicatedApplicationCredential) {
              warnings.add(
                'Application API read prerequisites are verified; Servers '
                'write permission is confirmed when a server is created.',
              );
            }
          }
          for (final PterodactylNode node in nodes) {
            if (node.diskMiB > 0 && node.allocatedDiskMiB > node.diskMiB * 2) {
              final String nodeName = _safeProviderText(node.name);
              warnings.add(
                'Node $nodeName has ${node.allocatedDiskMiB} MiB assigned '
                'against ${node.diskMiB} MiB configured disk; creation may '
                'fail unless that over-allocation is intentional.',
              );
            }
          }
        } on PterodactylApiException catch (error) {
          if (!error.isUnauthorized) rethrow;
          warnings.add(
            'Node or allocation inventory is not granted to this API key.',
          );
        }
      }
      return PterodactylVerification(
        profile: target,
        serverCount: servers.length,
        nodeCount: nodeCount,
        capabilities: Set<PterodactylCapability>.unmodifiable(capabilities),
        warnings: List<String>.unmodifiable(warnings),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<List<PterodactylClientServer>> listServers(String id) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      return await _listServers(handle.client, profile);
    } finally {
      handle.client.close();
    }
  }

  /// Captures the full remote fleet with one authenticated client and
  /// bounded parallel resource requests. A single unavailable server keeps
  /// its inventory row with null resources instead of hiding the fleet.
  Future<List<PterodactylFleetSample>> captureFleet(String id) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      final List<PterodactylClientServer> servers = await _listServers(
        handle.client,
        profile,
      );
      final List<PterodactylFleetSample> result = <PterodactylFleetSample>[];
      const int concurrency = 4;
      for (int offset = 0; offset < servers.length; offset += concurrency) {
        final int end = offset + concurrency < servers.length
            ? offset + concurrency
            : servers.length;
        result.addAll(
          await Future.wait<PterodactylFleetSample>(
            servers.sublist(offset, end).map((
              PterodactylClientServer server,
            ) async {
              try {
                final PterodactylResourceUsage resources = await handle.client
                    .getServerResources(server.identifier);
                return PterodactylFleetSample(
                  server: server,
                  resources: resources,
                );
              } on PterodactylApiException catch (error) {
                // A revoked key or a panel-wide throttle is not a per-server
                // telemetry gap. Let the feed retain its last good snapshot
                // and surface the connection error instead of erasing every
                // metric one row at a time.
                if (error.statusCode == 401 || error.isRateLimited) {
                  rethrow;
                }
                return PterodactylFleetSample(server: server);
              } on PterodactylException {
                return PterodactylFleetSample(server: server);
              }
            }),
          ),
        );
      }
      return List<PterodactylFleetSample>.unmodifiable(result);
    } finally {
      handle.client.close();
    }
  }

  Future<List<PterodactylNode>> listNodes(String id) async {
    final _ClientHandle handle = await _applicationClientFor(
      _requireProfile(id),
    );
    try {
      return await handle.client.listAllApplicationNodes();
    } finally {
      handle.client.close();
    }
  }

  Future<PterodactylResourceUsage> resources(
    String id,
    String identifier,
  ) async {
    final _ClientHandle handle = await _clientFor(_requireProfile(id));
    try {
      return await handle.client.getServerResources(identifier);
    } finally {
      handle.client.close();
    }
  }

  Future<void> power(
    String id,
    String identifier,
    PterodactylPowerSignal signal,
  ) async {
    final _ClientHandle handle = await _clientFor(_requireProfile(id));
    try {
      await handle.client.sendPowerSignal(identifier, signal);
    } finally {
      handle.client.close();
    }
  }

  Future<void> command(String id, String identifier, String command) async {
    final _ClientHandle handle = await _clientFor(_requireProfile(id));
    try {
      await handle.client.sendConsoleCommand(identifier, command);
    } finally {
      handle.client.close();
    }
  }

  /// Creates an unstarted Wings console and retains the API client for token
  /// refreshes until the console reaches its terminal lifecycle state. The
  /// caller starts it with [PterodactylConsoleConnection.connect].
  Future<PterodactylConsoleConnection> openConsole(
    String id,
    String identifier, {
    PterodactylConsoleSocketConnector connector =
        const DartIoPterodactylConsoleSocketConnector(),
  }) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    final PterodactylConsoleSession session;
    try {
      session = PterodactylConsoleSession(
        profile: profile,
        serverIdentifier: identifier,
        loadCredentials: handle.client.getServerWebsocketCredentials,
        connector: connector,
      );
    } catch (_) {
      handle.client.close();
      rethrow;
    }
    return _OwnedPterodactylConsoleConnection(session, handle.client);
  }

  /// Creates a remote instance by cloning the immutable launch/resource
  /// shape of an existing server and assigning up to two free ports on that
  /// server's node. Server data, schedules and backups are not copied.
  Future<PterodactylApplicationServer> createFromTemplate({
    required String profileId,
    required String template,
    required String name,
    int? memoryMiB,
    int? diskMiB,
    int? cpuPercent,
    bool startOnCompletion = false,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final List<PterodactylClientServer> clientServers = await _listServers(
        handle.client,
        profile,
      );
      final PterodactylClientServer clientTemplate = _resolveServer(
        clientServers,
        template,
      );
      if (!canUseAsTemplate(profileId, clientTemplate)) {
        throw StateError(
          'That server is shared with this account and cannot safely own a '
          'clone. Choose a server you own.',
        );
      }
      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer applicationTemplate =
          await applicationHandle.client.getApplicationServer(
            clientTemplate.internalId,
          );
      final List<PterodactylAllocation> allocations = await applicationHandle
          .client
          .listAllNodeAllocations(applicationTemplate.nodeId);
      final List<PterodactylAllocation> free =
          allocations
              .where(
                (PterodactylAllocation allocation) =>
                    allocation.isAssigned == false,
              )
              .toList()
            ..sort(
              (PterodactylAllocation a, PterodactylAllocation b) =>
                  a.port.compareTo(b.port),
            );
      if (free.isEmpty) {
        throw StateError(
          'A free allocation is required to create a remote instance.',
        );
      }

      final Map<String, String> environment = <String, String>{
        for (final MapEntry<String, String> entry
            in applicationTemplate.environment.entries)
          if (!entry.key.startsWith('P_SERVER_') && entry.key != 'STARTUP')
            entry.key: entry.value,
      };
      final PterodactylServerLimits limits = applicationTemplate.limits;
      return await applicationHandle.client.createApplicationServer(
        PterodactylCreateServerRequest(
          name: name,
          description:
              'Created by Multiplexor from ${applicationTemplate.name}.',
          ownerId: applicationTemplate.ownerId,
          eggId: applicationTemplate.eggId,
          dockerImage: applicationTemplate.image,
          startup: applicationTemplate.startup,
          environment: environment,
          limits: PterodactylServerLimits(
            memoryMiB: memoryMiB ?? limits.memoryMiB,
            swapMiB: limits.swapMiB,
            diskMiB: diskMiB ?? limits.diskMiB,
            ioWeight: limits.ioWeight,
            cpuPercent: cpuPercent ?? limits.cpuPercent,
            threads: limits.threads,
            oomDisabled: limits.oomDisabled,
          ),
          featureLimits: applicationTemplate.featureLimits,
          defaultAllocationId: free[0].id,
          additionalAllocationIds: free.length > 1
              ? <int>[free[1].id]
              : const <int>[],
          startOnCompletion: startOnCompletion,
          oomDisabled: limits.oomDisabled,
        ),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  PterodactylProfile _requireProfile(String id) {
    final PterodactylProfile? result = profile(id);
    if (result == null) {
      throw StateError('Unknown Pterodactyl profile: $id');
    }
    return result;
  }

  /// Uses Pterodactyl's admin-all view when the Client key is a root-admin
  /// key, while retaining ordinary owner/subuser behavior for every other
  /// key. Pterodactyl intentionally answers a non-admin admin-all probe with
  /// an empty list, so the probe does not disclose or mutate anything.
  Future<List<PterodactylClientServer>> _listServers(
    PterodactylClient client,
    PterodactylProfile profile,
  ) async {
    final String scopeKey = _scopeKey(profile);
    final PterodactylClientServerScope? known = _serverScopes[scopeKey];
    if (known != null) {
      return client.listAllClientServers(scope: known);
    }

    final List<PterodactylClientServer> accessible = await client
        .listAllClientServers();
    try {
      final List<PterodactylClientServer> adminAll = await client
          .listAllClientServers(scope: PterodactylClientServerScope.adminAll);
      if (adminAll.isNotEmpty) {
        _serverScopes[scopeKey] = PterodactylClientServerScope.adminAll;
        return adminAll;
      }
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
    }
    _serverScopes[scopeKey] = PterodactylClientServerScope.accessible;
    return accessible;
  }

  static String _scopeKey(PterodactylProfile profile) =>
      '${profile.id}\n${profile.origin}';

  void _forgetScope(String profileId) {
    _serverScopes.removeWhere(
      (String key, PterodactylClientServerScope _) =>
          key.startsWith('$profileId\n'),
    );
  }

  /// Selects the least-involved credential that can reach Application routes.
  /// Modern root-admin Client keys work directly; only a rejected one causes
  /// the optional dedicated Application credential to be read from Keychain.
  Future<_ClientHandle> _applicationClientFor(
    PterodactylProfile profile,
  ) async {
    final _ClientHandle clientHandle = await _clientFor(profile);
    try {
      await clientHandle.client.listApplicationServers(perPage: 1);
      return clientHandle;
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) {
        clientHandle.client.close();
        rethrow;
      }
      clientHandle.client.close();

      final _ClientHandle applicationHandle = await _clientFor(
        profile,
        includeDedicatedApplicationCredential: true,
      );
      if (!applicationHandle.hasDedicatedApplicationCredential) {
        applicationHandle.client.close();
        rethrow;
      }
      try {
        await applicationHandle.client.listApplicationServers(perPage: 1);
        return applicationHandle;
      } catch (_) {
        applicationHandle.client.close();
        rethrow;
      }
    } catch (_) {
      clientHandle.client.close();
      rethrow;
    }
  }

  /// The REST resources endpoint is cached for 20 seconds. Larger fleets
  /// need a longer cadence to stay comfortably below the Panel's default
  /// request limit because each sweep performs one inventory request plus
  /// one resources request per server.
  static Duration recommendedPollInterval(int serverCount) {
    // Panel 1.12.1+ defaults to 256 requests/minute, but older Panels used
    // 128 and operators can lower it. A 100-request target leaves useful
    // room for power, console-token and normal Panel traffic.
    const int targetRequestsPerMinute = 100;
    final int requestsPerSweep = serverCount < 0 ? 1 : serverCount + 1;
    final int seconds =
        (requestsPerSweep * 60 + targetRequestsPerMinute - 1) ~/
        targetRequestsPerMinute;
    return Duration(seconds: seconds < 20 ? 20 : seconds);
  }

  static String _safeProviderText(String value) =>
      PterodactylConsoleSanitizer.text(
        value,
      ).replaceAll(RegExp(r'[\r\n\t]'), ' ');

  static PterodactylClientServer _resolveServer(
    List<PterodactylClientServer> servers,
    String selector,
  ) {
    final String normalized = selector.trim().toLowerCase();
    final List<PterodactylClientServer> matches = servers
        .where(
          (PterodactylClientServer server) =>
              server.identifier.toLowerCase() == normalized ||
              server.uuid.toLowerCase() == normalized ||
              server.name.toLowerCase() == normalized,
        )
        .toList(growable: false);
    if (matches.length != 1) {
      throw StateError(
        matches.isEmpty
            ? 'No remote server matches: $selector'
            : 'Remote server name is ambiguous: $selector',
      );
    }
    return matches.single;
  }

  Future<_ClientHandle> _clientFor(
    PterodactylProfile profile, {
    bool includeDedicatedApplicationCredential = false,
  }) async {
    final PterodactylCredential? clientCredential = await _credentialStore.read(
      profile,
      PterodactylCredentialRole.client,
    );
    if (clientCredential == null) {
      throw StateError(
        'No Client API key enrolled for ${profile.id}. Run remote connect.',
      );
    }
    final PterodactylCredential? applicationCredential =
        includeDedicatedApplicationCredential
        ? await _credentialStore.read(
            profile,
            PterodactylCredentialRole.application,
          )
        : null;
    return _ClientHandle(
      client: PterodactylClient(
        baseUri: profile.panelUri,
        clientKey: clientCredential.value,
        applicationKey: applicationCredential?.value ?? clientCredential.value,
        trustedCertificatePath: profile.trustedCertificatePath,
      ),
      hasDedicatedApplicationCredential: applicationCredential != null,
    );
  }
}

final class _ClientHandle {
  const _ClientHandle({
    required this.client,
    required this.hasDedicatedApplicationCredential,
  });

  final PterodactylClient client;
  final bool hasDedicatedApplicationCredential;
}

/// Keeps token refresh available for the lifetime of the console, then closes
/// the API client for explicit close, remote disconnect, and connect failure.
final class _OwnedPterodactylConsoleConnection
    implements PterodactylConsoleConnection {
  _OwnedPterodactylConsoleConnection(this._delegate, PterodactylClient client)
    : done = _closeClientWhenDone(_delegate.done, client);

  final PterodactylConsoleConnection _delegate;

  @override
  final Future<void> done;

  @override
  Stream<PterodactylConsoleEvent> get events => _delegate.events;

  @override
  Future<void> connect() => _delegate.connect();

  @override
  Future<void> requestLogs() => _delegate.requestLogs();

  @override
  Future<void> requestStats() => _delegate.requestStats();

  @override
  Future<void> sendCommand(String command) => _delegate.sendCommand(command);

  @override
  Future<void> close() async {
    await _delegate.close();
    await done;
  }

  static Future<void> _closeClientWhenDone(
    Future<void> sessionDone,
    PterodactylClient client,
  ) async {
    try {
      await sessionDone;
    } finally {
      client.close();
    }
  }
}
