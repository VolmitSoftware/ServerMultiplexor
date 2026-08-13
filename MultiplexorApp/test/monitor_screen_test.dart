import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/metrics_sampler.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/services/monitor/monitor_screen.dart';
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
