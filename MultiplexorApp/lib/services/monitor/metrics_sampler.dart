/// In-memory ring buffers of [MetricSample] history, fed by the injected
/// `captureMetrics` callback (in production, `runtime metrics`) and
/// optionally mirrored to a [TrendStore] for cross-session persistence.
///
/// The dashboard's event loop calls [sweep] on a timer (no [Timer] lives
/// inside this class — scheduling is the caller's job); charts read
/// [history] and [latest]. [seedFromStore] backfills a ring with older,
/// persisted samples once at startup.
library;

import 'metric_sample.dart';
import 'trend_store.dart';

/// Samples every managed instance on each [sweep] and keeps a bounded,
/// oldest-first ring of [MetricSample]s per instance in memory.
class MetricsSampler {
  MetricsSampler({
    required Future<String> Function() captureMetrics,
    TrendStore? store,
    this.ringCapacity = 900,
    DateTime Function()? clock,
  }) : _captureMetrics = captureMetrics,
       _store = store,
       _clock = clock ?? (() => DateTime.now().toUtc());

  /// Maximum number of samples retained per instance's ring. Oldest samples
  /// are evicted first once a ring exceeds this size.
  final int ringCapacity;

  final Future<String> Function() _captureMetrics;
  final TrendStore? _store;
  final DateTime Function() _clock;

  final Map<String, List<MetricSample>> _rings = <String, List<MetricSample>>{};
  final Map<String, MetricSample> _networkBaselines = <String, MetricSample>{};
  List<String> _instances = <String>[];
  bool _sweeping = false;

  /// True while a [sweep] is in flight. [sweep] uses this as an overlap
  /// guard so a slow `captureMetrics` call never runs concurrently with
  /// itself.
  bool get sweeping => _sweeping;

  /// Instance names present in the most recent sweep, in that sweep's row
  /// order. An instance absent from the latest sweep drops out of this list
  /// even though its ring (see [history]) is retained.
  List<String> get instances => List<String>.unmodifiable(_instances);

  /// Captures one round of metrics, parses each row, and pushes the result
  /// into each instance's ring (and, if a [TrendStore] was supplied, appends
  /// each row to it).
  ///
  /// Guarded against overlap: if a sweep is already in flight, this returns
  /// immediately without calling `captureMetrics` again. If `captureMetrics`
  /// throws, the error is swallowed, no state changes, and [sweeping] is
  /// still cleared — a broken capture must never take down the dashboard's
  /// event loop.
  Future<void> sweep() async {
    if (_sweeping) {
      return;
    }
    _sweeping = true;
    try {
      final String raw = await _captureMetrics();
      final DateTime now = _clock();

      final List<MetricSample> parsed = <MetricSample>[];
      for (final String line in raw.split('\n')) {
        if (line.isEmpty) {
          continue;
        }
        final MetricSample? captured = MetricSample.fromMetricsTsv(line, now);
        if (captured != null) {
          final MetricSample sample = captured.withNetworkRatesFrom(
            _networkBaselines[captured.instance],
          );
          parsed.add(sample);
          _networkBaselines[captured.instance] = captured;
        }
      }

      for (final MetricSample sample in parsed) {
        final List<MetricSample> ring = _rings.putIfAbsent(
          sample.instance,
          () => <MetricSample>[],
        );
        ring.add(sample);
        while (ring.length > ringCapacity) {
          ring.removeAt(0);
        }
      }

      final TrendStore? store = _store;
      if (store != null) {
        for (final MetricSample sample in parsed) {
          await store.append(sample.instance, sample);
        }
      }

      _instances = <String>[
        for (final MetricSample sample in parsed) sample.instance,
      ];
    } catch (_) {
      // captureMetrics (or a downstream step) failed: swallow it so the
      // dashboard's event loop keeps running. State is left as it was
      // before this sweep started.
    } finally {
      _sweeping = false;
    }
  }

  /// Backfills each named instance's ring with its persisted history from
  /// the [TrendStore], for the given lookback [window]. A no-op when this
  /// sampler has no store.
  ///
  /// Persisted samples are treated as older than whatever is already in the
  /// ring and are prepended ahead of it; a persisted sample sharing an exact
  /// epoch-millis `ts` with a live sample is dropped in favor of the live
  /// one. The merged ring is then trimmed to [ringCapacity], keeping the
  /// newest samples. This never touches [instances] — that list reflects
  /// only [sweep]'s row order.
  Future<void> seedFromStore(
    List<String> instances, {
    required Duration window,
  }) async {
    final TrendStore? store = _store;
    if (store == null) {
      return;
    }
    final DateTime now = _clock();
    for (final String instance in instances) {
      final List<MetricSample> persisted = await store.read(
        instance,
        now: now,
        window: window,
      );
      final List<MetricSample> live = _rings[instance] ?? <MetricSample>[];
      final Set<int> liveTsMs = <int>{
        for (final MetricSample sample in live)
          sample.ts.millisecondsSinceEpoch,
      };

      final List<MetricSample> merged = <MetricSample>[
        for (final MetricSample sample in persisted)
          if (!liveTsMs.contains(sample.ts.millisecondsSinceEpoch)) sample,
        ...live,
      ];

      _rings[instance] = merged.length > ringCapacity
          ? merged.sublist(merged.length - ringCapacity)
          : merged;
    }
  }

  /// Applies the [TrendStore]'s retention policy to each named instance's
  /// file. A no-op when this sampler has no store.
  ///
  /// Nothing else calls [TrendStore.compactIfNeeded], so without this a
  /// trend file only ever grows: at the dashboard's two-second cadence one
  /// instance writes on the order of ten megabytes a day, all of which the
  /// next session's [seedFromStore] would read back. Call it once per
  /// session, off the frame path — the store itself skips any file still
  /// under [TrendRetention.compactAfterBytes], so the usual cost is one
  /// `stat` per instance.
  ///
  /// Never throws. The store already degrades on [IOException] by disabling
  /// writes, and anything it does not catch is swallowed here for the same
  /// reason [sweep] swallows a failed capture: history is a convenience, and
  /// losing it must not take down the session that was about to be drawn.
  Future<void> compactStore(List<String> instances) async {
    final TrendStore? store = _store;
    if (store == null) {
      return;
    }
    final DateTime now = _clock();
    for (final String instance in instances) {
      try {
        await store.compactIfNeeded(instance, now);
      } catch (_) {
        // Trend compaction is best-effort; see the doc comment above.
      }
    }
  }

  /// This instance's samples, oldest-first. Empty for an instance that has
  /// never been swept or seeded.
  List<MetricSample> history(String instance) {
    final List<MetricSample>? ring = _rings[instance];
    if (ring == null) {
      return <MetricSample>[];
    }
    return List<MetricSample>.unmodifiable(ring);
  }

  /// The most recent sample for this instance, or null if it has none.
  MetricSample? latest(String instance) {
    final List<MetricSample>? ring = _rings[instance];
    if (ring == null || ring.isEmpty) {
      return null;
    }
    return ring.last;
  }
}
