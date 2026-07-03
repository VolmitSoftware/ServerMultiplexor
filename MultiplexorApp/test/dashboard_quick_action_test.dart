import 'package:multiplexor/services/dashboard_quick_action.dart';
import 'package:test/test.dart';

void main() {
  group('dashboardQuickAction', () {
    test('maps uppercase keys on a server row', () {
      expect(
        dashboardQuickAction('R', onServerRow: true),
        DashboardQuickAction.restart,
      );
      expect(
        dashboardQuickAction('S', onServerRow: true),
        DashboardQuickAction.stop,
      );
      expect(
        dashboardQuickAction('X', onServerRow: true),
        DashboardQuickAction.kill,
      );
      expect(
        dashboardQuickAction('O', onServerRow: true),
        DashboardQuickAction.console,
      );
    });

    test('returns null when the highlight is not a server row', () {
      expect(dashboardQuickAction('R', onServerRow: false), isNull);
      expect(dashboardQuickAction('X', onServerRow: false), isNull);
    });

    test('ignores lowercase and unrelated characters', () {
      expect(dashboardQuickAction('r', onServerRow: true), isNull);
      expect(dashboardQuickAction('s', onServerRow: true), isNull);
      expect(dashboardQuickAction('q', onServerRow: true), isNull);
      expect(dashboardQuickAction('1', onServerRow: true), isNull);
      expect(dashboardQuickAction('', onServerRow: true), isNull);
    });
  });
}
