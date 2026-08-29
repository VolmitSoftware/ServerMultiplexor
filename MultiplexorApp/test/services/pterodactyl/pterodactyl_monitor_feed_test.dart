import 'dart:io';

import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_monitor_feed.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:test/test.dart';

const PterodactylServerLimits limits = PterodactylServerLimits(
  memoryMiB: 4096,
  swapMiB: 0,
  diskMiB: 8192,
  ioWeight: 500,
  cpuPercent: 200,
  threads: null,
  oomDisabled: false,
);

const PterodactylFeatureLimits featureLimits = PterodactylFeatureLimits(
  databases: 1,
  allocations: 4,
  backups: 2,
);

PterodactylClientServer server(
  String identifier, {
  String? status,
  bool maintenance = false,
  List<PterodactylAllocation> allocations = const <PterodactylAllocation>[],
}) => PterodactylClientServer(
  identifier: identifier,
  internalId: identifier.hashCode,
  uuid: 'uuid-$identifier',
  name: 'Server $identifier',
  nodeName: 'node-a',
  description: '',
  isOwner: true,
  isNodeUnderMaintenance: maintenance,
  status: status,
  sftpHost: 'sftp.example.test',
  sftpPort: 2022,
  limits: limits,
  featureLimits: featureLimits,
  allocations: allocations,
);

PterodactylResourceUsage resources(String state, {bool suspended = false}) =>
    PterodactylResourceUsage(
      currentState: state,
      isSuspended: suspended,
      memoryBytes: 1024,
      cpuAbsolute: 12.5,
      diskBytes: 2048,
      networkRxBytes: 300,
      networkTxBytes: 400,
      uptime: const Duration(seconds: 60),
    );

void main() {
  test(
    'exposes a failed first capture for the connection repair surface',
    () async {
      int attempts = 0;
      final PterodactylMonitorFeed feed = PterodactylMonitorFeed.withCapture(
        profileId: 'production',
        captureFleet: (String _) async {
          attempts += 1;
          if (attempts == 1) throw const SocketException('offline');
          return <PterodactylFleetSample>[];
        },
      );

      await expectLater(feed.captureMetrics(), throwsA(isA<SocketException>()));
      expect(feed.connectionFailed, isTrue);

      await feed.captureMetrics();
      expect(feed.connectionFailed, isFalse);
    },
  );

  test('retains every advertised alias and bind allocation', () async {
    int dnsLookups = 0;
    final PterodactylMonitorFeed feed = PterodactylMonitorFeed.withCapture(
      profileId: 'production',
      dnsLookup: (String host) async {
        dnsLookups += 1;
        expect(host, 'play.example.test');
        return <InternetAddress>[
          InternetAddress('198.51.100.20'),
          InternetAddress('2001:db8::20'),
        ];
      },
      captureFleet: (String profileId) async {
        expect(profileId, 'production');
        return <PterodactylFleetSample>[
          PterodactylFleetSample(
            server: server(
              'alpha',
              allocations: const <PterodactylAllocation>[
                PterodactylAllocation(
                  id: 1,
                  ip: '0.0.0.0',
                  port: 25565,
                  alias: 'play.example.test',
                  isDefault: true,
                ),
                PterodactylAllocation(
                  id: 2,
                  ip: '::',
                  port: 25566,
                  alias: '2001:db8::10',
                ),
                PterodactylAllocation(id: 3, ip: '10.0.0.8', port: 25567),
              ],
            ),
            resources: resources('running'),
          ),
        ];
      },
    );

    await feed.captureMetrics();
    await feed.captureMetrics();
    expect(dnsLookups, 1, reason: 'A/AAAA answers are cached per feed');
    final MonitorSnapshot snapshot = MonitorSnapshot(
      instances: feed.instances,
      history: const <String, List<MetricSample>>{},
      consumerName: 'remote',
      displayNames: feed.displayNames,
      advertisedEndpoints: feed.advertisedEndpoints,
      bindEndpoints: feed.bindEndpoints,
    );

    expect(snapshot.advertisedEndpointsFor('alpha'), <String>[
      'play.example.test (198.51.100.20):25565',
      'play.example.test (2001:db8::20):25565',
      '[2001:db8::10]:25566',
    ]);
    expect(snapshot.bindEndpointsFor('alpha'), <String>[
      '0.0.0.0:25565',
      '[::]:25566',
      '10.0.0.8:25567',
    ]);
  });

  test(
    'literal aliases skip DNS and lookup failures retain hostname',
    () async {
      int dnsLookups = 0;
      final PterodactylMonitorFeed feed = PterodactylMonitorFeed.withCapture(
        profileId: 'production',
        dnsLookup: (String host) async {
          dnsLookups += 1;
          throw const SocketException('not found');
        },
        captureFleet: (String _) async => <PterodactylFleetSample>[
          PterodactylFleetSample(
            server: server(
              'alpha',
              allocations: const <PterodactylAllocation>[
                PterodactylAllocation(
                  id: 1,
                  ip: '0.0.0.0',
                  port: 25565,
                  alias: 'missing.example.test',
                ),
                PterodactylAllocation(
                  id: 2,
                  ip: '0.0.0.0',
                  port: 25566,
                  alias: '198.51.100.8',
                ),
              ],
            ),
            resources: resources('running'),
          ),
        ],
      );

      await feed.captureMetrics();
      final MonitorSnapshot snapshot = MonitorSnapshot(
        instances: feed.instances,
        history: const <String, List<MetricSample>>{},
        consumerName: 'remote',
        advertisedEndpoints: feed.advertisedEndpoints,
      );

      expect(dnsLookups, 1);
      expect(snapshot.advertisedEndpointsFor('alpha'), <String>[
        'missing.example.test:25565',
        '198.51.100.8:25566',
      ]);
    },
  );

  test(
    'carries a specific operation block reason for every unsafe state',
    () async {
      final PterodactylMonitorFeed feed = PterodactylMonitorFeed.withCapture(
        profileId: 'production',
        captureFleet: (String _) async => <PterodactylFleetSample>[
          PterodactylFleetSample(server: server('missing')),
          PterodactylFleetSample(
            server: server('maintenance', maintenance: true),
            resources: resources('running'),
          ),
          PterodactylFleetSample(
            server: server('suspended'),
            resources: resources('offline', suspended: true),
          ),
          PterodactylFleetSample(
            server: server('installing', status: 'installing'),
            resources: resources('running'),
          ),
          PterodactylFleetSample(
            server: server('restoring', status: 'restoring_backup'),
            resources: resources('running'),
          ),
          PterodactylFleetSample(
            server: server('blank-status', status: '  '),
            resources: resources('running'),
          ),
          PterodactylFleetSample(
            server: server('unknown'),
            resources: resources('migrating'),
          ),
          PterodactylFleetSample(
            server: server('healthy'),
            resources: resources(' running '),
          ),
        ],
      );

      final String metrics = await feed.captureMetrics();
      final MonitorSnapshot snapshot = MonitorSnapshot(
        instances: feed.instances,
        history: const <String, List<MetricSample>>{},
        consumerName: 'remote',
        displayNames: feed.displayNames,
        operationBlockReasons: feed.operationBlockReasons,
      );

      expect(feed.operationBlockReasons, <String, String>{
        'missing': 'resources unavailable',
        'maintenance': 'node is under maintenance',
        'suspended': 'server is suspended',
        'installing': 'server is installing',
        'restoring': 'server status: restoring_backup',
        'blank-status': 'server status is unknown',
        'unknown': 'unknown runtime state: migrating',
      });
      expect(
        snapshot.operationBlockReasonFor('missing'),
        'resources unavailable',
      );
      expect(snapshot.operationBlockReasonFor('healthy'), isNull);
      expect(metrics, contains('healthy\trunning'));
      expect(metrics, isNot(contains('missing\t')));
      expect(metrics, isNot(contains('unknown\t')));
    },
  );

  test(
    'emits the canonical resource row with packet counters unavailable',
    () async {
      final PterodactylMonitorFeed feed = PterodactylMonitorFeed.withCapture(
        profileId: 'production',
        captureFleet: (String _) async => <PterodactylFleetSample>[
          PterodactylFleetSample(
            server: server('alpha'),
            resources: resources('running'),
          ),
        ],
      );

      final List<String> cells = (await feed.captureMetrics()).split('\t');
      expect(cells, hasLength(21));
      expect(cells[14], '2048');
      expect(cells[15], '300');
      expect(cells[16], '400');
      expect(cells[19], '-');
      expect(cells[20], '-');
    },
  );
}
