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
  bool remote = false,
  String? operationBlockReason,
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
  remote: remote,
  operationBlockReason: operationBlockReason,
  theme: theme ?? MonitorTheme.plain(),
  hoveredId: hoveredId,
  pressedId: pressedId,
  columns: columns,
  lines: lines,
);

/// Renders a workspace modal over a default base frame.
MonitorFrame workspaceOverlay({
  bool remote = false,
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
  remote: remote,
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
    test('names every Local and Remote instance action', () {
      expect(InstanceModalAction.values, <InstanceModalAction>[
        InstanceModalAction.start,
        InstanceModalAction.stop,
        InstanceModalAction.restart,
        InstanceModalAction.console,
        InstanceModalAction.pullToLocal,
        InstanceModalAction.pushToRemote,
        InstanceModalAction.settings,
        InstanceModalAction.history,
        InstanceModalAction.reinstall,
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

    test('every hit id parses back to the action that emitted it', () {
      for (final InstanceModalAction action in InstanceModalAction.values) {
        expect(
          instanceModalActionForId(instanceModalHitId(action)),
          action,
          reason: action.name,
        );
      }
    });

    test('an id from anywhere else parses to null', () {
      expect(instanceModalActionForId('wm:wipe'), isNull);
      expect(instanceModalActionForId('server:alpha'), isNull);
      expect(instanceModalActionForId('act:start'), isNull);
      expect(instanceModalActionForId('start'), isNull);
      expect(instanceModalActionForId('im:'), isNull);
      expect(instanceModalActionForId('im:bogus'), isNull);
      expect(instanceModalActionForId(''), isNull);
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
        WorkspaceModalAction.connect,
        WorkspaceModalAction.files,
        WorkspaceModalAction.bulkActions,
      ]);
    });

    test('hit ids are the action name behind the workspace-modal prefix', () {
      expect(workspaceModalHitPrefix, 'wm:');
      expect(workspaceModalHitId(WorkspaceModalAction.stopAll), 'wm:stopAll');
    });

    test('every hit id parses back to the action that emitted it', () {
      for (final WorkspaceModalAction action in WorkspaceModalAction.values) {
        expect(
          workspaceModalActionForId(workspaceModalHitId(action)),
          action,
          reason: action.name,
        );
      }
    });

    test('an id from anywhere else parses to null', () {
      expect(workspaceModalActionForId('im:start'), isNull);
      expect(workspaceModalActionForId('ws:new'), isNull);
      expect(workspaceModalActionForId('wipe'), isNull);
      expect(workspaceModalActionForId('wm:'), isNull);
      expect(workspaceModalActionForId('wm:bogus'), isNull);
      expect(workspaceModalActionForId(''), isNull);
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
      // 46 wide over 100 columns, 10 rows over 30 lines.
      expect(plainRows(frame)[10].substring(27, 73), startsWith('┌─ alpha '));
      expect(plainRows(frame)[19].substring(27, 73), startsWith('└'));
      expect(plainRows(frame)[19][72], '┘');
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
      for (final int index in <int>[0, 5, 9, 20, 25, 29]) {
        expect(frame.rows[index], base.rows[index], reason: 'row $index');
      }
    });

    test('keeps the base text left of the card on every card row', () {
      final MonitorFrame base = baseFrame();
      final MonitorFrame frame = instanceOverlay();
      for (int index = 10; index <= 19; index++) {
        expect(
          plainRows(frame)[index].substring(0, 27),
          Ansi.strip(base.rows[index]).substring(0, 27),
          reason: 'row $index',
        );
      }
    });

    test('blanks the base text right of the card on every card row', () {
      final MonitorFrame frame = instanceOverlay();
      for (int index = 10; index <= 19; index++) {
        expect(
          plainRows(frame)[index].substring(73),
          ' ' * 27,
          reason: 'row $index',
        );
      }
    });

    test('draws the esc hint on the row just inside the bottom border', () {
      final MonitorFrame frame = instanceOverlay();
      expect(plainRows(frame)[18], contains('esc closes'));
      expect(rowWith(frame, 'esc closes'), 18);
    });

    test('badges the instance card with the sampled state', () {
      final MonitorFrame frame = instanceOverlay(state: RuntimeState.stopped);
      expect(plainRows(frame)[10], contains('stopped'));
    });

    test('badges an unsampled instance as having no data', () {
      final MonitorFrame frame = instanceOverlay(state: null);
      expect(plainRows(frame)[10], contains('no data'));
    });

    test('centers the workspace card over its own smaller height', () {
      final MonitorFrame frame = workspaceOverlay();
      // 6 rows over 30 lines.
      expect(
        plainRows(frame)[12].substring(27, 73),
        startsWith('┌─ WORKSPACE'),
      );
      expect(plainRows(frame)[17][72], '┘');
      expect(rowWith(frame, 'esc closes'), 16);
    });
  });

  group('overlayModal hitboxes', () {
    test('lays a full-width scrim over every row of the frame', () {
      final MonitorFrame frame = instanceOverlay();
      final List<MonitorHitbox> scrim = frame.hitboxes
          .where((MonitorHitbox box) => box.id == modalScrimHitId)
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
      expect(
        hitTest(frame.hitboxes, row: stop.row, col: stop.colEnd),
        isNot('im:stop'),
      );
    });

    test('hit-tests Local push and Remote pull as complete buttons', () {
      final MonitorFrame local = instanceOverlay(state: RuntimeState.stopped);
      final MonitorHitbox push = boxFor(local, 'im:pushToRemote')!;
      expect(
        hitTest(local.hitboxes, row: push.row, col: push.colStart),
        'im:pushToRemote',
      );
      expect(
        hitTest(local.hitboxes, row: push.row, col: push.colEnd - 1),
        'im:pushToRemote',
      );

      final MonitorFrame remote = instanceOverlay(
        remote: true,
        state: RuntimeState.stopped,
      );
      final MonitorHitbox pull = boxFor(remote, 'im:pullToLocal')!;
      expect(
        hitTest(remote.hitboxes, row: pull.row, col: pull.colStart),
        'im:pullToLocal',
      );
      expect(
        hitTest(remote.hitboxes, row: pull.row, col: pull.colEnd - 1),
        'im:pullToLocal',
      );
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

    test('emits scrim, then card, then buttons so the topmost layer wins', () {
      final MonitorFrame frame = instanceOverlay();
      final int lastScrim = frame.hitboxes.lastIndexWhere(
        (MonitorHitbox box) => box.id == modalScrimHitId,
      );
      final int firstCard = frame.hitboxes.indexWhere(
        (MonitorHitbox box) => box.id == modalCardHitId,
      );
      final int lastCard = frame.hitboxes.lastIndexWhere(
        (MonitorHitbox box) => box.id == modalCardHitId,
      );
      final int firstButton = frame.hitboxes.indexWhere(
        (MonitorHitbox box) => box.kind == MonitorHitKind.button,
      );
      expect(firstCard, greaterThan(lastScrim));
      expect(firstButton, greaterThan(lastCard));
    });

    test('covers the card rectangle with a no-op card hitbox', () {
      final MonitorFrame frame = instanceOverlay();
      final List<MonitorHitbox> cardBoxes = frame.hitboxes
          .where((MonitorHitbox box) => box.id == modalCardHitId)
          .toList();
      expect(cardBoxes.length, 10);
      for (final MonitorHitbox box in cardBoxes) {
        expect(box.kind, MonitorHitKind.modalScrim);
        expect(box.colStart, 27);
        expect(box.colEnd, 73);
      }
      expect(cardBoxes.map((MonitorHitbox box) => box.row).toSet(), <int>{
        for (int index = 10; index <= 19; index++) index,
      });
    });

    test('hit-tests the card border, title and padding as the card', () {
      final MonitorFrame frame = instanceOverlay();
      // Top-left corner, the inlaid title, and a chip row's left padding.
      expect(hitTest(frame.hitboxes, row: 10, col: 27), modalCardHitId);
      expect(hitTest(frame.hitboxes, row: 10, col: 31), modalCardHitId);
      expect(hitTest(frame.hitboxes, row: 11, col: 28), modalCardHitId);
      // The gap between the two chips, and the bottom border.
      expect(hitTest(frame.hitboxes, row: 11, col: 39), modalCardHitId);
      expect(hitTest(frame.hitboxes, row: 19, col: 72), modalCardHitId);
    });

    test('hit-tests just past the card edges as the scrim', () {
      final MonitorFrame frame = instanceOverlay();
      expect(hitTest(frame.hitboxes, row: 10, col: 26), modalScrimHitId);
      expect(hitTest(frame.hitboxes, row: 10, col: 73), modalScrimHitId);
      expect(hitTest(frame.hitboxes, row: 9, col: 40), modalScrimHitId);
      expect(hitTest(frame.hitboxes, row: 20, col: 40), modalScrimHitId);
    });
  });

  group('overlayModal instance actions', () {
    test('blocks runtime controls but keeps remote management available', () {
      final MonitorFrame frame = instanceOverlay(
        remote: true,
        operationBlockReason: 'node is under maintenance',
      );
      final String text = plainRows(frame).join('\n');

      expect(text, contains('BLOCKED'));
      expect(text, contains('node is under maintenance'));
      expect(text, contains('[ STOP ]'));
      expect(text, contains('[ RESTART ]'));
      expect(text, contains('[ CONSOLE ]'));
      expect(
        buttonIds(frame),
        isNot(containsAll(<String>['im:stop', 'im:restart', 'im:console'])),
      );
      expect(
        buttonIds(frame),
        containsAll(<String>[
          'im:settings',
          'im:history',
          'im:folder',
          'im:reinstall',
          'im:delete',
        ]),
      );
    });

    test(
      'offers remote lifecycle, history, settings, and local drive access',
      () {
        final MonitorFrame frame = instanceOverlay(remote: true);
        expect(
          buttonIds(frame),
          containsAll(<String>[
            'im:stop',
            'im:restart',
            'im:console',
            'im:settings',
            'im:history',
            'im:folder',
            'im:reinstall',
            'im:delete',
          ]),
        );
        final String text = plainRows(frame).join('\n');
        for (final String label in <String>[
          'SETTINGS',
          'HISTORY',
          'PULL TO LOCAL',
          'OPEN FOLDER',
          'REINSTALL',
          'DELETE',
        ]) {
          expect(text, contains('[ $label ]'));
        }
        expect(buttonIds(frame), isNot(contains('im:pullToLocal')));
      },
    );

    test('keeps remote settings, history and destruction while stopped', () {
      final Set<String> ids = buttonIds(
        instanceOverlay(remote: true, state: RuntimeState.stopped),
      );
      expect(ids, contains('im:start'));
      expect(ids, isNot(contains('im:console')));
      expect(
        ids,
        containsAll(<String>[
          'im:settings',
          'im:history',
          'im:pullToLocal',
          'im:folder',
          'im:reinstall',
          'im:delete',
        ]),
      );
    });

    test('withholds Remote pull while stopped operations are blocked', () {
      final MonitorFrame frame = instanceOverlay(
        remote: true,
        state: RuntimeState.stopped,
        operationBlockReason: 'server installation is incomplete',
      );

      expect(buttonIds(frame), isNot(contains('im:pullToLocal')));
      expect(plainRows(frame).join('\n'), contains('[ PULL TO LOCAL ]'));
    });

    test('withholds Remote pull from every sampled live state', () {
      for (final RuntimeState state in <RuntimeState>[
        RuntimeState.running,
        RuntimeState.starting,
        RuntimeState.stopping,
        RuntimeState.restarting,
      ]) {
        final MonitorFrame frame = instanceOverlay(remote: true, state: state);
        expect(
          buttonIds(frame),
          isNot(contains('im:pullToLocal')),
          reason: state.name,
        );
        expect(
          plainRows(frame).join('\n'),
          contains('[ PULL TO LOCAL ]'),
          reason: state.name,
        );
      }
    });

    test('offers stop, restart and console while the instance runs', () {
      final Set<String> ids = buttonIds(instanceOverlay());
      expect(ids, containsAll(<String>['im:stop', 'im:restart', 'im:console']));
      expect(ids, isNot(contains('im:start')));
    });

    test('withholds push, update, factory reset and delete while it runs', () {
      final Set<String> ids = buttonIds(instanceOverlay());
      expect(ids, isNot(contains('im:pushToRemote')));
      expect(ids, isNot(contains('im:update')));
      expect(ids, isNot(contains('im:factoryReset')));
      expect(ids, isNot(contains('im:delete')));
    });

    test(
      'offers push, start, update, factory reset and delete when stopped',
      () {
        final Set<String> ids = buttonIds(
          instanceOverlay(state: RuntimeState.stopped),
        );
        expect(
          ids,
          containsAll(<String>[
            'im:start',
            'im:pushToRemote',
            'im:update',
            'im:factoryReset',
            'im:delete',
          ]),
        );
      },
    );

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

    test(
      'offers share on an isolated instance and isolate on a shared one',
      () {
        final MonitorFrame isolatedFrame = instanceOverlay(isolated: true);
        expect(buttonIds(isolatedFrame), contains('im:shared'));
        expect(buttonIds(isolatedFrame), isNot(contains('im:isolated')));
        expect(plainRows(isolatedFrame).join('\n'), contains('[ SHARE ]'));

        final MonitorFrame sharedFrame = instanceOverlay();
        expect(buttonIds(sharedFrame), contains('im:isolated'));
        expect(buttonIds(sharedFrame), isNot(contains('im:shared')));
        expect(plainRows(sharedFrame).join('\n'), contains('[ ISOLATE ]'));
      },
    );

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

    test('offers account, files, create-many, and bulk actions remotely', () {
      final MonitorFrame frame = workspaceOverlay(remote: true);
      expect(buttonIds(frame), <String>{
        'wm:connect',
        'wm:files',
        'wm:createMany',
        'wm:bulkActions',
      });
      final String text = plainRows(frame).join('\n');
      expect(text, contains('[ CONNECTION ]'));
      expect(text, contains('[ FILES ]'));
      expect(text, contains('[ CREATE MANY ]'));
      expect(text, contains('[ BULK ACTIONS ]'));
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
      final MonitorFrame frame = instanceOverlay(columns: 50);
      // 50 - 8 = 42 wide, centered at column 4.
      expect(plainRows(frame)[10].substring(4, 46), startsWith('┌─ alpha '));
      expect(plainRows(frame)[19][45], '┘');
      for (final String row in frame.rows) {
        expect(Ansi.visibleLength(row), 50);
      }
    });

    test('spends the whole frame width when the inset card is too narrow', () {
      final MonitorFrame frame = instanceOverlay(columns: 28);
      expect(plainRows(frame)[10], startsWith('┌─ alpha '));
      for (final String row in frame.rows) {
        expect(Ansi.visibleLength(row), 28);
      }
    });

    test('never trades a chip away for the eight-column inset', () {
      // The inset would leave 32 columns, one short of what the destructive
      // row needs, so the card takes the whole frame rather than drop DELETE.
      final MonitorFrame frame = instanceOverlay(
        state: RuntimeState.stopped,
        columns: 40,
      );
      final String text = plainRows(frame).join('\n');
      expect(text, contains('[ FACTORY RESET ]'));
      expect(text, contains('[ DELETE ]'));
      expect(
        buttonIds(frame),
        containsAll(<String>['im:factoryReset', 'im:delete']),
      );
    });

    test('renders every enabled instance chip at the content floor', () {
      // 35 columns is exactly what the widest row (FACTORY RESET + DELETE)
      // needs once the card's own border and padding are paid for.
      final MonitorFrame frame = instanceOverlay(
        state: RuntimeState.stopped,
        columns: 35,
      );
      expect(Ansi.visibleLength(frame.rows[10]), 35);
      expect(buttonIds(frame), <String>{
        'im:start',
        'im:setPort',
        'im:pushToRemote',
        'im:makeActive',
        'im:motd',
        'im:lock',
        'im:isolated',
        'im:folder',
        'im:update',
        'im:factoryReset',
        'im:delete',
      });
      for (final String label in <String>[
        '[ START ]',
        '[ RESTART ]',
        '[ CONSOLE ]',
        '[ SET PORT ]',
        '[ PUSH TO REMOTE ]',
        '[ MAKE ACTIVE ]',
        '[ MOTD ]',
        '[ LOCK ]',
        '[ ISOLATE ]',
        '[ FOLDER ]',
        '[ UPDATE ]',
        '[ FACTORY RESET ]',
        '[ DELETE ]',
      ]) {
        expect(plainRows(frame).join('\n'), contains(label), reason: label);
      }
    });

    test('renders every workspace chip at the content floor', () {
      // BUILD & TUNING + PULL BUILDS is the widest workspace row: 41 columns.
      final MonitorFrame frame = workspaceOverlay(columns: 41);
      expect(Ansi.visibleLength(frame.rows[12]), 41);
      expect(buttonIds(frame), <String>{
        'wm:buildTuning',
        'wm:pullBuilds',
        'wm:createMany',
        'wm:startAll',
        'wm:stopAll',
        'wm:wipe',
      });
    });

    test('keeps transfer actions usable in a 24-column modal', () {
      final MonitorFrame local = instanceOverlay(
        state: RuntimeState.stopped,
        columns: 24,
      );
      expect(buttonIds(local), contains('im:pushToRemote'));
      expect(plainRows(local).join('\n'), contains('[ PUSH TO REMOTE ]'));

      final MonitorFrame remote = instanceOverlay(
        remote: true,
        state: RuntimeState.stopped,
        columns: 24,
      );
      expect(buttonIds(remote), contains('im:pullToLocal'));
      expect(plainRows(remote).join('\n'), contains('[ PULL TO LOCAL ]'));
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
