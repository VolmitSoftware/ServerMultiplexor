import 'dart:convert';

import '../runtime_state.dart';
import 'monitor_frame_util.dart';

/// One sampled reading of one managed server instance, as consumed by the
/// monitoring dashboard.
///
/// Every metric field is nullable by design: missing data stays null (and
/// renders as "n/a" downstream) rather than being fabricated as zero.
///
/// One field is not what its name suggests: [cpuPercent] comes from BSD
/// `ps %cpu`, which reports CPU time over the whole life of the process
/// divided by its elapsed run time — a lifetime average, not an
/// instantaneous reading. A long-lived server that spiked an hour ago and is
/// idle now still reports the raised average, and a busy server that only
/// just started reports a low one. Read the CPU series as a trend, not as a
/// live load meter.
class MetricSample {
  const MetricSample({
    required this.ts,
    required this.instance,
    required this.state,
    this.port,
    this.players,
    this.maxPlayers,
    this.tps,
    this.latencyMs,
    this.cpuPercent,
    this.rssBytes,
    this.uptimeSeconds,
    this.version,
    this.logPath,
  });

  final DateTime ts;
  final String instance;
  final RuntimeState state;
  final int? port;
  final int? players;
  final int? maxPlayers;
  final double? tps;
  final int? latencyMs;
  final double? cpuPercent;
  final int? rssBytes;
  final int? uptimeSeconds;
  final String? version;
  final String? logPath;

  /// Serializes this sample to a single-line, compact JSON string. Epoch
  /// milliseconds for [ts]; null-valued fields are omitted from the map.
  String toJsonLine() {
    final Map<String, Object> json = <String, Object>{
      'ts': ts.millisecondsSinceEpoch,
      'instance': instance,
      'state': state.name,
    };
    final int? port = this.port;
    if (port != null) {
      json['port'] = port;
    }
    final int? players = this.players;
    if (players != null) {
      json['players'] = players;
    }
    final int? maxPlayers = this.maxPlayers;
    if (maxPlayers != null) {
      json['maxPlayers'] = maxPlayers;
    }
    final double? tps = this.tps;
    if (tps != null) {
      json['tps'] = tps;
    }
    final int? latencyMs = this.latencyMs;
    if (latencyMs != null) {
      json['latencyMs'] = latencyMs;
    }
    final double? cpuPercent = this.cpuPercent;
    if (cpuPercent != null) {
      json['cpuPercent'] = cpuPercent;
    }
    final int? rssBytes = this.rssBytes;
    if (rssBytes != null) {
      json['rssBytes'] = rssBytes;
    }
    final int? uptimeSeconds = this.uptimeSeconds;
    if (uptimeSeconds != null) {
      json['uptimeSeconds'] = uptimeSeconds;
    }
    final String? version = this.version;
    if (version != null) {
      json['version'] = version;
    }
    final String? logPath = this.logPath;
    if (logPath != null) {
      json['logPath'] = logPath;
    }
    return jsonEncode(json);
  }

  /// Parses a line previously produced by [toJsonLine]. Returns null on
  /// malformed JSON, non-object JSON, or a missing/invalid `ts`, `instance`,
  /// or `state`. Missing optional keys are tolerated; numeric fields accept
  /// either JSON ints or doubles and are coerced to the declared type.
  static MetricSample? fromJsonLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final Object? tsRaw = decoded['ts'];
    final Object? instanceRaw = decoded['instance'];
    final Object? stateRaw = decoded['state'];
    if (tsRaw is! num || instanceRaw is! String || stateRaw is! String) {
      return null;
    }
    final RuntimeState? state = _runtimeStateFromName(stateRaw);
    if (state == null) {
      return null;
    }

    return MetricSample(
      ts: DateTime.fromMillisecondsSinceEpoch(tsRaw.toInt(), isUtc: true),
      instance: instanceRaw,
      state: state,
      port: _jsonToInt(decoded['port']),
      players: _jsonToInt(decoded['players']),
      maxPlayers: _jsonToInt(decoded['maxPlayers']),
      tps: _jsonToDouble(decoded['tps']),
      latencyMs: _jsonToInt(decoded['latencyMs']),
      cpuPercent: _jsonToDouble(decoded['cpuPercent']),
      rssBytes: _jsonToInt(decoded['rssBytes']),
      uptimeSeconds: _jsonToInt(decoded['uptimeSeconds']),
      version: decoded['version'] is String
          ? decoded['version'] as String
          : null,
      logPath: decoded['logPath'] is String
          ? decoded['logPath'] as String
          : null,
    );
  }

  /// Parses one row of the extended `runtime metrics` TSV output:
  /// `name state port locked players max version tps isolated
  /// uptimeSeconds cpuPercent rssBytes logPath latencyMs`, tab-separated,
  /// `-` marking a null cell.
  ///
  /// `locked` and `isolated` are read but not stored on [MetricSample] (the
  /// wizard reads lock/isolation state elsewhere). [ts] is stamped from
  /// [now]. Returns null when there are fewer than 9 columns, the name is
  /// empty, or the state column doesn't match a known [RuntimeState].
  ///
  /// Shorter rows are read as far as they go, so an older writer's output
  /// still parses: 9-12 columns leave every metrics-only field null, and 13
  /// columns (the format before ping latency was carried) leave
  /// [latencyMs] null rather than fabricating a round trip. Columns beyond
  /// the 14th are ignored.
  static MetricSample? fromMetricsTsv(String line, DateTime now) {
    final List<String> cols = line.split('\t');
    if (cols.length < 9) {
      return null;
    }

    final String name = cols[0];
    if (name.isEmpty) {
      return null;
    }
    final RuntimeState? state = _runtimeStateFromName(cols[1]);
    if (state == null) {
      return null;
    }

    int? uptimeSeconds;
    double? cpuPercent;
    int? rssBytes;
    String? logPath;
    if (cols.length >= 13) {
      uptimeSeconds = _tsvInt(cols[9]);
      cpuPercent = _tsvDouble(cols[10]);
      rssBytes = _tsvInt(cols[11]);
      logPath = _tsvString(cols[12]);
    }
    final int? latencyMs = cols.length >= 14 ? _tsvInt(cols[13]) : null;

    return MetricSample(
      ts: now,
      instance: name,
      state: state,
      port: _tsvInt(cols[2]),
      players: _tsvInt(cols[4]),
      maxPlayers: _tsvInt(cols[5]),
      version: _tsvString(cols[6]),
      tps: _tsvDouble(cols[7]),
      latencyMs: latencyMs,
      uptimeSeconds: uptimeSeconds,
      cpuPercent: cpuPercent,
      rssBytes: rssBytes,
      logPath: logPath,
    );
  }

  /// Returns a copy with the given fields replaced. Only the fields that
  /// change across a live poll are settable; everything else carries over
  /// unchanged.
  MetricSample copyWith({
    DateTime? ts,
    double? tps,
    double? cpuPercent,
    int? rssBytes,
    int? players,
  }) {
    return MetricSample(
      ts: ts ?? this.ts,
      instance: instance,
      state: state,
      port: port,
      players: players ?? this.players,
      maxPlayers: maxPlayers,
      tps: tps ?? this.tps,
      latencyMs: latencyMs,
      cpuPercent: cpuPercent ?? this.cpuPercent,
      rssBytes: rssBytes ?? this.rssBytes,
      uptimeSeconds: uptimeSeconds,
      version: version,
      logPath: logPath,
    );
  }
}

/// One `ps` reading for a single process: resident set size and CPU percent.
///
/// [cpuPercent] is BSD `%cpu` — a lifetime average over the process's whole
/// run, not an instantaneous sample. See [MetricSample].
class PsStat {
  const PsStat({required this.rssBytes, required this.cpuPercent});

  final int rssBytes;
  final double cpuPercent;
}

/// Parses the output of `ps -o pid=,rss=,%cpu= -p <pid> ...` (see
/// [psArgsForPids]): one process per line, whitespace-separated `pid
/// rss-in-KiB %cpu`. `rss` is converted from KiB to bytes. Lines with the
/// wrong field count or non-numeric fields are skipped. When a pid repeats,
/// the last matching line wins. Empty or whitespace-only input yields an
/// empty map.
Map<int, PsStat> parsePsOutput(String stdout) {
  final Map<int, PsStat> result = <int, PsStat>{};
  for (final String rawLine in stdout.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final List<String> parts = line.split(RegExp(r'\s+'));
    if (parts.length != 3) {
      continue;
    }
    final int? pid = int.tryParse(parts[0]);
    final int? rssKib = int.tryParse(parts[1]);
    final double? cpuPercent = double.tryParse(parts[2]);
    if (pid == null || rssKib == null || cpuPercent == null) {
      continue;
    }
    result[pid] = PsStat(rssBytes: rssKib * 1024, cpuPercent: cpuPercent);
  }
  return result;
}

/// Builds the `ps` argument list for sampling the given [pids]:
/// `-o pid=,rss=,%cpu= -p <pid1> -p <pid2> ...`. Empty [pids] yields an
/// empty argument list (nothing to sample).
List<String> psArgsForPids(List<int> pids) {
  if (pids.isEmpty) {
    return <String>[];
  }
  final List<String> args = <String>['-o', 'pid=,rss=,%cpu='];
  for (final int pid in pids) {
    args
      ..add('-p')
      ..add('$pid');
  }
  return args;
}

/// Renders one row of the extended `runtime metrics` TSV — the exact
/// inverse of [MetricSample.fromMetricsTsv]. Columns, in order:
/// `name state port locked players max version tps isolated uptimeSeconds
/// cpuPercent rssBytes logPath latencyMs`.
///
/// Every unavailable value renders as `-`, never as a zero. [tps] and
/// [cpuPercent] render with one decimal place. [version] and [logPath] are
/// treated as unavailable when blank, and any tab or newline they contain is
/// replaced with a space so a single row can never span or split columns.
///
/// New columns are only ever appended: a reader written against a shorter
/// row must keep parsing this one (see [MetricSample.fromMetricsTsv]).
String metricsTsvRow({
  required String name,
  required RuntimeState state,
  required bool locked,
  required bool isolated,
  int? port,
  int? players,
  int? maxPlayers,
  String? version,
  double? tps,
  int? uptimeSeconds,
  double? cpuPercent,
  int? rssBytes,
  String? logPath,
  int? latencyMs,
}) {
  return <String>[
    _tsvSanitize(name),
    state.name,
    _tsvNumberCell(port),
    locked ? 'locked' : 'unlocked',
    _tsvNumberCell(players),
    _tsvNumberCell(maxPlayers),
    _tsvTextCell(version),
    _tsvDecimalCell(tps),
    isolated ? 'isolated' : 'shared',
    _tsvNumberCell(uptimeSeconds),
    _tsvDecimalCell(cpuPercent),
    _tsvNumberCell(rssBytes),
    _tsvTextCell(logPath),
    _tsvNumberCell(latencyMs),
  ].join('\t');
}

/// The lock and isolation flags carried by one row of the `runtime metrics`
/// TSV — the two columns [MetricSample.fromMetricsTsv] deliberately drops
/// (column 4, `locked`/`unlocked`, and column 9, `isolated`/`shared`).
///
/// Returns null for anything that is not a well-formed row: fewer than the 9
/// columns that carry both flags, or a token in either column that is not one
/// of the two words that column can hold. A row is either trusted for both
/// flags or not trusted at all — guessing would silently offer LOCK on a
/// locked instance.
///
/// The instance name is not returned: see [metricsTsvFlagsByInstance] for the
/// keyed form.
InstanceFlags? metricsTsvFlags(String line) {
  final List<String> cols = line.split('\t');
  if (cols.length < 9) {
    return null;
  }
  final bool? locked = switch (cols[3]) {
    'locked' => true,
    'unlocked' => false,
    _ => null,
  };
  final bool? isolated = switch (cols[8]) {
    'isolated' => true,
    'shared' => false,
    _ => null,
  };
  if (locked == null || isolated == null) {
    return null;
  }
  return InstanceFlags(locked: locked, isolated: isolated);
}

/// Every instance's flags from a whole `runtime metrics` capture, keyed by
/// instance name and in row order.
///
/// Rows [metricsTsvFlags] rejects are skipped, as are rows with an empty name
/// — the same discipline [MetricSample.fromMetricsTsv] applies, so a capture
/// parses to the same set of instances either way. A repeated name keeps the
/// last row.
Map<String, InstanceFlags> metricsTsvFlagsByInstance(String capture) {
  final Map<String, InstanceFlags> result = <String, InstanceFlags>{};
  for (final String line in capture.split('\n')) {
    final InstanceFlags? flags = metricsTsvFlags(line);
    if (flags == null) {
      continue;
    }
    final String name = line.split('\t').first;
    if (name.isEmpty) {
      continue;
    }
    result[name] = flags;
  }
  return result;
}

RuntimeState? _runtimeStateFromName(String name) {
  for (final RuntimeState state in RuntimeState.values) {
    if (state.name == name) {
      return state;
    }
  }
  return null;
}

int? _jsonToInt(Object? value) => value is num ? value.toInt() : null;

double? _jsonToDouble(Object? value) => value is num ? value.toDouble() : null;

int? _tsvInt(String cell) => cell == '-' ? null : int.tryParse(cell);

double? _tsvDouble(String cell) => cell == '-' ? null : double.tryParse(cell);

String? _tsvString(String cell) => cell == '-' ? null : cell;

/// Replaces every tab, carriage return, and newline in [text] with a single
/// space so a value can neither split a column nor break a row.
String _tsvSanitize(String text) => text.replaceAll(RegExp(r'[\t\r\n]'), ' ');

String _tsvNumberCell(num? value) => value == null ? '-' : '$value';

String _tsvDecimalCell(double? value) =>
    value == null ? '-' : value.toStringAsFixed(1);

String _tsvTextCell(String? value) =>
    value == null || value.isEmpty ? '-' : _tsvSanitize(value);
