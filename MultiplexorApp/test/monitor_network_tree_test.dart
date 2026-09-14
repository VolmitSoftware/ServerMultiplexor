import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/monitor/monitor_network_tree.dart';
import 'package:multiplexor/services/monitor/monitor_selection.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

const List<MonitorNetworkGroup> groups = <MonitorNetworkGroup>[
  MonitorNetworkGroup(
    name: 'dev',
    proxy: 'dev-proxy',
    port: 25565,
    members: <MonitorNetworkMember>[
      MonitorNetworkMember(instance: 'lobby', alias: 'hub', port: 25566),
      MonitorNetworkMember(
        instance: 'survival',
        alias: 'survival',
        port: 25567,
      ),
    ],
  ),
  MonitorNetworkGroup(
    name: 'test',
    proxy: 'test-proxy',
    port: 25600,
    members: <MonitorNetworkMember>[
      MonitorNetworkMember(instance: 'games', alias: 'games', port: 25601),
    ],
  ),
];

const List<String> unsorted = <String>[
  'standalone',
  'lobby',
  'games',
  'survival',
  'test-proxy',
  'dev-proxy',
];
final DateTime now = DateTime.utc(2026, 9, 14);

MonitorSnapshot snapshot(MonitorNetworkTree tree) => MonitorSnapshot(
  instances: tree.instances,
  history: <String, List<MetricSample>>{
    for (final String instance in tree.instances)
      instance: <MetricSample>[
        MetricSample(
          ts: now,
          instance: instance,
          state: instance == 'survival'
              ? RuntimeState.starting
              : RuntimeState.stopped,
          port: instance == 'standalone' ? 25590 : null,
        ),
      ],
  },
  consumerName: 'plugin',
  networkRows: tree.rows,
  activeInstance: 'lobby',
);

MonitorFrame frame(
  MonitorSnapshot state,
  int selected, {
  int columns = 100,
  int lines = 32,
  MonitorTheme? theme,
}) => buildMonitorFrame(
  snapshot: state,
  selectedIndex: selected,
  frame: -1,
  columns: columns,
  lines: lines,
  theme: theme ?? MonitorTheme.plain(),
  range: const Duration(minutes: 15),
  now: now,
  clockNow: now,
);

void main() {
  test(
    'networks group each proxy and its members without duplicate instances',
    () {
      final MonitorNetworkTree tree = MonitorNetworkTree.project(
        unsorted,
        groups,
      );
      expect(tree.instances, <String>[
        'standalone',
        'dev-proxy',
        'lobby',
        'survival',
        'test-proxy',
        'games',
      ]);
      expect(tree.instances.toSet(), unsorted.toSet());
      expect(tree.rows['dev-proxy']!.isProxy, isTrue);
      expect(tree.rows['lobby']!.lastChild, isFalse);
      expect(tree.rows['survival']!.lastChild, isTrue);
      expect(tree.rows['games']!.lastChild, isTrue);
      expect(tree.rows['lobby']!.alias, 'hub');
      expect(tree.rows['dev-proxy']!.port, 25565);
      expect(tree.rows['lobby']!.port, 25566);
    },
  );

  test('missing or repeated metadata never hides or invents an instance', () {
    final MonitorNetworkTree missing = MonitorNetworkTree.project(
      const <String>['lobby', 'standalone'],
      groups,
    );
    expect(missing.instances, <String>['lobby', 'standalone']);
    expect(missing.rows, isEmpty);
    final MonitorNetworkTree duplicates = MonitorNetworkTree.project(
      unsorted,
      <MonitorNetworkGroup>[...groups, ...groups],
    );
    expect(duplicates.instances.toSet(), unsorted.toSet());
    expect(duplicates.instances.length, unsorted.length);
  });

  test('tree rows show network names, branches, ports and distinct states', () {
    final MonitorSnapshot state = snapshot(
      MonitorNetworkTree.project(unsorted, groups),
    );
    final MonitorFrame rendered = frame(state, 2);
    final List<String> rows = rendered.rows.map(Ansi.strip).toList();
    final Map<String, String> serverRows = <String, String>{
      for (final MonitorHitbox hit in rendered.hitboxes)
        if (hit.kind == MonitorHitKind.serverRow)
          hit.id.substring(serverHitPrefix.length): rows[hit.row],
    };
    expect(serverRows.keys.toList(), state.instances);
    expect(serverRows['dev-proxy'], contains('Velocity / dev'));
    expect(serverRows['dev-proxy'], contains('25565'));
    expect(serverRows['lobby'], contains('├─ lobby (hub)'));
    expect(serverRows['lobby'], contains('25566'));
    expect(serverRows['lobby'], contains('*'));
    expect(serverRows['survival'], contains('└─ survival'));
    expect(serverRows['survival'], contains('starting'));
    expect(serverRows['survival'], contains('25567'));
    expect(serverRows['test-proxy'], contains('Velocity / test'));
    expect(serverRows['games'], contains('└─ games'));
    expect(serverRows['games'], contains('25601'));
    expect(serverRows['standalone'], contains('standalone'));
    expect(serverRows['standalone'], contains('25590'));
    expect(
      rows.join('\n'),
      contains('NETWORK dev · via dev-proxy · hub:25566'),
    );
  });

  test(
    'ASCII trees retain working row identities and width at every selection',
    () {
      final MonitorSnapshot state = snapshot(
        MonitorNetworkTree.project(unsorted, groups),
      );
      for (int selected = 0; selected < state.instances.length; selected++) {
        final MonitorFrame rendered = frame(
          state,
          selected,
          columns: 80,
          lines: 24,
          theme: MonitorTheme.plainAscii(),
        );
        expect(rendered.rows, hasLength(24));
        for (final String row in rendered.rows) {
          expect(Ansi.visibleLength(row), 80);
          expect(row, isNot(contains('├─')));
          expect(row, isNot(contains('└─')));
        }
        final MonitorHitbox selectedHit = rendered.hitboxes.firstWhere(
          (MonitorHitbox hit) =>
              hit.id == '$serverHitPrefix${state.instances[selected]}',
        );
        final MonitorNetworkRow? member =
            state.networkRows[state.instances[selected]];
        if (member != null) {
          expect(rendered.rows[selectedHit.row], contains('${member.port}'));
        }
      }
    },
  );

  test('focus and checked identities survive regrouping', () {
    final MonitorNetworkTree tree = MonitorNetworkTree.project(
      unsorted,
      groups,
    );
    expect(
      reconcileMonitorFocus(
        previous: unsorted,
        next: tree.instances,
        selectedIndex: 1,
      ),
      2,
    );
    final MonitorSelection checked = MonitorSelection();
    final MonitorSnapshot before = snapshot(
      MonitorNetworkTree(instances: unsorted, rows: const {}),
    );
    checked.toggle('lobby', before);
    checked.toggle('games', before);
    final MonitorSnapshot after = snapshot(tree);
    checked.reconcile(after);
    expect(checked.targets(after), <String>['lobby', 'games']);
    expect(
      reconcileMonitorFocus(
        previous: tree.instances,
        next: const [],
        selectedIndex: 2,
      ),
      0,
    );
    expect(
      reconcileMonitorFocus(
        previous: tree.instances,
        next: const ['standalone'],
        selectedIndex: 5,
      ),
      0,
    );
  });
}
