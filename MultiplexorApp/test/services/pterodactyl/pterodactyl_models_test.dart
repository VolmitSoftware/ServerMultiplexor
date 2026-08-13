import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:test/test.dart';

void main() {
  test('bulk result retains item order and counts partial failures', () {
    final PterodactylBulkResult result = PterodactylBulkResult(
      action: PterodactylBulkAction.restart,
      items: const <PterodactylBulkItemResult>[
        PterodactylBulkItemResult(
          target: 'one',
          name: 'One',
          identifier: 'one',
          succeeded: true,
        ),
        PterodactylBulkItemResult(
          target: 'two',
          name: 'Two',
          identifier: 'two',
          succeeded: false,
          error: 'HTTP 500',
        ),
      ],
    );

    expect(result.items.map((PterodactylBulkItemResult item) => item.target), [
      'one',
      'two',
    ]);
    expect(result.totalCount, 2);
    expect(result.succeededCount, 1);
    expect(result.failedCount, 1);
    expect(result.isSuccess, isFalse);
  });

  test('create request requires exactly one allocation strategy', () {
    PterodactylCreateServerRequest build({
      int? allocation,
      PterodactylServerDeployment? deployment,
    }) => PterodactylCreateServerRequest(
      name: 'Server',
      ownerId: 1,
      eggId: 2,
      dockerImage: 'image',
      startup: 'start',
      environment: const <String, String>{},
      limits: const PterodactylServerLimits(
        memoryMiB: 1024,
        swapMiB: 0,
        diskMiB: 2048,
        ioWeight: 500,
        cpuPercent: 100,
        threads: null,
        oomDisabled: false,
      ),
      featureLimits: const PterodactylFeatureLimits(
        databases: 0,
        allocations: 1,
        backups: 0,
      ),
      defaultAllocationId: allocation,
      deployment: deployment,
    );

    expect(() => build(), throwsArgumentError);
    expect(
      () => build(
        allocation: 1,
        deployment: PterodactylServerDeployment(
          locationIds: const <int>[1],
          dedicatedIp: false,
          portRanges: const <String>[],
        ),
      ),
      throwsArgumentError,
    );
    expect(
      build(allocation: 1).toJson()['limits'],
      isNot(contains('oom_disabled')),
    );
  });

  test('feature limits retain nulls in create payloads', () {
    const PterodactylFeatureLimits limits = PterodactylFeatureLimits(
      databases: null,
      allocations: null,
      backups: null,
    );

    expect(limits.toJson(), <String, Object?>{
      'databases': null,
      'allocations': null,
      'backups': null,
    });
  });

  test('feature limits reject non-numeric non-null values', () {
    expect(
      () => PterodactylFeatureLimits.fromJson(<String, Object?>{
        'databases': 'unlimited',
        'allocations': null,
        'backups': 0,
      }),
      throwsFormatException,
    );
  });

  test('Application build update validates and serializes nested limits', () {
    final PterodactylUpdateServerBuildRequest request =
        PterodactylUpdateServerBuildRequest(
          defaultAllocationId: 7,
          limits: const PterodactylServerLimits(
            memoryMiB: 4096,
            swapMiB: -1,
            diskMiB: 10000,
            ioWeight: 500,
            cpuPercent: 200,
            threads: '0-3',
            oomDisabled: true,
          ),
          featureLimits: const PterodactylFeatureLimits(
            databases: 2,
            allocations: 3,
            backups: 4,
          ),
          oomDisabled: true,
          addAllocationIds: const <int>[8],
          removeAllocationIds: const <int>[9],
        );

    expect(request.toJson(), <String, Object?>{
      'allocation': 7,
      'oom_disabled': true,
      'limits': <String, Object?>{
        'memory': 4096,
        'swap': -1,
        'disk': 10000,
        'io': 500,
        'cpu': 200,
        'threads': '0-3',
      },
      'feature_limits': <String, Object?>{
        'databases': 2,
        'allocations': 3,
        'backups': 4,
      },
      'add_allocations': <int>[8],
      'remove_allocations': <int>[9],
    });
  });

  test('Application build update rejects unsafe values and conflicts', () {
    PterodactylUpdateServerBuildRequest build({
      int ioWeight = 500,
      List<int> add = const <int>[],
      List<int> remove = const <int>[],
    }) => PterodactylUpdateServerBuildRequest(
      defaultAllocationId: 7,
      limits: PterodactylServerLimits(
        memoryMiB: 4096,
        swapMiB: 0,
        diskMiB: 10000,
        ioWeight: ioWeight,
        cpuPercent: 200,
        threads: null,
        oomDisabled: false,
      ),
      featureLimits: const PterodactylFeatureLimits(
        databases: 0,
        allocations: 0,
        backups: 0,
      ),
      oomDisabled: false,
      addAllocationIds: add,
      removeAllocationIds: remove,
    );

    expect(() => build(ioWeight: 9), throwsRangeError);
    expect(() => build(add: <int>[8], remove: <int>[8]), throwsArgumentError);
  });

  test('Application detail and startup updates retain required fields', () {
    final PterodactylUpdateServerDetailsRequest details =
        PterodactylUpdateServerDetailsRequest(
          name: 'Renamed',
          ownerId: 5,
          description: null,
          externalId: 'external-1',
        );
    final PterodactylUpdateServerStartupRequest startup =
        PterodactylUpdateServerStartupRequest(
          startup: 'java -jar {{SERVER_JARFILE}}',
          environment: const <String, String>{'SERVER_JARFILE': 'paper.jar'},
          eggId: 2,
          dockerImage: 'ghcr.io/pterodactyl/yolks:java_21',
          skipScripts: true,
        );

    expect(details.toJson(), <String, Object?>{
      'external_id': 'external-1',
      'name': 'Renamed',
      'user': 5,
      'description': null,
    });
    expect(startup.toJson(), <String, Object?>{
      'startup': 'java -jar {{SERVER_JARFILE}}',
      'environment': <String, String>{'SERVER_JARFILE': 'paper.jar'},
      'egg': 2,
      'image': 'ghcr.io/pterodactyl/yolks:java_21',
      'skip_scripts': true,
    });
  });

  test('activity requires ISO timestamp and retains structured metadata', () {
    final PterodactylActivity activity = PterodactylActivity.fromJson(
      <String, Object?>{
        'id': 'id',
        'batch': null,
        'event': 'server:power.start',
        'is_api': true,
        'ip': null,
        'description': '',
        'properties': <String, Object?>{'signal': 'start'},
        'has_additional_metadata': false,
        'timestamp': '2026-08-12T12:00:00Z',
      },
    );

    expect(activity.timestamp.isUtc, isTrue);
    expect(activity.properties, <String, Object?>{'signal': 'start'});
    final PterodactylActivity nullable =
        PterodactylActivity.fromJson(<String, Object?>{
          'id': 'nullable',
          'batch': null,
          'event': 'server:power.stop',
          'is_api': false,
          'ip': null,
          'description': null,
          'properties': null,
          'has_additional_metadata': false,
          'timestamp': '2026-08-12T12:00:00Z',
        });
    expect(nullable.description, isEmpty);
    expect(nullable.properties, isEmpty);
    expect(
      () => PterodactylActivity.fromJson(<String, Object?>{
        'id': 'id',
        'event': 'event',
        'is_api': false,
        'description': '',
        'properties': <String, Object?>{},
        'has_additional_metadata': false,
        'timestamp': 'not-a-date',
      }),
      throwsFormatException,
    );
  });

  test('startup metadata parses Docker images and empty legacy maps', () {
    final PterodactylServerStartup populated =
        PterodactylServerStartup.fromJson(
          <String, Object?>{
            'startup_command': 'java -jar paper.jar',
            'raw_startup_command': 'java -jar {{SERVER_JARFILE}}',
            'docker_images': <String, Object?>{
              'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
            },
          },
          <JsonObject>[
            <String, Object?>{
              'name': 'Server Jar',
              'description': null,
              'env_variable': 'SERVER_JARFILE',
              'default_value': 'server.jar',
              'server_value': 'paper.jar',
              'is_editable': true,
              'rules': 'required|string',
            },
          ],
        );
    final PterodactylServerStartup empty =
        PterodactylServerStartup.fromJson(<String, Object?>{
          'startup_command': 'run',
          'raw_startup_command': 'run',
          'docker_images': <Object?>[],
        }, const <JsonObject>[]);

    expect(populated.variables.single.serverValue, 'paper.jar');
    expect(populated.dockerImages, <String, String>{
      'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
    });
    expect(empty.dockerImages, isEmpty);
  });

  test(
    'SSH public keys normalize canonically without leaking bad material',
    () {
      const String openSsh =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOaXIq09NH4a93EVdrvHYiZ67Wj+'
          'GBEBQ9ou4W0qSYm2 comment';
      final String canonical = PterodactylAccountSshKey.normalizePublicKey(
        openSsh,
      );
      final PterodactylAccountSshKey key = PterodactylAccountSshKey(
        name: 'Multiplexor',
        fingerprint: 'SHA256:fixture',
        publicKey: canonical,
        createdAt: DateTime.utc(2026, 8, 12),
      );

      expect(canonical, startsWith('-----BEGIN PUBLIC KEY-----\n'));
      expect(canonical, endsWith('\n-----END PUBLIC KEY-----'));
      expect(canonical, isNot(contains('comment')));
      expect(
        PterodactylAccountSshKey.normalizePublicKey('\r\n$canonical\r\n'),
        canonical,
      );
      expect(key.toString(), contains('[REDACTED]'));
      expect(key.toString(), isNot(contains(canonical)));

      const String malformed = 'ssh-ed25519 definitely-not-a-key';
      expect(
        () => PterodactylAccountSshKey.normalizePublicKey(malformed),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError error) => error.toString(),
            'text',
            isNot(contains(malformed)),
          ),
        ),
      );
    },
  );

  test('WebSocket credentials require a clean wss URL', () {
    for (final String socket in <String>[
      'ws://node.example.test/api/servers/server/ws',
      'https://node.example.test/api/servers/server/ws',
      'wss://user@node.example.test/api/servers/server/ws',
      'wss://node.example.test/api/servers/server/ws?token=secret',
    ]) {
      expect(
        () => PterodactylWebsocketCredentials.fromJson(<String, Object?>{
          'token': 'one-time-token',
          'socket': socket,
        }),
        throwsFormatException,
        reason: socket,
      );
    }
  });

  test('WebSocket credentials reject blank tokens without echoing them', () {
    expect(
      () => PterodactylWebsocketCredentials.fromJson(<String, Object?>{
        'token': ' ',
        'socket': 'wss://node.example.test/api/servers/server/ws',
      }),
      throwsA(
        isA<FormatException>().having(
          (FormatException error) => error.toString(),
          'text',
          isNot(contains("' '")),
        ),
      ),
    );
  });
}
