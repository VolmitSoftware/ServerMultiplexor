import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_landing.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

final DateTime now = DateTime.utc(2026, 9, 3);

MonitorSnapshot fleet({
  Map<String, RuntimeState?> states = const <String, RuntimeState?>{
    'alpha': RuntimeState.running,
    'beta': RuntimeState.stopped,
  },
  MonitorView view = MonitorView.local,
  Set<String> locked = const <String>{},
  Map<String, String> blocked = const <String, String>{},
}) => MonitorSnapshot(
  instances: states.keys.toList(growable: false),
  history: <String, List<MetricSample>>{
    for (final MapEntry<String, RuntimeState?> entry in states.entries)
      entry.key: <MetricSample>[
        if (entry.value case final RuntimeState state)
          MetricSample(ts: now, instance: entry.key, state: state),
      ],
  },
  flags: <String, InstanceFlags>{
    for (final String name in locked)
      name: const InstanceFlags(locked: true, isolated: false),
  },
  consumerName: 'plugin',
  view: view,
  operationBlockReasons: blocked,
);

MonitorFrame frame({
  MonitorSnapshot? snapshot,
  Set<String> checked = const <String>{},
  int selected = 0,
  int columns = 80,
  int lines = 24,
  MonitorTheme? theme,
}) => buildMonitorFrame(
  snapshot: snapshot ?? fleet(),
  selectedIndex: selected,
  checkedInstances: checked,
  frame: 0,
  columns: columns,
  lines: lines,
  theme: theme ?? MonitorTheme.plain(),
  range: const Duration(minutes: 15),
  now: now,
  clockNow: now,
);

MonitorHitbox hit(MonitorFrame frame, String id) =>
    frame.hitboxes.singleWhere((MonitorHitbox item) => item.id == id);

Set<String> buttons(MonitorFrame frame) => frame.hitboxes
    .where((MonitorHitbox item) => item.kind == MonitorHitKind.button)
    .map((MonitorHitbox item) => item.id)
    .toSet();

String checkboxText(MonitorFrame frame, String id) {
  final MonitorHitbox item = hit(frame, id);
  return Ansi.strip(
    frame.rows[item.row],
  ).substring(item.colStart, item.colStart + 3);
}

void main() {
  test('left checkbox wins over the row and does not replace row focus', () {
    final MonitorFrame rendered = frame(checked: <String>{'beta'});
    for (final String name in <String>['alpha', 'beta']) {
      final MonitorHitbox checkbox = hit(
        rendered,
        '$serverCheckHitPrefix$name',
      );
      final MonitorHitbox row = hit(rendered, '$serverHitPrefix$name');
      expect(checkbox.kind, MonitorHitKind.checkbox);
      expect(checkbox.row, row.row);
      expect(checkbox.colStart, 2);
      expect(checkbox.colEnd, 5);
      expect(hitTest(rendered.hitboxes, row: row.row, col: 2), checkbox.id);
      expect(hitTest(rendered.hitboxes, row: row.row, col: 4), checkbox.id);
      expect(hitTest(rendered.hitboxes, row: row.row, col: 6), row.id);
    }
    expect(checkboxText(rendered, 'check:alpha'), '[ ]');
    expect(checkboxText(rendered, 'check:beta'), '[x]');
    expect(
      Ansi.strip(rendered.rows[hit(rendered, 'server:alpha').row])[6],
      '▸',
    );
  });

  test('header has empty, mixed, and all states for the whole snapshot', () {
    expect(checkboxText(frame(), selectAllHitId), '[ ]');
    expect(
      checkboxText(frame(checked: <String>{'alpha'}), selectAllHitId),
      '[-]',
    );
    expect(
      checkboxText(frame(checked: <String>{'alpha', 'beta'}), selectAllHitId),
      '[x]',
    );
    final MonitorHitbox all = hit(frame(), selectAllHitId);
    expect(all.kind, MonitorHitKind.checkbox);
    expect(
      Ansi.strip(frame().rows[all.row]).substring(all.colStart, all.colEnd),
      '[ ] ALL',
    );
  });

  test('selection count and all marker include rows outside the viewport', () {
    final MonitorSnapshot snapshot = fleet(
      states: <String, RuntimeState?>{
        for (int index = 0; index < 30; index++)
          'server-$index': RuntimeState.running,
      },
    );
    final Set<String> all = snapshot.instances.toSet();
    final MonitorFrame rendered = frame(
      snapshot: snapshot,
      selected: 15,
      checked: all,
    );
    expect(checkboxText(rendered, selectAllHitId), '[x]');
    expect(Ansi.strip(rendered.rows[6]), contains('30 SELECTED'));
    expect(
      rendered.hitboxes
          .where(
            (MonitorHitbox item) => item.id.startsWith(serverCheckHitPrefix),
          )
          .length,
      lessThan(30),
    );
    final MonitorFrame mixed = frame(
      snapshot: snapshot,
      selected: 15,
      checked: <String>{'server-0'},
    );
    expect(checkboxText(mixed, selectAllHitId), '[-]');
    expect(Ansi.strip(mixed.rows[21]), contains('1 SELECTED'));
    expect(
      mixed.hitboxes.any((MonitorHitbox item) => item.id == 'check:server-0'),
      isFalse,
    );
  });

  test('all selected actions fit at 80 by 24 with exact chip hitboxes', () {
    final MonitorFrame rendered = frame(checked: <String>{'alpha', 'beta'});
    expect(rendered.rows.length, 24);
    for (final String row in rendered.rows) {
      expect(Ansi.visibleLength(row), 80);
    }
    expect(Ansi.strip(rendered.rows[21]), startsWith(' 2 SELECTED'));
    for (final (String id, String label) in <(String, String)>[
      (bulkStartHitId, 'START'),
      (bulkStopHitId, 'STOP'),
      (bulkRestartHitId, 'RESTART'),
      (bulkDeleteHitId, 'DELETE'),
      (clearSelectionHitId, 'CLEAR'),
    ]) {
      final MonitorHitbox button = hit(rendered, id);
      final String row = Ansi.strip(rendered.rows[button.row]);
      expect(row.substring(button.colStart, button.colEnd), '[ $label ]');
      expect(
        hitTest(rendered.hitboxes, row: button.row, col: button.colStart),
        id,
      );
      expect(
        hitTest(rendered.hitboxes, row: button.row, col: button.colEnd - 1),
        id,
      );
    }
    expect(
      buttons(rendered).where((String id) => id.startsWith('act:')),
      isEmpty,
    );
    expect(Ansi.strip(rendered.rows.last), contains('Space check'));
    expect(Ansi.strip(rendered.rows.last), contains('b selected actions'));
    expect(Ansi.strip(frame().rows.last), contains('Space check'));
  });

  test(
    'bulk controls follow checked eligibility rather than focused state',
    () {
      final MonitorFrame stopped = frame(checked: <String>{'beta'});
      expect(buttons(stopped), contains(bulkStartHitId));
      expect(buttons(stopped), isNot(contains(bulkStopHitId)));
      expect(buttons(stopped), isNot(contains(bulkRestartHitId)));
      final MonitorFrame lockedUnknown = frame(
        snapshot: fleet(
          states: <String, RuntimeState?>{'alpha': null},
          locked: <String>{'alpha'},
        ),
        checked: <String>{'alpha'},
      );
      expect(
        buttons(lockedUnknown).where((String id) => id.startsWith('bulk:')),
        isEmpty,
      );
      expect(buttons(lockedUnknown), contains(clearSelectionHitId));
      expect(Ansi.strip(lockedUnknown.rows[21]), contains('[ DELETE ]'));
    },
  );

  test(
    'remote blocked power leaves accessible deletion and clear controls',
    () {
      final MonitorFrame rendered = frame(
        snapshot: fleet(
          view: MonitorView.remote,
          blocked: <String, String>{'alpha': 'Installing'},
        ),
        checked: <String>{'alpha'},
      );
      expect(
        buttons(rendered),
        containsAll(<String>[bulkDeleteHitId, clearSelectionHitId]),
      );
      expect(buttons(rendered), isNot(contains(bulkStartHitId)));
      expect(buttons(rendered), isNot(contains(bulkStopHitId)));
      expect(buttons(rendered), isNot(contains(bulkRestartHitId)));
    },
  );

  test(
    'delete uses the danger token and no selection keeps focused actions',
    () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final MonitorFrame rendered = frame(
        checked: <String>{'alpha'},
        theme: theme,
      );
      expect(rendered.rows[21], contains('${theme.danger}DELETE'));
      expect(buttons(frame()), contains(actStopHitId));
      expect(
        buttons(frame()).where((String id) => id.startsWith('bulk:')),
        isEmpty,
      );
    },
  );

  test(
    'empty snapshots disable selection even when stale checks are supplied',
    () {
      final MonitorFrame rendered = frame(
        snapshot: fleet(states: <String, RuntimeState?>{}),
        checked: <String>{'removed'},
      );
      expect(
        rendered.hitboxes.where(
          (MonitorHitbox item) => item.kind == MonitorHitKind.checkbox,
        ),
        isEmpty,
      );
      expect(
        buttons(rendered).where((String id) => id.startsWith('bulk:')),
        isEmpty,
      );
      expect(buttons(rendered), isNot(contains(clearSelectionHitId)));
    },
  );

  test('narrow list keeps checkbox hitboxes inside its rendered width', () {
    final MonitorSnapshot snapshot = fleet();
    final MonitorPanelRender rendered = renderServerList(
      snapshot: snapshot,
      rollup: MonitorRollup.of(snapshot, windowStart: now, windowEnd: now),
      selectedIndex: 0,
      checkedInstances: <String>{'beta'},
      rows: 5,
      width: 24,
      topRow: 0,
      theme: MonitorTheme.plain(),
      windowStart: now,
      windowEnd: now,
    );
    for (final String row in rendered.rows) {
      expect(Ansi.visibleLength(row), 24);
    }
    for (final MonitorHitbox item in rendered.hitboxes) {
      expect(item.colStart, greaterThanOrEqualTo(0));
      expect(item.colEnd, lessThanOrEqualTo(24));
    }
    expect(hitTest(rendered.hitboxes, row: 3, col: 2), 'check:beta');
    expect(Ansi.strip(rendered.rows[3]).substring(2, 5), '[x]');
    expect(frame(columns: 24).hitboxes, isEmpty);
  });
}
