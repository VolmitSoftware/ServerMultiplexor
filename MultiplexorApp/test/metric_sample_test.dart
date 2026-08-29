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
    diskBytes: 1073741824,
    networkRxBytes: 1048576,
    networkTxBytes: 2097152,
    networkRxPackets: 1200,
    networkTxPackets: 900,
    networkRxBytesPerSecond: 8192.5,
    networkTxBytesPerSecond: 4096.25,
    networkRxPacketsPerSecond: 42.5,
    networkTxPacketsPerSecond: 21.25,
    memoryLimitBytes: 4294967296,
    diskLimitBytes: 10737418240,
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
        'diskBytes': 1073741824,
        'networkRxBytes': 1048576,
        'networkTxBytes': 2097152,
        'networkRxPackets': 1200,
        'networkTxPackets': 900,
        'networkRxBytesPerSecond': 8192.5,
        'networkTxBytesPerSecond': 4096.25,
        'networkRxPacketsPerSecond': 42.5,
        'networkTxPacketsPerSecond': 21.25,
        'memoryLimitBytes': 4294967296,
        'diskLimitBytes': 10737418240,
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
      expect(parsed.diskBytes, 1073741824);
      expect(parsed.networkRxBytes, 1048576);
      expect(parsed.networkTxBytes, 2097152);
      expect(parsed.networkRxPackets, 1200);
      expect(parsed.networkTxPackets, 900);
      expect(parsed.networkRxBytesPerSecond, 8192.5);
      expect(parsed.networkTxBytesPerSecond, 4096.25);
      expect(parsed.networkRxPacketsPerSecond, 42.5);
      expect(parsed.networkTxPacketsPerSecond, 21.25);
      expect(parsed.memoryLimitBytes, 4294967296);
      expect(parsed.diskLimitBytes, 10737418240);
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
    test('parses a full 14-column row', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log\t42';
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
      expect(sample.latencyMs, 42);
    });

    test('a dashed latency cell parses to null, never zero', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log\t-';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.latencyMs, isNull);
    });

    test('a legacy 13-column row leaves latency null', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.logPath, '/logs/survival/latest.log');
      expect(sample.rssBytes, 536870912);
      expect(sample.latencyMs, isNull);
    });

    test('extra columns beyond 14 are ignored', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log\t42'
          '\tEXTRA\tSTUFF';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.logPath, '/logs/survival/latest.log');
      expect(sample.latencyMs, 42);
    });

    test('parses appended Pterodactyl resource columns', () {
      const String line =
          'remote\trunning\t25565\tunlocked\t-\t-\t-\t-\tshared'
          '\t3600\t12.5\t1073741824\t-\t-\t536870912'
          '\t1048576\t2097152\t6442450944\t53687091200';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.diskBytes, 536870912);
      expect(sample.networkRxBytes, 1048576);
      expect(sample.networkTxBytes, 2097152);
      expect(sample.memoryLimitBytes, 6442450944);
      expect(sample.diskLimitBytes, 53687091200);
      expect(sample.networkRxPackets, isNull);
      expect(sample.networkTxPackets, isNull);
    });

    test('parses appended per-process packet counters', () {
      const String line =
          'local\trunning\t25565\tunlocked\t-\t-\t-\t-\tshared'
          '\t3600\t12.5\t1073741824\t-\t-\t-\t1048576\t2097152\t-\t-'
          '\t1200\t900';
      final MetricSample? sample = MetricSample.fromMetricsTsv(line, ts);
      expect(sample, isNotNull);
      expect(sample!.networkRxBytes, 1048576);
      expect(sample.networkTxBytes, 2097152);
      expect(sample.networkRxPackets, 1200);
      expect(sample.networkTxPackets, 900);
    });

    test('a stopped instance row with dash fields parses to nulls', () {
      const String line =
          'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared\t-\t-\t-\t-\t-';
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

  group('MetricSample.withNetworkRatesFrom', () {
    MetricSample counters({
      required DateTime at,
      required int rxBytes,
      required int txBytes,
      required int rxPackets,
      required int txPackets,
      int uptimeSeconds = 100,
    }) => MetricSample(
      ts: at,
      instance: 'survival',
      state: RuntimeState.running,
      networkRxBytes: rxBytes,
      networkTxBytes: txBytes,
      networkRxPackets: rxPackets,
      networkTxPackets: txPackets,
      uptimeSeconds: uptimeSeconds,
    );

    test('derives byte and packet rates over the measured interval', () {
      final MetricSample previous = counters(
        at: ts,
        rxBytes: 1000,
        txBytes: 2000,
        rxPackets: 100,
        txPackets: 200,
      );
      final MetricSample current = counters(
        at: ts.add(const Duration(seconds: 2)),
        rxBytes: 5000,
        txBytes: 3000,
        rxPackets: 140,
        txPackets: 260,
        uptimeSeconds: 102,
      ).withNetworkRatesFrom(previous);
      expect(current.networkRxBytesPerSecond, 2000);
      expect(current.networkTxBytesPerSecond, 500);
      expect(current.networkRxPacketsPerSecond, 20);
      expect(current.networkTxPacketsPerSecond, 30);
    });

    test('first sample and reset counters leave rates unavailable', () {
      final MetricSample previous = counters(
        at: ts,
        rxBytes: 5000,
        txBytes: 3000,
        rxPackets: 140,
        txPackets: 260,
      );
      expect(
        previous.withNetworkRatesFrom(null).networkRxBytesPerSecond,
        isNull,
      );
      final MetricSample reset = counters(
        at: ts.add(const Duration(seconds: 2)),
        rxBytes: 10,
        txBytes: 20,
        rxPackets: 1,
        txPackets: 2,
        uptimeSeconds: 1,
      ).withNetworkRatesFrom(previous);
      expect(reset.networkRxBytesPerSecond, isNull);
      expect(reset.networkTxBytesPerSecond, isNull);
      expect(reset.networkRxPacketsPerSecond, isNull);
      expect(reset.networkTxPacketsPerSecond, isNull);
    });

    test('never compares counters belonging to another instance', () {
      final MetricSample previous = MetricSample(
        ts: ts,
        instance: 'creative',
        state: RuntimeState.running,
        networkRxPackets: 100,
      );
      final MetricSample current = counters(
        at: ts.add(const Duration(seconds: 2)),
        rxBytes: 1000,
        txBytes: 1000,
        rxPackets: 140,
        txPackets: 140,
      ).withNetworkRatesFrom(previous);
      expect(current.networkRxPacketsPerSecond, isNull);
    });
  });

  group('metricsTsvFlags', () {
    test('reads locked and isolated from a full 14-column row', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
          '\t3600\t3.5\t536870912\t/logs/survival/latest.log\t42';
      final InstanceFlags? flags = metricsTsvFlags(line);
      expect(flags, isNotNull);
      expect(flags!.locked, isTrue);
      expect(flags.isolated, isTrue);
    });

    test('reads unlocked and shared as the false half of each pair', () {
      const String line =
          'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared\t-\t-\t-\t-\t-';
      final InstanceFlags? flags = metricsTsvFlags(line);
      expect(flags, isNotNull);
      expect(flags!.locked, isFalse);
      expect(flags.isolated, isFalse);
    });

    test('parses a legacy 9-column row, the shortest that carries both', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tshared';
      final InstanceFlags? flags = metricsTsvFlags(line);
      expect(flags, isNotNull);
      expect(flags!.locked, isTrue);
      expect(flags.isolated, isFalse);
    });

    test('fewer than 9 columns returns null', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8';
      expect(metricsTsvFlags(line), isNull);
    });

    test('a line that is not a row at all returns null', () {
      expect(metricsTsvFlags(''), isNull);
      expect(metricsTsvFlags('no such instance'), isNull);
    });

    test('an unknown lock token returns null rather than guessing', () {
      const String line =
          'survival\trunning\t25565\tmaybe\t4\t20\t1.21.1\t19.8\tisolated';
      expect(metricsTsvFlags(line), isNull);
    });

    test('an unknown isolation token returns null rather than guessing', () {
      const String line =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tsomewhat';
      expect(metricsTsvFlags(line), isNull);
    });
  });

  group('metricsTsvFlagsByInstance', () {
    test('keys every parsed row by its instance name', () {
      const String capture =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated\n'
          'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared';
      final Map<String, InstanceFlags> flags = metricsTsvFlagsByInstance(
        capture,
      );
      expect(flags.keys, <String>['survival', 'lobby']);
      expect(flags['survival']!.locked, isTrue);
      expect(flags['survival']!.isolated, isTrue);
      expect(flags['lobby']!.locked, isFalse);
      expect(flags['lobby']!.isolated, isFalse);
    });

    test('skips blank lines, nameless rows, and malformed rows', () {
      const String capture =
          '\n'
          '\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated\n'
          'broken\trunning\t25565\tmaybe\t4\t20\t1.21.1\t19.8\tisolated\n'
          'short\trunning\t25565\tlocked\n'
          'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared\n';
      final Map<String, InstanceFlags> flags = metricsTsvFlagsByInstance(
        capture,
      );
      expect(flags.keys, <String>['lobby']);
    });

    test('an empty capture yields an empty map', () {
      expect(metricsTsvFlagsByInstance(''), isEmpty);
    });

    test('a repeated instance keeps the last row', () {
      const String capture =
          'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated\n'
          'survival\trunning\t25565\tunlocked\t4\t20\t1.21.1\t19.8\tshared';
      final Map<String, InstanceFlags> flags = metricsTsvFlagsByInstance(
        capture,
      );
      expect(flags['survival']!.locked, isFalse);
      expect(flags['survival']!.isolated, isFalse);
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

  group('parseNettopOutput', () {
    test('maps reordered headers and process pid suffixes', () {
      const String output =
          ',packets_in,bytes_in,packets_out,bytes_out,\n'
          'java.32185,17278,34771964,14176,175139,\n';
      final Map<int, ProcessNetworkCounters> result = parseNettopOutput(output);
      expect(result.keys, <int>[32185]);
      expect(result[32185]!.rxBytes, 34771964);
      expect(result[32185]!.txBytes, 175139);
      expect(result[32185]!.rxPackets, 17278);
      expect(result[32185]!.txPackets, 14176);
    });

    test('rejects missing headers and malformed rows', () {
      expect(parseNettopOutput(',bytes_in,bytes_out,\njava.1,2,3,'), isEmpty);
      expect(
        parseNettopOutput(
          ',packets_in,bytes_in,packets_out,bytes_out,\n'
          'java.nope,1,2,3,4,\n',
        ),
        isEmpty,
      );
    });
  });

  group('nettopArgsForPids', () {
    test('builds one batch query for every pid', () {
      expect(nettopArgsForPids(<int>[123, 456]), <String>[
        '-L',
        '1',
        '-P',
        '-n',
        '-x',
        '-J',
        'bytes_in,bytes_out,packets_in,packets_out',
        '-p',
        '123',
        '-p',
        '456',
      ]);
    });

    test('returns no arguments for no pids', () {
      expect(nettopArgsForPids(<int>[]), isEmpty);
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

  group('metricsTsvRow', () {
    test('emits 21 tab-separated columns in the documented order', () {
      final String row = metricsTsvRow(
        name: 'survival',
        state: RuntimeState.running,
        port: 25565,
        locked: true,
        players: 4,
        maxPlayers: 20,
        version: '1.21.1',
        tps: 19.75,
        isolated: true,
        uptimeSeconds: 3600,
        cpuPercent: 3.54,
        rssBytes: 536870912,
        logPath: '/logs/survival/latest.log',
        latencyMs: 42,
        diskBytes: 1073741824,
        networkRxBytes: 1048576,
        networkTxBytes: 2097152,
        memoryLimitBytes: 4294967296,
        diskLimitBytes: 10737418240,
        networkRxPackets: 1200,
        networkTxPackets: 900,
      );
      expect(
        row,
        'survival\trunning\t25565\tlocked\t4\t20\t1.21.1\t19.8\tisolated'
        '\t3600\t3.5\t536870912\t/logs/survival/latest.log\t42'
        '\t1073741824\t1048576\t2097152\t4294967296\t10737418240\t1200\t900',
      );
      expect(row.split('\t'), hasLength(21));
    });

    test('renders every unavailable value as a dash, never zero', () {
      final String row = metricsTsvRow(
        name: 'lobby',
        state: RuntimeState.stopped,
        port: null,
        locked: false,
        players: null,
        maxPlayers: null,
        version: null,
        tps: null,
        isolated: false,
        uptimeSeconds: null,
        cpuPercent: null,
        rssBytes: null,
        logPath: null,
        latencyMs: null,
      );
      expect(
        row,
        'lobby\tstopped\t-\tunlocked\t-\t-\t-\t-\tshared\t-\t-\t-\t-\t-'
        '\t-\t-\t-\t-\t-\t-\t-',
      );
    });

    test('treats a blank text cell as unavailable', () {
      final String row = metricsTsvRow(
        name: 'lobby',
        state: RuntimeState.stopped,
        locked: false,
        version: '',
        isolated: false,
        logPath: '',
      );
      final List<String> cols = row.split('\t');
      expect(cols[6], '-');
      expect(cols[12], '-');
    });

    test('replaces embedded tabs and newlines in text cells with spaces', () {
      final String row = metricsTsvRow(
        name: 'survival',
        state: RuntimeState.running,
        locked: false,
        version: 'Paper\t1.21\nbeta',
        isolated: false,
        logPath: '/logs/a\tb.log',
      );
      final List<String> cols = row.split('\t');
      expect(cols, hasLength(21));
      expect(cols[6], 'Paper 1.21 beta');
      expect(cols[12], '/logs/a b.log');
    });

    test('round-trips through MetricSample.fromMetricsTsv', () {
      final String row = metricsTsvRow(
        name: 'survival',
        state: RuntimeState.running,
        port: 25565,
        locked: true,
        players: 4,
        maxPlayers: 20,
        version: '1.21.1',
        tps: 19.8,
        isolated: true,
        uptimeSeconds: 3600,
        cpuPercent: 3.5,
        rssBytes: 536870912,
        logPath: '/logs/survival/latest.log',
        latencyMs: 42,
        diskBytes: 1073741824,
        networkRxBytes: 1048576,
        networkTxBytes: 2097152,
        memoryLimitBytes: 4294967296,
        diskLimitBytes: 10737418240,
        networkRxPackets: 1200,
        networkTxPackets: 900,
      );
      final MetricSample? sample = MetricSample.fromMetricsTsv(row, ts);
      expect(sample, isNotNull);
      expect(sample!.instance, 'survival');
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
      expect(sample.latencyMs, 42);
      expect(sample.diskBytes, 1073741824);
      expect(sample.networkRxBytes, 1048576);
      expect(sample.networkTxBytes, 2097152);
      expect(sample.memoryLimitBytes, 4294967296);
      expect(sample.diskLimitBytes, 10737418240);
      expect(sample.networkRxPackets, 1200);
      expect(sample.networkTxPackets, 900);
    });

    test('a fully-unavailable row round-trips back to nulls', () {
      final String row = metricsTsvRow(
        name: 'lobby',
        state: RuntimeState.stopped,
        locked: false,
        isolated: false,
      );
      final MetricSample? sample = MetricSample.fromMetricsTsv(row, ts);
      expect(sample, isNotNull);
      expect(sample!.instance, 'lobby');
      expect(sample.state, RuntimeState.stopped);
      expect(sample.port, isNull);
      expect(sample.players, isNull);
      expect(sample.tps, isNull);
      expect(sample.uptimeSeconds, isNull);
      expect(sample.cpuPercent, isNull);
      expect(sample.rssBytes, isNull);
      expect(sample.logPath, isNull);
      expect(sample.latencyMs, isNull);
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
      expect(updated.networkRxBytes, original.networkRxBytes);
      expect(updated.networkTxBytes, original.networkTxBytes);
      expect(updated.networkRxPackets, original.networkRxPackets);
      expect(updated.networkTxPackets, original.networkTxPackets);
      expect(
        updated.networkRxPacketsPerSecond,
        original.networkRxPacketsPerSecond,
      );
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
