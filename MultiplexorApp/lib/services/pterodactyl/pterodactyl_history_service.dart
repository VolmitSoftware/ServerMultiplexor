import 'dart:io';

import 'package:path/path.dart' as p;

import '../monitor/metric_sample.dart';
import '../monitor/trend_store.dart';
import 'pterodactyl_profile.dart';

/// Read-only access to the metric history recorded by the Remote monitor.
///
/// History remains optional telemetry: missing directories and files produce
/// empty results, and this service never polls a panel or mutates the trend
/// store. The monitor remains the only writer.
final class PterodactylHistoryService {
  PterodactylHistoryService(this.globalStateDirectoryPath);

  final String globalStateDirectoryPath;

  Future<List<MetricSample>> read(
    String profileId,
    String serverIdentifier, {
    Duration? window,
    DateTime? now,
  }) {
    final TrendStore store = _store(profileId);
    return store.read(
      serverIdentifier,
      now: now ?? DateTime.now().toUtc(),
      window: window,
    );
  }

  /// Server identifiers with persisted history, sorted alphabetically.
  Future<List<String>> recordedServers(String profileId) async {
    final Directory directory = _directory(profileId);
    if (!await directory.exists()) {
      return const <String>[];
    }
    final List<String> result = <String>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File || p.extension(entity.path) != '.jsonl') {
        continue;
      }
      result.add(p.basenameWithoutExtension(entity.path));
    }
    result.sort();
    return List<String>.unmodifiable(result);
  }

  TrendStore _store(String profileId) => TrendStore(_directory(profileId));

  Directory _directory(String profileId) {
    final String normalized = PterodactylProfile.normalizeId(profileId);
    return Directory(
      p.join(globalStateDirectoryPath, 'pterodactyl', normalized, 'trends'),
    );
  }
}

/// Parses compact history windows such as `15m`, `6h`, or `7d`.
Duration parsePterodactylHistoryWindow(String value) {
  final RegExpMatch? match = RegExp(
    r'^([1-9][0-9]*)(s|m|h|d|w)$',
  ).firstMatch(value.trim().toLowerCase());
  if (match == null) {
    throw const FormatException(
      'History window must look like 15m, 6h, 24h, or 7d.',
    );
  }
  final int amount = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    'd' => Duration(days: amount),
    'w' => Duration(days: amount * 7),
    _ => throw const FormatException('Unsupported history window unit.'),
  };
}
