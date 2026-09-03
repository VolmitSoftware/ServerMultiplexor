import '../../utils/async_work_pool.dart';
import '../runtime_stop.dart';
import 'pterodactyl_client.dart';
import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_console_session.dart';
import 'pterodactyl_credential.dart';
import 'pterodactyl_credential_store.dart';
import 'pterodactyl_errors.dart';
import 'pterodactyl_models.dart';
import 'pterodactyl_profile.dart';
import 'pterodactyl_profile_store.dart';

typedef PterodactylClientFactory =
    PterodactylClient Function({
      required PterodactylProfile profile,
      required PterodactylCredential clientCredential,
      PterodactylCredential? applicationCredential,
    });

enum PterodactylCapability { view, power, console, create, configure, delete }

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

final class _BulkCreateTarget {
  const _BulkCreateTarget({
    required this.name,
    required this.defaultAllocationId,
    required this.additionalAllocationId,
  });

  final String name;
  final int defaultAllocationId;
  final int? additionalAllocationId;
}

final class _EggCreateOutcome {
  const _EggCreateOutcome({required this.item, this.server});

  final PterodactylBulkItemResult item;
  final PterodactylApplicationServer? server;
}

final class _EggCreateBatch {
  const _EggCreateBatch({required this.result, required this.outcomes});

  final PterodactylBulkResult result;
  final List<_EggCreateOutcome> outcomes;
}

/// High-level connection boundary used by the CLI and the Remote dashboard.
///
/// Profiles are non-secret files. Bearer values are resolved immediately
/// before a request and are never returned by any public method.
final class PterodactylService {
  PterodactylService({
    required PterodactylProfileStore profileStore,
    required PterodactylCredentialStore credentialStore,
    PterodactylClientFactory? clientFactory,
  }) : _profileStore = profileStore,
       _credentialStore = credentialStore,
       _clientFactory = clientFactory ?? _createClient;

  final PterodactylProfileStore _profileStore;
  final PterodactylCredentialStore _credentialStore;
  final PterodactylClientFactory _clientFactory;
  final Map<String, PterodactylClientServerScope> _serverScopes =
      <String, PterodactylClientServerScope>{};

  List<PterodactylProfile> listProfiles() => _profileStore.loadAll();

  PterodactylProfile? profile(String id) => _profileStore.load(id);

  PterodactylProfile? activeProfile() {
    final String? id = _profileStore.loadActiveId();
    return id == null ? null : _profileStore.load(id);
  }

  void selectProfile(String id) => _profileStore.setActive(id);

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

  Future<void> saveCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
    PterodactylCredential credential,
  ) async {
    await _credentialStore.save(profile, role, credential);
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
    if (existing == null) {
      _forgetScope(id);
      return;
    }

    // Snapshot everything before mutating either store. Profile metadata is
    // removed last, so a credential failure leaves the account discoverable;
    // a later profile-store failure restores every credential whose deletion
    // was attempted and rewrites the original profile when necessary.
    final String? activeId = _profileStore.loadActiveId();
    final PterodactylCredential? clientCredential = await _credentialStore.read(
      existing,
      PterodactylCredentialRole.client,
    );
    final PterodactylCredential? applicationCredential = await _credentialStore
        .read(existing, PterodactylCredentialRole.application);
    bool profileMutationAttempted = false;
    bool clientRemovalAttempted = false;
    bool applicationRemovalAttempted = false;

    try {
      if (clientCredential != null) {
        clientRemovalAttempted = true;
        await _credentialStore.remove(
          existing,
          PterodactylCredentialRole.client,
        );
      }
      if (applicationCredential != null) {
        applicationRemovalAttempted = true;
        await _credentialStore.remove(
          existing,
          PterodactylCredentialRole.application,
        );
      }
      profileMutationAttempted = true;
      if (!_profileStore.remove(id)) {
        _forgetScope(id);
        return;
      }
    } catch (error, stackTrace) {
      final List<Object> rollbackErrors = <Object>[];
      if (profileMutationAttempted) {
        try {
          _profileStore.save(existing);
          if (activeId != null) {
            _profileStore.setActive(activeId);
          }
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (clientRemovalAttempted && clientCredential != null) {
        try {
          await _credentialStore.restore(
            existing,
            PterodactylCredentialRole.client,
            clientCredential,
          );
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (applicationRemovalAttempted && applicationCredential != null) {
        try {
          await _credentialStore.restore(
            existing,
            PterodactylCredentialRole.application,
            applicationCredential,
          );
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (rollbackErrors.isNotEmpty) {
        throw StateError(
          'Pterodactyl profile removal failed and '
          '${rollbackErrors.length} rollback operation(s) also failed.',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    _forgetScope(id);
  }

  /// Returns creation inputs entirely through Application API authority.
  /// This remains useful when a new Panel has no servers in Client inventory.
  Future<PterodactylCreationCatalog> creationCatalog(
    String profileId, {
    bool allowPartialEggInventory = false,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final String clientUsername = await accountUsername(profileId);
    final _ClientHandle applicationHandle;
    try {
      applicationHandle = await _applicationClientFor(profile);
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      throw const PterodactylCreationCatalogPermissionException(
        permission: 'Servers READ',
      );
    }
    try {
      final List<PterodactylApplicationServer> templates =
          await _catalogResource(
            'Servers READ',
            applicationHandle.client.listAllApplicationServers,
          );
      final List<PterodactylUser> users = await _catalogResource(
        'Users READ',
        applicationHandle.client.listAllApplicationUsers,
      );
      final List<PterodactylNode> nodes = await _catalogResource(
        'Nodes READ',
        applicationHandle.client.listAllApplicationNodes,
      );
      List<PterodactylNest> nests = const <PterodactylNest>[];
      final List<PterodactylEgg> eggs = <PterodactylEgg>[];
      String? eggInventoryUnavailablePermission;
      try {
        nests = await _catalogResource(
          'Nests READ',
          applicationHandle.client.listAllApplicationNests,
        );
        for (final PterodactylNest nest in nests) {
          eggs.addAll(
            await _catalogResource(
              'Eggs READ',
              () => applicationHandle.client.listAllNestEggs(nest.id),
            ),
          );
        }
      } on PterodactylCreationCatalogPermissionException catch (error) {
        if (!allowPartialEggInventory || templates.isEmpty) rethrow;
        nests = const <PterodactylNest>[];
        eggs.clear();
        eggInventoryUnavailablePermission = error.permission;
      }
      final Map<int, List<PterodactylAllocation>> freeAllocations =
          <int, List<PterodactylAllocation>>{};
      for (final PterodactylNode node in nodes) {
        final List<PterodactylAllocation> free =
            (await _catalogResource(
                  'Allocations READ',
                  () =>
                      applicationHandle.client.listAllNodeAllocations(node.id),
                ))
                .where((PterodactylAllocation allocation) => allocation.isFree)
                .toList()
              ..sort(
                (PterodactylAllocation a, PterodactylAllocation b) =>
                    a.port.compareTo(b.port),
              );
        freeAllocations[node.id] = free;
      }
      return PterodactylCreationCatalog(
        templates: templates,
        users: users,
        nodes: nodes,
        nests: nests,
        eggs: eggs,
        freeAllocationsByNode: freeAllocations,
        eggInventoryUnavailablePermission: eggInventoryUnavailablePermission,
        recommendedOwnerId: users
            .where(
              (PterodactylUser user) =>
                  user.username.toLowerCase() == clientUsername.toLowerCase(),
            )
            .firstOrNull
            ?.id,
      );
    } finally {
      applicationHandle.client.close();
    }
  }

  /// Finds every Application server carrying [externalId].
  ///
  /// Create & Push recovery deliberately receives all exact matches so its
  /// coordinator can reject ambiguous Panel state rather than choosing one.
  Future<List<PterodactylApplicationServer>>
  findApplicationServersByExternalId({
    required String profileId,
    required String externalId,
  }) async {
    final String normalizedExternalId = externalId.trim();
    if (normalizedExternalId.isEmpty) {
      throw ArgumentError.value(externalId, 'externalId', 'must not be empty');
    }
    final _ClientHandle applicationHandle = await _applicationClientFor(
      _requireProfile(profileId),
    );
    try {
      final List<PterodactylApplicationServer> matches =
          (await applicationHandle.client.listAllApplicationServers())
              .where(
                (PterodactylApplicationServer server) =>
                    server.externalId == normalizedExternalId,
              )
              .toList(growable: false)
            ..sort(
              (
                PterodactylApplicationServer left,
                PterodactylApplicationServer right,
              ) => left.id.compareTo(right.id),
            );
      return List<PterodactylApplicationServer>.unmodifiable(matches);
    } finally {
      applicationHandle.client.close();
    }
  }

  static Future<T> _catalogResource<T>(
    String permission,
    Future<T> Function() request,
  ) async {
    try {
      return await request();
    } on PterodactylApiException catch (error) {
      if (!error.isUnauthorized) rethrow;
      throw PterodactylCreationCatalogPermissionException(
        permission: permission,
      );
    }
  }

  Future<PterodactylVerification> verify(String id) =>
      verifyProfile(_requireProfile(id));

  /// Verifies one stored credential through the API surface for its role.
  ///
  /// This is deliberately separate from [verifyProfile]: a root-admin Client
  /// key can satisfy Application routes itself, which would otherwise let a
  /// newly enrolled but invalid dedicated Application key appear healthy.
  Future<void> verifyCredential(
    PterodactylProfile profile,
    PterodactylCredentialRole role,
  ) async {
    switch (role) {
      case PterodactylCredentialRole.client:
        final _ClientHandle handle = await _clientFor(profile);
        try {
          await handle.client.getAccount();
        } finally {
          handle.client.close();
        }
      case PterodactylCredentialRole.application:
        final _ClientHandle handle = await _clientFor(
          profile,
          includeDedicatedApplicationCredential: true,
        );
        try {
          if (!handle.hasDedicatedApplicationCredential) {
            throw StateError(
              'No Application API key enrolled for ${profile.id}.',
            );
          }
          await handle.client.listApplicationServers(perPage: 1);
        } finally {
          handle.client.close();
        }
    }
  }

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
        capabilities
          ..add(PterodactylCapability.configure)
          ..add(PterodactylCapability.delete);
        try {
          final List<PterodactylApplicationServer> templates =
              await verifiedApplicationHandle.client
                  .listApplicationServers(perPage: 1)
                  .then(
                    (PterodactylPage<PterodactylApplicationServer> page) =>
                        page.items,
                  );
          final List<PterodactylNode> nodes = await verifiedApplicationHandle
              .client
              .listAllApplicationNodes();
          nodeCount = nodes.length;
          if (nodes.isEmpty) {
            warnings.add('Remote creation needs at least one Panel node.');
          } else {
            // Every creation path needs an owner and a free allocation.
            // Nest and egg inventory is only required when no template exists.
            final List<PterodactylUser> users = await verifiedApplicationHandle
                .client
                .listApplicationUsers(perPage: 1)
                .then((PterodactylPage<PterodactylUser> page) => page.items);
            await verifiedApplicationHandle.client.listNodeAllocations(
              nodes.first.id,
              perPage: 1,
            );
            if (users.isEmpty) {
              warnings.add(
                'Remote creation needs at least one Panel user to own the '
                'server.',
              );
            }
            bool hasCreationSource = templates.isNotEmpty;
            if (!hasCreationSource) {
              final List<PterodactylNest> nests =
                  await verifiedApplicationHandle.client
                      .listAllApplicationNests();
              if (nests.isEmpty) {
                warnings.add(
                  'Remote creation needs an existing template or at least '
                  'one Panel nest and egg.',
                );
              }
              bool hasUsableEgg = false;
              for (final PterodactylNest nest in nests) {
                final PterodactylPage<PterodactylEgg> eggs =
                    await verifiedApplicationHandle.client.listNestEggs(
                      nest.id,
                      perPage: 1,
                    );
                hasUsableEgg = eggs.items.any(
                  (PterodactylEgg egg) =>
                      egg.startup?.trim().isNotEmpty == true &&
                      egg.dockerImages.values.any(
                        (String image) => image.trim().isNotEmpty,
                      ),
                );
                if (hasUsableEgg) break;
              }
              if (nests.isNotEmpty && !hasUsableEgg) {
                warnings.add(
                  'Remote creation needs at least one Panel egg with a '
                  'startup command and Docker image.',
                );
              }
              hasCreationSource = hasUsableEgg;
            }
            if (users.isNotEmpty && hasCreationSource) {
              capabilities.add(PterodactylCapability.create);
            }
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
            'Creation inventory is not fully granted. Application creation '
            'needs Users, Nodes, Allocations, Nests, and Eggs READ plus '
            'Servers WRITE.',
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

  /// Resolves an entire bulk selection before any mutating request is sent.
  ///
  /// Explicit selectors and [all] are mutually exclusive. Duplicate or
  /// ambiguous selectors fail the whole preflight, and an empty result never
  /// turns into a successful no-op.
  Future<List<PterodactylClientServer>> resolveBulkServers({
    required String profileId,
    Iterable<String> selectors = const <String>[],
    bool all = false,
    PterodactylBulkServerState? state,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      return await _resolveBulkServers(
        handle.client,
        profile,
        selectors: selectors,
        all: all,
        state: state,
      );
    } finally {
      handle.client.close();
    }
  }

  static String bulkConfirmationToken({
    required PterodactylBulkAction action,
    required String profileId,
    required Iterable<String> serverIdentifiers,
  }) {
    if (action != PterodactylBulkAction.reinstall &&
        action != PterodactylBulkAction.delete) {
      throw ArgumentError(
        'Bulk confirmation is only defined for reinstall and delete.',
      );
    }
    final String normalizedProfile = profileId.trim().toLowerCase();
    if (normalizedProfile.isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', 'must not be empty');
    }
    final List<String> identifiers = serverIdentifiers
        .map((String identifier) => identifier.trim().toLowerCase())
        .toList(growable: false);
    if (identifiers.isEmpty ||
        identifiers.any((String identifier) => identifier.isEmpty)) {
      throw ArgumentError('At least one server identifier is required.');
    }
    if (identifiers.toSet().length != identifiers.length) {
      throw ArgumentError('Server identifiers must be unique.');
    }
    identifiers.sort();
    return '${action.name}:$normalizedProfile:${identifiers.join(',')}';
  }

  Future<String> accountUsername(String profileId) async {
    final _ClientHandle handle = await _clientFor(_requireProfile(profileId));
    try {
      return (await handle.client.getAccount()).username;
    } finally {
      handle.client.close();
    }
  }

  /// Ensures this Client account has the requested SFTP public key. The
  /// create-and-recheck flow is safe across concurrent Multiplexor starts:
  /// whichever process loses a duplicate race observes the winner's key.
  Future<void> ensureAccountSshPublicKey(
    String profileId, {
    required String name,
    required String publicKey,
  }) async {
    final String normalizedName = name.trim();
    if (normalizedName.isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalizedName)) {
      throw ArgumentError('name must contain printable characters.');
    }
    final String normalizedPublicKey =
        PterodactylAccountSshKey.normalizePublicKey(publicKey);
    final _ClientHandle handle = await _clientFor(_requireProfile(profileId));
    try {
      if (_containsPublicKey(
        await handle.client.listAccountSshKeys(),
        normalizedPublicKey,
      )) {
        return;
      }
      try {
        await handle.client.createAccountSshKey(
          name: normalizedName,
          publicKey: normalizedPublicKey,
        );
      } on PterodactylException {
        try {
          if (_containsPublicKey(
            await handle.client.listAccountSshKeys(),
            normalizedPublicKey,
          )) {
            return;
          }
        } on PterodactylException {
          // Preserve the original create failure; neither exception contains
          // response bodies or key material.
        }
        rethrow;
      }
    } finally {
      handle.client.close();
    }
  }

  static bool _containsPublicKey(
    List<PterodactylAccountSshKey> keys,
    String normalizedPublicKey,
  ) => keys.any(
    (PterodactylAccountSshKey key) => key.publicKey == normalizedPublicKey,
  );

  /// Resolves an identifier, UUID, or unique name and returns the Panel's
  /// per-server permission metadata for safe UI and command gating.
  Future<PterodactylClientServerAccess> serverAccess(
    String id,
    String selector,
  ) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      return await _serverAccess(handle.client, profile, selector);
    } finally {
      handle.client.close();
    }
  }

  Future<PterodactylPage<PterodactylActivity>> activity(
    String id,
    String selector, {
    int page = 1,
    int perPage = 25,
  }) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        selector,
      );
      _requirePermission(access, PterodactylServerPermission.activityRead);
      return await handle.client.listServerActivity(
        access.server.identifier,
        page: page,
        perPage: perPage,
      );
    } finally {
      handle.client.close();
    }
  }

  Future<PterodactylServerStartup> startup(String id, String selector) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        selector,
      );
      _requirePermission(access, PterodactylServerPermission.startupRead);
      return await handle.client.getServerStartup(access.server.identifier);
    } finally {
      handle.client.close();
    }
  }

  Future<PterodactylStartupVariable> updateStartupVariable({
    required String profileId,
    required String server,
    required String key,
    required String value,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      if (access.allows(PterodactylServerPermission.startupUpdate)) {
        return await handle.client.updateServerStartupVariable(
          access.server.identifier,
          key: key,
          value: value,
        );
      }

      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer current = await applicationHandle
          .client
          .getApplicationServer(access.server.internalId);
      final Map<String, String> environment = _editableEnvironment(current);
      if (!environment.containsKey(key)) {
        throw StateError(
          'The Application API did not expose startup variable '
          '${_safeProviderText(key)} for this server.',
        );
      }
      environment[key] = value;
      await applicationHandle.client.updateApplicationServerStartup(
        current.id,
        _startupUpdate(current, environment: environment),
      );
      return PterodactylStartupVariable(
        name: key,
        environmentVariable: key,
        serverValue: value,
        isEditable: true,
        rules: '',
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<void> updateDockerImage({
    required String profileId,
    required String server,
    required String dockerImage,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      if (access.allows(PterodactylServerPermission.startupDockerImage)) {
        await handle.client.setServerDockerImage(
          access.server.identifier,
          dockerImage,
        );
        return;
      }

      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer current = await applicationHandle
          .client
          .getApplicationServer(access.server.internalId);
      await applicationHandle.client.updateApplicationServerStartup(
        current.id,
        _startupUpdate(current, dockerImage: dockerImage),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  /// Renames or describes a server using the least privileged route available.
  /// Client permissions are preferred; an enrolled Application credential is
  /// only consulted when the Client account cannot rename this server.
  Future<void> rename({
    required String profileId,
    required String server,
    required String name,
    String? description,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      if (access.allows(PterodactylServerPermission.settingsRename)) {
        await handle.client.renameServer(
          access.server.identifier,
          name: name,
          description: description,
        );
        return;
      }

      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer current = await applicationHandle
          .client
          .getApplicationServer(access.server.internalId);
      await applicationHandle.client.updateApplicationServerDetails(
        current.id,
        PterodactylUpdateServerDetailsRequest.fromServer(
          current,
          name: name,
          description: description,
        ),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  /// Reinstalls through the Client API when permitted, otherwise through the
  /// Application API. Both routes are bound to this profile's exact origin.
  Future<void> reinstall(String id, String server) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      if (access.allows(PterodactylServerPermission.settingsReinstall)) {
        await handle.client.reinstallServer(access.server.identifier);
        return;
      }
      applicationHandle = await _applicationClientFor(profile);
      await applicationHandle.client.reinstallApplicationServer(
        access.server.internalId,
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<void> delete(String id, String server, {bool force = false}) async {
    final PterodactylProfile profile = _requireProfile(id);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      applicationHandle = await _applicationClientFor(profile);
      await applicationHandle.client.deleteApplicationServer(
        access.server.internalId,
        force: force,
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<PterodactylApplicationServer> updateBuildSettings({
    required String profileId,
    required String server,
    int? allocationId,
    int? memoryMiB,
    int? swapMiB,
    int? diskMiB,
    int? ioWeight,
    int? cpuPercent,
    String? threads,
    bool clearThreads = false,
    bool? oomDisabled,
    int? databaseLimit,
    int? allocationLimit,
    int? backupLimit,
    List<int> addAllocationIds = const <int>[],
    List<int> removeAllocationIds = const <int>[],
  }) async {
    if (threads != null && clearThreads) {
      throw ArgumentError('threads and clearThreads are mutually exclusive.');
    }
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer current = await applicationHandle
          .client
          .getApplicationServer(access.server.internalId);
      final PterodactylServerLimits currentLimits = current.limits;
      return await applicationHandle.client.updateApplicationServerBuild(
        current.id,
        PterodactylUpdateServerBuildRequest(
          defaultAllocationId: allocationId ?? current.allocationId,
          limits: PterodactylServerLimits(
            memoryMiB: memoryMiB ?? currentLimits.memoryMiB,
            swapMiB: swapMiB ?? currentLimits.swapMiB,
            diskMiB: diskMiB ?? currentLimits.diskMiB,
            ioWeight: ioWeight ?? currentLimits.ioWeight,
            cpuPercent: cpuPercent ?? currentLimits.cpuPercent,
            threads: clearThreads ? null : threads ?? currentLimits.threads,
            oomDisabled: oomDisabled ?? currentLimits.oomDisabled,
          ),
          featureLimits: PterodactylFeatureLimits(
            databases: databaseLimit ?? current.featureLimits.databases,
            allocations: allocationLimit ?? current.featureLimits.allocations,
            backups: backupLimit ?? current.featureLimits.backups,
          ),
          oomDisabled: oomDisabled ?? currentLimits.oomDisabled,
          addAllocationIds: addAllocationIds,
          removeAllocationIds: removeAllocationIds,
        ),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<PterodactylApplicationServer> updateStartupCommand({
    required String profileId,
    required String server,
    required String startup,
  }) async {
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final PterodactylClientServerAccess access = await _serverAccess(
        handle.client,
        profile,
        server,
      );
      applicationHandle = await _applicationClientFor(profile);
      final PterodactylApplicationServer current = await applicationHandle
          .client
          .getApplicationServer(access.server.internalId);
      final Map<String, String> environment = <String, String>{
        ..._editableEnvironment(current),
      };
      return await applicationHandle.client.updateApplicationServerStartup(
        current.id,
        _startupUpdate(current, startup: startup, environment: environment),
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  static Map<String, String> _editableEnvironment(
    PterodactylApplicationServer server,
  ) => <String, String>{
    for (final MapEntry<String, String> entry in server.environment.entries)
      if (!entry.key.startsWith('P_SERVER_') && entry.key != 'STARTUP')
        entry.key: entry.value,
  };

  static PterodactylUpdateServerStartupRequest _startupUpdate(
    PterodactylApplicationServer server, {
    String? startup,
    Map<String, String>? environment,
    String? dockerImage,
  }) => PterodactylUpdateServerStartupRequest(
    startup: startup ?? server.startup,
    environment: environment ?? _editableEnvironment(server),
    eggId: server.eggId,
    dockerImage: dockerImage ?? server.image,
    skipScripts: server.skipScripts,
  );

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
      PterodactylApiException? fatalError;
      final List<PterodactylFleetSample> result = await boundedMap(servers, (
        PterodactylClientServer server,
      ) async {
        // Stop admitting HTTP work on a panel-wide failure while the pool
        // drains requests already in flight before this client's cleanup.
        final PterodactylApiException? blocked = fatalError;
        if (blocked != null) throw blocked;
        try {
          final PterodactylResourceUsage resources = await handle.client
              .getServerResources(server.identifier);
          return PterodactylFleetSample(server: server, resources: resources);
        } on PterodactylApiException catch (error) {
          // A revoked key or a panel-wide throttle is not a per-server
          // telemetry gap. Let the feed retain its last good snapshot
          // and surface the connection error instead of erasing every
          // metric one row at a time.
          if (error.statusCode == 401 || error.isRateLimited) {
            fatalError ??= error;
            rethrow;
          }
          return PterodactylFleetSample(server: server);
        } on PterodactylException {
          return PterodactylFleetSample(server: server);
        }
      });
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
      await _sendPower(handle.client, identifier, signal);
    } finally {
      handle.client.close();
    }
  }

  Future<void> _sendPower(
    PterodactylClient client,
    String identifier,
    PterodactylPowerSignal signal,
  ) async {
    if (signal != PterodactylPowerSignal.stop) {
      await client.sendPowerSignal(identifier, signal);
      return;
    }
    await stopRuntime(
      requestStop: () => client.sendPowerSignal(identifier, signal),
      isStopped: () async {
        final PterodactylResourceUsage usage = await client.getServerResources(
          identifier,
        );
        return usage.currentState.trim().toLowerCase() == 'offline';
      },
      forceStop: () =>
          client.sendPowerSignal(identifier, PterodactylPowerSignal.kill),
      pollInterval: const Duration(milliseconds: 500),
    );
  }

  Future<PterodactylBulkResult> bulkPower({
    required String profileId,
    required Iterable<String> serverIdentifiers,
    required PterodactylPowerSignal signal,
    int concurrency = 4,
  }) async {
    _requireBulkConcurrency(concurrency);
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    try {
      final List<PterodactylClientServer> targets = await _resolveBulkServers(
        handle.client,
        profile,
        selectors: serverIdentifiers,
      );
      return await _runBulkExisting(
        action: PterodactylBulkAction.values.byName(signal.name),
        targets: targets,
        concurrency: concurrency,
        operation: (PterodactylClientServer server) =>
            _sendPower(handle.client, server.identifier, signal),
      );
    } finally {
      handle.client.close();
    }
  }

  Future<PterodactylBulkResult> bulkReinstall({
    required String profileId,
    required Iterable<String> serverIdentifiers,
    int concurrency = 4,
  }) async {
    _requireBulkConcurrency(concurrency);
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final List<PterodactylClientServer> targets = await _resolveBulkServers(
        handle.client,
        profile,
        selectors: serverIdentifiers,
      );
      final List<PterodactylClientServerAccess> access = await boundedMap(
        targets,
        (PterodactylClientServer server) =>
            handle.client.getClientServerAccess(server.identifier),
        concurrency: concurrency,
      );
      for (int index = 0; index < targets.length; index++) {
        if (access[index].server.identifier != targets[index].identifier) {
          throw const PterodactylProtocolException(
            'Server permission preflight returned a mismatched server.',
          );
        }
      }
      if (access.any(
        (PterodactylClientServerAccess item) =>
            !item.allows(PterodactylServerPermission.settingsReinstall),
      )) {
        applicationHandle = await _applicationClientFor(profile);
      }
      final Map<String, PterodactylClientServerAccess> accessByIdentifier =
          <String, PterodactylClientServerAccess>{
            for (int index = 0; index < targets.length; index++)
              targets[index].identifier: access[index],
          };
      return await _runBulkExisting(
        action: PterodactylBulkAction.reinstall,
        targets: targets,
        concurrency: concurrency,
        operation: (PterodactylClientServer server) {
          final PterodactylClientServerAccess item =
              accessByIdentifier[server.identifier]!;
          if (item.allows(PterodactylServerPermission.settingsReinstall)) {
            return handle.client.reinstallServer(server.identifier);
          }
          return applicationHandle!.client.reinstallApplicationServer(
            server.internalId,
          );
        },
      );
    } finally {
      applicationHandle?.client.close();
      handle.client.close();
    }
  }

  Future<PterodactylBulkResult> bulkDelete({
    required String profileId,
    required Iterable<String> serverIdentifiers,
    bool force = false,
    int concurrency = 4,
  }) async {
    _requireBulkConcurrency(concurrency);
    final PterodactylProfile profile = _requireProfile(profileId);
    final _ClientHandle handle = await _clientFor(profile);
    _ClientHandle? applicationHandle;
    try {
      final List<PterodactylClientServer> targets = await _resolveBulkServers(
        handle.client,
        profile,
        selectors: serverIdentifiers,
      );
      // Authenticate the Application route before deleting the first target.
      applicationHandle = await _applicationClientFor(profile);
      return await _runBulkExisting(
        action: PterodactylBulkAction.delete,
        targets: targets,
        concurrency: concurrency,
        operation: (PterodactylClientServer server) => applicationHandle!.client
            .deleteApplicationServer(server.internalId, force: force),
      );
    } finally {
      applicationHandle?.client.close();
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
    int? ownerId,
    bool startOnCompletion = false,
  }) async {
    final String requestedName = _validateCreateName(name);
    final PterodactylProfile profile = _requireProfile(profileId);
    final String? clientUsername = ownerId == null
        ? await accountUsername(profileId)
        : null;
    final _ClientHandle applicationHandle = await _applicationClientFor(
      profile,
    );
    try {
      final PterodactylApplicationServer applicationTemplate =
          _resolveApplicationServer(
            await applicationHandle.client.listAllApplicationServers(),
            template,
          );
      final int selectedOwnerId = _resolveCreationOwner(
        await applicationHandle.client.listAllApplicationUsers(),
        ownerId: ownerId,
        clientUsername: clientUsername,
      );
      final PterodactylNode node = _resolveCreationNode(
        await applicationHandle.client.listAllApplicationNodes(),
        applicationTemplate.nodeId,
      );
      _validateCreationNode(
        node: node,
        memoryMiB: memoryMiB ?? applicationTemplate.limits.memoryMiB,
        diskMiB: diskMiB ?? applicationTemplate.limits.diskMiB,
        serverCount: 1,
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

      return await applicationHandle.client.createApplicationServer(
        _templateCreateRequest(
          template: applicationTemplate,
          ownerId: selectedOwnerId,
          name: requestedName,
          defaultAllocationId: free[0].id,
          additionalAllocationId: free.length > 1 ? free[1].id : null,
          memoryMiB: memoryMiB,
          diskMiB: diskMiB,
          cpuPercent: cpuPercent,
          startOnCompletion: startOnCompletion,
        ),
      );
    } finally {
      applicationHandle.client.close();
    }
  }

  /// Creates from an already resolved template plan without re-deriving any
  /// server setting after operator confirmation.
  ///
  /// The free allocation is deliberately selected at execution time, while
  /// the template identity, owner, node, image, startup, environment, limits,
  /// feature limits, and initial power behavior come from [plan] exactly.
  Future<PterodactylApplicationServer> createFromTemplatePlan({
    required String profileId,
    required PterodactylTemplateCreatePlan plan,
  }) async {
    final String requestedName = _validateCreateName(plan.name);
    if (requestedName != plan.name) {
      throw ArgumentError.value(
        plan.name,
        'plan.name',
        'must already be normalized',
      );
    }
    final _ClientHandle applicationHandle = await _applicationClientFor(
      _requireProfile(profileId),
    );
    try {
      _resolveApplicationServer(
        await applicationHandle.client.listAllApplicationServers(),
        plan.templateUuid,
      );
      _resolveCreationOwner(
        await applicationHandle.client.listAllApplicationUsers(),
        ownerId: plan.ownerId,
        clientUsername: null,
      );
      final PterodactylNode node = _resolveCreationNode(
        await applicationHandle.client.listAllApplicationNodes(),
        plan.nodeId,
      );
      _validateCreationNode(
        node: node,
        memoryMiB: plan.limits.memoryMiB,
        diskMiB: plan.limits.diskMiB,
        serverCount: 1,
      );
      final List<PterodactylAllocation> free =
          (await applicationHandle.client.listAllNodeAllocations(plan.nodeId))
              .where((PterodactylAllocation allocation) => allocation.isFree)
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
      return await applicationHandle.client.createApplicationServer(
        plan.toRequest(
          defaultAllocationId: free[0].id,
          additionalAllocationId: free.length > 1 ? free[1].id : null,
        ),
      );
    } finally {
      applicationHandle.client.close();
    }
  }

  /// Creates a fleet from one Application-visible template after reserving
  /// distinct free allocations for every request in the batch. Requests can run in
  /// parallel without selecting the same allocation; an external allocation
  /// race is reported on the affected item by the Panel.
  Future<PterodactylBulkResult> bulkCreateFromTemplate({
    required String profileId,
    required String template,
    required Iterable<String> names,
    int? memoryMiB,
    int? diskMiB,
    int? cpuPercent,
    int? ownerId,
    bool startOnCompletion = false,
    int concurrency = 4,
  }) async {
    _requireBulkConcurrency(concurrency);
    final List<String> requestedNames = _validateBulkCreateNames(names);

    final PterodactylProfile profile = _requireProfile(profileId);
    final String? clientUsername = ownerId == null
        ? await accountUsername(profileId)
        : null;
    final _ClientHandle applicationHandle = await _applicationClientFor(
      profile,
    );
    try {
      final PterodactylApplicationServer applicationTemplate =
          _resolveApplicationServer(
            await applicationHandle.client.listAllApplicationServers(),
            template,
          );
      final int selectedOwnerId = _resolveCreationOwner(
        await applicationHandle.client.listAllApplicationUsers(),
        ownerId: ownerId,
        clientUsername: clientUsername,
      );
      final PterodactylNode node = _resolveCreationNode(
        await applicationHandle.client.listAllApplicationNodes(),
        applicationTemplate.nodeId,
      );
      _validateCreationNode(
        node: node,
        memoryMiB: memoryMiB ?? applicationTemplate.limits.memoryMiB,
        diskMiB: diskMiB ?? applicationTemplate.limits.diskMiB,
        serverCount: requestedNames.length,
      );
      final List<PterodactylAllocation> free =
          (await applicationHandle.client.listAllNodeAllocations(
                applicationTemplate.nodeId,
              ))
              .where(
                (PterodactylAllocation allocation) =>
                    allocation.isAssigned == false,
              )
              .toList()
            ..sort(
              (PterodactylAllocation a, PterodactylAllocation b) =>
                  a.port.compareTo(b.port),
            );
      if (free.length < requestedNames.length) {
        throw StateError(
          'Create-many requires ${requestedNames.length} free allocations, '
          'but only ${free.length} are available. No servers were created.',
        );
      }

      final List<_BulkCreateTarget> targets = List<_BulkCreateTarget>.generate(
        requestedNames.length,
        (int index) {
          final int additionalIndex = requestedNames.length + index;
          return _BulkCreateTarget(
            name: requestedNames[index],
            defaultAllocationId: free[index].id,
            additionalAllocationId: additionalIndex < free.length
                ? free[additionalIndex].id
                : null,
          );
        },
        growable: false,
      );
      final List<PterodactylBulkItemResult> items = await boundedMap(targets, (
        _BulkCreateTarget target,
      ) async {
        try {
          final PterodactylApplicationServer created = await applicationHandle
              .client
              .createApplicationServer(
                _templateCreateRequest(
                  template: applicationTemplate,
                  ownerId: selectedOwnerId,
                  name: target.name,
                  defaultAllocationId: target.defaultAllocationId,
                  additionalAllocationId: target.additionalAllocationId,
                  memoryMiB: memoryMiB,
                  diskMiB: diskMiB,
                  cpuPercent: cpuPercent,
                  startOnCompletion: startOnCompletion,
                ),
              );
          return PterodactylBulkItemResult(
            target: target.name,
            name: created.name,
            identifier: created.identifier,
            succeeded: true,
          );
        } on Object catch (error) {
          return PterodactylBulkItemResult(
            target: target.name,
            name: target.name,
            identifier: null,
            succeeded: false,
            error: _bulkErrorText(error),
          );
        }
      }, concurrency: concurrency);
      return PterodactylBulkResult(
        action: PterodactylBulkAction.create,
        items: items,
      );
    } finally {
      applicationHandle.client.close();
    }
  }

  Future<PterodactylApplicationServer> createFromEgg({
    required String profileId,
    required String name,
    required PterodactylEggCreatePlan plan,
  }) async {
    final _EggCreateBatch batch = await _createEggBatch(
      profileId: profileId,
      names: <String>[name],
      plan: plan,
    );
    final _EggCreateOutcome outcome = batch.outcomes.single;
    if (outcome.server == null) {
      throw StateError(outcome.item.error ?? 'Remote server creation failed.');
    }
    return outcome.server!;
  }

  /// Creates servers directly from a Panel egg, including on an empty Panel.
  /// Every referenced object and all required egg variables are validated and
  /// distinct allocations are reserved before the first create request.
  Future<PterodactylBulkResult> bulkCreateFromEgg({
    required String profileId,
    required Iterable<String> names,
    required PterodactylEggCreatePlan plan,
    int concurrency = 4,
  }) async => (await _createEggBatch(
    profileId: profileId,
    names: names,
    plan: plan,
    concurrency: concurrency,
  )).result;

  Future<_EggCreateBatch> _createEggBatch({
    required String profileId,
    required Iterable<String> names,
    required PterodactylEggCreatePlan plan,
    int concurrency = 1,
  }) async {
    _requireBulkConcurrency(concurrency);
    final List<String> requestedNames = _validateBulkCreateNames(names);
    if (plan.externalId != null && requestedNames.length != 1) {
      throw ArgumentError(
        'A Panel external ID can only be used for one server creation.',
      );
    }
    final _ClientHandle applicationHandle = await _applicationClientFor(
      _requireProfile(profileId),
    );
    try {
      final List<PterodactylUser> users = await applicationHandle.client
          .listAllApplicationUsers();
      if (!users.any((PterodactylUser user) => user.id == plan.ownerId)) {
        throw StateError('The selected owner is no longer available.');
      }
      final List<PterodactylNode> nodes = await applicationHandle.client
          .listAllApplicationNodes();
      final PterodactylNode node = _resolveCreationNode(nodes, plan.nodeId);
      _validateCreationNode(
        node: node,
        memoryMiB: plan.memoryMiB,
        diskMiB: plan.diskMiB,
        serverCount: requestedNames.length,
      );
      final List<PterodactylNest> nests = await applicationHandle.client
          .listAllApplicationNests();
      PterodactylEgg? selectedEgg;
      for (final PterodactylNest nest in nests) {
        final List<PterodactylEgg> eggs = await applicationHandle.client
            .listAllNestEggs(nest.id);
        for (final PterodactylEgg egg in eggs) {
          if (egg.id == plan.eggId) selectedEgg = egg;
        }
      }
      final PterodactylEgg egg =
          selectedEgg ??
          (throw StateError('The selected egg is no longer available.'));
      if (plan.eggUuid case final String expectedUuid
          when expectedUuid != egg.uuid) {
        throw StateError(
          'The selected egg identity changed. Reload the creation catalog '
          'and try again.',
        );
      }
      final String? eggStartup = egg.startup;
      if (eggStartup == null || eggStartup.trim().isEmpty) {
        throw StateError(
          'The selected egg has no startup command configured on the Panel.',
        );
      }
      if (plan.startup != eggStartup) {
        throw StateError(
          'The selected egg startup command changed. Reload the creation '
          'catalog and try again.',
        );
      }
      if (!egg.dockerImages.values.contains(plan.dockerImage)) {
        throw StateError(
          'The selected Docker image is not allowed by the egg.',
        );
      }
      final Set<String> variableNames = egg.variables
          .map(
            (PterodactylEggVariable variable) => variable.environmentVariable,
          )
          .toSet();
      final List<String> unknownVariables =
          plan.environment.keys
              .where((String key) => !variableNames.contains(key))
              .toList(growable: false)
            ..sort();
      if (unknownVariables.isNotEmpty) {
        throw StateError(
          'Unknown egg environment variables: ${unknownVariables.join(', ')}',
        );
      }
      if (plan.eggUuid != null) {
        final List<String> addedVariables =
            variableNames
                .where((String key) => !plan.environment.containsKey(key))
                .toList(growable: false)
              ..sort();
        if (addedVariables.isNotEmpty) {
          throw StateError(
            'Egg environment variables changed after planning: '
            '${addedVariables.join(', ')}. Reload the creation catalog and '
            'try again.',
          );
        }
      }
      final Map<String, String> environment = <String, String>{
        for (final PterodactylEggVariable variable in egg.variables)
          variable.environmentVariable:
              plan.environment[variable.environmentVariable] ??
              variable.defaultValue,
      };
      final List<String> missing = <String>[
        for (final PterodactylEggVariable variable in egg.variables)
          if (variable.isRequired &&
              (environment[variable.environmentVariable]?.trim().isEmpty ??
                  true))
            variable.environmentVariable,
      ];
      if (missing.isNotEmpty) {
        throw StateError(
          'Required egg variables need values: ${missing.join(', ')}',
        );
      }
      final List<PterodactylAllocation> free =
          (await applicationHandle.client.listAllNodeAllocations(plan.nodeId))
              .where((PterodactylAllocation allocation) => allocation.isFree)
              .toList()
            ..sort(
              (PterodactylAllocation a, PterodactylAllocation b) =>
                  a.port.compareTo(b.port),
            );
      if (free.length < requestedNames.length) {
        throw StateError(
          'Create-many requires ${requestedNames.length} free allocations, '
          'but only ${free.length} are available. No servers were created.',
        );
      }
      final List<_BulkCreateTarget> targets = List<_BulkCreateTarget>.generate(
        requestedNames.length,
        (int index) => _BulkCreateTarget(
          name: requestedNames[index],
          defaultAllocationId: free[index].id,
          additionalAllocationId: null,
        ),
        growable: false,
      );
      final List<_EggCreateOutcome> outcomes = await boundedMap(targets, (
        _BulkCreateTarget target,
      ) async {
        try {
          final PterodactylApplicationServer created = await applicationHandle
              .client
              .createApplicationServer(
                _eggCreateRequest(
                  name: target.name,
                  plan: plan,
                  environment: environment,
                  allocationId: target.defaultAllocationId,
                ),
              );
          return _EggCreateOutcome(
            server: created,
            item: PterodactylBulkItemResult(
              target: target.name,
              name: created.name,
              identifier: created.identifier,
              succeeded: true,
            ),
          );
        } on Object catch (error) {
          return _EggCreateOutcome(
            item: PterodactylBulkItemResult(
              target: target.name,
              name: target.name,
              identifier: null,
              succeeded: false,
              error: _bulkErrorText(error),
            ),
          );
        }
      }, concurrency: concurrency);
      return _EggCreateBatch(
        outcomes: List<_EggCreateOutcome>.unmodifiable(outcomes),
        result: PterodactylBulkResult(
          action: PterodactylBulkAction.create,
          items: outcomes
              .map((_EggCreateOutcome outcome) => outcome.item)
              .toList(growable: false),
        ),
      );
    } finally {
      applicationHandle.client.close();
    }
  }

  static PterodactylCreateServerRequest _eggCreateRequest({
    required String name,
    required PterodactylEggCreatePlan plan,
    required Map<String, String> environment,
    required int allocationId,
  }) => PterodactylCreateServerRequest(
    name: name,
    description: 'Created by Multiplexor from Panel egg ${plan.eggId}.',
    externalId: plan.externalId,
    ownerId: plan.ownerId,
    eggId: plan.eggId,
    dockerImage: plan.dockerImage,
    startup: plan.startup,
    environment: environment,
    limits: PterodactylServerLimits(
      memoryMiB: plan.memoryMiB,
      swapMiB: plan.swapMiB,
      diskMiB: plan.diskMiB,
      ioWeight: plan.ioWeight,
      cpuPercent: plan.cpuPercent,
      threads: null,
      oomDisabled: true,
    ),
    featureLimits: PterodactylFeatureLimits(
      databases: plan.databaseLimit,
      allocations: plan.allocationLimit,
      backups: plan.backupLimit,
    ),
    defaultAllocationId: allocationId,
    startOnCompletion: plan.startOnCompletion,
    oomDisabled: true,
  );

  static void _validateCreationNode({
    required PterodactylNode node,
    required int memoryMiB,
    required int diskMiB,
    required int serverCount,
  }) {
    if (node.maintenanceMode) {
      throw StateError('The selected node is in maintenance mode.');
    }
    final int requestedMemory = memoryMiB * serverCount;
    final int requestedDisk = diskMiB * serverCount;
    final int? maximumMemory = node.maximumAllocatedMemoryMiB;
    if (maximumMemory != null &&
        node.allocatedMemoryMiB + requestedMemory > maximumMemory) {
      throw StateError(
        'The selected node does not have enough configured memory capacity '
        'for $serverCount server(s). No servers were created.',
      );
    }
    final int? maximumDisk = node.maximumAllocatedDiskMiB;
    if (maximumDisk != null &&
        node.allocatedDiskMiB + requestedDisk > maximumDisk) {
      throw StateError(
        'The selected node does not have enough configured disk capacity '
        'for $serverCount server(s). No servers were created.',
      );
    }
  }

  static PterodactylNode _resolveCreationNode(
    List<PterodactylNode> nodes,
    int nodeId,
  ) =>
      nodes.where((PterodactylNode node) => node.id == nodeId).firstOrNull ??
      (throw StateError('The selected node is no longer available.'));

  static List<String> _validateBulkCreateNames(Iterable<String> names) {
    final List<String> requestedNames = names
        .map(_validateCreateName)
        .toList(growable: false);
    if (requestedNames.isEmpty) {
      throw ArgumentError('At least one non-empty server name is required.');
    }
    if (requestedNames.length > 100) {
      throw ArgumentError(
        'Create-many supports at most 100 servers per batch.',
      );
    }
    if (requestedNames
            .map((String name) => name.toLowerCase())
            .toSet()
            .length !=
        requestedNames.length) {
      throw ArgumentError('Server names in a create batch must be unique.');
    }
    return requestedNames;
  }

  static String _validateCreateName(String name) {
    final String normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 191) {
      throw ArgumentError.value(
        name,
        'name',
        'must contain between 1 and 191 characters',
      );
    }
    return normalized;
  }

  static PterodactylCreateServerRequest _templateCreateRequest({
    required PterodactylApplicationServer template,
    required int ownerId,
    required String name,
    required int defaultAllocationId,
    required int? additionalAllocationId,
    required int? memoryMiB,
    required int? diskMiB,
    required int? cpuPercent,
    required bool startOnCompletion,
  }) {
    final Map<String, String> environment = <String, String>{
      for (final MapEntry<String, String> entry in template.environment.entries)
        if (!entry.key.startsWith('P_SERVER_') && entry.key != 'STARTUP')
          entry.key: entry.value,
    };
    final PterodactylServerLimits limits = template.limits;
    return PterodactylCreateServerRequest(
      name: name,
      description: 'Created by Multiplexor from ${template.name}.',
      ownerId: ownerId,
      eggId: template.eggId,
      dockerImage: template.image,
      startup: template.startup,
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
      featureLimits: template.featureLimits,
      defaultAllocationId: defaultAllocationId,
      additionalAllocationIds: additionalAllocationId == null
          ? const <int>[]
          : <int>[additionalAllocationId],
      startOnCompletion: startOnCompletion,
      oomDisabled: limits.oomDisabled,
    );
  }

  Future<List<PterodactylClientServer>> _resolveBulkServers(
    PterodactylClient client,
    PterodactylProfile profile, {
    Iterable<String> selectors = const <String>[],
    bool all = false,
    PterodactylBulkServerState? state,
  }) async {
    final List<String> requested = selectors
        .map((String selector) => selector.trim())
        .toList(growable: false);
    if (all && requested.isNotEmpty) {
      throw ArgumentError('Use explicit servers or --all, not both.');
    }
    if (!all && requested.isEmpty) {
      throw ArgumentError('Select at least one server or use --all.');
    }
    if (requested.any((String selector) => selector.isEmpty)) {
      throw ArgumentError('Server selectors must not be empty.');
    }
    final List<PterodactylClientServer> servers = await _listServers(
      client,
      profile,
    );
    final List<PterodactylClientServer> selected = all
        ? List<PterodactylClientServer>.from(servers)
        : requested
              .map((String selector) => _resolveServer(servers, selector))
              .toList(growable: false);
    final Set<String> seen = <String>{};
    for (final PterodactylClientServer server in selected) {
      if (!seen.add(server.identifier)) {
        throw ArgumentError(
          'Bulk selection resolves the same server more than once: '
          '${server.identifier}',
        );
      }
    }
    final List<PterodactylClientServer> filtered;
    if (state == null) {
      filtered = selected;
    } else {
      final List<PterodactylResourceUsage> resources = await boundedMap(
        selected,
        (PterodactylClientServer server) =>
            client.getServerResources(server.identifier),
      );
      filtered = <PterodactylClientServer>[
        for (int index = 0; index < selected.length; index++)
          if (switch (state) {
            PterodactylBulkServerState.running =>
              _normalizedServerState(resources[index].currentState) !=
                  'offline',
            PterodactylBulkServerState.offline =>
              _normalizedServerState(resources[index].currentState) ==
                  'offline',
          })
            selected[index],
      ];
    }
    if (filtered.isEmpty) {
      throw StateError('The bulk selection resolved to zero servers.');
    }
    return List<PterodactylClientServer>.unmodifiable(filtered);
  }

  static String _normalizedServerState(String state) =>
      state.trim().toLowerCase();

  static Future<PterodactylBulkResult> _runBulkExisting({
    required PterodactylBulkAction action,
    required List<PterodactylClientServer> targets,
    required int concurrency,
    required Future<void> Function(PterodactylClientServer server) operation,
  }) async {
    final List<PterodactylBulkItemResult> items = await boundedMap(targets, (
      PterodactylClientServer server,
    ) async {
      try {
        await operation(server);
        return PterodactylBulkItemResult(
          target: server.identifier,
          name: server.name,
          identifier: server.identifier,
          succeeded: true,
        );
      } on Object catch (error) {
        return PterodactylBulkItemResult(
          target: server.identifier,
          name: server.name,
          identifier: server.identifier,
          succeeded: false,
          error: _bulkErrorText(error),
        );
      }
    }, concurrency: concurrency);
    return PterodactylBulkResult(action: action, items: items);
  }

  static void _requireBulkConcurrency(int concurrency) {
    if (concurrency < 1 || concurrency > 8) {
      throw ArgumentError.value(
        concurrency,
        'concurrency',
        'must be between 1 and 8',
      );
    }
  }

  static String _bulkErrorText(Object error) => _safeProviderText(
    error is PterodactylException ? error.message : error.toString(),
  );

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

  Future<PterodactylClientServerAccess> _serverAccess(
    PterodactylClient client,
    PterodactylProfile profile,
    String selector,
  ) async {
    final PterodactylClientServer resolved = _resolveServer(
      await _listServers(client, profile),
      selector,
    );
    return client.getClientServerAccess(resolved.identifier);
  }

  static void _requirePermission(
    PterodactylClientServerAccess access,
    PterodactylServerPermission permission,
  ) {
    if (access.allows(permission)) return;
    throw StateError(
      'Remote account lacks ${permission.wireValue} for '
      '${_safeProviderText(access.server.name)}.',
    );
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

  static PterodactylApplicationServer _resolveApplicationServer(
    List<PterodactylApplicationServer> servers,
    String selector,
  ) {
    final String normalized = selector.trim().toLowerCase();
    final List<PterodactylApplicationServer> matches = servers
        .where(
          (PterodactylApplicationServer server) =>
              server.identifier.toLowerCase() == normalized ||
              server.uuid.toLowerCase() == normalized ||
              server.name.toLowerCase() == normalized,
        )
        .toList(growable: false);
    if (matches.length != 1) {
      throw StateError(
        matches.isEmpty
            ? 'No remote server template matches: $selector'
            : 'Remote server template name is ambiguous: $selector',
      );
    }
    return matches.single;
  }

  static int _resolveCreationOwner(
    List<PterodactylUser> users, {
    required int? ownerId,
    required String? clientUsername,
  }) {
    final List<PterodactylUser> matches = ownerId != null
        ? users
              .where((PterodactylUser user) => user.id == ownerId)
              .toList(growable: false)
        : users
              .where(
                (PterodactylUser user) =>
                    user.username.toLowerCase() ==
                    clientUsername?.toLowerCase(),
              )
              .toList(growable: false);
    if (matches.length != 1) {
      throw StateError(
        ownerId != null
            ? 'The selected server owner is no longer available.'
            : 'No unique Application user matches the connected Client '
                  'username. Select an owner explicitly.',
      );
    }
    return matches.single.id;
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
      client: _clientFactory(
        profile: profile,
        clientCredential: clientCredential,
        applicationCredential: applicationCredential,
      ),
      hasDedicatedApplicationCredential: applicationCredential != null,
    );
  }

  static PterodactylClient _createClient({
    required PterodactylProfile profile,
    required PterodactylCredential clientCredential,
    PterodactylCredential? applicationCredential,
  }) => PterodactylClient(
    baseUri: profile.panelUri,
    clientKey: clientCredential.value,
    applicationKey: applicationCredential?.value ?? clientCredential.value,
    trustedCertificatePath: profile.trustedCertificatePath,
  );
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
