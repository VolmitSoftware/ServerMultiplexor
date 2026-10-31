import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_detail_model.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 10, 30, 19, 2);

List<MetricSample> _running(String instance) => <MetricSample>[
  for (int i = 0; i < 60; i++)
    MetricSample(
      ts: _now.subtract(Duration(seconds: 15 * (59 - i))),
      instance: instance,
      state: RuntimeState.running,
      players: 3,
      maxPlayers: 20,
      tps: 20,
      cpuPercent: 30,
      rssBytes: 4 << 30,
      networkRxPacketsPerSecond: 40,
      networkTxPacketsPerSecond: 25,
      uptimeSeconds: 3600 + i * 15,
      version: 'Leaf 26.3',
      logPath: '/srv/leaf/logs/latest.log',
    ),
];

MonitorSnapshot _grouped() => MonitorSnapshot(
  instances: const <String>['plugin/leaf', 'plugin/spigot'],
  history: <String, List<MetricSample>>{
    'plugin/leaf': _running('plugin/leaf'),
    'plugin/spigot': const <MetricSample>[],
  },
  consumerName: 'Local',
  groupedLocal: true,
  instanceConsumers: const <String, ConsumerProfile>{
    'plugin/leaf': ConsumerProfile.plugin,
    'plugin/spigot': ConsumerProfile.plugin,
  },
);

List<String> _frame({
  required int columns,
  required int lines,
  List<String>? logLines,
}) => buildMonitorFrame(
  snapshot: _grouped(),
  selectedIndex: 0,
  frame: 0,
  columns: columns,
  lines: lines,
  theme: MonitorTheme.plain(),
  range: const Duration(minutes: 15),
  now: _now,
  clockNow: _now,
  logLines: logLines,
).rows.map(Ansi.strip).toList();

int _rowOf(List<String> rows, String text) =>
    rows.indexWhere((String row) => row.contains(text));

void main() {
  test('a tall terminal gives its spare rows to the card, not the group', () {
    final List<String> rows = _frame(
      columns: 200,
      lines: 90,
      logLines: <String>[for (int i = 0; i < 80; i++) 'log line $i'],
    );
    final int plugins = _rowOf(rows, 'Plugins');
    final int fabric = _rowOf(rows, 'Fabric');
    expect(
      fabric - plugins,
      lessThanOrEqualTo(5),
      reason: 'the Plugins group keeps its natural height',
    );
    expect(rows.join('\n'), contains('log line 79'));
    expect(_rowOf(rows, 'LOG'), greaterThan(_rowOf(rows, '─ LEAF')));
  });

  test('chart height stops growing where it stops helping', () {
    final List<String> rows = _frame(columns: 200, lines: 90);
    final int axis = rows.indexWhere((String row) => row.contains('20 ┤'));
    final int base = rows.indexWhere((String row) => row.contains('0 └'));
    expect(base - axis, lessThanOrEqualTo(18));
  });

  test('a wide card charts network and players instead of a sparkline row', () {
    final List<String> rows = _frame(columns: 220, lines: 50);
    final String header = rows[_rowOf(rows, 'TPS 20.0')];
    expect(header, contains('NET'));
    expect(header, contains('PLAYERS 3/20'));
    expect(rows.join('\n'), isNot(contains('NETWORK PPS')));
  });

  test('a narrow card keeps three charts and the network row', () {
    final List<String> rows = _frame(columns: 120, lines: 50);
    final String header = rows[_rowOf(rows, 'TPS 20.0')];
    expect(header, isNot(contains('PLAYERS')));
    expect(rows.join('\n'), contains('NETWORK PPS'));
  });

  test('every screen stays whole and usable from 40x12 up', () {
    for (final int columns in <int>[40, 55, 80, 120, 200, 320]) {
      for (final int lines in <int>[12, 18, 24, 40, 70, 100]) {
        final String size = '${columns}x$lines';
        final MonitorFrame dashboard = buildMonitorFrame(
          snapshot: _grouped(),
          selectedIndex: 0,
          frame: 0,
          columns: columns,
          lines: lines,
          theme: MonitorTheme.plain(),
          range: const Duration(minutes: 15),
          now: _now,
          clockNow: _now,
          logLines: const <String>['ready'],
        );
        final List<List<String>> screens = <List<String>>[
          dashboard.rows,
          overlayModal(
            base: dashboard,
            modal: const InstanceModal('plugin/leaf'),
            latest: _running('plugin/leaf').last,
            locked: false,
            isolated: false,
            theme: MonitorTheme.plain(),
            columns: columns,
            lines: lines,
          ).rows,
          buildDetailFrame(
            instance: 'plugin/leaf',
            history: _running('plugin/leaf'),
            logLines: const <String>['ready'],
            frame: 0,
            columns: columns,
            lines: lines,
            theme: MonitorTheme.plain(),
            range: const Duration(minutes: 15),
            now: _now,
          ).rows,
        ];
        for (final List<String> screen in screens) {
          expect(screen, hasLength(lines), reason: size);
          for (final String row in screen) {
            expect(Ansi.visibleLength(row), columns, reason: size);
          }
          expect(
            screen.map(Ansi.strip).join('\n'),
            isNot(contains('RESIZE REQUIRED')),
            reason: size,
          );
        }
        final List<String> rows = dashboard.rows.map(Ansi.strip).toList();
        expect(rows.last, contains('quit'), reason: '$size footer');
        expect(rows[lines - 2], contains('[ '), reason: '$size action bar');
      }
    }
  });
}
