import 'dart:io';

import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/trend_store.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  MetricSample sample({
    required DateTime ts,
    String instance = 'survival',
    RuntimeState state = RuntimeState.running,
    int? port,
    int? players,
    int? maxPlayers,
    double? tps,
    int? latencyMs,
    double? cpuPercent,
    int? rssBytes,
    int? diskBytes,
    int? networkRxBytes,
    int? networkTxBytes,
    int? networkRxPackets,
    int? networkTxPackets,
    double? networkRxBytesPerSecond,
    double? networkTxBytesPerSecond,
    double? networkRxPacketsPerSecond,
    double? networkTxPacketsPerSecond,
    int? memoryLimitBytes,
    int? diskLimitBytes,
    int? uptimeSeconds,
    String? version,
    String? logPath,
  }) => MetricSample(
    ts: ts,
    instance: instance,
    state: state,
    port: port,
    players: players,
    maxPlayers: maxPlayers,
    tps: tps,
    latencyMs: latencyMs,
    cpuPercent: cpuPercent,
    rssBytes: rssBytes,
    diskBytes: diskBytes,
    networkRxBytes: networkRxBytes,
    networkTxBytes: networkTxBytes,
    networkRxPackets: networkRxPackets,
    networkTxPackets: networkTxPackets,
    networkRxBytesPerSecond: networkRxBytesPerSecond,
    networkTxBytesPerSecond: networkTxBytesPerSecond,
    networkRxPacketsPerSecond: networkRxPacketsPerSecond,
    networkTxPacketsPerSecond: networkTxPacketsPerSecond,
    memoryLimitBytes: memoryLimitBytes,
    diskLimitBytes: diskLimitBytes,
    uptimeSeconds: uptimeSeconds,
    version: version,
    logPath: logPath,
  );

  group('rollupSamples', () {
    final DateTime bucketStart = DateTime.utc(2026, 7, 30, 12, 0, 0);

    test('returns an empty list for empty input', () {
      expect(
        rollupSamples(<MetricSample>[], const Duration(minutes: 5)),
        isEmpty,
      );
    });

    test('ts of the rolled sample is the bucket start, in UTC', () {
      final List<MetricSample> rolled = rollupSamples(<MetricSample>[
        sample(ts: bucketStart.add(const Duration(minutes: 2))),
      ], const Duration(minutes: 5));
      expect(rolled, hasLength(1));
      expect(rolled.single.ts, bucketStart);
      expect(rolled.single.ts.isUtc, isTrue);
    });

    test(
      'numeric fields become the mean of non-null values, integer fields rounded',
      () {
        final List<MetricSample> bucket = <MetricSample>[
          sample(
            ts: bucketStart,
            instance: 's1',
            players: 2,
            maxPlayers: 20,
            tps: 18.0,
            latencyMs: 40,
            cpuPercent: 1.0,
            rssBytes: 1000,
            diskBytes: 100,
            networkRxBytes: 1000,
            networkTxBytes: 400,
            networkRxPackets: 100,
            networkTxPackets: 40,
            networkRxBytesPerSecond: 10,
            networkTxBytesPerSecond: 4,
            networkRxPacketsPerSecond: 1,
            networkTxPacketsPerSecond: 0.4,
            memoryLimitBytes: 4000,
            diskLimitBytes: 8000,
            uptimeSeconds: 60,
          ),
          sample(
            ts: bucketStart.add(const Duration(minutes: 1)),
            instance: 's2',
            players: 3,
            maxPlayers: 20,
            tps: 19.0,
            latencyMs: 42,
            cpuPercent: 2.0,
            rssBytes: 2000,
            diskBytes: 200,
            networkRxBytes: 2000,
            networkTxBytes: 800,
            networkRxPackets: 200,
            networkTxPackets: 80,
            networkRxBytesPerSecond: 20,
            networkTxBytesPerSecond: 8,
            networkRxPacketsPerSecond: 2,
            networkTxPacketsPerSecond: 0.8,
            memoryLimitBytes: 6000,
            diskLimitBytes: 10000,
            uptimeSeconds: 120,
          ),
          sample(
            ts: bucketStart.add(const Duration(minutes: 2)),
            instance: 's3',
            players: 4,
            maxPlayers: 20,
            tps: 20.0,
            latencyMs: 44,
            cpuPercent: 3.0,
            rssBytes: 3000,
            diskBytes: 300,
            networkRxBytes: 3000,
            networkTxBytes: 1200,
            networkRxPackets: 300,
            networkTxPackets: 120,
            networkRxBytesPerSecond: 30,
            networkTxBytesPerSecond: 12,
            networkRxPacketsPerSecond: 3,
            networkTxPacketsPerSecond: 1.2,
            memoryLimitBytes: 8000,
            diskLimitBytes: 12000,
            uptimeSeconds: 180,
          ),
        ];
        final MetricSample rolled = rollupSamples(
          bucket,
          const Duration(minutes: 5),
        ).single;
        expect(rolled.players, 3); // (2+3+4)/3 = 3.0 exactly
        expect(rolled.maxPlayers, 20);
        expect(rolled.tps, 19.0);
        expect(rolled.latencyMs, 42); // (40+42+44)/3 = 42.0 exactly
        expect(rolled.cpuPercent, 2.0);
        expect(rolled.rssBytes, 2000);
        expect(rolled.diskBytes, 200);
        expect(rolled.networkRxBytes, 2000);
        expect(rolled.networkTxBytes, 800);
        expect(rolled.networkRxPackets, 200);
        expect(rolled.networkTxPackets, 80);
        expect(rolled.networkRxBytesPerSecond, 20);
        expect(rolled.networkTxBytesPerSecond, 8);
        expect(rolled.networkRxPacketsPerSecond, 2);
        expect(rolled.networkTxPacketsPerSecond, closeTo(0.8, 0.0001));
        expect(rolled.memoryLimitBytes, 6000);
        expect(rolled.diskLimitBytes, 10000);
        expect(rolled.uptimeSeconds, 120);
      },
    );

    test(
      'a field that is null on every sample in the bucket stays null, never zero',
      () {
        final MetricSample rolled = rollupSamples(<MetricSample>[
          sample(ts: bucketStart, tps: null),
          sample(ts: bucketStart.add(const Duration(minutes: 1)), tps: null),
        ], const Duration(minutes: 5)).single;
        expect(rolled.tps, isNull);
      },
    );

    test('a field with partial nulls means only over the non-null values', () {
      final MetricSample rolled = rollupSamples(<MetricSample>[
        sample(ts: bucketStart, players: 10),
        sample(ts: bucketStart.add(const Duration(minutes: 1)), players: null),
        sample(ts: bucketStart.add(const Duration(minutes: 2)), players: 20),
      ], const Duration(minutes: 5)).single;
      expect(
        rolled.players,
        15,
      ); // (10+20)/2, the null is excluded not averaged as 0
    });

    test('state is the last sample in the bucket by ts order', () {
      final MetricSample rolled = rollupSamples(<MetricSample>[
        sample(ts: bucketStart, state: RuntimeState.starting),
        sample(
          ts: bucketStart.add(const Duration(minutes: 1)),
          state: RuntimeState.running,
        ),
        sample(
          ts: bucketStart.add(const Duration(minutes: 2)),
          state: RuntimeState.stopping,
        ),
      ], const Duration(minutes: 5)).single;
      expect(rolled.state, RuntimeState.stopping);
    });

    test('instance is the first sample in the bucket by ts order', () {
      final MetricSample rolled = rollupSamples(<MetricSample>[
        sample(ts: bucketStart, instance: 'first'),
        sample(
          ts: bucketStart.add(const Duration(minutes: 1)),
          instance: 'second',
        ),
      ], const Duration(minutes: 5)).single;
      expect(rolled.instance, 'first');
    });

    test(
      'version, logPath, and port are the last non-null value in the bucket',
      () {
        final MetricSample rolled = rollupSamples(<MetricSample>[
          sample(ts: bucketStart, version: null, logPath: null, port: null),
          sample(
            ts: bucketStart.add(const Duration(minutes: 1)),
            version: '1.21.0',
            logPath: '/a.log',
            port: 25565,
          ),
          sample(
            ts: bucketStart.add(const Duration(minutes: 2)),
            version: '1.21.1',
            logPath: '/b.log',
            port: null,
          ),
        ], const Duration(minutes: 5)).single;
        expect(rolled.version, '1.21.1');
        expect(rolled.logPath, '/b.log');
        expect(
          rolled.port,
          25565,
        ); // last non-null wins even though the latest sample's port is null
      },
    );

    test(
      'unsorted input is grouped and ordered as if it had been sorted first',
      () {
        final List<MetricSample> unsorted = <MetricSample>[
          sample(
            ts: bucketStart.add(const Duration(minutes: 2)),
            state: RuntimeState.stopping,
            tps: 20.0,
          ),
          sample(ts: bucketStart, state: RuntimeState.starting, tps: 18.0),
          sample(
            ts: bucketStart.add(const Duration(minutes: 1)),
            state: RuntimeState.running,
            tps: 19.0,
          ),
        ];
        final MetricSample rolled = rollupSamples(
          unsorted,
          const Duration(minutes: 5),
        ).single;
        expect(
          rolled.state,
          RuntimeState.stopping,
        ); // still the last by ts, not by list order
        expect(rolled.tps, 19.0);
      },
    );

    test('multiple buckets are emitted sorted by ts ascending', () {
      final DateTime otherBucket = bucketStart.add(const Duration(minutes: 10));
      final List<MetricSample> rolled = rollupSamples(<MetricSample>[
        sample(ts: otherBucket, instance: 'later'),
        sample(ts: bucketStart, instance: 'earlier'),
      ], const Duration(minutes: 5));
      expect(rolled, hasLength(2));
      expect(rolled[0].ts, bucketStart);
      expect(rolled[0].instance, 'earlier');
      expect(rolled[1].ts, otherBucket);
      expect(rolled[1].instance, 'later');
    });
  });

  group('planCompaction', () {
    // now is deliberately not 5-minute aligned (12:03) so raw-vs-rolled is
    // distinguishable by whether ts snapped to a bucket start.
    final DateTime now = DateTime.utc(2026, 7, 30, 12, 3, 0);
    const TrendRetention retention = TrendRetention();

    test('keeps a sample well within the raw window unchanged', () {
      final MetricSample fresh = sample(
        ts: now.subtract(const Duration(hours: 1)),
        instance: 'fresh',
        tps: 20.0,
      );
      final List<MetricSample> result = planCompaction(
        <MetricSample>[fresh],
        now,
        retention,
      );
      expect(result, hasLength(1));
      expect(result.single.ts, fresh.ts);
      expect(result.single.tps, 20.0);
    });

    test('a sample exactly at the raw window edge stays raw (unrolled)', () {
      final DateTime edgeTs = now.subtract(const Duration(hours: 24));
      final MetricSample edge = sample(ts: edgeTs, tps: 19.5);
      final List<MetricSample> result = planCompaction(
        <MetricSample>[edge],
        now,
        retention,
      );
      expect(result, hasLength(1));
      expect(
        result.single.ts,
        edgeTs,
      ); // unchanged ts proves it was not rolled up
      expect(result.single.tps, 19.5);
    });

    test(
      'a sample just older than the raw window is rolled up into its 5-minute bucket',
      () {
        final DateTime justOlder = now.subtract(
          const Duration(hours: 24, minutes: 1),
        );
        final MetricSample sampleJustOlder = sample(ts: justOlder, tps: 19.0);
        final List<MetricSample> result = planCompaction(
          <MetricSample>[sampleJustOlder],
          now,
          retention,
        );
        expect(result, hasLength(1));
        expect(
          result.single.ts,
          isNot(justOlder),
        ); // snapped to bucket start, so ts changed
        expect(result.single.ts, DateTime.utc(2026, 7, 29, 12, 0, 0));
        expect(result.single.tps, 19.0);
      },
    );

    test(
      'a sample exactly at the total window edge is kept (rolled), not dropped',
      () {
        final DateTime edgeTs = now.subtract(const Duration(days: 7));
        final MetricSample edge = sample(ts: edgeTs, tps: 18.0);
        final List<MetricSample> result = planCompaction(
          <MetricSample>[edge],
          now,
          retention,
        );
        expect(result, hasLength(1));
        expect(result.single.tps, 18.0);
      },
    );

    test('a sample just older than the total window is dropped entirely', () {
      final DateTime justOlder = now.subtract(
        const Duration(days: 7, minutes: 1),
      );
      final MetricSample sampleJustOlder = sample(ts: justOlder, tps: 10.0);
      final List<MetricSample> result = planCompaction(
        <MetricSample>[sampleJustOlder],
        now,
        retention,
      );
      expect(result, isEmpty);
    });

    test(
      'a dropped sample never leaks into a surviving bucket it would otherwise share',
      () {
        // Both land in the same 5-minute bucket (2026-07-23T12:00:00Z) if
        // the drop boundary were computed incorrectly.
        final DateTime survivingEdge = now.subtract(const Duration(days: 7));
        final DateTime droppedNeighbor = now.subtract(
          const Duration(days: 7, minutes: 1),
        );
        final List<MetricSample> result = planCompaction(
          <MetricSample>[
            sample(ts: survivingEdge, tps: 18.0),
            sample(ts: droppedNeighbor, tps: 10.0),
          ],
          now,
          retention,
        );
        expect(result, hasLength(1));
        expect(result.single.tps, 18.0); // not averaged with the dropped 10.0
      },
    );

    test(
      'result is sorted by ts ascending across raw and rolled samples together',
      () {
        final MetricSample raw = sample(
          ts: now.subtract(const Duration(minutes: 5)),
          instance: 'raw',
        );
        final MetricSample old = sample(
          ts: now.subtract(const Duration(hours: 30)),
          instance: 'old',
        );
        final List<MetricSample> result = planCompaction(
          <MetricSample>[raw, old],
          now,
          retention,
        );
        expect(result, hasLength(2));
        expect(result[0].ts.isBefore(result[1].ts), isTrue);
        expect(result[0].instance, 'old');
        expect(result[1].instance, 'raw');
      },
    );
  });

  group('TrendStore.fileFor', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trend_store_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('sanitizes forward slashes to hyphens', () {
      final TrendStore store = TrendStore(tempDir);
      final File file = store.fileFor('foo/bar');
      expect(p.basename(file.path), 'foo-bar.jsonl');
      expect(p.dirname(file.path), tempDir.path);
    });

    test('sanitizes spaces to hyphens', () {
      final TrendStore store = TrendStore(tempDir);
      final File file = store.fileFor('my server');
      expect(p.basename(file.path), 'my-server.jsonl');
    });

    test(
      'never escapes the store directory for a traversal-shaped instance name',
      () {
        final TrendStore store = TrendStore(tempDir);
        final File file = store.fileFor('../../etc/passwd');
        expect(p.dirname(file.path), tempDir.path);
        expect(p.basename(file.path).contains('/'), isFalse);
      },
    );

    test(
      'leaves allowed characters (letters, digits, dot, underscore, hyphen) untouched',
      () {
        final TrendStore store = TrendStore(tempDir);
        final File file = store.fileFor('abc123_.-XYZ');
        expect(p.basename(file.path), 'abc123_.-XYZ.jsonl');
      },
    );
  });

  group('TrendStore append/read', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trend_store_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('read on a missing file returns an empty list', () async {
      final TrendStore store = TrendStore(tempDir);
      final List<MetricSample> result = await store.read(
        'nobody',
        now: DateTime.utc(2026, 7, 30),
      );
      expect(result, isEmpty);
    });

    test('round-trips a single appended sample', () async {
      final TrendStore store = TrendStore(tempDir);
      final DateTime ts = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final MetricSample original = sample(ts: ts, players: 5, tps: 19.9);
      await store.append('survival', original);
      final List<MetricSample> result = await store.read('survival', now: ts);
      expect(result, hasLength(1));
      expect(result.single.ts, ts);
      expect(result.single.players, 5);
      expect(result.single.tps, 19.9);
    });

    test('creates the store directory recursively on first write', () async {
      final Directory nested = Directory(p.join(tempDir.path, 'a', 'b', 'c'));
      final TrendStore store = TrendStore(nested);
      expect(nested.existsSync(), isFalse);
      await store.append('survival', sample(ts: DateTime.utc(2026, 7, 30)));
      expect(nested.existsSync(), isTrue);
      expect(store.fileFor('survival').existsSync(), isTrue);
    });

    test('read sorts ascending by ts regardless of append order', () async {
      final TrendStore store = TrendStore(tempDir);
      final DateTime later = DateTime.utc(2026, 7, 30, 12, 5, 0);
      final DateTime earlier = DateTime.utc(2026, 7, 30, 12, 0, 0);
      await store.append('survival', sample(ts: later, instance: 'later'));
      await store.append('survival', sample(ts: earlier, instance: 'earlier'));
      final List<MetricSample> result = await store.read(
        'survival',
        now: later,
      );
      expect(result, hasLength(2));
      expect(result[0].ts, earlier);
      expect(result[1].ts, later);
    });

    test('malformed lines are skipped, valid lines still read', () async {
      final TrendStore store = TrendStore(tempDir);
      final DateTime ts = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final File file = store.fileFor('survival');
      await file.parent.create(recursive: true);
      final String goodLine = sample(ts: ts, players: 7).toJsonLine();
      await file.writeAsString(
        '$goodLine\nnot json at all\n\n{"missing":"fields"}\n',
      );
      final List<MetricSample> result = await store.read('survival', now: ts);
      expect(result, hasLength(1));
      expect(result.single.players, 7);
    });

    test('window filters out samples older than now minus window', () async {
      final TrendStore store = TrendStore(tempDir);
      final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final DateTime withinWindow = now.subtract(const Duration(minutes: 30));
      final DateTime outsideWindow = now.subtract(const Duration(hours: 2));
      await store.append(
        'survival',
        sample(ts: outsideWindow, instance: 'outside'),
      );
      await store.append(
        'survival',
        sample(ts: withinWindow, instance: 'inside'),
      );
      final List<MetricSample> result = await store.read(
        'survival',
        now: now,
        window: const Duration(hours: 1),
      );
      expect(result, hasLength(1));
      expect(result.single.instance, 'inside');
    });

    test(
      'window boundary is inclusive: a sample exactly at now minus window is kept',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
        final DateTime exactlyAtEdge = now.subtract(const Duration(hours: 1));
        await store.append('survival', sample(ts: exactlyAtEdge));
        final List<MetricSample> result = await store.read(
          'survival',
          now: now,
          window: const Duration(hours: 1),
        );
        expect(result, hasLength(1));
      },
    );
  });

  group('TrendStore.compactIfNeeded', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trend_store_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('does nothing when the file does not exist', () async {
      final TrendStore store = TrendStore(tempDir);
      await store.compactIfNeeded('nobody', DateTime.utc(2026, 7, 30));
      expect(store.fileFor('nobody').existsSync(), isFalse);
    });

    test(
      'does nothing when the file is under the compaction threshold',
      () async {
        final TrendStore store = TrendStore(
          tempDir,
          retention: const TrendRetention(compactAfterBytes: 1024 * 1024),
        );
        final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
        await store.append('survival', sample(ts: now, players: 1));
        final List<MetricSample> before = await store.read(
          'survival',
          now: now,
        );
        await store.compactIfNeeded('survival', now);
        final List<MetricSample> after = await store.read('survival', now: now);
        expect(after, hasLength(before.length));
        expect(after.single.players, 1);
      },
    );

    test(
      'rewrites the file with compaction survivors once over the threshold, and it rereads cleanly',
      () async {
        final TrendStore store = TrendStore(
          tempDir,
          retention: const TrendRetention(compactAfterBytes: 10),
        );
        final DateTime now = DateTime.utc(2026, 7, 30, 12, 3, 0);
        final DateTime recent = now.subtract(const Duration(minutes: 5));
        final DateTime middle = now.subtract(
          const Duration(hours: 30),
        ); // rolls up
        final DateTime ancient = now.subtract(
          const Duration(days: 10),
        ); // dropped

        await store.append(
          'survival',
          sample(ts: ancient, instance: 'ancient', players: 99),
        );
        await store.append(
          'survival',
          sample(ts: middle, instance: 'middle', players: 5),
        );
        await store.append(
          'survival',
          sample(ts: recent, instance: 'recent', players: 3),
        );

        await store.compactIfNeeded('survival', now);

        // No leftover temp file after the atomic rename.
        expect(
          File('${store.fileFor('survival').path}.tmp').existsSync(),
          isFalse,
        );

        final List<MetricSample> survivors = await store.read(
          'survival',
          now: now,
        );
        expect(
          survivors.any((MetricSample s) => s.instance == 'ancient'),
          isFalse,
        );
        expect(
          survivors.any((MetricSample s) => s.ts == recent && s.players == 3),
          isTrue,
        );
        // The middle sample survives, rolled up (its exact ts will have
        // snapped to a bucket start rather than staying at `middle`).
        expect(survivors.any((MetricSample s) => s.players == 5), isTrue);
        expect(survivors, hasLength(2));
      },
    );
  });

  group('TrendStore write failure handling', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trend_store_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'a directory that cannot be created disables writes after one failure, without throwing',
      () async {
        final String blockedPath = p.join(tempDir.path, 'blocked');
        // Create a plain file where the store expects to create a directory,
        // so the recursive directory creation fails.
        File(blockedPath).writeAsStringSync('not a directory');

        final TrendStore store = TrendStore(Directory(blockedPath));
        expect(store.writeFailed, isFalse);

        await store.append('survival', sample(ts: DateTime.utc(2026, 7, 30)));
        expect(store.writeFailed, isTrue);

        // Second call must silently no-op rather than throw again.
        await store.append('survival', sample(ts: DateTime.utc(2026, 7, 30)));
        expect(store.writeFailed, isTrue);
      },
    );
  });
}
