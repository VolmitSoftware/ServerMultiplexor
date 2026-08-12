import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:test/test.dart';

void main() {
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
