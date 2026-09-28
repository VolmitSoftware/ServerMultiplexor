import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_groups.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 9, 28);

MonitorSnapshot _fleet({int perGroup = 1}) {
  List<String> instances = <String>[
    for (ConsumerProfile consumer in monitorConsumerGroups)
      for (int index = 0; index < perGroup; index++)
        '${consumer.shortName}:server-$index',
  ];
  return MonitorSnapshot(
    instances: instances,
    consumerName: 'all',
    groupedLocal: true,
    instanceConsumers: <String, ConsumerProfile>{
      for (String instance in instances)
        instance: ConsumerProfile.parse(instance.split(':').first)!,
    },
    displayNames: <String, String>{
      for (String instance in instances) instance: instance.split(':').last,
    },
    primaryInstances: <String>{
      for (ConsumerProfile consumer in monitorConsumerGroups)
        if (perGroup > 0) '${consumer.shortName}:server-0',
    },
    history: <String, List<MetricSample>>{
      for (String instance in instances)
        instance: <MetricSample>[
          MetricSample(
            ts: _now,
            instance: instance,
            state: RuntimeState.stopped,
            port: 25565 + instances.indexOf(instance),
          ),
        ],
    },
  );
}

MonitorFrame _frame(
  MonitorSnapshot snapshot, {
  int selected = 0,
  int columns = 80,
  int lines = 24,
  String? focusedGroup,
}) => buildMonitorFrame(
  snapshot: snapshot,
  selectedIndex: selected,
  focusedGroup: focusedGroup,
  frame: 0,
  columns: columns,
  lines: lines,
  theme: MonitorTheme.plain(),
  range: const Duration(minutes: 15),
  now: _now,
  clockNow: _now,
);

void main() {
  test('populated groups fill spare rows while empty groups stay strips', () {
    MonitorSnapshot snapshot = MonitorSnapshot(
      instances: const <String>['plugin/demo', 'neoforge/demo'],
      history: const <String, List<MetricSample>>{},
      consumerName: 'local',
      groupedLocal: true,
      instanceConsumers: const <String, ConsumerProfile>{
        'plugin/demo': ConsumerProfile.plugin,
        'neoforge/demo': ConsumerProfile.neoforge,
      },
    );
    List<MonitorConsumerGroup> groups = planMonitorConsumerGroups(
      snapshot: snapshot,
      rows: 26,
      selectedInstance: 'neoforge/demo',
    );
    expect(
      groups.fold<int>(
        1,
        (int sum, MonitorConsumerGroup group) => sum + group.rows,
      ),
      26,
    );
    expect(groups[1].rows, 1);
    expect(groups[2].rows, 1);
    expect((groups[0].rows - groups[3].rows).abs(), lessThanOrEqualTo(1));
    expect(groups[0].visibleInstances, <String>['plugin/demo']);
    expect(groups[3].visibleInstances, <String>['neoforge/demo']);

    MonitorFrame frame = _frame(snapshot, lines: 40);
    expect(
      frame.rows.take(37).every((String row) => row.trim().isNotEmpty),
      isTrue,
    );
    List<MonitorHitbox> padding = frame.hitboxes
        .where((MonitorHitbox box) => box.kind == MonitorHitKind.listArea)
        .toList();
    expect(padding, isNotEmpty);
    expect(padding.last.id, startsWith('group:area:neoforge:'));
    expect(frame.rows[padding.last.row].trim(), isNotEmpty);
    expect(
      frame.hitboxes.any(
        (MonitorHitbox box) =>
            box.row == padding.last.row && box.kind == MonitorHitKind.serverRow,
      ),
      isFalse,
    );
  });

  test('every overflowing server has a visible row when focused', () {
    MonitorSnapshot snapshot = _fleet(perGroup: 40);
    for (int selected = 0; selected < snapshot.instances.length; selected++) {
      MonitorFrame frame = _frame(snapshot, selected: selected);
      expect(
        frame.hitboxes.any(
          (MonitorHitbox box) =>
              box.id == '$serverHitPrefix${snapshot.instances[selected]}',
        ),
        isTrue,
      );
      expect(frame.rows, hasLength(24));
    }
  });

  test('all groups and right-side ports and primary controls fit at 80x24', () {
    MonitorSnapshot snapshot = _fleet();
    MonitorFrame frame = _frame(snapshot);
    List<String> rows = frame.rows.map(Ansi.strip).toList();
    int previousGroupRow = -1;
    for (ConsumerProfile consumer in monitorConsumerGroups) {
      MonitorHitbox create = frame.hitboxes.singleWhere(
        (MonitorHitbox box) =>
            box.id == '$groupNewHitPrefix${consumer.shortName}',
      );
      expect(create.row, greaterThan(previousGroupRow));
      expect(rows[create.row], contains(monitorConsumerLabel(consumer)));
      previousGroupRow = create.row;
      String instance = '${consumer.shortName}:server-0';
      MonitorHitbox primary = frame.hitboxes.singleWhere(
        (MonitorHitbox box) => box.id == '$primaryHitPrefix$instance',
      );
      expect(primary.colStart, 71);
      expect(
        rows[primary.row].substring(primary.colStart, primary.colEnd),
        contains('[x]'),
      );
      expect(rows[primary.row], contains('${snapshot.portFor(instance)}'));
      expect(
        hitTest(frame.hitboxes, row: primary.row, col: 75),
        '$primaryHitPrefix$instance',
      );
      expect(
        hitTest(frame.hitboxes, row: primary.row, col: 12),
        '$serverHitPrefix$instance',
      );
    }
    expect(rows, hasLength(24));
    expect(rows.every((String row) => row.length == 80), isTrue);
    expect(rows.join('\n'), isNot(contains('CONSUMER')));
  });

  test('empty groups are consecutive clickable one-row strips', () {
    MonitorFrame frame = _frame(_fleet(perGroup: 0), focusedGroup: 'forge');
    List<MonitorHitbox> creates = frame.hitboxes
        .where((MonitorHitbox box) => box.id.startsWith(groupNewHitPrefix))
        .toList();
    expect(creates, hasLength(4));
    for (int index = 0; index < creates.length; index++) {
      MonitorHitbox create = creates[index];
      expect(create.row, creates.first.row + index);
      expect(frame.rows[create.row], contains('Create first server'));
      expect(create.colStart, 0);
      expect(create.colEnd, 80);
    }
    expect(
      frame.rows[creates[2].row],
      contains('${MonitorTheme.plain().glyphs.selector} Forge'),
    );
  });

  test(
    'keyboard targets include every creation action and same-named server',
    () {
      expect(localMonitorFocusTargets(_fleet()), <String>[
        'group:new:plugin',
        'server:plugin:server-0',
        'group:new:fabric',
        'server:fabric:server-0',
        'group:new:forge',
        'server:forge:server-0',
        'group:new:neoforge',
        'server:neoforge:server-0',
      ]);
    },
  );

  test('deep selection stays visible without losing other groups', () {
    MonitorSnapshot snapshot = _fleet(perGroup: 40);
    MonitorFrame frame = _frame(snapshot, selected: 159);
    expect(
      frame.hitboxes.any(
        (MonitorHitbox box) => box.id == 'server:neoforge:server-39',
      ),
      isTrue,
    );
    expect(
      frame.hitboxes.where(
        (MonitorHitbox box) => box.id.startsWith(groupNewHitPrefix),
      ),
      hasLength(4),
    );
    expect(frame.rows.any((String row) => row.contains('/40')), isTrue);
    expect(
      frame.rows.every((String row) => Ansi.visibleLength(row) == 80),
      isTrue,
    );
  });

  test(
    'group focus clears server focus and routes its action bar to creation',
    () {
      MonitorFrame frame = _frame(_fleet(), focusedGroup: 'fabric');
      expect(frame.rows[21], contains('+ NEW'));
      expect(
        frame.hitboxes.any((MonitorHitbox box) => box.id == actStopHitId),
        isFalse,
      );
      expect(
        frame.hitboxes.where(
          (MonitorHitbox box) => box.id == 'group:new:fabric',
        ),
        hasLength(2),
      );
    },
  );

  test('wide frames retain metrics and aligned primary controls', () {
    MonitorFrame frame = _frame(_fleet(perGroup: 2), columns: 160, lines: 40);
    expect(frame.rows.join('\n'), contains('TREND'));
    expect(frame.rows.join('\n'), contains('PLAYERS'));
    for (MonitorHitbox box in frame.hitboxes.where(
      (MonitorHitbox box) => box.id.startsWith(primaryHitPrefix),
    )) {
      expect(box.colEnd, 158);
      expect(
        Ansi.strip(frame.rows[box.row]).substring(box.colStart, box.colEnd),
        matches(r'\[[ x]\]'),
      );
    }
  });
}
