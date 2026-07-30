import 'dart:convert';

import '../runtime_state.dart';

/// One sampled reading of one managed server instance, as consumed by the
/// monitoring dashboard.
///
/// Every metric field is nullable by design: missing data stays null (and
/// renders as "n/a" downstream) rather than being fabricated as zero.
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
  /// uptimeSeconds cpuPercent rssBytes logPath`, tab-separated, `-` marking
  /// a null cell.
  ///
  /// `locked` and `isolated` are read but not stored on [MetricSample] (the
  /// wizard reads lock/isolation state elsewhere). [ts] is stamped from
  /// [now]. Returns null when there are fewer than 9 columns, the name is
  /// empty, or the state column doesn't match a known [RuntimeState]. Rows
  /// with 9-12 columns (the pre-extension format) leave the trailing
  /// metrics-only columns null; columns beyond the 13th are ignored.
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

    return MetricSample(
      ts: now,
      instance: name,
      state: state,
      port: _tsvInt(cols[2]),
      players: _tsvInt(cols[4]),
      maxPlayers: _tsvInt(cols[5]),
      version: _tsvString(cols[6]),
      tps: _tsvDouble(cols[7]),
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
