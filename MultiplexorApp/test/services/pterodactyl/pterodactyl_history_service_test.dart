import 'dart:io';

import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/trend_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_history_service.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

void main() {
  test('reads a bounded window from the remote trend directory', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-remote-history-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final DateTime now = DateTime.utc(2026, 8, 12, 18);
    final TrendStore store = TrendStore(
      Directory('${temporary.path}/pterodactyl/dev/trends'),
    );
    await store.append(
      'abc123',
      MetricSample(
        ts: now.subtract(const Duration(hours: 2)),
        instance: 'abc123',
        state: RuntimeState.running,
        cpuPercent: 5,
      ),
    );
    await store.append(
      'abc123',
      MetricSample(
        ts: now.subtract(const Duration(minutes: 30)),
        instance: 'abc123',
        state: RuntimeState.running,
        cpuPercent: 12,
      ),
    );
    final PterodactylHistoryService history = PterodactylHistoryService(
      temporary.path,
    );

    final List<MetricSample> samples = await history.read(
      'dev',
      'abc123',
      now: now,
      window: const Duration(hours: 1),
    );

    expect(samples, hasLength(1));
    expect(samples.single.cpuPercent, 12);
    expect(await history.recordedServers('dev'), <String>['abc123']);
  });

  test('missing history is an empty read-only result', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-remote-history-empty-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylHistoryService history = PterodactylHistoryService(
      temporary.path,
    );

    expect(await history.read('dev', 'missing'), isEmpty);
    expect(await history.recordedServers('dev'), isEmpty);
  });

  test('parses compact history windows and rejects ambiguous values', () {
    expect(parsePterodactylHistoryWindow('15m'), const Duration(minutes: 15));
    expect(parsePterodactylHistoryWindow('6H'), const Duration(hours: 6));
    expect(parsePterodactylHistoryWindow('7d'), const Duration(days: 7));
    expect(
      () => parsePterodactylHistoryWindow('1 month'),
      throwsFormatException,
    );
    expect(() => parsePterodactylHistoryWindow('0h'), throwsFormatException);
  });
}
