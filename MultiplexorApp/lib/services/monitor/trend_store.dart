/// Session-spanning persistence for [MetricSample] history.
///
/// Samples are appended as one JSON line per instance under a directory
/// (`<instance>.jsonl`), so dashboard charts survive a wizard restart.
/// Storage is tiered to bound growth: everything newer than
/// [TrendRetention.rawWindow] is kept at full resolution, the next
/// [TrendRetention.totalWindow] is rolled up into
/// [TrendRetention.rollupBucket]-sized mean samples, and anything older than
/// [TrendRetention.totalWindow] is dropped. Rollup and compaction planning
/// are pure functions ([rollupSamples], [planCompaction]); [TrendStore] is a
/// thin IO wrapper around them.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'metric_sample.dart';

/// How long trend data is kept, and at what point it degrades from raw
/// samples to rolled-up means, then is dropped entirely.
class TrendRetention {
  const TrendRetention({
    this.rawWindow = const Duration(hours: 24),
    this.rollupBucket = const Duration(minutes: 5),
    this.totalWindow = const Duration(days: 7),
    this.compactAfterBytes = 4 * 1024 * 1024,
  });

  /// Samples newer than this are kept at full resolution.
  final Duration rawWindow;

  /// Bucket width used to roll up samples older than [rawWindow].
  final Duration rollupBucket;

  /// Samples older than this are dropped entirely.
  final Duration totalWindow;

  /// A store's `.jsonl` file is only rewritten once it exceeds this size.
  final int compactAfterBytes;
}

/// Groups [samples] into fixed-width, epoch-aligned buckets of [bucket] and
/// collapses each bucket into a single mean sample.
///
/// [samples] need not be sorted. Within a bucket: `ts` is the bucket start
/// (UTC), `instance` is the first sample's instance (by `ts` order), `state`
/// is the last sample's state, `players`/`maxPlayers`/`tps`/`latencyMs`/
/// `cpuPercent`/`rssBytes`/`uptimeSeconds` are the mean of the non-null
/// values in the bucket (null when every value in the bucket is null,
/// integer fields rounded to the nearest int), and `port`/`version`/
/// `logPath` are the last non-null value. The result is sorted by `ts`
/// ascending.
List<MetricSample> rollupSamples(List<MetricSample> samples, Duration bucket) {
  if (samples.isEmpty) {
    return <MetricSample>[];
  }
  final int bucketMs = bucket.inMilliseconds;

  // Sort by ts, breaking ties by original position, so "first"/"last"
  // within a bucket are well-defined even for samples sharing one ts.
  final List<int> order = List<int>.generate(samples.length, (int i) => i)
    ..sort((int a, int b) {
      final int cmp = samples[a].ts.millisecondsSinceEpoch.compareTo(
        samples[b].ts.millisecondsSinceEpoch,
      );
      return cmp != 0 ? cmp : a.compareTo(b);
    });

  final Map<int, List<MetricSample>> buckets = <int, List<MetricSample>>{};
  for (final int i in order) {
    final MetricSample sample = samples[i];
    final int bucketIndex = sample.ts.millisecondsSinceEpoch ~/ bucketMs;
    buckets.putIfAbsent(bucketIndex, () => <MetricSample>[]).add(sample);
  }

  final List<int> bucketIndices = buckets.keys.toList()..sort();
  return <MetricSample>[
    for (final int bucketIndex in bucketIndices)
      _rollupBucket(bucketIndex, bucketMs, buckets[bucketIndex]!),
  ];
}

/// Collapses one bucket's worth of time-ordered samples into a single mean
/// sample. [bucketSamples] must already be sorted ascending by `ts`.
MetricSample _rollupBucket(
  int bucketIndex,
  int bucketMs,
  List<MetricSample> bucketSamples,
) {
  return MetricSample(
    ts: DateTime.fromMillisecondsSinceEpoch(
      bucketIndex * bucketMs,
      isUtc: true,
    ),
    instance: bucketSamples.first.instance,
    state: bucketSamples.last.state,
    port: _lastNonNull(bucketSamples.map((MetricSample s) => s.port)),
    players: _meanInt(bucketSamples.map((MetricSample s) => s.players)),
    maxPlayers: _meanInt(bucketSamples.map((MetricSample s) => s.maxPlayers)),
    tps: _meanDouble(bucketSamples.map((MetricSample s) => s.tps)),
    latencyMs: _meanInt(bucketSamples.map((MetricSample s) => s.latencyMs)),
    cpuPercent: _meanDouble(
      bucketSamples.map((MetricSample s) => s.cpuPercent),
    ),
    rssBytes: _meanInt(bucketSamples.map((MetricSample s) => s.rssBytes)),
    uptimeSeconds: _meanInt(
      bucketSamples.map((MetricSample s) => s.uptimeSeconds),
    ),
    version: _lastNonNull(bucketSamples.map((MetricSample s) => s.version)),
    logPath: _lastNonNull(bucketSamples.map((MetricSample s) => s.logPath)),
  );
}

/// Mean of the non-null values in [values], rounded to the nearest int.
/// Null when every value is null — never fabricated as zero.
int? _meanInt(Iterable<int?> values) =>
    _meanDouble(values.map((int? v) => v?.toDouble()))?.round();

/// Mean of the non-null values in [values]. Null when every value is null.
double? _meanDouble(Iterable<double?> values) {
  double sum = 0;
  int count = 0;
  for (final double? value in values) {
    if (value == null) {
      continue;
    }
    sum += value;
    count++;
  }
  return count == 0 ? null : sum / count;
}

/// The last non-null value in [values], in iteration order. Null when every
/// value is null.
T? _lastNonNull<T>(Iterable<T?> values) {
  T? result;
  for (final T? value in values) {
    if (value != null) {
      result = value;
    }
  }
  return result;
}

/// Decides which of [samples] survive compaction at [now], per
/// [retention]: samples older than `now - retention.totalWindow` are
/// dropped; samples newer than `now - retention.rawWindow` are kept
/// unchanged; everything in between is rolled up via [rollupSamples] using
/// `retention.rollupBucket`. A sample exactly at a window edge is treated as
/// still inside that window (raw at the raw-window edge, kept at the
/// total-window edge). The result is sorted by `ts` ascending; already
/// rolled-up samples in the middle band simply participate in rollup again,
/// which is idempotent for buckets that are already aligned.
List<MetricSample> planCompaction(
  List<MetricSample> samples,
  DateTime now,
  TrendRetention retention,
) {
  final int nowMs = now.millisecondsSinceEpoch;
  final int rawCutoffMs = nowMs - retention.rawWindow.inMilliseconds;
  final int totalCutoffMs = nowMs - retention.totalWindow.inMilliseconds;

  final List<MetricSample> raw = <MetricSample>[];
  final List<MetricSample> toRollup = <MetricSample>[];
  for (final MetricSample sample in samples) {
    final int tsMs = sample.ts.millisecondsSinceEpoch;
    if (tsMs < totalCutoffMs) {
      continue; // strictly older than the total window: dropped.
    }
    if (tsMs >= rawCutoffMs) {
      raw.add(sample); // at or newer than the raw window edge: stays raw.
    } else {
      toRollup.add(sample);
    }
  }

  final List<MetricSample> result = <MetricSample>[
    ...rollupSamples(toRollup, retention.rollupBucket),
    ...raw,
  ];
  result.sort(
    (MetricSample a, MetricSample b) =>
        a.ts.millisecondsSinceEpoch.compareTo(b.ts.millisecondsSinceEpoch),
  );
  return result;
}

/// JSONL-backed history for one or more instances' [MetricSample]s, with
/// tiered retention applied at compaction time.
///
/// IO failures never crash the caller: the first write failure (directory
/// creation, append, or compaction) prints one `[WARN]` line to stderr and
/// sets [writeFailed], after which every future write silently no-ops for
/// the lifetime of this store.
class TrendStore {
  TrendStore(this.directory, {this.retention = const TrendRetention()});

  final Directory directory;
  final TrendRetention retention;

  bool _writeFailed = false;
  bool _directoryReady = false;

  /// True once a write has failed; all further writes on this store no-op.
  bool get writeFailed => _writeFailed;

  /// The `.jsonl` file for [instance]: any character outside
  /// `[a-zA-Z0-9._-]` becomes `-`, so instance names can never escape
  /// [directory] or collide with path separators.
  File fileFor(String instance) {
    final String sanitized = instance.replaceAll(
      RegExp(r'[^a-zA-Z0-9._-]'),
      '-',
    );
    return File(p.join(directory.path, '$sanitized.jsonl'));
  }

  /// All samples recorded for [instance], sorted by `ts` ascending.
  ///
  /// A missing file yields an empty list. Malformed lines are skipped. When
  /// [window] is given, only samples with `ts >= now - window` are
  /// returned.
  Future<List<MetricSample>> read(
    String instance, {
    required DateTime now,
    Duration? window,
  }) async {
    final File file = fileFor(instance);
    if (!await file.exists()) {
      return <MetricSample>[];
    }
    final String content = await file.readAsString();
    final List<MetricSample> samples = <MetricSample>[];
    for (final String line in content.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      final MetricSample? sample = MetricSample.fromJsonLine(line);
      if (sample != null) {
        samples.add(sample);
      }
    }

    List<MetricSample> filtered = samples;
    if (window != null) {
      final int cutoffMs = now.millisecondsSinceEpoch - window.inMilliseconds;
      filtered = samples
          .where((MetricSample s) => s.ts.millisecondsSinceEpoch >= cutoffMs)
          .toList();
    }
    filtered.sort(
      (MetricSample a, MetricSample b) =>
          a.ts.millisecondsSinceEpoch.compareTo(b.ts.millisecondsSinceEpoch),
    );
    return filtered;
  }

  /// Appends [sample] as one JSON line to [instance]'s file, creating
  /// [directory] on first write. No-ops silently once [writeFailed].
  Future<void> append(String instance, MetricSample sample) async {
    if (_writeFailed) {
      return;
    }
    try {
      if (!_directoryReady) {
        await directory.create(recursive: true);
        _directoryReady = true;
      }
      await fileFor(instance).writeAsString(
        '${sample.toJsonLine()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on IOException catch (error) {
      _disableWrites(error);
    }
  }

  /// Rewrites [instance]'s file to only its [planCompaction] survivors, but
  /// only once the file exceeds [TrendRetention.compactAfterBytes]. Writes
  /// to a `.tmp` sibling and atomically renames it over the original so a
  /// concurrent reader never sees a partially-written file. No-ops silently
  /// once [writeFailed].
  Future<void> compactIfNeeded(String instance, DateTime now) async {
    if (_writeFailed) {
      return;
    }
    final File file = fileFor(instance);
    try {
      if (!await file.exists()) {
        return;
      }
      if (await file.length() <= retention.compactAfterBytes) {
        return;
      }
      final List<MetricSample> samples = await read(instance, now: now);
      final List<MetricSample> survivors = planCompaction(
        samples,
        now,
        retention,
      );
      final StringBuffer buffer = StringBuffer();
      for (final MetricSample sample in survivors) {
        buffer.writeln(sample.toJsonLine());
      }
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(buffer.toString(), flush: true);
      await tmp.rename(file.path);
    } on IOException catch (error) {
      _disableWrites(error);
    }
  }

  void _disableWrites(Object error) {
    _writeFailed = true;
    stderr.writeln('[WARN] trend store disabled: $error');
  }
}
