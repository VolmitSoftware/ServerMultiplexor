import '../../models/consumer_profile.dart';
import 'monitor_frame_util.dart';
import 'monitor_hitbox.dart';

const List<ConsumerProfile> monitorConsumerGroups = <ConsumerProfile>[
  ConsumerProfile.plugin,
  ConsumerProfile.fabric,
  ConsumerProfile.forge,
  ConsumerProfile.neoforge,
];

String monitorConsumerLabel(ConsumerProfile consumer) => switch (consumer) {
  ConsumerProfile.plugin => 'Plugins',
  ConsumerProfile.fabric => 'Fabric',
  ConsumerProfile.forge => 'Forge',
  ConsumerProfile.neoforge => 'NeoForge',
};

List<String> localMonitorFocusTargets(MonitorSnapshot snapshot) => <String>[
  for (ConsumerProfile consumer in monitorConsumerGroups) ...<String>[
    '$groupNewHitPrefix${consumer.shortName}',
    for (String instance in snapshot.instances)
      if (snapshot.consumerFor(instance) == consumer)
        '$serverHitPrefix$instance',
  ],
];

final class MonitorConsumerGroup {
  const MonitorConsumerGroup({
    required this.consumer,
    required this.instances,
    required this.visibleInstances,
    required this.offset,
    required this.contentRows,
    this.collapsed = false,
  });

  final ConsumerProfile consumer;
  final List<String> instances;
  final List<String> visibleInstances;
  final int offset;
  final int contentRows;

  /// A populated group folded to its title row because the terminal is too
  /// short to list it beside the selected server's group.
  final bool collapsed;

  int get rows => instances.isEmpty || collapsed ? 1 : contentRows + 2;
}

int localMonitorNaturalRows(MonitorSnapshot snapshot) {
  int rows = 1;
  for (ConsumerProfile consumer in monitorConsumerGroups) {
    int count = snapshot.instances
        .where((String instance) => snapshot.consumerFor(instance) == consumer)
        .length;
    rows += count == 0 ? 1 : count + 2;
  }
  return rows;
}

/// The fewest rows the grouped list can draw in: its column header, one
/// title row per empty group, and one scrolling row with borders per
/// populated group.
int localMonitorMinimumRows(MonitorSnapshot snapshot) {
  int rows = 1;
  for (ConsumerProfile consumer in monitorConsumerGroups) {
    bool populated = snapshot.instances.any(
      (String instance) => snapshot.consumerFor(instance) == consumer,
    );
    rows += populated ? 3 : 1;
  }
  return rows;
}

List<MonitorConsumerGroup> planMonitorConsumerGroups({
  required MonitorSnapshot snapshot,
  required int rows,
  required String? selectedInstance,
}) {
  List<List<String>> instances = <List<String>>[
    for (ConsumerProfile consumer in monitorConsumerGroups)
      snapshot.instances
          .where(
            (String instance) => snapshot.consumerFor(instance) == consumer,
          )
          .toList(growable: false),
  ];
  List<int> slots = <int>[
    for (List<String> group in instances) group.isEmpty ? 0 : 1,
  ];
  int used = 1;
  for (List<String> group in instances) {
    used += group.isEmpty ? 1 : 3;
  }
  // Too short for every populated group: fold the ones without the
  // selection to their title rows, last group first.
  List<bool> collapsed = List<bool>.filled(instances.length, false);
  for (int index = instances.length - 1; index >= 0 && used > rows; index--) {
    if (instances[index].isEmpty ||
        instances[index].contains(selectedInstance)) {
      continue;
    }
    collapsed[index] = true;
    slots[index] = 0;
    used -= 2;
  }
  while (used < rows) {
    bool expanded = false;
    for (int index = 0; index < instances.length && used < rows; index++) {
      if (!collapsed[index] && slots[index] < instances[index].length) {
        slots[index]++;
        used++;
        expanded = true;
      }
    }
    if (!expanded) break;
  }
  List<int> contentRows = List<int>.of(slots);
  List<int> populated = <int>[
    for (int index = 0; index < instances.length; index++)
      if (instances[index].isNotEmpty && !collapsed[index]) index,
  ];
  if (populated.isNotEmpty && used < rows) {
    int spare = rows - used;
    for (int position = 0; position < populated.length; position++) {
      contentRows[populated[position]] +=
          spare ~/ populated.length +
          (position < spare % populated.length ? 1 : 0);
    }
  }
  return <MonitorConsumerGroup>[
    for (int index = 0; index < instances.length; index++)
      _planGroup(
        consumer: monitorConsumerGroups[index],
        instances: instances[index],
        slots: slots[index],
        contentRows: contentRows[index],
        selectedInstance: selectedInstance,
        collapsed: collapsed[index],
      ),
  ];
}

MonitorConsumerGroup _planGroup({
  required ConsumerProfile consumer,
  required List<String> instances,
  required int slots,
  required int contentRows,
  required String? selectedInstance,
  bool collapsed = false,
}) {
  int selected = selectedInstance == null
      ? -1
      : instances.indexOf(selectedInstance);
  int offset = selected >= slots ? selected - slots + 1 : 0;
  return MonitorConsumerGroup(
    consumer: consumer,
    instances: instances,
    visibleInstances: instances.sublist(offset, offset + slots),
    offset: offset,
    contentRows: contentRows,
    collapsed: collapsed,
  );
}
