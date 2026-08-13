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

  test('shared servers are not offered as creation templates', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-pterodactyl-service-',
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
    final PterodactylService service = PterodactylService(
      profileStore: profiles,
      credentialStore: PterodactylCredentialStore(
        temporary.path,
        environment: const <String, String>{},
      ),
    );

    expect(
      service.canUseAsTemplate(profile.id, _server(isOwner: false)),
      isFalse,
    );
    expect(
      service.canUseAsTemplate(profile.id, _server(isOwner: true)),
      isTrue,
    );
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
        _ServiceReply(200, _serverListResponse(isOwner: true)),
        _ServiceReply(200, _serverListResponse(empty: true)),
      ]),
      _ServiceTransport(<_ServiceReply>[
        _ServiceReply(200, _applicationServerListResponse(empty: true)),
        _ServiceReply(200, _applicationServerResponse()),
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
          concurrency: 2,
        );

    expect(result.isSuccess, isTrue);
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
          _ServiceReply(200, _serverListResponse(isOwner: true)),
          _ServiceReply(200, _serverListResponse(empty: true)),
        ]),
        _ServiceTransport(<_ServiceReply>[
          _ServiceReply(200, _applicationServerListResponse(empty: true)),
          _ServiceReply(200, _applicationServerResponse()),
          _ServiceReply(200, _allocationListResponse(1)),
        ]),
      ]);
      addTearDown(fixture.close);

      await expectLater(
        fixture.service.bulkCreateFromTemplate(
          profileId: fixture.profile.id,
          template: 'server01',
          names: <String>['One', 'Two'],
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

PterodactylClientServer _server({required bool isOwner}) =>
    PterodactylClientServer(
      identifier: 'abc12345',
      internalId: 1,
      uuid: '00000000-0000-0000-0000-000000000001',
      name: 'Template',
      nodeName: 'node',
      description: '',
      isOwner: isOwner,
      isNodeUnderMaintenance: false,
      status: null,
      sftpHost: 'panel.example.test',
      sftpPort: 2022,
      limits: const PterodactylServerLimits(
        memoryMiB: 1024,
        swapMiB: 0,
        diskMiB: 1024,
        ioWeight: 500,
        cpuPercent: 100,
        threads: null,
        oomDisabled: false,
      ),
      featureLimits: const PterodactylFeatureLimits(
        databases: 0,
        allocations: 0,
        backups: 0,
      ),
      allocations: const <PterodactylAllocation>[],
    );

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
