import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

/// A theme resolved at truecolor depth, for tests that assert exact escape
/// sequences.
MonitorTheme truecolor() => MonitorTheme.detect(
  env: <String, String>{'COLORTERM': 'truecolor'},
  isTty: true,
);

/// A base frame of recognizable, escape-free rows exactly [columns] wide,
/// carrying one hitbox the overlay is expected to discard.
MonitorFrame baseFrame({int columns = 100, int lines = 30}) => MonitorFrame(
  rows: List<String>.generate(
    lines,
    (int index) =>
        ('base-$index-' * 60).substring(0, columns < 0 ? 0 : columns),
  ),
  hitboxes: const <MonitorHitbox>[
    MonitorHitbox(
      id: 'server:alpha',
      row: 4,
      colStart: 0,
      colEnd: 20,
      kind: MonitorHitKind.serverRow,
    ),
  ],
);

/// A single reading for `alpha` in [state].
MetricSample sample(RuntimeState state) => MetricSample(
  ts: DateTime.utc(2026, 7, 30, 14),
  instance: 'alpha',
  state: state,
  port: 25565,
);

/// Every clickable button id in [frame].
Set<String> buttonIds(MonitorFrame frame) => frame.hitboxes
    .where((MonitorHitbox box) => box.kind == MonitorHitKind.button)
    .map((MonitorHitbox box) => box.id)
    .toSet();

/// The hitbox carrying [id], or null when the overlay emitted none.
MonitorHitbox? boxFor(MonitorFrame frame, String id) {
  for (final MonitorHitbox box in frame.hitboxes) {
    if (box.id == id) {
      return box;
    }
  }
  return null;
}

/// Every row of [frame] with its escapes removed.
List<String> plainRows(MonitorFrame frame) =>
    frame.rows.map(Ansi.strip).toList();

/// The index of the single row of [frame] whose visible text contains [text].
int rowWith(MonitorFrame frame, String text) {
  final List<String> rows = plainRows(frame);
  for (int index = 0; index < rows.length; index++) {
    if (rows[index].contains(text)) {
      return index;
    }
  }
  return -1;
}

/// Renders an instance modal over a default base frame.
MonitorFrame instanceOverlay({
  RuntimeState? state = RuntimeState.running,
  bool locked = false,
  bool isolated = false,
  MonitorTheme? theme,
  String? hoveredId,
  String? pressedId,
  int columns = 100,
  int lines = 30,
}) => overlayModal(
  base: baseFrame(columns: columns, lines: lines),
  modal: const InstanceModal('alpha'),
  latest: state == null ? null : sample(state),
  locked: locked,
  isolated: isolated,
  theme: theme ?? MonitorTheme.plain(),
  hoveredId: hoveredId,
  pressedId: pressedId,
  columns: columns,
  lines: lines,
);

/// Renders a workspace modal over a default base frame.
MonitorFrame workspaceOverlay({
  MonitorTheme? theme,
  String? hoveredId,
  String? pressedId,
  int columns = 100,
  int lines = 30,
}) => overlayModal(
  base: baseFrame(columns: columns, lines: lines),
  modal: const WorkspaceModal(),
  latest: null,
  locked: false,
  isolated: false,
  theme: theme ?? MonitorTheme.plain(),
  hoveredId: hoveredId,
  pressedId: pressedId,
  columns: columns,
  lines: lines,
);

void main() {
  group('MonitorModalState', () {
    test('an instance modal carries the instance it acts on', () {
      const InstanceModal modal = InstanceModal('alpha');
      expect(modal.instance, 'alpha');
    });

    test('a workspace modal is a constant with no payload', () {
      expect(const WorkspaceModal(), isA<MonitorModalState>());
    });
  });

  group('InstanceModalAction', () {
    test('names every instance action the old menu offered', () {
      expect(InstanceModalAction.values, <InstanceModalAction>[
        InstanceModalAction.start,
        InstanceModalAction.stop,
        InstanceModalAction.restart,
        InstanceModalAction.console,
        InstanceModalAction.setPort,
        InstanceModalAction.makeActive,
        InstanceModalAction.motd,
        InstanceModalAction.lock,
        InstanceModalAction.unlock,
        InstanceModalAction.isolated,
        InstanceModalAction.shared,
        InstanceModalAction.folder,
        InstanceModalAction.update,
        InstanceModalAction.factoryReset,
        InstanceModalAction.delete,
      ]);
    });

    test('hit ids are the action name behind the instance-modal prefix', () {
      expect(instanceModalHitPrefix, 'im:');
      expect(instanceModalHitId(InstanceModalAction.setPort), 'im:setPort');
      expect(
        instanceModalHitId(InstanceModalAction.factoryReset),
        'im:factoryReset',
      );
    });
  });

  group('WorkspaceModalAction', () {
    test('names every workspace action including the bar-only new', () {
      expect(WorkspaceModalAction.values, <WorkspaceModalAction>[
        WorkspaceModalAction.buildTuning,
        WorkspaceModalAction.pullBuilds,
        WorkspaceModalAction.createMany,
        WorkspaceModalAction.startAll,
        WorkspaceModalAction.stopAll,
        WorkspaceModalAction.wipe,
        WorkspaceModalAction.newInstance,
      ]);
    });

    test('hit ids are the action name behind the workspace-modal prefix', () {
      expect(workspaceModalHitPrefix, 'wm:');
      expect(workspaceModalHitId(WorkspaceModalAction.stopAll), 'wm:stopAll');
    });
  });

  group('overlayModal geometry', () {
    test('emits exactly the requested rows and visible columns', () {
      final MonitorFrame frame = instanceOverlay();
      expect(frame.rows.length, 30);
      for (final String row in frame.rows) {
        expect(Ansi.visibleLength(row), 100);
      }
    });

    test('centers the instance card horizontally and vertically', () {
      final MonitorFrame frame = instanceOverlay();
      // 46 wide over 100 columns, 9 rows over 30 lines.
      expect(plainRows(frame)[10].substring(27, 73), startsWith('┌─ alpha '));
      expect(plainRows(frame)[18].substring(27, 73), startsWith('└'));
      expect(plainRows(frame)[18][72], '┘');
    });

    test('leaves the base rows above and below the card untouched', () {
      final MonitorFrame base = baseFrame();
      final MonitorFrame frame = overlayModal(
        base: base,
        modal: const InstanceModal('alpha'),
        latest: sample(RuntimeState.running),
        locked: false,
        isolated: false,
        theme: MonitorTheme.plain(),
        columns: 100,
        lines: 30,
      );
      for (final int index in <int>[0, 5, 9, 19, 25, 29]) {
        expect(frame.rows[index], base.rows[index], reason: 'row $index');
      }
    });

    test('keeps the base text left of the card on every card row', () {
      final MonitorFrame base = baseFrame();
      final MonitorFrame frame = instanceOverlay();
      for (int index = 10; index <= 18; index++) {
        expect(
          plainRows(frame)[index].substring(0, 27),
          Ansi.strip(base.rows[index]).substring(0, 27),
          reason: 'row $index',
        );
      }
    });

    test('blanks the base text right of the card on every card row', () {
      final MonitorFrame frame = instanceOverlay();
      for (int index = 10; index <= 18; index++) {
        expect(
          plainRows(frame)[index].substring(73),
          ' ' * 27,
          reason: 'row $index',
        );
      }
    });

    test('draws the esc hint on the row just inside the bottom border', () {
      final MonitorFrame frame = instanceOverlay();
      expect(plainRows(frame)[17], contains('esc closes'));
      expect(rowWith(frame, 'esc closes'), 17);
    });

    test('badges the instance card with the sampled state', () {
      final MonitorFrame frame = instanceOverlay(
        state: RuntimeState.stopped,
      );
      expect(plainRows(frame)[10], contains('stopped'));
    });

    test('badges an unsampled instance as having no data', () {
      final MonitorFrame frame = instanceOverlay(state: null);
      expect(plainRows(frame)[10], contains('no data'));
    });

    test('centers the workspace card over its own smaller height', () {
      final MonitorFrame frame = workspaceOverlay();
      // 6 rows over 30 lines.
      expect(plainRows(frame)[12].substring(27, 73), startsWith('┌─ WORKSPACE'));
      expect(plainRows(frame)[17][72], '┘');
      expect(rowWith(frame, 'esc closes'), 16);
    });
  });

  group('overlayModal hitboxes', () {
    test('lays a full-width scrim over every row of the frame', () {
      final MonitorFrame frame = instanceOverlay();
      final List<MonitorHitbox> scrim = frame.hitboxes
          .where((MonitorHitbox box) => box.kind == MonitorHitKind.modalScrim)
          .toList();
      expect(scrim.length, 30);
      expect(scrim.map((MonitorHitbox box) => box.row).toSet(), <int>{
        for (int index = 0; index < 30; index++) index,
      });
      for (final MonitorHitbox box in scrim) {
        expect(box.id, modalScrimHitId);
        expect(box.colStart, 0);
        expect(box.colEnd, 100);
      }
    });

    test('discards every hitbox the base frame carried', () {
      final MonitorFrame frame = instanceOverlay();
      expect(boxFor(frame, 'server:alpha'), isNull);
    });

    test('hit-tests a point outside the card as the scrim', () {
      final MonitorFrame frame = instanceOverlay();
      expect(hitTest(frame.hitboxes, row: 0, col: 0), modalScrimHitId);
      expect(hitTest(frame.hitboxes, row: 29, col: 99), modalScrimHitId);
      expect(hitTest(frame.hitboxes, row: 11, col: 5), modalScrimHitId);
    });

    test('hit-tests a card button as the button, not the scrim beneath', () {
      final MonitorFrame frame = instanceOverlay();
      final MonitorHitbox stop = boxFor(frame, 'im:stop')!;
      expect(
        hitTest(frame.hitboxes, row: stop.row, col: stop.colStart),
        'im:stop',
      );
      expect(
        hitTest(frame.hitboxes, row: stop.row, col: stop.colEnd - 1),
        'im:stop',
      );
      expect(hitTest(frame.hitboxes, row: stop.row, col: stop.colEnd), isNot('im:stop'));
    });

    test('offsets button spans by the card left edge and its border', () {
      final MonitorFrame frame = instanceOverlay();
      final MonitorHitbox stop = boxFor(frame, 'im:stop')!;
      // card left 27 + border/pad 2 + row indent 2, chip width 4 + 4.
      expect(stop.row, 11);
      expect(stop.colStart, 31);
      expect(stop.colEnd, 39);
      final MonitorHitbox restart = boxFor(frame, 'im:restart')!;
      expect(restart.row, 11);
      expect(restart.colStart, 41);
      expect(restart.colEnd, 52);
    });

    test('emits the scrim before the buttons so the buttons win', () {
      final MonitorFrame frame = instanceOverlay();
      final int lastScrim = frame.hitboxes.lastIndexWhere(
        (MonitorHitbox box) => box.kind == MonitorHitKind.modalScrim,
      );
      final int firstButton = frame.hitboxes.indexWhere(
        (MonitorHitbox box) => box.kind == MonitorHitKind.button,
      );
      expect(firstButton, greaterThan(lastScrim));
    });
  });

  group('overlayModal instance actions', () {
    test('offers stop, restart and console while the instance runs', () {
      final Set<String> ids = buttonIds(instanceOverlay());
      expect(ids, containsAll(<String>['im:stop', 'im:restart', 'im:console']));
      expect(ids, isNot(contains('im:start')));
    });

    test('withholds update, factory reset and delete while it runs', () {
      final Set<String> ids = buttonIds(instanceOverlay());
      expect(ids, isNot(contains('im:update')));
      expect(ids, isNot(contains('im:factoryReset')));
      expect(ids, isNot(contains('im:delete')));
    });

    test('offers start, update, factory reset and delete when stopped', () {
      final Set<String> ids = buttonIds(
        instanceOverlay(state: RuntimeState.stopped),
      );
      expect(
        ids,
        containsAll(<String>[
          'im:start',
          'im:update',
          'im:factoryReset',
          'im:delete',
        ]),
      );
    });

    test('withholds restart and console when stopped', () {
      final Set<String> ids = buttonIds(
        instanceOverlay(state: RuntimeState.stopped),
      );
      expect(ids, isNot(contains('im:restart')));
      expect(ids, isNot(contains('im:console')));
      expect(ids, isNot(contains('im:stop')));
    });

    test('still renders the disabled chips it withholds', () {
      final List<String> rows = plainRows(
        instanceOverlay(state: RuntimeState.stopped),
      );
      expect(rows.join('\n'), contains('[ RESTART ]'));
      expect(rows.join('\n'), contains('[ CONSOLE ]'));
    });

    test('treats a mid-flight state as live, not stopped', () {
      for (final RuntimeState state in <RuntimeState>[
        RuntimeState.starting,
        RuntimeState.stopping,
        RuntimeState.restarting,
      ]) {
        final Set<String> ids = buttonIds(instanceOverlay(state: state));
        expect(ids, contains('im:stop'), reason: state.name);
        expect(ids, isNot(contains('im:start')), reason: state.name);
      }
    });

    test('treats an unsampled instance as stopped', () {
      final Set<String> ids = buttonIds(instanceOverlay(state: null));
      expect(ids, contains('im:start'));
      expect(ids, isNot(contains('im:stop')));
    });

    test('offers unlock and no destructive action while locked', () {
      final Set<String> ids = buttonIds(
        instanceOverlay(state: RuntimeState.stopped, locked: true),
      );
      expect(ids, contains('im:unlock'));
      expect(ids, isNot(contains('im:lock')));
      expect(ids, isNot(contains('im:factoryReset')));
      expect(ids, isNot(contains('im:delete')));
    });

    test('offers lock while unlocked', () {
      final Set<String> ids = buttonIds(
        instanceOverlay(state: RuntimeState.stopped),
      );
      expect(ids, contains('im:lock'));
      expect(ids, isNot(contains('im:unlock')));
    });

    test('offers share on an isolated instance and isolate on a shared one', () {
      final MonitorFrame isolatedFrame = instanceOverlay(isolated: true);
      expect(buttonIds(isolatedFrame), contains('im:shared'));
      expect(buttonIds(isolatedFrame), isNot(contains('im:isolated')));
      expect(plainRows(isolatedFrame).join('\n'), contains('[ SHARE ]'));

      final MonitorFrame sharedFrame = instanceOverlay();
      expect(buttonIds(sharedFrame), contains('im:isolated'));
      expect(buttonIds(sharedFrame), isNot(contains('im:shared')));
      expect(plainRows(sharedFrame).join('\n'), contains('[ ISOLATE ]'));
    });

    test('always offers set port, make active, motd and folder', () {
      for (final MonitorFrame frame in <MonitorFrame>[
        instanceOverlay(),
        instanceOverlay(state: RuntimeState.stopped),
        instanceOverlay(state: RuntimeState.stopped, locked: true),
        instanceOverlay(state: null),
      ]) {
        expect(
          buttonIds(frame),
          containsAll(<String>[
            'im:setPort',
            'im:makeActive',
            'im:motd',
            'im:folder',
          ]),
        );
      }
    });
  });

  group('overlayModal workspace actions', () {
    test('offers exactly the six workspace card actions', () {
      expect(buttonIds(workspaceOverlay()), <String>{
        'wm:buildTuning',
        'wm:pullBuilds',
        'wm:createMany',
        'wm:startAll',
        'wm:stopAll',
        'wm:wipe',
      });
    });

    test('never puts the bar-only new instance action on the card', () {
      final MonitorFrame frame = workspaceOverlay();
      expect(buttonIds(frame), isNot(contains('wm:newInstance')));
      expect(plainRows(frame).join('\n'), isNot(contains('NEW')));
    });
  });

  group('overlayModal tones', () {
    test('paints the destructive instance chips in the danger tone', () {
      final MonitorTheme theme = truecolor();
      final MonitorFrame frame = instanceOverlay(
        state: RuntimeState.stopped,
        theme: theme,
      );
      final int row = rowWith(frame, 'FACTORY RESET');
      expect(row, greaterThan(0));
      expect(frame.rows[row], contains(theme.danger));
      expect(frame.rows[row], contains('DELETE'));
    });

    test('paints the workspace wipe chip in the danger tone', () {
      final MonitorTheme theme = truecolor();
      final MonitorFrame frame = workspaceOverlay(theme: theme);
      final int row = rowWith(frame, 'WIPE');
      expect(row, greaterThan(0));
      expect(frame.rows[row], contains(theme.danger));
    });

    test('paints only the hovered chip row in the accent tone', () {
      final MonitorTheme theme = truecolor();
      final MonitorFrame frame = instanceOverlay(
        theme: theme,
        hoveredId: 'im:stop',
      );
      final int hovered = rowWith(frame, 'STOP');
      expect(frame.rows[hovered], contains(theme.accent));
      for (int index = 0; index < frame.rows.length; index++) {
        if (index == hovered) {
          continue;
        }
        expect(
          frame.rows[index],
          isNot(contains(theme.accent)),
          reason: 'row $index',
        );
      }
    });

    test('paints the pressed chip in the uniform press flash', () {
      final MonitorTheme theme = truecolor();
      final MonitorFrame frame = instanceOverlay(
        state: RuntimeState.stopped,
        theme: theme,
        pressedId: 'im:delete',
      );
      final int row = rowWith(frame, 'DELETE');
      expect(frame.rows[row], contains('${theme.bold}${theme.textStrong}'));
    });

    test('emits zero escape bytes under a colorless theme', () {
      for (final MonitorFrame frame in <MonitorFrame>[
        instanceOverlay(state: RuntimeState.stopped, hoveredId: 'im:delete'),
        workspaceOverlay(pressedId: 'wm:wipe'),
      ]) {
        for (final String row in frame.rows) {
          expect(Ansi.strip(row), row);
        }
      }
    });
  });

  group('overlayModal clamping', () {
    test('narrows the card to eight columns short of the frame', () {
      final MonitorFrame frame = instanceOverlay(columns: 40);
      // 40 - 8 = 32 wide, centered at column 4.
      expect(plainRows(frame)[10].substring(4, 36), startsWith('┌─ alpha '));
      for (final String row in frame.rows) {
        expect(Ansi.visibleLength(row), 40);
      }
    });

    test('spends the whole frame width when the inset card is too narrow', () {
      final MonitorFrame frame = instanceOverlay(columns: 28);
      expect(plainRows(frame)[10], startsWith('┌─ alpha '));
      for (final String row in frame.rows) {
        expect(Ansi.visibleLength(row), 28);
      }
    });

    test('drops button rows from the bottom when the frame is short', () {
      final MonitorFrame frame = instanceOverlay(lines: 6);
      expect(frame.rows.length, 6);
      expect(
        buttonIds(frame),
        containsAll(<String>['im:stop', 'im:restart', 'im:console']),
      );
      expect(buttonIds(frame), isNot(contains('im:folder')));
      expect(rowWith(frame, 'esc closes'), 4);
    });

    test('keeps the first button row at the smallest workable height', () {
      final MonitorFrame frame = instanceOverlay(lines: 4);
      expect(frame.rows.length, 4);
      expect(buttonIds(frame), contains('im:stop'));
      expect(buttonIds(frame), isNot(contains('im:console')));
      expect(rowWith(frame, 'esc closes'), 2);
    });

    test('drops the esc hint before it drops the last button row', () {
      final MonitorFrame frame = instanceOverlay(lines: 3);
      expect(frame.rows.length, 3);
      expect(buttonIds(frame), contains('im:stop'));
      expect(rowWith(frame, 'esc closes'), -1);
    });

    test('holds the frame invariants at absurd sizes', () {
      for (final List<int> size in <List<int>>[
        <int>[1, 1],
        <int>[2, 2],
        <int>[10, 3],
        <int>[80, 24],
      ]) {
        final MonitorFrame frame = instanceOverlay(
          columns: size[0],
          lines: size[1],
        );
        expect(frame.rows.length, size[1], reason: '${size[0]}x${size[1]}');
        for (final String row in frame.rows) {
          expect(
            Ansi.visibleLength(row),
            size[0],
            reason: '${size[0]}x${size[1]}',
          );
        }
        for (final MonitorHitbox box in frame.hitboxes) {
          expect(box.row, lessThan(size[1]));
          expect(box.colEnd, lessThanOrEqualTo(size[0]));
        }
      }
    });
  });
}
