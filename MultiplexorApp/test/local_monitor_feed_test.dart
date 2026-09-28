import 'dart:async';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/monitor/local_monitor_feed.dart';
import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_landing.dart';
import 'package:multiplexor/services/monitor/monitor_network_tree.dart';
import 'package:multiplexor/services/monitor/trend_store.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _row(String name, int port, {bool locked = false, int? rxBytes}) =>
    metricsTsvRow(
      name: name,
      state: RuntimeState.running,
      locked: locked,
      isolated: false,
      port: port,
      networkRxBytes: rxBytes,
    );

void main() {
  test(
    'profile captures share a timestamp for fleet history aggregation',
    () async {
      final DateTime start = DateTime.utc(2026, 9, 28);
      int clockCalls = 0;
      final Completer<void> pluginCaptured = Completer<void>();
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async {
          if (profile == ConsumerProfile.plugin) {
            pluginCaptured.complete();
          } else if (profile == ConsumerProfile.forge) {
            await pluginCaptured.future;
          } else {
            return '';
          }
          return metricsTsvRow(
            name: 'demo',
            state: RuntimeState.running,
            locked: false,
            isolated: false,
            tps: profile == ConsumerProfile.plugin ? 20 : 16,
            rssBytes: profile == ConsumerProfile.plugin ? 1000 : 2000,
          );
        },
        capturePrimary: (ConsumerProfile profile) async => null,
        clock: () => start.add(Duration(microseconds: clockCalls++)),
      );

      await feed.sweep();
      final MonitorRollup rollup = MonitorRollup.of(
        feed.snapshot(),
        windowStart: start.subtract(const Duration(seconds: 1)),
        windowEnd: start.add(const Duration(seconds: 1)),
      );

      expect(clockCalls, 1);
      expect(feed.latest('plugin/demo')!.ts, feed.latest('forge/demo')!.ts);
      expect(rollup.tpsSeries, <double>[18]);
      expect(rollup.rssSum, 3000);
      expect(rollup.peakRssSum, 3000);
    },
  );

  test(
    'duplicate names retain separate metrics, flags and primary state',
    () async {
      DateTime now = DateTime.utc(2026, 9, 28);
      int sweep = 0;
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async => switch (profile) {
          ConsumerProfile.plugin => _row(
            'demo',
            25565,
            rxBytes: 100 + sweep * 20,
          ),
          ConsumerProfile.forge => _row(
            'demo',
            25566,
            locked: true,
            rxBytes: 500 + sweep * 100,
          ),
          _ => '',
        },
        capturePrimary: (ConsumerProfile profile) async => 'demo',
        clock: () => now,
      );
      await feed.sweep();
      sweep++;
      now = now.add(const Duration(seconds: 2));
      await feed.sweep();
      final MonitorSnapshot snapshot = feed.snapshot();

      expect(snapshot.instances, <String>['plugin/demo', 'forge/demo']);
      expect(snapshot.groupedLocal, isTrue);
      expect(snapshot.primaryInstances, <String>{'plugin/demo', 'forge/demo'});
      expect(snapshot.instanceConsumers['forge/demo'], ConsumerProfile.forge);
      expect(snapshot.displayNameFor('forge/demo'), 'demo');
      expect(snapshot.flagsFor('plugin/demo').locked, isFalse);
      expect(snapshot.flagsFor('forge/demo').locked, isTrue);
      expect(feed.latest('plugin/demo')!.port, 25565);
      expect(feed.latest('forge/demo')!.port, 25566);
      expect(feed.latest('plugin/demo')!.networkRxBytesPerSecond, 10);
      expect(feed.latest('forge/demo')!.networkRxBytesPerSecond, 50);
      expect(feed.history('plugin/demo'), hasLength(2));
      expect(feed.latest('demo'), isNull);
      expect(feed.history('unknown/demo'), isEmpty);
    },
  );

  test(
    'failed profile retains its last capture while other profiles refresh',
    () async {
      bool failForge = false;
      int pluginPort = 25565;
      DateTime now = DateTime.utc(2026, 9, 28);
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async {
          if (profile == ConsumerProfile.forge && failForge) {
            throw StateError('unavailable');
          }
          return switch (profile) {
            ConsumerProfile.plugin => _row('demo', pluginPort),
            ConsumerProfile.forge => _row('demo', 25566, locked: true),
            _ => '',
          };
        },
        capturePrimary: (ConsumerProfile profile) async => 'demo',
        clock: () => now,
      );
      await feed.sweep();
      final DateTime originalTime = now;
      now = now.add(const Duration(seconds: 2));
      failForge = true;
      pluginPort = 25567;
      await feed.sweep();
      final MonitorSnapshot snapshot = feed.snapshot();

      expect(snapshot.instances, <String>['plugin/demo', 'forge/demo']);
      expect(snapshot.captureError, contains('forge:'));
      expect(snapshot.lastSuccessfulCapture, originalTime);
      expect(feed.latest('plugin/demo')!.port, 25567);
      expect(feed.latest('forge/demo')!.ts, originalTime);
      expect(feed.history('forge/demo'), hasLength(1));
      expect(snapshot.flagsFor('forge/demo').locked, isTrue);
    },
  );

  test(
    'successful empty profile clears servers and failed primary read retains selection',
    () async {
      bool primaryFails = false;
      bool empty = false;
      String? primary = 'demo';
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async =>
            profile == ConsumerProfile.fabric && !empty
            ? _row('demo', 25565)
            : '',
        capturePrimary: (ConsumerProfile profile) async {
          if (profile != ConsumerProfile.fabric) return null;
          if (primaryFails) throw StateError('primary unavailable');
          return primary;
        },
      );
      await feed.sweep();
      primaryFails = true;
      await feed.sweep();
      expect(feed.snapshot().primaryInstances, <String>{'fabric/demo'});
      expect(feed.snapshot().captureError, contains('fabric primary:'));
      primaryFails = false;
      primary = null;
      await feed.sweep();
      expect(feed.snapshot().primaryInstances, isEmpty);
      expect(feed.snapshot().captureError, isNull);
      empty = true;
      await feed.sweep();
      expect(feed.snapshot().instances, isEmpty);
      expect(feed.snapshot().groupedLocal, isTrue);
    },
  );

  test(
    'plugin network ordering and endpoints use qualified identifiers',
    () async {
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async => switch (profile) {
          ConsumerProfile.plugin =>
            '${_row('lobby', 25566)}\n${_row('proxy', 25565)}',
          ConsumerProfile.forge => _row('proxy', 25567),
          _ => '',
        },
        capturePrimary: (ConsumerProfile profile) async => null,
      );
      await feed.sweep();
      final MonitorSnapshot snapshot = feed.snapshot(
        networks: const <MonitorNetworkGroup>[
          MonitorNetworkGroup(
            name: 'network',
            proxy: 'proxy',
            port: 25565,
            members: <MonitorNetworkMember>[
              MonitorNetworkMember(
                instance: 'lobby',
                alias: 'hub',
                port: 25566,
              ),
            ],
          ),
        ],
        advertisedEndpoints: const <String, String>{
          'proxy': 'play.example.test:25565',
        },
        networkTopologyStale: true,
      );
      expect(snapshot.instances, <String>[
        'plugin/proxy',
        'plugin/lobby',
        'forge/proxy',
      ]);
      expect(snapshot.networkRows['plugin/lobby']!.proxy, 'plugin/proxy');
      expect(snapshot.networkRows['plugin/lobby']!.alias, 'hub');
      expect(snapshot.networkRows['forge/proxy'], isNull);
      expect(
        snapshot.advertisedEndpointFor('plugin/proxy'),
        'play.example.test:25565',
      );
      expect(snapshot.advertisedEndpointFor('forge/proxy'), isNull);
      expect(snapshot.networkTopologyStale, isTrue);
    },
  );

  test(
    'profile trend stores retain their original names and histories',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'multiplexor-feed-test-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final DateTime now = DateTime.utc(2026, 9, 28);
      final Map<ConsumerProfile, TrendStore> stores =
          <ConsumerProfile, TrendStore>{
            for (final ConsumerProfile profile in <ConsumerProfile>[
              ConsumerProfile.plugin,
              ConsumerProfile.forge,
            ])
              profile: TrendStore(
                Directory(p.join(temp.path, profile.shortName)),
              ),
          };
      for (final MapEntry<ConsumerProfile, TrendStore> entry
          in stores.entries) {
        await entry.value.append(
          'demo',
          MetricSample(
            ts: now.subtract(const Duration(minutes: 1)),
            instance: 'demo',
            state: RuntimeState.stopped,
            port: entry.key == ConsumerProfile.plugin ? 25565 : 25566,
          ),
        );
      }
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async => switch (profile) {
          ConsumerProfile.plugin => _row('demo', 25565),
          ConsumerProfile.forge => _row('demo', 25566),
          _ => '',
        },
        capturePrimary: (ConsumerProfile profile) async => null,
        stores: stores,
        clock: () => now,
      );
      await feed.initialize(window: const Duration(days: 7));
      expect(
        feed.history('plugin/demo').map((MetricSample sample) => sample.port),
        <int>[25565, 25565],
      );
      expect(
        feed.history('forge/demo').map((MetricSample sample) => sample.port),
        <int>[25566, 25566],
      );
      expect(
        feed
            .history('forge/demo')
            .every((MetricSample sample) => sample.instance == 'demo'),
        isTrue,
      );
    },
  );

  test(
    'sweeps profiles concurrently and drops overlapping refreshes',
    () async {
      final Completer<void> gate = Completer<void>();
      final Set<ConsumerProfile> entered = <ConsumerProfile>{};
      final LocalMonitorFeed feed = LocalMonitorFeed(
        captureMetrics: (ConsumerProfile profile) async {
          entered.add(profile);
          await gate.future;
          return '';
        },
        capturePrimary: (ConsumerProfile profile) async => null,
      );
      final Future<void> first = feed.sweep();
      expect(entered, ConsumerProfile.values.toSet());
      await feed.sweep();
      gate.complete();
      await first;
      expect(feed.snapshot().captureError, isNull);
    },
  );
}
