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
  });

  final ConsumerProfile consumer;
  final List<String> instances;
  final List<String> visibleInstances;
  final int offset;
  final int contentRows;

  int get rows => instances.isEmpty ? 1 : contentRows + 2;
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
  while (used < rows) {
    bool expanded = false;
    for (int index = 0; index < instances.length && used < rows; index++) {
      if (slots[index] < instances[index].length) {
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
      if (instances[index].isNotEmpty) index,
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
      ),
  ];
}

MonitorConsumerGroup _planGroup({
  required ConsumerProfile consumer,
  required List<String> instances,
  required int slots,
  required int contentRows,
  required String? selectedInstance,
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
  );
}
