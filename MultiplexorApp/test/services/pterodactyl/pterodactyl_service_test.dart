import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_client.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_session.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_errors.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:test/test.dart';

void main() {
  test('remote polling stays at the Panel cache floor for small fleets', () {
    expect(
      PterodactylService.recommendedPollInterval(10),
      const Duration(seconds: 20),
    );
  });

  test('remote polling slows down before a large fleet hits rate limits', () {
    final Duration interval = PterodactylService.recommendedPollInterval(85);
    final double requestsPerMinute = 86 * 60 / interval.inSeconds;

    expect(interval, const Duration(seconds: 52));
    expect(requestsPerMinute, lessThanOrEqualTo(100));
  });

  test('bulk confirmation token is exact, normalized, and stable', () {
    expect(
      PterodactylService.bulkConfirmationToken(
        action: PterodactylBulkAction.delete,
        profileId: ' Remote ',
        serverIdentifiers: <String>['SERVER02', 'server01'],
      ),
      'delete:remote:server01,server02',
    );
    expect(
      () => PterodactylService.bulkConfirmationToken(
        action: PterodactylBulkAction.start,
        profileId: 'remote',
        serverIdentifiers: <String>['server01'],
      ),
      throwsArgumentError,
    );
  });

  test('bulk selection resolves every selector before mutation', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _serverListResponse(isOwner: true)),
        _ServiceReply(200, _serverListResponse(empty: true)),
      ]),
    ]);
    addTearDown(fixture.close);

    await expectLater(
      fixture.service.bulkPower(
        profileId: fixture.profile.id,
        serverIdentifiers: <String>['server01', 'missing'],
        signal: PterodactylPowerSignal.start,
      ),
      throwsStateError,
    );

    expect(
      fixture.transports.single.requests
          .where(
            (PterodactylTransportRequest request) =>
                request.uri.path.endsWith('/power'),
          )
          .toList(),
      isEmpty,
    );
  });

  test('bulk selection rejects empty, mixed, and duplicate targets', () async {
    final _ServiceFixture emptyFixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(const <_ServiceReply>[]),
    ]);
    addTearDown(emptyFixture.close);
    await expectLater(
      emptyFixture.service.resolveBulkServers(
        profileId: emptyFixture.profile.id,
      ),
      throwsArgumentError,
    );
    await expectLater(
      emptyFixture.service.resolveBulkServers(
        profileId: emptyFixture.profile.id,
        selectors: <String>['server01'],
        all: true,
      ),
      throwsArgumentError,
    );

    final _ServiceFixture duplicateFixture = _serviceFixture(
      <_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _serverListResponse(isOwner: true)),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
      ],
    );
    addTearDown(duplicateFixture.close);
    await expectLater(
      duplicateFixture.service.resolveBulkServers(
        profileId: duplicateFixture.profile.id,
        selectors: <String>['server01', 'Server'],
      ),
      throwsArgumentError,
    );

    final _ServiceFixture ambiguousFixture = _serviceFixture(
      <_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _twoServerListResponse(secondName: 'Server')),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
      ],
    );
    addTearDown(ambiguousFixture.close);
    await expectLater(
      ambiguousFixture.service.resolveBulkServers(
        profileId: ambiguousFixture.profile.id,
        selectors: <String>['Server'],
      ),
      throwsStateError,
    );
  });

  test(
    'bulk state selection reads resources when inventory status is null',
    () async {
      final _ServiceFixture runningFixture = _serviceFixture(
        <_ServiceTransport>[
          _ServiceTransport(<_ServiceReply>[
            _ServiceReply(200, _serverListResponse()),
            _ServiceReply(200, _serverListResponse(empty: true)),
            _ServiceReply(200, _resourceResponse('running')),
          ]),
        ],
      );
      addTearDown(runningFixture.close);
      final List<PterodactylClientServer> running = await runningFixture.service
          .resolveBulkServers(
            profileId: runningFixture.profile.id,
            all: true,
            state: PterodactylBulkServerState.running,
          );
      expect(running.single.status, isNull);

      final _ServiceFixture offlineFixture = _serviceFixture(
        <_ServiceTransport>[
          _ServiceTransport(<_ServiceReply>[
            _ServiceReply(200, _serverListResponse()),
            _ServiceReply(200, _serverListResponse(empty: true)),
            _ServiceReply(200, _resourceResponse('offline')),
          ]),
        ],
      );
      addTearDown(offlineFixture.close);
      final List<PterodactylClientServer> offline = await offlineFixture.service
          .resolveBulkServers(
            profileId: offlineFixture.profile.id,
            all: true,
            state: PterodactylBulkServerState.offline,
          );
      expect(offline.single.identifier, 'server01');
    },
  );

  test('bulk power preserves target order and exposes every failure', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _twoServerListResponse()),
        _ServiceReply(200, _serverListResponse(empty: true)),
        const _ServiceReply(204, ''),
        const _ServiceReply(
          500,
          '{"errors":[{"code":"SensitiveProviderDetail"}]}',
        ),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service.bulkPower(
      profileId: fixture.profile.id,
      serverIdentifiers: <String>['server02', 'server01'],
      signal: PterodactylPowerSignal.restart,
      concurrency: 1,
    );

    expect(
      result.items.map((PterodactylBulkItemResult item) => item.identifier),
      <String?>['server02', 'server01'],
    );
    expect(result.succeededCount, 1);
    expect(result.failedCount, 1);
    expect(
      result.items.last.error,
      'Pterodactyl request failed with HTTP 500.',
    );
    expect(result.items.last.error, isNot(contains('SensitiveProviderDetail')));
  });

  test('bulk power never exceeds requested concurrency', () async {
    final _ConcurrencyTransport transport = _ConcurrencyTransport();
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      transport,
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service.bulkPower(
      profileId: fixture.profile.id,
      serverIdentifiers: <String>['server01', 'server02', 'server03'],
      signal: PterodactylPowerSignal.start,
      concurrency: 2,
    );

    expect(result.isSuccess, isTrue);
    expect(transport.maximumPowerRequests, 2);
  });

  test('bulk reinstall uses Client permission without elevation', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _serverListResponse()),
        _ServiceReply(200, _serverListResponse(empty: true)),
        _ServiceReply(
          200,
          _serverAccessResponse(<String>['settings.reinstall']),
        ),
        const _ServiceReply(204, ''),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service.bulkReinstall(
      profileId: fixture.profile.id,
      serverIdentifiers: <String>['server01'],
    );

    expect(result.isSuccess, isTrue);
    expect(fixture.clientRoles, <bool>[false]);
    expect(
      fixture.transports.single.requests.last.uri.path,
      '/api/client/servers/server01/settings/reinstall',
    );
  });

  test('bulk delete reports Application-route partial failures', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _twoServerListResponse()),
        _ServiceReply(200, _serverListResponse(empty: true)),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        const _ServiceReply(204, ''),
        const _ServiceReply(409, '{"errors":[{"code":"Conflict"}]}'),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service.bulkDelete(
      profileId: fixture.profile.id,
      serverIdentifiers: <String>['server01', 'server02'],
      force: true,
      concurrency: 1,
    );

    expect(result.succeededCount, 1);
    expect(result.failedCount, 1);
    expect(
      fixture.transports.last.requests
          .skip(1)
          .map((PterodactylTransportRequest request) => request.uri.path),
      <String>[
        '/api/application/servers/9/force',
        '/api/application/servers/10/force',
      ],
    );
  });

  test('bulk create reserves unique allocations before requests', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _applicationServerListResponse(empty: false)),
        _ServiceReply(200, _userListResponse()),
        _ServiceReply(200, _nodeListResponse(diskMiB: 100000)),
        _ServiceReply(200, _allocationListResponse(4)),
        _ServiceReply(201, _applicationServerResponse(name: 'Clone One')),
        _ServiceReply(201, _applicationServerResponse(name: 'Clone Two')),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service
        .bulkCreateFromTemplate(
          profileId: fixture.profile.id,
          template: 'server01',
          names: <String>['Clone One', 'Clone Two'],
          ownerId: 5,
          concurrency: 2,
        );

    expect(result.isSuccess, isTrue);
    expect(fixture.clientRoles, <bool>[false]);
    expect(
      fixture.transports.single.requests
          .where(
            (PterodactylTransportRequest request) =>
                request.uri.path == '/api/client',
          )
          .toList(),
      isEmpty,
    );
    final List<Map<String, Object?>> payloads = fixture.transports.last.requests
        .where(
          (PterodactylTransportRequest request) =>
              request.method == 'POST' &&
              request.uri.path == '/api/application/servers',
        )
        .map(
          (PterodactylTransportRequest request) =>
              jsonDecode(request.body!) as Map<String, Object?>,
        )
        .toList(growable: false);
    final List<Map<String, Object?>> allocations = payloads
        .map(
          (Map<String, Object?> payload) =>
              payload['allocation']! as Map<String, Object?>,
        )
        .toList(growable: false);
    expect(
      allocations.map((Map<String, Object?> value) => value['default']),
      <int>[101, 102],
    );
    expect(
      allocations.map((Map<String, Object?> value) => value['additional']),
      <List<int>>[
        <int>[103],
        <int>[104],
      ],
    );
  });

  test(
    'bulk create aborts before mutation when allocations are insufficient',
    () async {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: false)),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _nodeListResponse(diskMiB: 100000)),
          _ServiceReply(200, _allocationListResponse(1)),
        ]),
      ]);
      addTearDown(fixture.close);

      await expectLater(
        fixture.service.bulkCreateFromTemplate(
          profileId: fixture.profile.id,
          template: 'server01',
          names: <String>['One', 'Two'],
          ownerId: 5,
        ),
        throwsStateError,
      );
      expect(
        fixture.transports.last.requests.where(
          (PterodactylTransportRequest request) =>
              request.method == 'POST' &&
              request.uri.path == '/api/application/servers',
        ),
        isEmpty,
      );
    },
  );

  test(
    'template create validates names and node viability before POST',
    () async {
      final _ServiceTransport longNameTransport = _ServiceTransport(
        const <_ServiceReply>[],
      );
      final _ServiceFixture longNameFixture = _serviceFixture(
        <_ServiceTransport>[longNameTransport],
      );
      addTearDown(longNameFixture.close);
      await expectLater(
        longNameFixture.service.bulkCreateFromTemplate(
          profileId: longNameFixture.profile.id,
          template: 'server01',
          names: <String>['valid', 'x' * 192],
          ownerId: 5,
        ),
        throwsArgumentError,
      );
      await expectLater(
        longNameFixture.service.createFromTemplate(
          profileId: longNameFixture.profile.id,
          template: 'server01',
          name: 'x' * 192,
          ownerId: 5,
        ),
        throwsArgumentError,
      );
      expect(longNameTransport.requests, isEmpty);

      final List<({String label, String nodeResponse, int? memory, int? disk})>
      cases = <({String label, String nodeResponse, int? memory, int? disk})>[
        (
          label: 'missing node',
          nodeResponse: _nodeListResponse(nodeId: 4, diskMiB: 100000),
          memory: null,
          disk: null,
        ),
        (
          label: 'maintenance',
          nodeResponse: _nodeListResponse(
            maintenanceMode: true,
            diskMiB: 100000,
          ),
          memory: null,
          disk: null,
        ),
        (
          label: 'aggregate capacity',
          nodeResponse: _nodeListResponse(
            memoryMiB: 4096,
            allocatedMemoryMiB: 2048,
            diskMiB: 100000,
          ),
          memory: null,
          disk: null,
        ),
        (
          label: 'already over capacity at zero request',
          nodeResponse: _nodeListResponse(
            memoryMiB: 4096,
            allocatedMemoryMiB: 4097,
            diskMiB: 100000,
          ),
          memory: 0,
          disk: 0,
        ),
      ];

      for (final ({String label, String nodeResponse, int? memory, int? disk})
          item
          in cases) {
        final _ServiceTransport transport = _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: false)),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, item.nodeResponse),
        ]);
        final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
          transport,
        ]);
        addTearDown(fixture.close);
        await expectLater(
          fixture.service.bulkCreateFromTemplate(
            profileId: fixture.profile.id,
            template: 'server01',
            names: const <String>['One', 'Two'],
            memoryMiB: item.memory,
            diskMiB: item.disk,
            ownerId: 5,
          ),
          throwsStateError,
          reason: item.label,
        );
        expect(
          transport.requests.where(
            (PterodactylTransportRequest request) => request.method == 'POST',
          ),
          isEmpty,
          reason: item.label,
        );
      }
    },
  );

  test('template capacity treats Panel overallocate -1 as unlimited', () async {
    final _ServiceTransport transport = _ServiceTransport(<_ServiceReply>[
      _ServiceReply(200, _applicationServerListResponse(empty: true)),
      _ServiceReply(200, _applicationServerListResponse(empty: false)),
      _ServiceReply(200, _userListResponse()),
      _ServiceReply(
        200,
        _nodeListResponse(
          memoryMiB: 1,
          allocatedMemoryMiB: 999999,
          memoryOverallocatePercent: -1,
          diskMiB: 1,
          allocatedDiskMiB: 999999,
          diskOverallocatePercent: -1,
        ),
      ),
      _ServiceReply(200, _allocationListResponse(2)),
      _ServiceReply(201, _applicationServerResponse(name: 'Unlimited')),
    ]);
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      transport,
    ]);
    addTearDown(fixture.close);

    final PterodactylBulkResult result = await fixture.service
        .bulkCreateFromTemplate(
          profileId: fixture.profile.id,
          template: 'server01',
          names: const <String>['Unlimited'],
          memoryMiB: 999999,
          diskMiB: 999999,
          ownerId: 5,
        );

    expect(result.isSuccess, isTrue);
    expect(
      transport.requests.where(
        (PterodactylTransportRequest request) => request.method == 'POST',
      ),
      hasLength(1),
    );
  });

  test(
    'creation catalog bootstraps an empty Panel and recommends Client owner',
    () async {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _accountResponse('panel-user')),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _nodeListResponse()),
          _ServiceReply(200, _nestListResponse()),
          _ServiceReply(200, _eggListResponse()),
          _ServiceReply(200, _allocationListResponse(2)),
        ]),
      ]);
      addTearDown(fixture.close);

      final PterodactylCreationCatalog catalog = await fixture.service
          .creationCatalog(fixture.profile.id);

      expect(catalog.templates, isEmpty);
      expect(catalog.users.single.username, 'panel-user');
      expect(catalog.recommendedOwnerId, 5);
      expect(catalog.nodes.single.name, 'Node One');
      expect(catalog.nests.single.name, 'Minecraft');
      expect(catalog.eggs.single.variables, hasLength(2));
      expect(catalog.freeAllocationCount(3), 2);
      expect(
        fixture.transports.expand(
          (_ServiceTransport transport) => transport.requests,
        ),
        isNot(
          contains(
            predicate<PterodactylTransportRequest>(
              (PterodactylTransportRequest request) => request.method == 'POST',
            ),
          ),
        ),
      );
    },
  );

  test(
    'creation catalog identifies the missing Application permission',
    () async {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _accountResponse('panel-user')),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
        ]),
      ]);
      addTearDown(fixture.close);

      await expectLater(
        fixture.service.creationCatalog(fixture.profile.id),
        throwsA(
          isA<PterodactylCreationCatalogPermissionException>().having(
            (PterodactylCreationCatalogPermissionException error) =>
                error.permission,
            'permission',
            'Users READ',
          ),
        ),
      );
      expect(
        fixture.transports
            .expand((_ServiceTransport transport) => transport.requests)
            .where(
              (PterodactylTransportRequest request) => request.method == 'POST',
            ),
        isEmpty,
      );
    },
  );

  test(
    'partial catalog preserves cloning when nest ACL is unavailable',
    () async {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _accountResponse('panel-user')),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: false)),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _nodeListResponse(diskMiB: 100000)),
          const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
          _ServiceReply(200, _allocationListResponse(2)),
        ]),
      ]);
      addTearDown(fixture.close);

      final PterodactylCreationCatalog catalog = await fixture.service
          .creationCatalog(fixture.profile.id, allowPartialEggInventory: true);

      expect(catalog.templates, hasLength(1));
      expect(catalog.users, hasLength(1));
      expect(catalog.nodes, hasLength(1));
      expect(catalog.nests, isEmpty);
      expect(catalog.eggs, isEmpty);
      expect(catalog.freeAllocationCount(3), 2);
      expect(catalog.eggInventoryUnavailablePermission, 'Nests READ');
    },
  );

  test('partial catalog clears nests when egg ACL is unavailable', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _accountResponse('panel-user')),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _applicationServerListResponse(empty: false)),
        _ServiceReply(200, _userListResponse()),
        _ServiceReply(200, _nodeListResponse(diskMiB: 100000)),
        _ServiceReply(200, _nestListResponse()),
        const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
        _ServiceReply(200, _allocationListResponse(2)),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylCreationCatalog catalog = await fixture.service
        .creationCatalog(fixture.profile.id, allowPartialEggInventory: true);

    expect(catalog.templates, hasLength(1));
    expect(catalog.nests, isEmpty);
    expect(catalog.eggs, isEmpty);
    expect(catalog.eggInventoryUnavailablePermission, 'Eggs READ');
  });

  test(
    'strict and empty-template catalogs still require egg inventory',
    () async {
      Future<void> expectDenied({
        required bool hasTemplate,
        required bool allowPartial,
      }) async {
        final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
          _ServiceTransport(<_ServiceReply>[
            _ServiceReply(200, _accountResponse('panel-user')),
          ]),
          _ServiceTransport(<_ServiceReply>[
            _ServiceReply(200, _applicationServerListResponse(empty: true)),
            _ServiceReply(
              200,
              _applicationServerListResponse(empty: !hasTemplate),
            ),
            _ServiceReply(200, _userListResponse()),
            _ServiceReply(200, _nodeListResponse()),
            const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
          ]),
        ]);
        addTearDown(fixture.close);

        await expectLater(
          fixture.service.creationCatalog(
            fixture.profile.id,
            allowPartialEggInventory: allowPartial,
          ),
          throwsA(
            isA<PterodactylCreationCatalogPermissionException>().having(
              (PterodactylCreationCatalogPermissionException error) =>
                  error.permission,
              'permission',
              'Nests READ',
            ),
          ),
        );
      }

      await expectDenied(hasTemplate: true, allowPartial: false);
      await expectDenied(hasTemplate: false, allowPartial: true);
    },
  );

  test('creation catalog types a Servers READ probe failure', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _accountResponse('panel-user')),
      ]),
      _ServiceTransport(<_ServiceReply>[
        const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
      ]),
      _ServiceTransport(const <_ServiceReply>[]),
    ]);
    addTearDown(fixture.close);

    await expectLater(
      fixture.service.creationCatalog(fixture.profile.id),
      throwsA(
        isA<PterodactylCreationCatalogPermissionException>().having(
          (PterodactylCreationCatalogPermissionException error) =>
              error.permission,
          'permission',
          'Servers READ',
        ),
      ),
    );
    expect(
      fixture.transports
          .expand((_ServiceTransport transport) => transport.requests)
          .where(
            (PterodactylTransportRequest request) => request.method == 'POST',
          ),
      isEmpty,
    );
  });

  test(
    'verification advertises create only after full catalog ACL probes',
    () async {
      final _ServiceFixture ready = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _serverListResponse(empty: true)),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _nodeListResponse()),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _allocationListResponse(1)),
          _ServiceReply(200, _nestListResponse()),
          _ServiceReply(200, _eggListResponse()),
        ]),
      ]);
      addTearDown(ready.close);

      final PterodactylVerification verified = await ready.service
          .verifyProfile(ready.profile);
      expect(verified.capabilities, contains(PterodactylCapability.create));

      final _ServiceFixture denied = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _serverListResponse(empty: true)),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _nodeListResponse()),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _allocationListResponse(1)),
          _ServiceReply(200, _nestListResponse()),
          const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
        ]),
      ]);
      addTearDown(denied.close);

      final PterodactylVerification rejected = await denied.service
          .verifyProfile(denied.profile);
      expect(
        rejected.capabilities,
        isNot(contains(PterodactylCapability.create)),
      );
      expect(rejected.warnings.single, contains('Eggs READ'));
    },
  );

  test(
    'verification accepts an Application template without egg ACLs',
    () async {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _serverListResponse(empty: true)),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerListResponse(empty: false)),
          _ServiceReply(200, _nodeListResponse()),
          _ServiceReply(200, _userListResponse()),
          _ServiceReply(200, _allocationListResponse(1)),
        ]),
      ]);
      addTearDown(fixture.close);

      final PterodactylVerification verified = await fixture.service
          .verifyProfile(fixture.profile);

      expect(verified.capabilities, contains(PterodactylCapability.create));
      expect(
        fixture.transports.last.requests.where(
          (PterodactylTransportRequest request) =>
              request.uri.path.contains('/nests'),
        ),
        isEmpty,
      );
    },
  );

  test('verification finds a usable egg after an empty first nest', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _serverListResponse(empty: true)),
        _ServiceReply(200, _serverListResponse(empty: true)),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _nodeListResponse()),
        _ServiceReply(200, _userListResponse()),
        _ServiceReply(200, _allocationListResponse(1)),
        _ServiceReply(200, _nestListResponse(count: 2)),
        _ServiceReply(200, _eggListResponse(empty: true)),
        _ServiceReply(200, _eggListResponse(nestId: 2)),
      ]),
    ]);
    addTearDown(fixture.close);

    final PterodactylVerification verified = await fixture.service
        .verifyProfile(fixture.profile);

    expect(verified.capabilities, contains(PterodactylCapability.create));
    expect(
      fixture.transports.last.requests
          .where(
            (PterodactylTransportRequest request) =>
                request.uri.path.contains('/eggs'),
          )
          .map((PterodactylTransportRequest request) => request.uri.path),
      <String>[
        '/api/application/nests/1/eggs',
        '/api/application/nests/2/eggs',
      ],
    );
  });

  test(
    'egg create succeeds from zero servers with defaults and unique ports',
    () async {
      final _ServiceTransport transport = _eggCreateTransport(
        allocationCount: 2,
        createdNames: const <String>['Bootstrap One', 'Bootstrap Two'],
      );
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        transport,
      ]);
      addTearDown(fixture.close);

      final PterodactylBulkResult result = await fixture.service
          .bulkCreateFromEgg(
            profileId: fixture.profile.id,
            names: const <String>['Bootstrap One', 'Bootstrap Two'],
            plan: _eggPlan(
              environment: const <String, String>{
                'REQUIRED_TOKEN': 'operator-value',
              },
            ),
            concurrency: 2,
          );

      expect(result.isSuccess, isTrue);
      final List<Map<String, Object?>> payloads = transport.requests
          .where(
            (PterodactylTransportRequest request) =>
                request.method == 'POST' &&
                request.uri.path == '/api/application/servers',
          )
          .map(
            (PterodactylTransportRequest request) =>
                jsonDecode(request.body!) as Map<String, Object?>,
          )
          .toList(growable: false);
      expect(payloads, hasLength(2));
      expect(
        payloads.map(
          (Map<String, Object?> payload) =>
              (payload['allocation']! as Map<String, Object?>)['default'],
        ),
        <int>[101, 102],
      );
      for (final Map<String, Object?> payload in payloads) {
        expect(payload['user'], 5);
        expect(payload['egg'], 2);
        expect(payload['docker_image'], _eggImage);
        expect(payload['startup'], _eggStartup);
        expect(payload['environment'], <String, Object?>{
          'SERVER_JARFILE': 'server.jar',
          'REQUIRED_TOKEN': 'operator-value',
        });
        expect(payload['limits'], containsPair('memory', 4096));
        expect(payload['limits'], containsPair('disk', 0));
        expect(payload['limits'], containsPair('cpu', 0));
        expect(payload['feature_limits'], <String, Object?>{
          'databases': 0,
          'allocations': 0,
          'backups': 0,
        });
        expect(payload['oom_disabled'], isTrue);
      }
    },
  );

  test(
    'single egg create returns POST response without inventory reload',
    () async {
      final _ServiceTransport transport = _eggCreateTransport(
        allocationCount: 1,
        createdNames: const <String>['Bootstrap'],
      );
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        transport,
      ]);
      addTearDown(fixture.close);

      final PterodactylApplicationServer server = await fixture.service
          .createFromEgg(
            profileId: fixture.profile.id,
            name: 'Bootstrap',
            plan: _eggPlan(
              environment: const <String, String>{
                'REQUIRED_TOKEN': 'operator-value',
              },
            ),
          );

      expect(server.name, 'Bootstrap');
      expect(
        transport.requests
            .where(
              (PterodactylTransportRequest request) =>
                  request.uri.path == '/api/application/servers',
            )
            .length,
        2,
      );
    },
  );

  test('egg create rejects stale catalog inputs before every POST', () async {
    final List<
      ({
        String label,
        _ServiceTransport transport,
        PterodactylEggCreatePlan plan,
      })
    >
    cases =
        <
          ({
            String label,
            _ServiceTransport transport,
            PterodactylEggCreatePlan plan,
          })
        >[
          (
            label: 'owner',
            transport: _eggCreateTransport(ownerId: 6),
            plan: _eggPlan(),
          ),
          (
            label: 'node',
            transport: _eggCreateTransport(nodeId: 4),
            plan: _eggPlan(),
          ),
          (
            label: 'maintenance node',
            transport: _eggCreateTransport(maintenanceMode: true),
            plan: _eggPlan(),
          ),
          (
            label: 'egg',
            transport: _eggCreateTransport(eggId: 3),
            plan: _eggPlan(),
          ),
          (
            label: 'image',
            transport: _eggCreateTransport(),
            plan: _eggPlan(dockerImage: 'invalid:image'),
          ),
          (
            label: 'startup drift',
            transport: _eggCreateTransport(),
            plan: _eggPlan(startup: 'changed startup'),
          ),
          (
            label: 'missing startup',
            transport: _eggCreateTransport(eggStartup: null),
            plan: _eggPlan(),
          ),
          (
            label: 'unknown environment',
            transport: _eggCreateTransport(),
            plan: _eggPlan(
              environment: const <String, String>{'UNKNOWN': 'value'},
            ),
          ),
          (
            label: 'missing required variable',
            transport: _eggCreateTransport(requiredDefault: ''),
            plan: _eggPlan(),
          ),
          (
            label: 'insufficient allocations',
            transport: _eggCreateTransport(allocationCount: 1),
            plan: _eggPlan(),
          ),
          (
            label: 'memory capacity',
            transport: _eggCreateTransport(
              nodeMemoryMiB: 4096,
              allocatedMemoryMiB: 2048,
            ),
            plan: _eggPlan(),
          ),
        ];

    for (final ({
          String label,
          _ServiceTransport transport,
          PterodactylEggCreatePlan plan,
        })
        item
        in cases) {
      final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
        item.transport,
      ]);
      addTearDown(fixture.close);
      await expectLater(
        fixture.service.bulkCreateFromEgg(
          profileId: fixture.profile.id,
          names: const <String>['One', 'Two'],
          plan: item.plan,
        ),
        throwsStateError,
        reason: item.label,
      );
      expect(
        item.transport.requests.where(
          (PterodactylTransportRequest request) => request.method == 'POST',
        ),
        isEmpty,
        reason: item.label,
      );
    }
  });

  test('egg create rejects all invalid names before API inventory', () async {
    final _ServiceTransport transport = _ServiceTransport(
      const <_ServiceReply>[],
    );
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      transport,
    ]);
    addTearDown(fixture.close);

    await expectLater(
      fixture.service.bulkCreateFromEgg(
        profileId: fixture.profile.id,
        names: <String>['valid', 'x' * 192],
        plan: _eggPlan(),
      ),
      throwsArgumentError,
    );
    expect(transport.requests, isEmpty);
  });

  test('openConsole returns an unstarted owned connection', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-pterodactyl-console-service-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylProfile profile = PterodactylProfile(
      id: 'remote',
      name: 'Remote',
      panelUri: Uri.parse('https://panel.example.test'),
    );
    final PterodactylProfileStore profiles = PterodactylProfileStore(
      temporary.path,
    )..save(profile);
    final String credentialVariable =
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        );
    final String originVariable =
        PterodactylCredentialStore.environmentOriginVariableFor(profile);
    final PterodactylService service = PterodactylService(
      profileStore: profiles,
      credentialStore: PterodactylCredentialStore(
        temporary.path,
        environment: <String, String>{
          credentialVariable: 'client-api-key',
          originVariable: profile.origin,
        },
      ),
    );
    final _RecordingConnector connector = _RecordingConnector();

    final PterodactylConsoleConnection connection = await service.openConsole(
      profile.id,
      'abc12345',
      connector: connector,
    );

    expect(connector.connectCount, 0);
    await expectLater(connection.requestStats(), throwsStateError);
    await connection.close();
    await connection.done;
    expect(connector.connectCount, 0);
  });

  test('rename uses Client permission without elevated fallback', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _serverListResponse()),
        _ServiceReply(200, _serverListResponse(empty: true)),
        _ServiceReply(200, _serverAccessResponse(<String>['settings.rename'])),
        const _ServiceReply(204, ''),
      ]),
    ]);
    addTearDown(fixture.close);

    await fixture.service.rename(
      profileId: fixture.profile.id,
      server: 'server01',
      name: 'Renamed',
    );

    expect(fixture.clientRoles, <bool>[false]);
    expect(
      fixture.transports.single.requests.map((request) => request.uri.path),
      contains('/api/client/servers/server01/settings/rename'),
    );
  });

  test('rename falls back to the dedicated Application credential', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _serverListResponse()),
        _ServiceReply(200, _serverListResponse(empty: true)),
        _ServiceReply(200, _serverAccessResponse(const <String>[])),
      ]),
      _ServiceTransport(<_ServiceReply>[
        const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _applicationServerResponse()),
        _ServiceReply(200, _applicationServerResponse(name: 'Renamed')),
      ]),
    ], includeApplicationCredential: true);
    addTearDown(fixture.close);

    await fixture.service.rename(
      profileId: fixture.profile.id,
      server: 'server01',
      name: 'Renamed',
    );

    expect(fixture.clientRoles, <bool>[false, false, true]);
    expect(
      fixture.transports.first.requests.any(
        (PterodactylTransportRequest request) =>
            request.uri.path.endsWith('/settings/rename'),
      ),
      isFalse,
    );
    final PterodactylTransportRequest update =
        fixture.transports.last.requests.last;
    expect(update.uri.path, '/api/application/servers/9/details');
    expect(
      update.headers[HttpHeaders.authorizationHeader],
      'Bearer application-secret',
    );
    expect(jsonDecode(update.body!), <String, Object?>{
      'external_id': 'external-9',
      'name': 'Renamed',
      'user': 5,
      'description': 'Existing description',
    });
  });

  test('account identity and existing SSH key are idempotent', () async {
    final String canonical = PterodactylAccountSshKey.normalizePublicKey(
      _ed25519PublicKey,
    );
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(
          200,
          jsonEncode(<String, Object?>{
            'object': 'user',
            'attributes': <String, Object?>{'username': 'panel-user'},
          }),
        ),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _sshKeyListResponse(canonical)),
      ]),
    ]);
    addTearDown(fixture.close);

    expect(
      await fixture.service.accountUsername(fixture.profile.id),
      'panel-user',
    );
    await fixture.service.ensureAccountSshPublicKey(
      fixture.profile.id,
      name: 'Multiplexor SMB',
      publicKey: _ed25519PublicKey,
    );

    expect(fixture.clientRoles, <bool>[false, false]);
    expect(fixture.transports.last.requests, hasLength(1));
    expect(
      fixture.transports.last.requests.single.uri.path,
      '/api/client/account/ssh-keys',
    );
  });

  test('SSH key duplicate race succeeds only after an exact recheck', () async {
    final String canonical = PterodactylAccountSshKey.normalizePublicKey(
      _ed25519PublicKey,
    );
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _sshKeyListResponse(null)),
        const _ServiceReply(422, '{"errors":[{"code":"ValidationException"}]}'),
        _ServiceReply(200, _sshKeyListResponse(canonical)),
      ]),
    ]);
    addTearDown(fixture.close);

    await fixture.service.ensureAccountSshPublicKey(
      fixture.profile.id,
      name: 'Multiplexor SMB',
      publicKey: _ed25519PublicKey,
    );

    expect(
      fixture.transports.single.requests.map((request) => request.method),
      <String>['GET', 'POST', 'GET'],
    );
  });

  test('credential verification exercises the requested key role', () async {
    final _ServiceFixture clientFixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(
          200,
          jsonEncode(<String, Object?>{
            'object': 'user',
            'attributes': <String, Object?>{'username': 'panel-user'},
          }),
        ),
      ]),
    ]);
    addTearDown(clientFixture.close);

    await clientFixture.service.verifyCredential(
      clientFixture.profile,
      PterodactylCredentialRole.client,
    );
    expect(clientFixture.clientRoles, <bool>[false]);
    expect(
      clientFixture.transports.single.requests.single.uri.path,
      '/api/client/account',
    );

    final _ServiceFixture applicationFixture = _serviceFixture(
      <_ServiceTransport>[
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
        ]),
      ],
      includeApplicationCredential: true,
    );
    addTearDown(applicationFixture.close);

    await applicationFixture.service.verifyCredential(
      applicationFixture.profile,
      PterodactylCredentialRole.application,
    );
    expect(applicationFixture.clientRoles, <bool>[true]);
    final PterodactylTransportRequest request =
        applicationFixture.transports.single.requests.single;
    expect(request.uri.path, '/api/application/servers');
    expect(
      request.headers[HttpHeaders.authorizationHeader],
      'Bearer application-secret',
    );
  });

  test('credential verification rejects an invalid dedicated key', () async {
    final _ServiceFixture fixture = _serviceFixture(<_ServiceTransport>[
      _ServiceTransport(<_ServiceReply>[
        const _ServiceReply(403, '{"errors":[{"code":"Forbidden"}]}'),
      ]),
    ], includeApplicationCredential: true);
    addTearDown(fixture.close);

    await expectLater(
      fixture.service.verifyCredential(
        fixture.profile,
        PterodactylCredentialRole.application,
      ),
      throwsA(isA<PterodactylApiException>()),
    );
    expect(fixture.clientRoles, <bool>[true]);
  });

  test(
    'profile removal restores metadata and both secrets after a mid-delete failure',
    () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-pterodactyl-remove-rollback-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final File security = File('${temporary.path}/security-stub')
        ..writeAsStringSync('''#!/bin/sh
case "\$1" in
  delete-generic-password)
    case "\$*" in
      *:application:*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  add-generic-password)
    IFS= read -r ignored || true
    exit 0
    ;;
  find-generic-password)
    exit 44
    ;;
esac
exit 0
''');
      expect(
        Process.runSync('chmod', <String>['700', security.path]).exitCode,
        0,
      );
      final PterodactylProfile profile = PterodactylProfile(
        id: 'remote',
        name: 'Remote',
        panelUri: Uri.parse('https://panel.example.test'),
      );
      final PterodactylProfile secondary = PterodactylProfile(
        id: 'secondary',
        name: 'Secondary',
        panelUri: Uri.parse('https://secondary.example.test'),
      );
      final PterodactylProfileStore profiles =
          PterodactylProfileStore(temporary.path)
            ..save(profile)
            ..save(secondary)
            ..setActive(profile.id);
      final PterodactylCredentialStore credentials =
          PterodactylCredentialStore(
              temporary.path,
              environment: const <String, String>{},
              securityExecutable: security.path,
            )
            ..putForSession(
              profile,
              PterodactylCredentialRole.client,
              PterodactylCredential('ptlc_original'),
            )
            ..putForSession(
              profile,
              PterodactylCredentialRole.application,
              PterodactylCredential('ptla_original'),
            );
      final PterodactylService service = PterodactylService(
        profileStore: profiles,
        credentialStore: credentials,
      );

      await expectLater(service.removeProfile(profile.id), throwsStateError);

      expect(profiles.load(profile.id), profile);
      expect(profiles.loadActiveId(), profile.id);
      expect(
        (await credentials.read(
          profile,
          PterodactylCredentialRole.client,
        ))?.value,
        'ptlc_original',
      );
      expect(
        (await credentials.read(
          profile,
          PterodactylCredentialRole.application,
        ))?.value,
        'ptla_original',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'profile-store failure restores credentials and preserves the profile',
    () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-pterodactyl-remove-profile-failure-',
      );
      addTearDown(() {
        Process.runSync('chmod', <String>['700', temporary.path]);
        temporary.deleteSync(recursive: true);
      });
      final File security = File('${temporary.path}/security-stub')
        ..writeAsStringSync('''#!/bin/sh
case "\$1" in
  delete-generic-password) exit 0 ;;
  add-generic-password)
    IFS= read -r ignored || true
    exit 0
    ;;
  find-generic-password) exit 44 ;;
esac
exit 0
''');
      expect(
        Process.runSync('chmod', <String>['700', security.path]).exitCode,
        0,
      );
      final PterodactylProfile profile = PterodactylProfile(
        id: 'remote',
        name: 'Remote',
        panelUri: Uri.parse('https://panel.example.test'),
      );
      final PterodactylProfileStore profiles = PterodactylProfileStore(
        temporary.path,
      )..save(profile);
      final PterodactylCredentialStore credentials =
          PterodactylCredentialStore(
              temporary.path,
              environment: const <String, String>{},
              securityExecutable: security.path,
            )
            ..putForSession(
              profile,
              PterodactylCredentialRole.client,
              PterodactylCredential('ptlc_untouched'),
            )
            ..putForSession(
              profile,
              PterodactylCredentialRole.application,
              PterodactylCredential('ptla_untouched'),
            );
      final PterodactylService service = PterodactylService(
        profileStore: profiles,
        credentialStore: credentials,
      );
      expect(
        Process.runSync('chmod', <String>['500', temporary.path]).exitCode,
        0,
      );
      try {
        await expectLater(service.removeProfile(profile.id), throwsStateError);
      } finally {
        Process.runSync('chmod', <String>['700', temporary.path]);
      }

      expect(profiles.load(profile.id), profile);
      expect(profiles.loadActiveId(), profile.id);
      expect(
        (await credentials.read(
          profile,
          PterodactylCredentialRole.client,
        ))?.value,
        'ptlc_untouched',
      );
      expect(
        (await credentials.read(
          profile,
          PterodactylCredentialRole.application,
        ))?.value,
        'ptla_untouched',
      );
    },
    skip: Platform.isWindows || _runningAsRoot,
  );
}

bool get _runningAsRoot {
  if (Platform.isWindows) return false;
  final ProcessResult result = Process.runSync('id', <String>['-u']);
  return result.exitCode == 0 && result.stdout.toString().trim() == '0';
}

final class _RecordingConnector implements PterodactylConsoleSocketConnector {
  int connectCount = 0;

  @override
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  }) async {
    connectCount++;
    throw StateError('Unexpected socket connection.');
  }
}

final class _ServiceFixture {
  _ServiceFixture({
    required this.directory,
    required this.profile,
    required this.service,
    required this.transports,
    required this.clientRoles,
  });

  final Directory directory;
  final PterodactylProfile profile;
  final PterodactylService service;
  final List<_ServiceTransport> transports;
  final List<bool> clientRoles;

  void close() => directory.deleteSync(recursive: true);
}

_ServiceFixture _serviceFixture(
  List<_ServiceTransport> transports, {
  bool includeApplicationCredential = false,
}) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'multiplexor-pterodactyl-lifecycle-service-',
  );
  final PterodactylProfile profile = PterodactylProfile(
    id: 'remote',
    name: 'Remote',
    panelUri: Uri.parse('https://panel.example.test'),
  );
  final PterodactylProfileStore profiles = PterodactylProfileStore(
    directory.path,
  )..save(profile);
  final Map<String, String> environment = <String, String>{
    PterodactylCredentialStore.environmentVariableFor(
      profile,
      PterodactylCredentialRole.client,
    ): 'client-secret',
    PterodactylCredentialStore.environmentOriginVariableFor(profile):
        profile.origin,
    if (includeApplicationCredential)
      PterodactylCredentialStore.environmentVariableFor(
        profile,
        PterodactylCredentialRole.application,
      ): 'application-secret',
  };
  final List<bool> clientRoles = <bool>[];
  int clientIndex = 0;
  final PterodactylService service = PterodactylService(
    profileStore: profiles,
    credentialStore: PterodactylCredentialStore(
      directory.path,
      environment: environment,
    ),
    clientFactory:
        ({
          required PterodactylProfile profile,
          required PterodactylCredential clientCredential,
          PterodactylCredential? applicationCredential,
        }) {
          clientRoles.add(applicationCredential != null);
          return PterodactylClient(
            baseUri: profile.panelUri,
            clientKey: clientCredential.value,
            applicationKey:
                applicationCredential?.value ?? clientCredential.value,
            transport: transports[clientIndex++],
          );
        },
  );
  return _ServiceFixture(
    directory: directory,
    profile: profile,
    service: service,
    transports: transports,
    clientRoles: clientRoles,
  );
}

String _serverListResponse({bool empty = false, bool isOwner = false}) =>
    jsonEncode(<String, Object?>{
      'object': 'list',
      'data': empty
          ? <Object?>[]
          : <Object?>[
              <String, Object?>{
                'object': 'server',
                'attributes': _clientServerAttributes(isOwner: isOwner),
              },
            ],
      'meta': _pagination(empty ? 0 : 1),
    });

String _twoServerListResponse({String secondName = 'Server Two'}) =>
    jsonEncode(<String, Object?>{
      'object': 'list',
      'data': <Object?>[
        <String, Object?>{
          'object': 'server',
          'attributes': _clientServerAttributes(),
        },
        <String, Object?>{
          'object': 'server',
          'attributes': <String, Object?>{
            ..._clientServerAttributes(),
            'identifier': 'server02',
            'internal_id': 10,
            'uuid': '00000000-0000-0000-0000-000000000010',
            'name': secondName,
          },
        },
      ],
      'meta': _pagination(2),
    });

String _threeServerListResponse() => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    for (int index = 1; index <= 3; index++)
      <String, Object?>{
        'object': 'server',
        'attributes': <String, Object?>{
          ..._clientServerAttributes(),
          'identifier': 'server0$index',
          'internal_id': 8 + index,
          'uuid': '00000000-0000-0000-0000-00000000000${8 + index}',
          'name': 'Server $index',
        },
      },
  ],
  'meta': _pagination(3),
});

String _resourceResponse(String state) => jsonEncode(<String, Object?>{
  'object': 'stats',
  'attributes': <String, Object?>{
    'current_state': state,
    'is_suspended': false,
    'resources': <String, Object?>{
      'memory_bytes': 0,
      'cpu_absolute': 0.0,
      'disk_bytes': 0,
      'network_rx_bytes': 0,
      'network_tx_bytes': 0,
      'uptime': 0,
    },
  },
});

String _serverAccessResponse(List<String> permissions) =>
    jsonEncode(<String, Object?>{
      'object': 'server',
      'attributes': _clientServerAttributes(),
      'meta': <String, Object?>{
        'is_server_owner': false,
        'user_permissions': permissions,
      },
    });

Map<String, Object?> _clientServerAttributes({
  bool isOwner = false,
}) => <String, Object?>{
  'identifier': 'server01',
  'internal_id': 9,
  'uuid': '00000000-0000-0000-0000-000000000009',
  'name': 'Server',
  'node': 'node',
  'description': 'Existing description',
  'server_owner': isOwner,
  'is_node_under_maintenance': false,
  'status': null,
  'sftp_details': <String, Object?>{'ip': 'node.example.test', 'port': 2022},
  'limits': <String, Object?>{
    'memory': 4096,
    'swap': 0,
    'disk': 10000,
    'io': 500,
    'cpu': 200,
    'threads': null,
    'oom_disabled': false,
  },
  'feature_limits': <String, Object?>{
    'databases': 1,
    'allocations': 2,
    'backups': 3,
  },
  'relationships': <String, Object?>{
    'allocations': <String, Object?>{'data': <Object?>[]},
  },
};

String _applicationServerListResponse({required bool empty}) =>
    jsonEncode(<String, Object?>{
      'object': 'list',
      'data': empty
          ? <Object?>[]
          : <Object?>[
              <String, Object?>{
                'object': 'server',
                'attributes': _applicationServerAttributes(),
              },
            ],
      'meta': _pagination(empty ? 0 : 1),
    });

String _applicationServerResponse({String name = 'Server'}) =>
    jsonEncode(<String, Object?>{
      'object': 'server',
      'attributes': <String, Object?>{
        ..._applicationServerAttributes(),
        'name': name,
      },
    });

const String _eggImage = 'ghcr.io/pterodactyl/yolks:java_21';
const String _eggStartup = 'java -jar {{SERVER_JARFILE}}';

PterodactylEggCreatePlan _eggPlan({
  int ownerId = 5,
  int nodeId = 3,
  int eggId = 2,
  String dockerImage = _eggImage,
  String startup = _eggStartup,
  Map<String, String> environment = const <String, String>{},
  int memoryMiB = 4096,
  int diskMiB = 0,
  int cpuPercent = 0,
}) => PterodactylEggCreatePlan(
  ownerId: ownerId,
  nodeId: nodeId,
  eggId: eggId,
  dockerImage: dockerImage,
  startup: startup,
  environment: environment,
  memoryMiB: memoryMiB,
  diskMiB: diskMiB,
  cpuPercent: cpuPercent,
);

_ServiceTransport _eggCreateTransport({
  int ownerId = 5,
  int nodeId = 3,
  bool maintenanceMode = false,
  int nodeMemoryMiB = 16384,
  int allocatedMemoryMiB = 0,
  int eggId = 2,
  Object? eggStartup = _eggStartup,
  String requiredDefault = 'default-token',
  int allocationCount = 2,
  List<String> createdNames = const <String>[],
}) => _ServiceTransport(<_ServiceReply>[
  _ServiceReply(200, _applicationServerListResponse(empty: true)),
  _ServiceReply(200, _userListResponse(ownerId: ownerId)),
  _ServiceReply(
    200,
    _nodeListResponse(
      nodeId: nodeId,
      maintenanceMode: maintenanceMode,
      memoryMiB: nodeMemoryMiB,
      allocatedMemoryMiB: allocatedMemoryMiB,
    ),
  ),
  _ServiceReply(200, _nestListResponse()),
  _ServiceReply(
    200,
    _eggListResponse(
      eggId: eggId,
      startup: eggStartup,
      requiredDefault: requiredDefault,
    ),
  ),
  _ServiceReply(200, _allocationListResponse(allocationCount)),
  for (final String name in createdNames)
    _ServiceReply(201, _applicationServerResponse(name: name)),
]);

String _accountResponse(String username) => jsonEncode(<String, Object?>{
  'object': 'user',
  'attributes': <String, Object?>{'username': username},
});

String _userListResponse({int ownerId = 5}) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    <String, Object?>{
      'object': 'user',
      'attributes': <String, Object?>{
        'id': ownerId,
        'external_id': null,
        'uuid': '00000000-0000-0000-0000-000000000005',
        'username': 'panel-user',
        'email': 'panel-user@example.test',
        'first_name': 'Panel',
        'last_name': 'User',
        'root_admin': true,
      },
    },
  ],
  'meta': _pagination(1),
});

String _nodeListResponse({
  int nodeId = 3,
  bool maintenanceMode = false,
  int memoryMiB = 16384,
  int allocatedMemoryMiB = 0,
  int memoryOverallocatePercent = 0,
  int diskMiB = 1024,
  int allocatedDiskMiB = 0,
  int diskOverallocatePercent = 20,
}) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    <String, Object?>{
      'object': 'node',
      'attributes': <String, Object?>{
        'id': nodeId,
        'uuid': '00000000-0000-0000-0000-000000000003',
        'name': 'Node One',
        'description': null,
        'fqdn': 'node.example.test',
        'scheme': 'https',
        'public': true,
        'behind_proxy': false,
        'maintenance_mode': maintenanceMode,
        'memory': memoryMiB,
        'memory_overallocate': memoryOverallocatePercent,
        'disk': diskMiB,
        'disk_overallocate': diskOverallocatePercent,
        'allocated_resources': <String, Object?>{
          'memory': allocatedMemoryMiB,
          'disk': allocatedDiskMiB,
        },
        'daemon_listen': 8080,
        'daemon_sftp': 2022,
      },
    },
  ],
  'meta': _pagination(1),
});

String _nestListResponse({int count = 1}) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    for (int index = 1; index <= count; index++)
      <String, Object?>{
        'object': 'nest',
        'attributes': <String, Object?>{
          'id': index,
          'uuid': '00000000-0000-0000-0000-00000000000$index',
          'name': index == 1 ? 'Minecraft' : 'Voice Servers',
          'author': 'support@example.test',
          'description': null,
        },
      },
  ],
  'meta': _pagination(count),
});

String _eggListResponse({
  bool empty = false,
  int eggId = 2,
  int nestId = 1,
  Object? startup = _eggStartup,
  String requiredDefault = 'default-token',
}) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': empty
      ? <Object?>[]
      : <Object?>[
          <String, Object?>{
            'object': 'egg',
            'attributes': <String, Object?>{
              'id': eggId,
              'uuid': '00000000-0000-0000-0000-000000000002',
              'name': 'Paper',
              'nest': nestId,
              'author': 'support@example.test',
              'description': 'Minecraft Java server',
              'startup': startup,
              'docker_images': <String, Object?>{'Java 21': _eggImage},
              'relationships': <String, Object?>{
                'variables': <String, Object?>{
                  'data': <Object?>[
                    _eggVariableResource(
                      name: 'Server Jar File',
                      environmentVariable: 'SERVER_JARFILE',
                      defaultValue: 'server.jar',
                    ),
                    _eggVariableResource(
                      name: 'Required Token',
                      environmentVariable: 'REQUIRED_TOKEN',
                      defaultValue: requiredDefault,
                    ),
                  ],
                },
              },
            },
          },
        ],
});

Map<String, Object?> _eggVariableResource({
  required String name,
  required String environmentVariable,
  required String defaultValue,
}) => <String, Object?>{
  'object': 'egg_variable',
  'attributes': <String, Object?>{
    'name': name,
    'description': 'Configure $name.',
    'env_variable': environmentVariable,
    'default_value': defaultValue,
    'rules': 'required|string',
    'user_editable': true,
    'user_viewable': true,
  },
};

String _allocationListResponse(int count) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': <Object?>[
    for (int index = 0; index < count; index++)
      <String, Object?>{
        'object': 'allocation',
        'attributes': <String, Object?>{
          'id': 101 + index,
          'ip': '127.0.0.1',
          'alias': null,
          'port': 25565 + index,
          'notes': null,
          'assigned': false,
        },
      },
  ],
  'meta': _pagination(count),
});

Map<String, Object?> _applicationServerAttributes() => <String, Object?>{
  'id': 9,
  'external_id': 'external-9',
  'uuid': '00000000-0000-0000-0000-000000000009',
  'identifier': 'server01',
  'name': 'Server',
  'description': 'Existing description',
  'status': null,
  'user': 5,
  'node': 3,
  'allocation': 77,
  'nest': 1,
  'egg': 2,
  'limits': <String, Object?>{
    'memory': 4096,
    'swap': 0,
    'disk': 10000,
    'io': 500,
    'cpu': 200,
    'threads': null,
    'oom_disabled': false,
  },
  'feature_limits': <String, Object?>{
    'databases': 1,
    'allocations': 2,
    'backups': 3,
  },
  'container': <String, Object?>{
    'image': 'ghcr.io/pterodactyl/yolks:java_21',
    'startup_command': 'java -jar server.jar',
    'environment': <String, Object?>{'SERVER_JARFILE': 'server.jar'},
    'skip_scripts': false,
  },
};

Map<String, Object?> _pagination(int count) => <String, Object?>{
  'pagination': <String, Object?>{
    'total': count,
    'count': count,
    'per_page': 100,
    'current_page': 1,
    'total_pages': 1,
  },
};

String _sshKeyListResponse(String? publicKey) => jsonEncode(<String, Object?>{
  'object': 'list',
  'data': publicKey == null
      ? <Object?>[]
      : <Object?>[
          <String, Object?>{
            'object': 'ssh_key',
            'attributes': <String, Object?>{
              'name': 'Multiplexor SMB',
              'fingerprint': 'SHA256:fixture',
              'public_key': publicKey,
              'created_at': '2026-08-12T12:00:00+00:00',
            },
          },
        ],
});

const String _ed25519PublicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOaXIq09NH4a93EVdrvHYiZ67Wj+'
    'GBEBQ9ou4W0qSYm2 multiplexor@test';

final class _ServiceReply {
  const _ServiceReply(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

final class _ServiceTransport implements PterodactylTransport {
  _ServiceTransport(this._replies);

  final List<_ServiceReply> _replies;
  final List<PterodactylTransportRequest> requests =
      <PterodactylTransportRequest>[];

  @override
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  ) async {
    requests.add(request);
    final _ServiceReply reply = _replies.removeAt(0);
    return PterodactylTransportResponse(
      statusCode: reply.statusCode,
      body: reply.body,
    );
  }

  @override
  void close() {}
}

final class _ConcurrencyTransport extends _ServiceTransport {
  _ConcurrencyTransport() : super(const <_ServiceReply>[]);

  int activePowerRequests = 0;
  int maximumPowerRequests = 0;

  @override
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  ) async {
    requests.add(request);
    if (request.uri.path == '/api/client') {
      final bool adminAll = request.uri.queryParameters['type'] == 'admin-all';
      return PterodactylTransportResponse(
        statusCode: 200,
        body: adminAll
            ? _serverListResponse(empty: true)
            : _threeServerListResponse(),
      );
    }
    if (request.uri.path.endsWith('/power')) {
      activePowerRequests += 1;
      if (activePowerRequests > maximumPowerRequests) {
        maximumPowerRequests = activePowerRequests;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      activePowerRequests -= 1;
      return const PterodactylTransportResponse(statusCode: 204, body: '');
    }
    throw StateError('Unexpected request: ${request.uri}');
  }
}
