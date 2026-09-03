import 'package:multiplexor/services/instance_bulk.dart';
import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_selection.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

void main() {
  group('MonitorSelection', () {
    test('an empty selection never targets the fleet', () {
      final MonitorSelection selection = MonitorSelection();
      final MonitorSnapshot snapshot = _snapshot(<String>['alpha', 'beta']);

      selection.reconcile(snapshot);

      expect(selection.isEmpty, isTrue);
      expect(selection.checked, isEmpty);
      expect(selection.targets(snapshot), isEmpty);
    });

    test('toggles stable IDs rather than shared display names', () {
      final MonitorSelection selection = MonitorSelection();
      final MonitorSnapshot snapshot = _snapshot(
        <String>['remote-1', 'remote-2'],
        view: MonitorView.remote,
        displayNames: <String, String>{
          'remote-1': 'Survival',
          'remote-2': 'Survival',
        },
      );

      selection.toggle('remote-2', snapshot);
      selection.toggle('Survival', snapshot);

      expect(selection.checked, <String>{'remote-2'});
      expect(selection.targets(snapshot), <String>['remote-2']);
      selection.toggle('remote-2', snapshot);
      expect(selection.isEmpty, isTrue);
    });

    test('retains identities across reordering and telemetry updates', () {
      final MonitorSelection selection = MonitorSelection();
      final MonitorSnapshot original = _snapshot(
        <String>['alpha', 'beta'],
        states: <String, RuntimeState>{'beta': RuntimeState.stopped},
      );
      selection.toggle('beta', original);
      final MonitorSnapshot refreshed = _snapshot(
        <String>['beta', 'alpha'],
        states: <String, RuntimeState>{'beta': RuntimeState.running},
        displayNames: <String, String>{'beta': 'Renamed server'},
        active: 'alpha',
      );

      selection.reconcile(refreshed);

      expect(selection.checked, <String>{'beta'});
      expect(selection.targets(refreshed), <String>['beta']);
    });

    test(
      'prunes removed IDs without selecting replacements or returning IDs',
      () {
        final MonitorSelection selection = MonitorSelection();
        selection.toggleAll(_snapshot(<String>['alpha', 'beta']));

        selection.reconcile(_snapshot(<String>['beta', 'replacement']));
        expect(selection.checked, <String>{'beta'});

        final MonitorSnapshot returned = _snapshot(<String>[
          'alpha',
          'beta',
          'replacement',
        ]);
        selection.reconcile(returned);
        expect(selection.targets(returned), <String>['beta']);
      },
    );

    test('select all selects current IDs and a second toggle clears them', () {
      final MonitorSelection selection = MonitorSelection();
      final MonitorSnapshot initial = _snapshot(<String>['alpha', 'beta']);
      selection.toggle('beta', initial);
      selection.toggleAll(initial);
      expect(selection.checked, <String>{'alpha', 'beta'});

      final MonitorSnapshot expanded = _snapshot(<String>[
        'alpha',
        'beta',
        'gamma',
      ]);
      selection.reconcile(expanded);
      expect(selection.checked, <String>{'alpha', 'beta'});
      selection.toggleAll(expanded);
      expect(selection.checked, <String>{'alpha', 'beta', 'gamma'});
      selection.toggleAll(expanded);
      expect(selection.targets(expanded), isEmpty);
    });

    test('empty fleet and unknown IDs leave the selection empty', () {
      final MonitorSelection selection = MonitorSelection();
      final MonitorSnapshot snapshot = _snapshot(const <String>[]);

      selection.toggleAll(snapshot);
      selection.toggle('missing', snapshot);

      expect(selection.checked, isEmpty);
      expect(selection.targets(snapshot), isEmpty);
    });

    test('consumer changes clear matching IDs from the previous consumer', () {
      final MonitorSelection selection = MonitorSelection();
      selection.toggle('shared-name', _snapshot(<String>['shared-name']));
      final MonitorSnapshot next = _snapshot(<String>[
        'shared-name',
      ], consumer: 'fabric');

      selection.reconcile(next);

      expect(selection.targets(next), isEmpty);
    });

    test('provider changes clear matching IDs even with the same consumer', () {
      final MonitorSelection selection = MonitorSelection();
      selection.toggle('same-id', _snapshot(<String>['same-id']));
      final MonitorSnapshot remote = _snapshot(<String>[
        'same-id',
      ], view: MonitorView.remote);

      selection.reconcile(remote);
      expect(selection.targets(remote), isEmpty);
      selection.toggle('same-id', remote);
      expect(selection.targets(_snapshot(<String>['same-id'])), isEmpty);
    });

    test(
      'changing the remote connection clears previous remote identities',
      () {
        final MonitorSelection selection = MonitorSelection();
        selection.toggle(
          'server-id',
          _snapshot(
            <String>['server-id'],
            view: MonitorView.remote,
            consumer: 'A',
          ),
        );

        expect(
          selection.targets(
            _snapshot(
              <String>['server-id'],
              view: MonitorView.remote,
              consumer: 'B',
            ),
          ),
          isEmpty,
        );
      },
    );

    test('target lists are immutable snapshots in current display order', () {
      final MonitorSelection selection = MonitorSelection();
      final List<String> instances = <String>['alpha', 'beta'];
      final MonitorSnapshot snapshot = _snapshot(instances);
      selection.toggle('beta', snapshot);
      selection.toggle('alpha', snapshot);
      final List<String> targets = selection.targets(snapshot);
      final Set<String> checked = selection.checked;

      expect(targets, <String>['alpha', 'beta']);
      expect(() => targets.add('unselected'), throwsUnsupportedError);
      expect(() => checked.add('unselected'), throwsUnsupportedError);
      selection.clear();
      instances.clear();

      expect(targets, <String>['alpha', 'beta']);
      expect(checked, <String>{'alpha', 'beta'});
      expect(selection.targets(snapshot), isEmpty);
    });

    test(
      'targets reconciles stale IDs before returning an action snapshot',
      () {
        final MonitorSelection selection = MonitorSelection();
        selection.toggleAll(_snapshot(<String>['gone', 'retained']));

        expect(
          selection.targets(_snapshot(<String>['new', 'retained'])),
          <String>['retained'],
        );
        expect(selection.targets(_snapshot(<String>['new'])), isEmpty);
        expect(selection.checked, isEmpty);
      },
    );
  });

  group('monitorBulkEligible', () {
    for (final ({RuntimeState? state, Set<InstanceBulkAction> eligible}) example
        in <({RuntimeState? state, Set<InstanceBulkAction> eligible})>[
          (state: null, eligible: <InstanceBulkAction>{}),
          (
            state: RuntimeState.stopped,
            eligible: <InstanceBulkAction>{InstanceBulkAction.start},
          ),
          (
            state: RuntimeState.starting,
            eligible: <InstanceBulkAction>{InstanceBulkAction.stop},
          ),
          (
            state: RuntimeState.running,
            eligible: <InstanceBulkAction>{
              InstanceBulkAction.stop,
              InstanceBulkAction.restart,
            },
          ),
          (
            state: RuntimeState.stopping,
            eligible: <InstanceBulkAction>{InstanceBulkAction.stop},
          ),
          (
            state: RuntimeState.restarting,
            eligible: <InstanceBulkAction>{InstanceBulkAction.stop},
          ),
        ]) {
      test(
        'power actions require the matching known ${example.state?.name ?? 'unknown'} state',
        () {
          final MonitorSnapshot snapshot = _snapshot(
            <String>['server'],
            states: <String, RuntimeState>{'server': ?example.state},
          );
          for (final InstanceBulkAction action in _powerActions) {
            expect(
              monitorBulkEligible(snapshot, 'server', action),
              example.eligible.contains(action),
              reason: action.name,
            );
          }
        },
      );
    }

    test('a removed ID is ineligible even if stale history still exists', () {
      final MonitorSnapshot snapshot = _snapshot(
        const <String>[],
        states: <String, RuntimeState>{'gone': RuntimeState.running},
      );

      for (final InstanceBulkAction action in InstanceBulkAction.values) {
        expect(monitorBulkEligible(snapshot, 'gone', action), isFalse);
      }
    });

    test('local delete respects locks independently of lifecycle state', () {
      final MonitorSnapshot snapshot = _snapshot(
        <String>['locked', 'unlocked'],
        states: <String, RuntimeState>{
          'locked': RuntimeState.running,
          'unlocked': RuntimeState.running,
        },
        flags: <String, InstanceFlags>{
          'locked': const InstanceFlags(locked: true, isolated: false),
          'unlocked': const InstanceFlags(locked: false, isolated: true),
        },
      );

      expect(
        monitorBulkEligible(snapshot, 'locked', InstanceBulkAction.delete),
        isFalse,
      );
      expect(
        monitorBulkEligible(snapshot, 'unlocked', InstanceBulkAction.delete),
        isTrue,
      );
      expect(
        monitorBulkEligible(snapshot, 'locked', InstanceBulkAction.stop),
        isTrue,
      );
    });

    test('operation blocks disable power without disabling remote delete', () {
      final MonitorSnapshot snapshot = _snapshot(
        <String>['stopped', 'running', 'unknown'],
        view: MonitorView.remote,
        states: <String, RuntimeState>{
          'stopped': RuntimeState.stopped,
          'running': RuntimeState.running,
        },
        blocked: <String, String>{
          'stopped': 'Installation incomplete',
          'running': 'Node under maintenance',
          'unknown': 'Power unavailable',
        },
      );

      for (final String id in snapshot.instances) {
        for (final InstanceBulkAction action in _powerActions) {
          expect(monitorBulkEligible(snapshot, id, action), isFalse);
        }
        expect(
          monitorBulkEligible(snapshot, id, InstanceBulkAction.delete),
          isTrue,
        );
      }
    });
  });
}

const List<InstanceBulkAction> _powerActions = <InstanceBulkAction>[
  InstanceBulkAction.start,
  InstanceBulkAction.stop,
  InstanceBulkAction.restart,
];

MonitorSnapshot _snapshot(
  List<String> instances, {
  MonitorView view = MonitorView.local,
  String consumer = 'plugin',
  String? active,
  Map<String, RuntimeState> states = const <String, RuntimeState>{},
  Map<String, InstanceFlags> flags = const <String, InstanceFlags>{},
  Map<String, String> displayNames = const <String, String>{},
  Map<String, String> blocked = const <String, String>{},
}) => MonitorSnapshot(
  instances: instances,
  consumerName: consumer,
  view: view,
  activeInstance: active,
  flags: flags,
  displayNames: displayNames,
  operationBlockReasons: blocked,
  history: <String, List<MetricSample>>{
    for (final MapEntry<String, RuntimeState> entry in states.entries)
      entry.key: <MetricSample>[
        MetricSample(
          ts: DateTime.utc(2026, 9, 2),
          instance: entry.key,
          state: entry.value,
        ),
      ],
  },
);
