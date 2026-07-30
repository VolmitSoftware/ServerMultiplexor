import 'dart:convert';

import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

void main() {
  final DateTime ts = DateTime.utc(2026, 7, 30, 12, 0, 0);

  MetricSample fullSample() => MetricSample(
    ts: ts,
    instance: 'survival',
    state: RuntimeState.running,
    port: 25565,
    players: 4,
    maxPlayers: 20,
    tps: 19.8,
    latencyMs: 42,
    cpuPercent: 3.5,
    rssBytes: 536870912,
    uptimeSeconds: 3600,
    version: '1.21.1',
    logPath: '/logs/survival/latest.log',
  );

  group('MetricSample.toJsonLine', () {
    test('emits every field when all are populated', () {
      final String line = fullSample().toJsonLine();
      final Map<String, dynamic> decoded =
          jsonDecode(line) as Map<String, dynamic>;
      expect(decoded, {
        'ts': ts.millisecondsSinceEpoch,
        'instance': 'survival',
        'state': 'running',
        'port': 25565,
        'players': 4,
        'maxPlayers': 20,
        'tps': 19.8,
        'latencyMs': 42,
        'cpuPercent': 3.5,
        'rssBytes': 536870912,
        'uptimeSeconds': 3600,
        'version': '1.21.1',
        'logPath': '/logs/survival/latest.log',
      });
    });

    test('omits null-valued keys, keeping only ts/instance/state', () {
      final MetricSample sample = MetricSample(
        ts: ts,
        instance: 'lobby',
        state: RuntimeState.stopped,
      );
      final String line = sample.toJsonLine();
      final Map<String, dynamic> decoded =
          jsonDecode(line) as Map<String, dynamic>;
      expect(decoded, {
        'ts': ts.millisecondsSinceEpoch,
        'instance': 'lobby',
        'state': 'stopped',
      });
    });

    test('produces a single line with no embedded newlines', () {
      final String line = fullSample().toJsonLine();
      expect(line.contains('\n'), isFalse);
    });
  });

  group('MetricSample.fromJsonLine', () {
    test('round-trips a fully populated sample', () {
      final String line = fullSample().toJsonLine();
      final MetricSample? parsed = MetricSample.fromJsonLine(line);
      expect(parsed, isNotNull);
      expect(parsed!.ts, ts);
      expect(parsed.instance, 'survival');
      expect(parsed.state, RuntimeState.running);
      expect(parsed.port, 25565);
      expect(parsed.players, 4);
      expect(parsed.maxPlayers, 20);
      expect(parsed.tps, 19.8);
      expect(parsed.latencyMs, 42);
      expect(parsed.cpuPercent, 3.5);
      expect(parsed.rssBytes, 536870912);
      expect(parsed.uptimeSeconds, 3600);
      expect(parsed.version, '1.21.1');
      expect(parsed.logPath, '/logs/survival/latest.log');
    });

    test('round-trips a sample with all optional fields null', () {
      final MetricSample sample = MetricSample(
        ts: ts,
        instance: 'lobby',
        state: RuntimeState.stopped,
      );
      final MetricSample? parsed = MetricSample.fromJsonLine(
        sample.toJsonLine(),
      );
      expect(parsed, isNotNull);
      expect(parsed!.ts, ts);
      expect(parsed.instance, 'lobby');
      expect(parsed.state, RuntimeState.stopped);
      expect(parsed.port, isNull);
      expect(parsed.players, isNull);
      expect(parsed.maxPlayers, isNull);
      expect(parsed.tps, isNull);
      expect(parsed.latencyMs, isNull);
      expect(parsed.cpuPercent, isNull);
      expect(parsed.rssBytes, isNull);
      expect(parsed.uptimeSeconds, isNull);
      expect(parsed.version, isNull);
      expect(parsed.logPath, isNull);
    });

    test('returns null for garbage that is not valid JSON', () {
      expect(MetricSample.fromJsonLine('not json at all {'), isNull);
    });

    test('returns null for JSON that is not an object', () {
      expect(MetricSample.fromJsonLine('[1, 2, 3]'), isNull);
      expect(MetricSample.fromJsonLine('"just a string"'), isNull);
    });

    test('returns null when ts/instance/state are missing', () {
      expect(MetricSample.fromJsonLine('{}'), isNull);
    });

    test('returns null when ts is not a number', () {
      const String line =
          '{"ts":"not-a-number","instance":"survival","state":"running"}';
      expect(MetricSample.fromJsonLine(line), isNull);
    });

    test('returns null when state is not a known RuntimeState name', () {
      const String line =
          '{"ts":1690000000000,"instance":"survival","state":"bogus"}';
      expect(MetricSample.fromJsonLine(line), isNull);
    });

    test('tolerates missing optional keys', () {
      const String line =
          '{"ts":1690000000000,"instance":"survival","state":"running"}';
      final MetricSample? parsed = MetricSample.fromJsonLine(line);
      expect(parsed, isNotNull);
      expect(parsed!.port, isNull);
      expect(parsed.tps, isNull);
    });

    test('coerces int-valued JSON numbers into double fields', () {
      const String line =
          '{"ts":1690000000000,"instance":"survival","state":"running",'
          '"tps":20,"cpuPercent":5}';
      final MetricSample? parsed = MetricSample.fromJsonLine(line);
      expect(parsed, isNotNull);
      expect(parsed!.tps, 20.0);
      expect(parsed.cpuPercent, 5.0);
    });

    test('coerces double-valued JSON numbers into int fields', () {
      const String line =
          '{"ts":1690000000000,"instance":"survival","state":"running",'
          '"port":25565.0,"rssBytes":1048576.0}';
      final MetricSample? parsed = MetricSample.fromJsonLine(line);
      expect(parsed, isNotNull);
      expect(parsed!.port, 25565);
      expect(parsed.rssBytes, 1048576);
    });
  });

  group('MetricSample.fromMetricsTsv', () {
    test('parses a full 13-column row', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.ts, ts);
      expect(sample.instance, 'survival');
      expect(sample.state, RuntimeState.running);
      expect(sample.port, 25565);
      expect(sample.players, 4);
      expect(sample.maxPlayers, 20);
      expect(sample.version, '1.21.1');
      expect(sample.tps, 19.8);
      expect(sample.uptimeSeconds, 3600);
      expect(sample.cpuPercent, 3.5);
      expect(sample.rssBytes, 536870912);
      expect(sample.logPath, '/logs/survival/latest.log');
      expect(sample.latencyMs, isNull);
    });

    test('extra columns beyond 13 are ignored', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log\tEXTRA\tSTUFF';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.logPath, '/logs/survival/latest.log');
    });

    test('a stopped instance row with dash fields parses to nulls', () {
      const String line =
          'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared\t-\t-\t-\t-';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.instance, 'lobby');
      expect(sample.state, RuntimeState.stopped);
      expect(sample.port, isNull);
      expect(sample.players, isNull);
      expect(sample.maxPlayers, isNull);
      expect(sample.version, isNull);
      expect(sample.tps, isNull);
      expect(sample.uptimeSeconds, isNull);
      expect(sample.cpuPercent, isNull);
      expect(sample.rssBytes, isNull);
      expect(sample.logPath, isNull);
      expect(sample.latencyMs, isNull);
      expect(sample.ts, ts);
    });

    test('a legacy 9-column row leaves extras null', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.instance, 'survival');
      expect(sample.state, RuntimeState.running);
      expect(sample.port, 25565);
      expect(sample.players, 4);
      expect(sample.maxPlayers, 20);
      expect(sample.version, '1.21.1');
      expect(sample.tps, 19.8);
      expect(sample.uptimeSeconds, isNull);
      expect(sample.cpuPercent, isNull);
      expect(sample.rssBytes, isNull);
      expect(sample.logPath, isNull);
    });

    test('fewer than 9 columns returns null', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8';
      expect(MetricSample.fromMetricsTsv(line, ts), isNull);
    });

    test('an empty instance name returns null', () {
      const String line =
          '\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated';
      expect(MetricSample.fromMetricsTsv(line, ts), isNull);
    });

    test('an unknown state name returns null', () {
      const String line =
          'survival\tbogus\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated';
      expect(MetricSample.fromMetricsTsv(line, ts), isNull);
    });
  });

  group('parsePsOutput', () {
    test(
      'parses pid, rss (KiB->bytes), and cpu percent from happy-path lines',
      () {
        final Map<int, PsStat> result = parsePsOutput(
          '  123 204800  4.2\n 456 102400 0.0\n',
        );
        expect(result.length, 2);
        expect(result[123]!.rssBytes, 209715200);
        expect(result[123]!.cpuPercent, 4.2);
        expect(result[456]!.rssBytes, 104857600);
        expect(result[456]!.cpuPercent, 0.0);
      },
    );

    test('skips malformed lines with non-numeric fields', () {
      final Map<int, PsStat> result = parsePsOutput(
        ' 123 204800 4.2\nnotanumber 100 1.0\n456 abc 2.0\n',
      );
      expect(result.length, 1);
      expect(result[123]!.rssBytes, 209715200);
    });

    test('skips malformed lines with the wrong field count', () {
      final Map<int, PsStat> result = parsePsOutput(
        ' 123 204800 4.2\n789 100\n999 1 2 3\n',
      );
      expect(result.length, 1);
      expect(result.containsKey(789), isFalse);
      expect(result.containsKey(999), isFalse);
    });

    test('last entry wins when a pid repeats', () {
      final Map<int, PsStat> result = parsePsOutput(
        ' 123 100 1.0\n 123 200 2.0\n',
      );
      expect(result.length, 1);
      expect(result[123]!.rssBytes, 204800);
      expect(result[123]!.cpuPercent, 2.0);
    });

    test('empty input returns an empty map', () {
      expect(parsePsOutput(''), isEmpty);
    });

    test('whitespace-only input returns an empty map', () {
      expect(parsePsOutput('   \n  \n'), isEmpty);
    });
  });

  group('psArgsForPids', () {
    test('builds the ps -o/-p argument list for multiple pids', () {
      expect(psArgsForPids([123, 456]), [
        '-o',
        'pid=,rss=,%cpu=',
        '-p',
        '123',
        '-p',
        '456',
      ]);
    });

    test('returns an empty list for no pids', () {
      expect(psArgsForPids(<int>[]), isEmpty);
    });
  });

  group('MetricSample.copyWith', () {
    test('overrides only the requested fields', () {
      final MetricSample original = fullSample();
      final MetricSample updated = original.copyWith(tps: 15.2, players: 10);
      expect(updated.tps, 15.2);
      expect(updated.players, 10);
      expect(updated.ts, original.ts);
      expect(updated.cpuPercent, original.cpuPercent);
      expect(updated.rssBytes, original.rssBytes);
      expect(updated.instance, original.instance);
      expect(updated.state, original.state);
      expect(updated.port, original.port);
      expect(updated.maxPlayers, original.maxPlayers);
      expect(updated.latencyMs, original.latencyMs);
      expect(updated.version, original.version);
      expect(updated.logPath, original.logPath);
      expect(updated.uptimeSeconds, original.uptimeSeconds);
    });

    test('with no arguments preserves every field', () {
      final MetricSample original = fullSample();
      final MetricSample same = original.copyWith();
      expect(same.ts, original.ts);
      expect(same.tps, original.tps);
      expect(same.cpuPercent, original.cpuPercent);
      expect(same.rssBytes, original.rssBytes);
      expect(same.players, original.players);
    });
  });
}
