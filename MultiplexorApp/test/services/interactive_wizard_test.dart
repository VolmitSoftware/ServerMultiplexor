import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:test/test.dart';

void main() {
  group('Remote quick-action runtime policy', () {
    test('offline restart starts instead', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: ' OFFLINE ',
        ),
        RemoteQuickActionEffect.start,
      );
    });

    test('offline stop, kill, and console are no-ops', () {
      for (final MonitorAction action in <MonitorAction>[
        MonitorAction.stop,
        MonitorAction.kill,
        MonitorAction.console,
      ]) {
        expect(
          remoteQuickActionEffect(action: action, currentState: 'offline'),
          RemoteQuickActionEffect.none,
          reason: action.name,
        );
      }
    });

    test('live shortcuts preserve their requested effects', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.restart,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.stop,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.stop,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.kill,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.kill,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.console,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.console,
      );
    });
  });
}
