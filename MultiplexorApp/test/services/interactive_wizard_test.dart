import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:test/test.dart';

void main() {
  group('Pterodactyl account key enrollment', () {
    test(
      'accepts the expected standard prefix and legacy unknown prefixes',
      () {
        expect(
          pterodactylCredentialMatchesRole(
            PterodactylCredential('ptlc_client'),
            PterodactylCredentialRole.client,
          ),
          isTrue,
        );
        expect(
          pterodactylCredentialMatchesRole(
            PterodactylCredential('legacy-token'),
            PterodactylCredentialRole.application,
          ),
          isTrue,
        );
      },
    );

    test('rejects a standard prefix for the opposite credential role', () {
      expect(
        pterodactylCredentialMatchesRole(
          PterodactylCredential('ptla_application'),
          PterodactylCredentialRole.client,
        ),
        isFalse,
      );
      expect(
        pterodactylCredentialMatchesRole(
          PterodactylCredential('ptlc_client'),
          PterodactylCredentialRole.application,
        ),
        isFalse,
      );
    });
  });

  group('Remote quick-action runtime policy', () {
    test('offline restart starts instead', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: ' OFFLINE ',
        ),
        RemoteQuickActionEffect.start,
      );
    });

    test('offline stop, kill, and console are no-ops', () {
      for (final MonitorAction action in <MonitorAction>[
        MonitorAction.stop,
        MonitorAction.kill,
        MonitorAction.console,
      ]) {
        expect(
          remoteQuickActionEffect(action: action, currentState: 'offline'),
          RemoteQuickActionEffect.none,
          reason: action.name,
        );
      }
    });

    test('live shortcuts preserve their requested effects', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.restart,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.stop,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.stop,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.kill,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.kill,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.console,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.console,
      );
    });
  });

  group('Remote bulk target policy', () {
    final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
      _sample('offline1', 'Offline', state: 'offline'),
      _sample('running1', 'Running', state: 'running'),
      _sample('starting', 'Starting', state: 'starting'),
      _sample('suspend1', 'Suspended', state: 'running', suspended: true),
      _sample('maintain', 'Maintenance', state: 'running', maintenance: true),
      _sample('install1', 'Installing', state: 'offline', status: 'installing'),
      _sample('unknown1', 'Unavailable'),
    ];

    test('start and live power actions retain only actionable states', () {
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.start,
            scope: RemoteBulkTargetScope.all,
          ),
        ),
        <String>['offline1'],
      );
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.restart,
            scope: RemoteBulkTargetScope.all,
          ),
        ),
        <String>['running1', 'starting'],
      );
    });

    test('selected scope follows the dashboard selection exactly', () {
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.delete,
            scope: RemoteBulkTargetScope.selected,
            selectedIdentifier: 'RUNNING1',
          ),
        ),
        <String>['running1'],
      );
    });

    test(
      'management actions can include suspended and unavailable servers',
      () {
        expect(
          _ids(
            remoteBulkTargets(
              fleet: fleet,
              action: RemoteBulkAction.reinstall,
              scope: RemoteBulkTargetScope.all,
            ),
          ),
          <String>[
            'offline1',
            'running1',
            'starting',
            'suspend1',
            'maintain',
            'install1',
            'unknown1',
          ],
        );
        expect(
          _ids(
            remoteBulkTargets(
              fleet: fleet,
              action: RemoteBulkAction.delete,
              scope: RemoteBulkTargetScope.running,
            ),
          ),
          <String>['running1', 'starting', 'suspend1', 'maintain'],
        );
      },
    );

    test('destructive actions use exact count or whole-profile phrases', () {
      expect(remoteBulkConfirmationPhrase(RemoteBulkAction.kill, 3), 'KILL 3');
      expect(
        remoteBulkConfirmationPhrase(
          RemoteBulkAction.delete,
          8,
          allProfileId: 'Production',
        ),
        'DELETE ALL production',
      );
      expect(
        remoteBulkActionRequiresTypedConfirmation(RemoteBulkAction.reinstall),
        isTrue,
      );
      expect(
        remoteBulkActionRequiresTypedConfirmation(RemoteBulkAction.stop),
        isFalse,
      );
    });
  });
}

List<String> _ids(Iterable<PterodactylFleetSample> samples) => samples
    .map((PterodactylFleetSample sample) => sample.server.identifier)
    .toList(growable: false);

PterodactylFleetSample _sample(
  String identifier,
  String name, {
  String? state,
  bool suspended = false,
  bool maintenance = false,
  String? status,
}) => PterodactylFleetSample(
  server: PterodactylClientServer(
    identifier: identifier,
    internalId: identifier.hashCode.abs() + 1,
    uuid: '00000000-0000-0000-0000-000000000001',
    name: name,
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
