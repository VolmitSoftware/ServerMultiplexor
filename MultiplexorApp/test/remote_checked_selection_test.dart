import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:test/test.dart';

void main() {
  group('remoteCheckedBulkTargets', () {
    test('restricts actions to exact checked IDs even when names collide', () {
      final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
        _sample('other', state: 'offline'),
        _sample('second', state: 'offline'),
        _sample('first', state: 'offline'),
      ];

      expect(
        _ids(
          remoteCheckedBulkTargets(
            fleet: fleet,
            checkedIdentifiers: <String>['first', 'second', 'first'],
            action: RemoteBulkAction.start,
          ),
        ),
        <String>['first', 'second'],
      );
    });

    test('empty deletion selection is rejected instead of meaning all', () {
      expect(
        () => remoteCheckedBulkTargets(
          fleet: <PterodactylFleetSample>[_sample('server', state: 'offline')],
          checkedIdentifiers: const <String>[],
          action: RemoteBulkAction.delete,
        ),
        throwsArgumentError,
      );
    });

    test('a missing checked ID rejects the entire selection', () {
      expect(
        () => remoteCheckedBulkTargets(
          fleet: <PterodactylFleetSample>[_sample('present', state: 'offline')],
          checkedIdentifiers: <String>['present', 'removed'],
          action: RemoteBulkAction.delete,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('removed'),
          ),
        ),
      );
    });

    test('a display name cannot substitute for the checked stable ID', () {
      expect(
        () => remoteCheckedBulkTargets(
          fleet: <PterodactylFleetSample>[
            _sample('server-id', state: 'offline'),
          ],
          checkedIdentifiers: <String>['Shared display name'],
          action: RemoteBulkAction.start,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('blocked and unknown servers are excluded from power actions', () {
      final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
        _sample('ready', state: 'offline'),
        _sample('maintenance', state: 'offline', maintenance: true),
        _sample('installing', state: 'offline', status: 'installing'),
        _sample('suspended', state: 'offline', suspended: true),
        _sample('unknown'),
        _sample('unrecognized', state: 'unknown'),
        _sample('unchecked', state: 'offline'),
      ];

      expect(
        _ids(
          remoteCheckedBulkTargets(
            fleet: fleet,
            checkedIdentifiers: <String>[
              'ready',
              'maintenance',
              'installing',
              'suspended',
              'unknown',
              'unrecognized',
            ],
            action: RemoteBulkAction.start,
          ),
        ),
        <String>['ready'],
      );
      expect(
        remoteCheckedBulkTargets(
          fleet: fleet,
          checkedIdentifiers: <String>['maintenance', 'unknown'],
          action: RemoteBulkAction.start,
        ),
        isEmpty,
      );
    });

    test(
      'restart excludes transitions while stop includes live transitions',
      () {
        final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
          _sample('starting', state: 'starting'),
          _sample('running', state: 'running'),
          _sample('stopping', state: 'stopping'),
          _sample('offline', state: 'offline'),
          _sample('blocked', state: 'running', maintenance: true),
        ];
        final List<String> checked = _ids(fleet);

        expect(
          _ids(
            remoteCheckedBulkTargets(
              fleet: fleet,
              checkedIdentifiers: checked,
              action: RemoteBulkAction.restart,
            ),
          ),
          <String>['running'],
        );
        expect(
          _ids(
            remoteCheckedBulkTargets(
              fleet: fleet,
              checkedIdentifiers: checked,
              action: RemoteBulkAction.stop,
            ),
          ),
          <String>['starting', 'running', 'stopping'],
        );
      },
    );

    test('delete retains checked accessible servers despite power blocks', () {
      final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
        _sample('unchecked', state: 'offline'),
        _sample('maintenance', state: 'running', maintenance: true),
        _sample('installing', state: 'offline', status: 'installing'),
        _sample('suspended', state: 'offline', suspended: true),
        _sample('unknown'),
      ];
      final List<String> checked = <String>[
        'maintenance',
        'installing',
        'suspended',
        'unknown',
      ];

      expect(
        _ids(
          remoteCheckedBulkTargets(
            fleet: fleet,
            checkedIdentifiers: checked,
            action: RemoteBulkAction.delete,
          ),
        ),
        checked,
      );
    });
  });
}

List<String> _ids(Iterable<PterodactylFleetSample> samples) => samples
    .map((PterodactylFleetSample sample) => sample.server.identifier)
    .toList(growable: false);

PterodactylFleetSample _sample(
  String identifier, {
  String? state,
  bool suspended = false,
  bool maintenance = false,
  String? status,
}) => PterodactylFleetSample(
  server: PterodactylClientServer(
    identifier: identifier,
    internalId: identifier.hashCode.abs() + 1,
    uuid: '00000000-0000-0000-0000-000000000001',
    name: 'Shared display name',
    nodeName: 'node',
    description: '',
    isOwner: true,
    isNodeUnderMaintenance: maintenance,
    status: status,
    sftpHost: 'wings.example.test',
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
  ),
  resources: state == null
      ? null
      : PterodactylResourceUsage(
          currentState: state,
          isSuspended: suspended,
          memoryBytes: 0,
          cpuAbsolute: 0,
          diskBytes: 0,
          networkRxBytes: 0,
          networkTxBytes: 0,
          uptime: Duration.zero,
        ),
);
