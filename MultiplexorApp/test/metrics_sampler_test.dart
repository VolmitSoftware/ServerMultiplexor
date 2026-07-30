import 'dart:async';
import 'dart:io';

import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/metrics_sampler.dart';
import 'package:multiplexor/services/monitor/trend_store.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // Builds one well-formed `runtime metrics` TSV row via the canonical
  // encoder, so tests never hand-roll column layouts.
  String tsvRow({
    String name = 'survival',
    RuntimeState state = RuntimeState.running,
    int? port = 25565,
    bool locked = false,
    int? players = 3,
    int? maxPlayers = 20,
    String? version = '1.21.1',
    double? tps = 19.9,
    bool isolated = false,
    int? uptimeSeconds = 120,
    double? cpuPercent = 12.5,
    int? rssBytes = 1024000,
    String? logPath = '/var/log/survival.log',
  }) => metricsTsvRow(
    name: name,
    state: state,
    locked: locked,
    isolated: isolated,
    port: port,
    players: players,
    maxPlayers: maxPlayers,
    version: version,
    tps: tps,
    uptimeSeconds: uptimeSeconds,
    cpuPercent: cpuPercent,
    rssBytes: rssBytes,
    logPath: logPath,
  );

  group('sweep', () {
    test('parses each row into latest and a one-entry history', () async {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => <String>[
          tsvRow(name: 'survival', players: 3),
          tsvRow(name: 'creative', players: 0),
        ].join('\n'),
        clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
      );

      await sampler.sweep();

      expect(sampler.instances, <String>['survival', 'creative']);
      expect(sampler.latest('survival')?.players, 3);
      expect(sampler.history('survival'), hasLength(1));
      expect(sampler.latest('creative')?.players, 0);
      expect(sampler.history('creative'), hasLength(1));
    });

    test(
      'blank lines and malformed rows are skipped without affecting valid rows',
      () async {
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => <String>[
            tsvRow(name: 'survival'),
            '',
            'not\tenough\tcolumns',
            '',
          ].join('\n'),
          clock: () => DateTime.utc(2026, 7, 30),
        );

        await sampler.sweep();

        expect(sampler.instances, <String>['survival']);
      },
    );

    test(
      'calls clock exactly once per sweep so every row shares one ts',
      () async {
        int clockCalls = 0;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => <String>[
            tsvRow(name: 'survival'),
            tsvRow(name: 'creative'),
          ].join('\n'),
          clock: () {
            clockCalls++;
            return DateTime.utc(2026, 7, 30, 12, clockCalls);
          },
        );

        await sampler.sweep();

        expect(clockCalls, 1);
        expect(sampler.latest('survival')!.ts, sampler.latest('creative')!.ts);
      },
    );

    test(
      'a second sweep appends to history rather than replacing it',
      () async {
        int sweepCount = 0;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async {
            sweepCount++;
            return tsvRow(name: 'survival', players: sweepCount);
          },
          clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
        );

        await sampler.sweep();
        await sampler.sweep();

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(2));
        expect(history[0].players, 1);
        expect(history[1].players, 2);
      },
    );

    test(
      'ring truncates to ringCapacity, keeping only the newest samples',
      () async {
        int sweepCount = 0;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async {
            sweepCount++;
            return tsvRow(name: 'survival', players: sweepCount);
          },
          ringCapacity: 3,
          clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
        );

        for (int i = 0; i < 5; i++) {
          await sampler.sweep();
        }

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(3));
        expect(history.map((MetricSample s) => s.players).toList(), <int>[
          3,
          4,
          5,
        ]);
      },
    );

    test(
      'an instance missing from a later sweep drops out of instances but keeps its history',
      () async {
        bool includeCreative = true;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async {
            final List<String> rows = <String>[tsvRow(name: 'survival')];
            if (includeCreative) {
              rows.add(tsvRow(name: 'creative'));
            }
            return rows.join('\n');
          },
          clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
        );

        await sampler.sweep();
        expect(sampler.instances, <String>['survival', 'creative']);

        includeCreative = false;
        await sampler.sweep();

        expect(sampler.instances, <String>['survival']);
        expect(sampler.history('creative'), hasLength(1));
      },
    );

    test(
      'a sweep already in flight causes a second sweep to return immediately without calling captureMetrics again',
      () async {
        final Completer<String> gate = Completer<String>();
        int captureCalls = 0;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () {
            captureCalls++;
            return gate.future;
          },
          clock: () => DateTime.utc(2026, 7, 30),
        );

        final Future<void> firstSweep = sampler.sweep();
        expect(sampler.sweeping, isTrue);

        await sampler.sweep();
        expect(captureCalls, 1);

        gate.complete(tsvRow(name: 'survival'));
        await firstSweep;

        expect(sampler.sweeping, isFalse);
        expect(captureCalls, 1);
        expect(sampler.instances, <String>['survival']);
      },
    );

    test(
      'captureMetrics throwing does not throw out of sweep and leaves sweeping cleared',
      () async {
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => throw StateError('boom'),
          clock: () => DateTime.utc(2026, 7, 30),
        );

        await sampler.sweep();

        expect(sampler.sweeping, isFalse);
        expect(sampler.instances, isEmpty);
        expect(sampler.latest('survival'), isNull);
      },
    );

    test(
      'a later throwing sweep leaves previously collected state unchanged',
      () async {
        bool shouldThrow = false;
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async {
            if (shouldThrow) {
              throw StateError('boom');
            }
            return tsvRow(name: 'survival', players: 3);
          },
          clock: () => DateTime.utc(2026, 7, 30),
        );

        await sampler.sweep();
        expect(sampler.instances, <String>['survival']);

        shouldThrow = true;
        await sampler.sweep();

        expect(sampler.sweeping, isFalse);
        expect(sampler.instances, <String>['survival']);
        expect(sampler.latest('survival')?.players, 3);
      },
    );

    test(
      'the default clock stamps samples in UTC when clock is omitted',
      () async {
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => tsvRow(name: 'survival'),
        );

        await sampler.sweep();

        expect(sampler.latest('survival')!.ts.isUtc, isTrue);
      },
    );
  });

  group('history', () {
    test('returns an empty list for an instance that has never been swept', () {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      expect(sampler.history('nobody'), isEmpty);
    });
  });

  group('latest', () {
    test('returns null for an instance that has never been swept', () {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      expect(sampler.latest('nobody'), isNull);
    });
  });

  group('instances', () {
    test('is empty before any sweep has run', () {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      expect(sampler.instances, isEmpty);
    });

    test('the returned list cannot be mutated by callers', () async {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => tsvRow(name: 'survival'),
        clock: () => DateTime.utc(2026, 7, 30),
      );
      await sampler.sweep();
      expect(() => sampler.instances.add('hack'), throwsUnsupportedError);
    });
  });

  group('sweeping', () {
    test('is false before any sweep has run', () {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      expect(sampler.sweeping, isFalse);
    });
  });

  group('sweep with a TrendStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('metrics_sampler_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'appends exactly one line per parsed row per sweep to the store',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => <String>[
            tsvRow(name: 'survival'),
            tsvRow(name: 'creative'),
          ].join('\n'),
          store: store,
          clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
        );

        await sampler.sweep();
        await sampler.sweep();
        await sampler.sweep();

        final List<String> survivalLines = store
            .fileFor('survival')
            .readAsLinesSync()
            .where((String l) => l.trim().isNotEmpty)
            .toList();
        final List<String> creativeLines = store
            .fileFor('creative')
            .readAsLinesSync()
            .where((String l) => l.trim().isNotEmpty)
            .toList();
        expect(survivalLines, hasLength(3));
        expect(creativeLines, hasLength(3));
      },
    );

    test('a null store means sweep never touches disk', () async {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => tsvRow(name: 'survival'),
        clock: () => DateTime.utc(2026, 7, 30),
      );
      await sampler.sweep();
      expect(sampler.latest('survival'), isNotNull);
    });
  });

  group('seedFromStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('metrics_sampler_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    MetricSample rawSample({required DateTime ts, int players = 0}) =>
        MetricSample(
          ts: ts,
          instance: 'survival',
          state: RuntimeState.running,
          players: players,
        );

    test('is a no-op when the sampler has no store', () async {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      await sampler.seedFromStore(<String>[
        'survival',
      ], window: const Duration(hours: 1));
      expect(sampler.history('survival'), isEmpty);
    });

    test(
      'prepends persisted samples older than the live ones already in the ring',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final DateTime older = DateTime.utc(2026, 7, 30, 11, 0, 0);
        final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
        await store.append('survival', rawSample(ts: older, players: 1));

        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => tsvRow(name: 'survival', players: 2),
          store: store,
          clock: () => now,
        );
        await sampler.sweep();

        await sampler.seedFromStore(<String>[
          'survival',
        ], window: const Duration(hours: 6));

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(2));
        expect(history[0].ts, older);
        expect(history[0].players, 1);
        expect(history[1].ts, now);
        expect(history[1].players, 2);
      },
    );

    test(
      'dedupes a persisted sample sharing an exact ts with a live sample, live wins',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final DateTime ts = DateTime.utc(2026, 7, 30, 12, 0, 0);
        await store.append('survival', rawSample(ts: ts, players: 99));

        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => tsvRow(name: 'survival', players: 5),
          store: store,
          clock: () => ts,
        );
        await sampler.sweep();

        await sampler.seedFromStore(<String>[
          'survival',
        ], window: const Duration(hours: 6));

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(1));
        expect(history.single.players, 5);
      },
    );

    test(
      'passes the window through to the store read, excluding samples outside it',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
        final DateTime withinWindow = now.subtract(const Duration(minutes: 30));
        final DateTime outsideWindow = now.subtract(const Duration(hours: 2));
        await store.append(
          'survival',
          rawSample(ts: outsideWindow, players: 1),
        );
        await store.append('survival', rawSample(ts: withinWindow, players: 2));

        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => '',
          store: store,
          clock: () => now,
        );

        await sampler.seedFromStore(<String>[
          'survival',
        ], window: const Duration(hours: 1));

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(1));
        expect(history.single.ts, withinWindow);
      },
    );

    test(
      'trims the merged history to ringCapacity, keeping the newest samples',
      () async {
        final TrendStore store = TrendStore(tempDir);
        final DateTime base = DateTime.utc(2026, 7, 30, 12, 0, 0);
        for (int i = 0; i < 5; i++) {
          await store.append(
            'survival',
            rawSample(
              ts: base.add(Duration(minutes: i)),
              players: i,
            ),
          );
        }

        final MetricsSampler sampler = MetricsSampler(
          captureMetrics: () async => '',
          store: store,
          ringCapacity: 3,
          clock: () => base.add(const Duration(minutes: 10)),
        );

        await sampler.seedFromStore(<String>[
          'survival',
        ], window: const Duration(hours: 1));

        final List<MetricSample> history = sampler.history('survival');
        expect(history, hasLength(3));
        expect(history.map((MetricSample s) => s.players).toList(), <int>[
          2,
          3,
          4,
        ]);
      },
    );

    test('does not alter the instances list', () async {
      final TrendStore store = TrendStore(tempDir);
      await store.append(
        'survival',
        rawSample(ts: DateTime.utc(2026, 7, 30), players: 1),
      );
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
        store: store,
        clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
      );
      expect(sampler.instances, isEmpty);

      await sampler.seedFromStore(<String>[
        'survival',
      ], window: const Duration(hours: 6));

      expect(sampler.instances, isEmpty);
    });
  });

  group('compactStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('metrics_sampler_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    MetricSample rawSample({
      required DateTime ts,
      String instance = 'survival',
      int players = 0,
    }) => MetricSample(
      ts: ts,
      instance: instance,
      state: RuntimeState.running,
      players: players,
    );

    // Every byte written is over the threshold, so compaction is exercised
    // without having to write a real 4 MiB file.
    const TrendRetention alwaysCompact = TrendRetention(compactAfterBytes: 0);

    test('is a no-op when the sampler has no store', () async {
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
      );
      await expectLater(sampler.compactStore(<String>['survival']), completes);
    });

    test('drops samples older than the retention window from disk', () async {
      final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final TrendStore store = TrendStore(tempDir, retention: alwaysCompact);
      await store.append(
        'survival',
        rawSample(ts: now.subtract(const Duration(days: 30)), players: 1),
      );
      await store.append('survival', rawSample(ts: now, players: 2));

      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
        store: store,
        clock: () => now,
      );
      await sampler.compactStore(<String>['survival']);

      final List<MetricSample> after = await store.read('survival', now: now);
      expect(after, hasLength(1));
      expect(after.single.players, 2);
    });

    test('compacts every named instance, not just the first', () async {
      final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final DateTime ancient = now.subtract(const Duration(days: 30));
      final TrendStore store = TrendStore(tempDir, retention: alwaysCompact);
      for (final String instance in <String>['survival', 'creative']) {
        await store.append(
          instance,
          rawSample(ts: ancient, instance: instance, players: 1),
        );
        await store.append(
          instance,
          rawSample(ts: now, instance: instance, players: 2),
        );
      }

      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
        store: store,
        clock: () => now,
      );
      await sampler.compactStore(<String>['survival', 'creative']);

      for (final String instance in <String>['survival', 'creative']) {
        expect(await store.read(instance, now: now), hasLength(1));
      }
    });

    test('leaves a file under the size threshold untouched', () async {
      final DateTime now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final TrendStore store = TrendStore(tempDir);
      await store.append(
        'survival',
        rawSample(ts: now.subtract(const Duration(days: 30)), players: 1),
      );
      await store.append('survival', rawSample(ts: now, players: 2));

      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
        store: store,
        clock: () => now,
      );
      await sampler.compactStore(<String>['survival']);

      // The default 4 MiB threshold is nowhere near reached, so the ancient
      // sample is still on disk: compaction pays for itself only in bulk.
      expect(await store.read('survival', now: now), hasLength(2));
    });

    test('never throws when the store directory is unusable', () async {
      // A file where the trend directory should be: every write fails.
      final File blocker = File(p.join(tempDir.path, 'blocked'));
      await blocker.writeAsString('not a directory');
      final TrendStore store = TrendStore(
        Directory(p.join(blocker.path, 'trends')),
        retention: alwaysCompact,
      );
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async => '',
        store: store,
        clock: () => DateTime.utc(2026, 7, 30, 12, 0, 0),
      );

      await expectLater(sampler.compactStore(<String>['survival']), completes);
    });
  });
}
