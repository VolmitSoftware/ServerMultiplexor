import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/metrics_sampler.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/services/monitor/monitor_screen.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

MonitorScreen screen({
  Duration sweepInterval = const Duration(seconds: 2),
  Duration Function()? sweepIntervalProvider,
}) => MonitorScreen(
  sampler: MetricsSampler(captureMetrics: () async => ''),
  theme: MonitorTheme.plain(),
  loadSnapshot: () async => const MonitorSnapshot(
    instances: <String>[],
    history: <String, List<MetricSample>>{},
    consumerName: 'test',
  ),
  suspend: (Future<void> Function() flow) => flow(),
  quickAction: (String _, MonitorAction _) async {},
  instanceAction: (String _, InstanceModalAction _) async {},
  workspaceAction: (WorkspaceModalAction _, String? _) async {},
  readLogTail: (String _, int _) async => const <String>[],
  sweepInterval: sweepInterval,
  sweepIntervalProvider: sweepIntervalProvider,
);

void main() {
  group('MonitorGeometryStabilizer', () {
    test('accepts the first observed size immediately', () {
      final MonitorGeometryStabilizer stabilizer = MonitorGeometryStabilizer();
      final DateTime now = DateTime.utc(2026, 1, 1);

      expect(stabilizer.observe(columns: 120, lines: 40, now: now), (
        columns: 120,
        lines: 40,
      ));
    });

    test('drops a one-tick small geometry without changing the frame', () {
      final MonitorGeometryStabilizer stabilizer = MonitorGeometryStabilizer();
      final DateTime now = DateTime.utc(2026, 1, 1);
      stabilizer.observe(columns: 120, lines: 40, now: now);

      expect(
        stabilizer.observe(
          columns: 45,
          lines: 8,
          now: now.add(const Duration(milliseconds: 250)),
        ),
        isNull,
      );
      expect(
        stabilizer.observe(
          columns: 120,
          lines: 40,
          now: now.add(const Duration(milliseconds: 500)),
        ),
        (columns: 120, lines: 40),
      );
    });

    test('accepts a real resize only after it stays stable', () {
      final MonitorGeometryStabilizer stabilizer = MonitorGeometryStabilizer();
      final DateTime now = DateTime.utc(2026, 1, 1);
      stabilizer.observe(columns: 120, lines: 40, now: now);

      expect(
        stabilizer.observe(
          columns: 100,
          lines: 30,
          now: now.add(const Duration(milliseconds: 250)),
        ),
        isNull,
      );
      expect(
        stabilizer.observe(
          columns: 100,
          lines: 30,
          now: now.add(const Duration(milliseconds: 749)),
        ),
        isNull,
      );
      expect(
        stabilizer.observe(
          columns: 100,
          lines: 30,
          now: now.add(const Duration(milliseconds: 750)),
        ),
        (columns: 100, lines: 30),
      );
    });
  });

  group('MonitorScreen rendering cadence', () {
    test('renders the monitor activity cell blank', () {
      expect(monitorSpinner(MonitorTheme.plain(), -1), ' ');
    });

    test('keeps chart time stable until a newer sample arrives', () {
      final DateTime previous = DateTime.utc(2026, 1, 1, 12);
      final MetricSample older = MetricSample(
        ts: previous.subtract(const Duration(seconds: 1)),
        instance: 'older',
        state: RuntimeState.running,
      );
      final MetricSample newer = MetricSample(
        ts: previous.add(const Duration(seconds: 2)),
        instance: 'newer',
        state: RuntimeState.running,
      );

      expect(
        monitorDataTime(
          previous: previous,
          latestSamples: <MetricSample?>[older, null],
        ),
        previous,
      );
      expect(
        monitorDataTime(
          previous: previous,
          latestSamples: <MetricSample?>[older, newer],
        ),
        newer.ts,
      );
    });
  });

  group('MonitorScreen sweep cadence', () {
    test('defaults to the Local two-second cadence', () {
      expect(screen().sweepInterval, const Duration(seconds: 2));
    });

    test('keeps the static cadence when no provider is supplied', () {
      final MonitorScreen monitor = screen(
        sweepInterval: const Duration(seconds: 7),
      );

      expect(monitor.sweepInterval, const Duration(seconds: 7));
    });

    test('reevaluates a dynamic cadence provider', () {
      int serverCount = 0;
      final MonitorScreen monitor = screen(
        sweepInterval: const Duration(seconds: 7),
        sweepIntervalProvider: () => Duration(seconds: 20 + serverCount),
      );

      expect(monitor.sweepInterval, const Duration(seconds: 20));
      serverCount = 80;
      expect(monitor.sweepInterval, const Duration(seconds: 100));
    });
  });

  test('build shortcut opens the provider-specific workspace action', () {
    expect(
      monitorBuildShortcutAction(MonitorView.local),
      WorkspaceModalAction.buildTuning,
    );
    expect(
      monitorBuildShortcutAction(MonitorView.remote),
      WorkspaceModalAction.bulkActions,
    );
  });
}
