import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_client.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_create_push.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reclaims one exact external-id server after an ambiguous create',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent resolved = _resolvedIntent();
      final PterodactylCreatePushIntentCoordinator coordinator =
          PterodactylCreatePushIntentCoordinator(
            metadataDirectoryPath: fixture.directory.path,
            service: fixture.service,
          );

      final PterodactylCreatePushIntentClaim first = await coordinator.claim(
        id: resolved.id,
        confirmationToken: resolved.confirmationToken,
        transferPlan: resolved.transferPlan,
        creation: resolved.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      );
      try {
        expect(first.shouldCreate, isTrue);
        expect(first.server, isNull);
        first.record(state: 'creating');
        first.record(state: 'create-unknown', failure: 'HTTP response lost');
      } finally {
        first.close();
      }

      fixture.transport.servers = <JsonObject>[
        _server(externalId: resolved.id),
      ];
      final PterodactylCreatePushIntentClaim resumed = await coordinator.claim(
        id: resolved.id,
        confirmationToken: resolved.confirmationToken,
        transferPlan: resolved.transferPlan,
        creation: resolved.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      );
      try {
        expect(resumed.shouldCreate, isFalse);
        expect(resumed.alreadyCompleted, isFalse);
        expect(resumed.server?.uuid, '00000000-0000-0000-0000-000000000009');
      } finally {
        resumed.close();
      }
    },
  );

  test('reclaims a created server after the Local source changes', () async {
    final _CreatePushFixture fixture = _fixture();
    addTearDown(fixture.close);
    final _ResolvedIntent original = _resolvedIntent();
    final PterodactylCreatePushIntentCoordinator coordinator =
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: fixture.directory.path,
          service: fixture.service,
        );
    final PterodactylApplicationServer created =
        PterodactylApplicationServer.fromJson(_server(externalId: original.id));

    final PterodactylCreatePushIntentClaim first = await coordinator.claim(
      id: original.id,
      confirmationToken: original.confirmationToken,
      transferPlan: original.transferPlan,
      creation: original.creation,
      startAfterTransfer: false,
      persistNewLink: true,
    );
    try {
      first.record(state: 'created', created: created);
    } finally {
      first.close();
    }

    fixture.transport.servers = <JsonObject>[_server(externalId: original.id)];
    final _ResolvedIntent changed = _resolvedIntent(
      sourceFingerprint: 'changed-source-fingerprint',
      transferConfirmationToken: 'changed-transfer-confirmation',
    );
    expect(changed.id, original.id);
    expect(changed.confirmationToken, isNot(original.confirmationToken));

    final int requestsBeforeStaleConfirmation = fixture.transport.requestCount;
    await expectLater(
      coordinator.claim(
        id: changed.id,
        confirmationToken: original.confirmationToken,
        transferPlan: changed.transferPlan,
        creation: changed.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      ),
      throwsArgumentError,
    );
    expect(fixture.transport.requestCount, requestsBeforeStaleConfirmation);

    final PterodactylCreatePushIntentClaim resumed = await coordinator.claim(
      id: changed.id,
      confirmationToken: changed.confirmationToken,
      transferPlan: changed.transferPlan,
      creation: changed.creation,
      startAfterTransfer: false,
      persistNewLink: true,
    );
    try {
      expect(resumed.shouldCreate, isFalse);
      expect(resumed.alreadyCompleted, isFalse);
      expect(resumed.needsPostconditionRepair, isFalse);
      expect(resumed.server?.uuid, created.uuid);
      final JsonObject journal =
          jsonDecode(File(resumed.path).readAsStringSync())! as JsonObject;
      expect(
        journal['transfer_confirmation_token'],
        changed.transferPlan.confirmationToken,
      );
    } finally {
      resumed.close();
    }
  });

  test(
    'refuses duplicate external-id matches without choosing a server',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent resolved = _resolvedIntent();
      fixture.transport.servers = <JsonObject>[
        _server(externalId: resolved.id),
        _server(
          externalId: resolved.id,
          id: 10,
          uuid: '00000000-0000-0000-0000-000000000010',
          identifier: 'server02',
        ),
      ];
      final PterodactylCreatePushIntentCoordinator coordinator =
          PterodactylCreatePushIntentCoordinator(
            metadataDirectoryPath: fixture.directory.path,
            service: fixture.service,
          );

      await expectLater(
        coordinator.claim(
          id: resolved.id,
          confirmationToken: resolved.confirmationToken,
          transferPlan: resolved.transferPlan,
          creation: resolved.creation,
          startAfterTransfer: false,
          persistNewLink: true,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => '$error',
            'message',
            contains('matches multiple Panel servers'),
          ),
        ),
      );
    },
  );

  test('refuses multiple journals claiming one stable intent', () async {
    final _CreatePushFixture fixture = _fixture();
    addTearDown(fixture.close);
    final _ResolvedIntent resolved = _resolvedIntent();
    final PterodactylCreatePushIntentCoordinator coordinator =
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: fixture.directory.path,
          service: fixture.service,
        );
    final PterodactylCreatePushIntentClaim first = await coordinator.claim(
      id: resolved.id,
      confirmationToken: resolved.confirmationToken,
      transferPlan: resolved.transferPlan,
      creation: resolved.creation,
      startAfterTransfer: false,
      persistNewLink: true,
    );
    late final String originalPath;
    try {
      originalPath = first.path;
    } finally {
      first.close();
    }
    final String duplicateId =
        'multiplexor-push-${List<String>.filled(32, 'f').join()}';
    expect(duplicateId, isNot(resolved.id));
    final File duplicate = File(
      '${File(originalPath).parent.path}/$duplicateId.json',
    )..writeAsStringSync(File(originalPath).readAsStringSync());

    await expectLater(
      coordinator.claim(
        id: resolved.id,
        confirmationToken: resolved.confirmationToken,
        transferPlan: resolved.transferPlan,
        creation: resolved.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => '$error',
          'message',
          contains('Multiple durable Create & Push intents'),
        ),
      ),
    );
    expect(duplicate.existsSync(), isTrue);
  });

  test(
    'rejects configuration A confirmation before configuration B lookup',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent configurationA = _resolvedIntent();
      final _ResolvedIntent configurationB = _resolvedIntent(memoryMiB: 8192);

      await expectLater(
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: fixture.directory.path,
          service: fixture.service,
        ).claim(
          id: configurationB.id,
          confirmationToken: configurationA.confirmationToken,
          transferPlan: configurationB.transferPlan,
          creation: configurationB.creation,
          startAfterTransfer: false,
          persistNewLink: true,
        ),
        throwsArgumentError,
      );
      expect(fixture.transport.requestCount, 0);
    },
  );

  test(
    'refuses an external-id server with different immutable settings',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent resolved = _resolvedIntent();
      fixture.transport.servers = <JsonObject>[
        _server(externalId: resolved.id, memoryMiB: 8192),
      ];
      final PterodactylCreatePushIntentCoordinator coordinator =
          PterodactylCreatePushIntentCoordinator(
            metadataDirectoryPath: fixture.directory.path,
            service: fixture.service,
          );

      await expectLater(
        coordinator.claim(
          id: resolved.id,
          confirmationToken: resolved.confirmationToken,
          transferPlan: resolved.transferPlan,
          creation: resolved.creation,
          startAfterTransfer: false,
          persistNewLink: true,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => '$error',
            'message',
            contains('immutable creation settings do not match'),
          ),
        ),
      );
    },
  );

  test('template resume ignores Panel-generated environment keys', () async {
    final _CreatePushFixture fixture = _fixture();
    addTearDown(fixture.close);
    final _ResolvedIntent resolved = _resolvedTemplateIntent();
    fixture.transport.servers = <JsonObject>[_server(externalId: resolved.id)];

    final PterodactylCreatePushIntentClaim claim =
        await PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: fixture.directory.path,
          service: fixture.service,
        ).claim(
          id: resolved.id,
          confirmationToken: resolved.confirmationToken,
          transferPlan: resolved.transferPlan,
          creation: resolved.creation,
          startAfterTransfer: false,
          persistNewLink: true,
        );
    try {
      expect(claim.server?.identifier, 'server01');
      expect(claim.shouldCreate, isFalse);
    } finally {
      claim.close();
    }
  });

  test(
    'records recoverable state when confirmed postconditions are missing',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent resolved = _resolvedIntent(
        startAfterTransfer: true,
      );
      final PterodactylCreatePushIntentClaim claim =
          await PterodactylCreatePushIntentCoordinator(
            metadataDirectoryPath: fixture.directory.path,
            service: fixture.service,
          ).claim(
            id: resolved.id,
            confirmationToken: resolved.confirmationToken,
            transferPlan: resolved.transferPlan,
            creation: resolved.creation,
            startAfterTransfer: true,
            persistNewLink: true,
          );
      final PterodactylApplicationServer created =
          PterodactylApplicationServer.fromJson(
            _server(externalId: resolved.id),
          );
      final DateTime now = DateTime.utc(2026, 8, 14);
      final PterodactylTransferResult result = PterodactylTransferResult(
        plan: resolved.transferPlan,
        localInstance: const PterodactylLocalInstance(
          name: 'local-one',
          consumer: 'plugin',
          path: '/workspace/instances/local-one',
        ),
        link: PterodactylRemoteLink(
          profileId: 'remote',
          serverIdentifier: created.identifier,
          serverUuid: created.uuid,
          serverName: created.name,
          localInstanceName: 'local-one',
          localConsumer: 'plugin',
          linkedAt: now,
          lastTransferredAt: now,
        ),
        remoteRestarted: false,
        linkPersisted: false,
      );
      try {
        expect(
          () => claim.complete(created: created, result: result),
          throwsA(isA<StateError>()),
        );
        final JsonObject journal =
            jsonDecode(File(claim.path).readAsStringSync())! as JsonObject;
        expect(journal['status'], 'postconditions-failed');
      } finally {
        claim.close();
      }
    },
  );

  test(
    'changed Local source resumes transfer after postconditions failed',
    () async {
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final _ResolvedIntent original = _resolvedIntent();
      final PterodactylCreatePushIntentCoordinator coordinator =
          PterodactylCreatePushIntentCoordinator(
            metadataDirectoryPath: fixture.directory.path,
            service: fixture.service,
          );
      final PterodactylApplicationServer created =
          PterodactylApplicationServer.fromJson(
            _server(externalId: original.id),
          );
      final PterodactylCreatePushIntentClaim first = await coordinator.claim(
        id: original.id,
        confirmationToken: original.confirmationToken,
        transferPlan: original.transferPlan,
        creation: original.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      );
      final DateTime now = DateTime.utc(2026, 8, 14);
      try {
        expect(
          () => first.complete(
            created: created,
            result: PterodactylTransferResult(
              plan: original.transferPlan,
              localInstance: const PterodactylLocalInstance(
                name: 'local-one',
                consumer: 'plugin',
                path: '/workspace/instances/local-one',
              ),
              link: PterodactylRemoteLink(
                profileId: 'remote',
                serverIdentifier: created.identifier,
                serverUuid: created.uuid,
                serverName: created.name,
                localInstanceName: 'local-one',
                localConsumer: 'plugin',
                linkedAt: now,
                lastTransferredAt: now,
              ),
              remoteRestarted: false,
              linkPersisted: false,
            ),
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        first.close();
      }
      fixture.transport.servers = <JsonObject>[
        _server(externalId: original.id),
      ];

      final PterodactylCreatePushIntentClaim unchanged = await coordinator
          .claim(
            id: original.id,
            confirmationToken: original.confirmationToken,
            transferPlan: original.transferPlan,
            creation: original.creation,
            startAfterTransfer: false,
            persistNewLink: true,
          );
      try {
        expect(unchanged.needsPostconditionRepair, isTrue);
      } finally {
        unchanged.close();
      }

      final _ResolvedIntent changed = _resolvedIntent(
        sourceFingerprint: 'changed-source-fingerprint',
        transferConfirmationToken: 'changed-transfer-confirmation',
      );
      expect(changed.id, original.id);
      final PterodactylCreatePushIntentClaim resumed = await coordinator.claim(
        id: changed.id,
        confirmationToken: changed.confirmationToken,
        transferPlan: changed.transferPlan,
        creation: changed.creation,
        startAfterTransfer: false,
        persistNewLink: true,
      );
      try {
        expect(resumed.server?.uuid, created.uuid);
        expect(resumed.sourceChangedSinceCommit, isTrue);
        expect(resumed.needsPostconditionRepair, isFalse);
        expect(resumed.alreadyCompleted, isFalse);
      } finally {
        resumed.close();
      }
    },
  );

  for (final String suffix in <String>['', '.lock', '.tmp', '.previous']) {
    test('refuses a preexisting symlink at the intent$suffix path', () async {
      if (Platform.isWindows) return;
      final _CreatePushFixture fixture = _fixture();
      addTearDown(fixture.close);
      final Directory outside = Directory.systemTemp.createTempSync(
        'multiplexor-create-push-outside-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      final File sentinel = File('${outside.path}/sentinel')
        ..writeAsStringSync('unchanged');
      final _ResolvedIntent resolved = _resolvedIntent();
      final Directory intents = Directory(
        '${fixture.directory.path}/pterodactyl-transfers/intents',
      )..createSync(recursive: true);
      final String collision = '${intents.path}/${resolved.id}.json$suffix';
      Link(collision).createSync(sentinel.path);

      await expectLater(
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: fixture.directory.path,
          service: fixture.service,
        ).claim(
          id: resolved.id,
          confirmationToken: resolved.confirmationToken,
          transferPlan: resolved.transferPlan,
          creation: resolved.creation,
          startAfterTransfer: false,
          persistNewLink: true,
        ),
        throwsA(isA<StateError>()),
      );
      expect(sentinel.readAsStringSync(), 'unchanged');
    });
  }
}

final class _ResolvedIntent {
  const _ResolvedIntent({
    required this.id,
    required this.confirmationToken,
    required this.transferPlan,
    required this.creation,
  });

  final String id;
  final String confirmationToken;
  final PterodactylTransferPlan transferPlan;
  final PterodactylCreatePushPlan creation;
}

_ResolvedIntent _resolvedIntent({
  bool startAfterTransfer = false,
  int memoryMiB = 4096,
  String sourceFingerprint = 'source-fingerprint',
  String transferConfirmationToken = 'transfer-confirmation',
}) {
  final PterodactylTransferPlan transferPlan = PterodactylTransferPlan(
    direction: PterodactylTransferDirection.push,
    mode: PterodactylTransferMode.update,
    localInstanceName: 'local-one',
    localConsumer: 'plugin',
    localInstancePath: '/workspace/instances/local-one',
    profileId: 'remote',
    serverIdentifier: '',
    remoteServerName: 'New Remote',
    targetExists: false,
    targetWasRunning: false,
    sourceFingerprint: sourceFingerprint,
    confirmationToken: transferConfirmationToken,
    createdAt: DateTime.utc(2026, 8, 14),
    changes: const <PterodactylTransferChange>[],
  );
  final PterodactylEgg egg = PterodactylEgg(
    id: 2,
    uuid: 'egg-uuid',
    name: 'Minecraft',
    nestId: 1,
    author: 'test@example.test',
    startup: 'java -jar server.jar',
    dockerImages: const <String, String>{
      'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
    },
  );
  final PterodactylCreatePushPlan unresolved = PterodactylCreatePushPlan.egg(
    name: 'New Remote',
    source: egg,
    plan: PterodactylEggCreatePlan(
      ownerId: 5,
      nodeId: 3,
      eggId: 2,
      eggUuid: egg.uuid,
      dockerImage: 'ghcr.io/pterodactyl/yolks:java_21',
      startup: 'java -jar server.jar',
      environment: const <String, String>{'SERVER_JARFILE': 'server.jar'},
      memoryMiB: memoryMiB,
      swapMiB: 0,
      diskMiB: 10000,
      ioWeight: 500,
      cpuPercent: 200,
      databaseLimit: 1,
      allocationLimit: 2,
      backupLimit: 3,
    ),
    ownerName: 'owner',
    nodeName: 'node',
  );
  final String id = pterodactylCreatePushIntentId(
    transferPlan: transferPlan,
    canonicalCreation: unresolved.canonicalJson,
    startAfterTransfer: startAfterTransfer,
    persistNewLink: true,
  );
  final PterodactylCreatePushPlan creation = unresolved.withExternalId(id);
  return _ResolvedIntent(
    id: id,
    confirmationToken: pterodactylCreatePushConfirmationToken(
      transferConfirmationToken: transferPlan.confirmationToken,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: startAfterTransfer,
      persistNewLink: true,
    ),
    transferPlan: transferPlan,
    creation: creation,
  );
}

_ResolvedIntent _resolvedTemplateIntent() {
  final PterodactylTransferPlan transferPlan = PterodactylTransferPlan(
    direction: PterodactylTransferDirection.push,
    mode: PterodactylTransferMode.update,
    localInstanceName: 'local-one',
    localConsumer: 'plugin',
    localInstancePath: '/workspace/instances/local-one',
    profileId: 'remote',
    serverIdentifier: '',
    remoteServerName: 'New Remote',
    targetExists: false,
    targetWasRunning: false,
    sourceFingerprint: 'source-fingerprint',
    confirmationToken: 'transfer-confirmation',
    createdAt: DateTime.utc(2026, 8, 14),
    changes: const <PterodactylTransferChange>[],
  );
  final PterodactylCreatePushPlan unresolved =
      PterodactylCreatePushPlan.template(
        plan: PterodactylTemplateCreatePlan(
          templateUuid: 'template-uuid',
          templateIdentifier: 'template01',
          templateName: 'Template',
          name: 'New Remote',
          description: 'Created by Multiplexor from Template.',
          ownerId: 5,
          nodeId: 3,
          eggId: 2,
          dockerImage: 'ghcr.io/pterodactyl/yolks:java_21',
          startup: 'java -jar server.jar',
          environment: const <String, String>{'SERVER_JARFILE': 'server.jar'},
          limits: const PterodactylServerLimits(
            memoryMiB: 4096,
            swapMiB: 0,
            diskMiB: 10000,
            ioWeight: 500,
            cpuPercent: 200,
            threads: null,
            oomDisabled: true,
          ),
          featureLimits: const PterodactylFeatureLimits(
            databases: 1,
            allocations: 2,
            backups: 3,
          ),
          startOnCompletion: false,
          skipScripts: false,
          oomDisabled: true,
        ),
        ownerName: 'owner',
        nodeName: 'node',
      );
  final String id = pterodactylCreatePushIntentId(
    transferPlan: transferPlan,
    canonicalCreation: unresolved.canonicalJson,
    startAfterTransfer: false,
    persistNewLink: true,
  );
  final PterodactylCreatePushPlan creation = unresolved.withExternalId(id);
  return _ResolvedIntent(
    id: id,
    confirmationToken: pterodactylCreatePushConfirmationToken(
      transferConfirmationToken: transferPlan.confirmationToken,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: false,
      persistNewLink: true,
    ),
    transferPlan: transferPlan,
    creation: creation,
  );
}

final class _CreatePushFixture {
  const _CreatePushFixture({
    required this.directory,
    required this.service,
    required this.transport,
  });

  final Directory directory;
  final PterodactylService service;
  final _InventoryTransport transport;

  void close() => directory.deleteSync(recursive: true);
}

_CreatePushFixture _fixture() {
  final Directory directory = Directory.systemTemp.createTempSync(
    'multiplexor-create-push-intent-',
  );
  final PterodactylProfile profile = PterodactylProfile(
    id: 'remote',
    name: 'Remote',
    panelUri: Uri.parse('https://panel.example.test'),
  );
  final PterodactylProfileStore profiles = PterodactylProfileStore(
    directory.path,
  )..save(profile);
  final _InventoryTransport transport = _InventoryTransport();
  final PterodactylService service = PterodactylService(
    profileStore: profiles,
    credentialStore: PterodactylCredentialStore(
      directory.path,
      environment: <String, String>{
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        ): 'client-secret',
        PterodactylCredentialStore.environmentOriginVariableFor(profile):
            profile.origin,
      },
    ),
    clientFactory:
        ({
          required PterodactylProfile profile,
          required PterodactylCredential clientCredential,
          PterodactylCredential? applicationCredential,
        }) => PterodactylClient(
          baseUri: profile.panelUri,
          clientKey: clientCredential.value,
          applicationKey:
              applicationCredential?.value ?? clientCredential.value,
          transport: transport,
        ),
  );
  return _CreatePushFixture(
    directory: directory,
    service: service,
    transport: transport,
  );
}

final class _InventoryTransport implements PterodactylTransport {
  List<JsonObject> servers = <JsonObject>[];
  int requestCount = 0;

  @override
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  ) async {
    requestCount += 1;
    if (request.uri.path != '/api/application/servers') {
      throw StateError('Unexpected request: ${request.uri}');
    }
    return PterodactylTransportResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'object': 'list',
        'data': <Object?>[
          for (final JsonObject server in servers)
            <String, Object?>{'object': 'server', 'attributes': server},
        ],
        'meta': <String, Object?>{
          'pagination': <String, Object?>{
            'total': servers.length,
            'count': servers.length,
            'per_page': 100,
            'current_page': 1,
            'total_pages': 1,
          },
        },
      }),
    );
  }

  @override
  void close() {}
}

JsonObject _server({
  required String externalId,
  int id = 9,
  String uuid = '00000000-0000-0000-0000-000000000009',
  String identifier = 'server01',
  int memoryMiB = 4096,
}) => <String, Object?>{
  'id': id,
  'external_id': externalId,
  'uuid': uuid,
  'identifier': identifier,
  'name': 'New Remote',
  'description': 'Created by Multiplexor from Panel egg 2.',
  'status': null,
  'user': 5,
  'node': 3,
  'allocation': 77,
  'nest': 1,
  'egg': 2,
  'limits': <String, Object?>{
    'memory': memoryMiB,
    'swap': 0,
    'disk': 10000,
    'io': 500,
    'cpu': 200,
    'threads': null,
    'oom_disabled': true,
  },
  'feature_limits': <String, Object?>{
    'databases': 1,
    'allocations': 2,
    'backups': 3,
  },
  'container': <String, Object?>{
    'image': 'ghcr.io/pterodactyl/yolks:java_21',
    'startup_command': 'java -jar server.jar',
    'environment': <String, Object?>{
      'SERVER_JARFILE': 'server.jar',
      'P_SERVER_ALLOCATION_LIMIT': '2',
      'P_SERVER_UUID': uuid,
      'STARTUP': 'java -jar server.jar',
    },
    'skip_scripts': false,
  },
};
