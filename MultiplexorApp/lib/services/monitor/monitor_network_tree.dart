class MonitorNetworkMember {
  const MonitorNetworkMember({
    required this.instance,
    required this.alias,
    required this.port,
  });

  final String instance;
  final String alias;
  final int port;
}

class MonitorNetworkGroup {
  const MonitorNetworkGroup({
    required this.name,
    required this.proxy,
    required this.port,
    required this.members,
  });

  final String name;
  final String proxy;
  final int port;
  final List<MonitorNetworkMember> members;
}

class MonitorNetworkRow {
  const MonitorNetworkRow({
    required this.network,
    required this.proxy,
    required this.port,
    this.alias,
    this.lastChild = false,
  });

  final String network;
  final String proxy;
  final int port;
  final String? alias;
  final bool lastChild;

  bool get isProxy => alias == null;
}

class MonitorNetworkTree {
  const MonitorNetworkTree({required this.instances, required this.rows});

  factory MonitorNetworkTree.project(
    List<String> instances,
    List<MonitorNetworkGroup> groups,
  ) {
    final Set<String> available = instances.toSet();
    final Map<String, MonitorNetworkGroup> membership =
        <String, MonitorNetworkGroup>{};
    for (final MonitorNetworkGroup group in groups) {
      if (!available.contains(group.proxy)) continue;
      membership.putIfAbsent(group.proxy, () => group);
      for (final MonitorNetworkMember member in group.members) {
        membership.putIfAbsent(member.instance, () => group);
      }
    }
    final List<String> ordered = <String>[];
    final Set<String> emitted = <String>{};
    final Map<String, MonitorNetworkRow> rows = <String, MonitorNetworkRow>{};
    for (final String instance in instances) {
      if (emitted.contains(instance)) continue;
      final MonitorNetworkGroup? group = membership[instance];
      if (group == null || emitted.contains(group.proxy)) {
        emitted.add(instance);
        ordered.add(instance);
        continue;
      }
      emitted.add(group.proxy);
      ordered.add(group.proxy);
      rows[group.proxy] = MonitorNetworkRow(
        network: group.name,
        proxy: group.proxy,
        port: group.port,
      );
      final List<MonitorNetworkMember> children = <MonitorNetworkMember>[];
      for (final MonitorNetworkMember member in group.members) {
        if (available.contains(member.instance) &&
            membership[member.instance] == group &&
            emitted.add(member.instance)) {
          children.add(member);
        }
      }
      for (int index = 0; index < children.length; index++) {
        final MonitorNetworkMember child = children[index];
        ordered.add(child.instance);
        rows[child.instance] = MonitorNetworkRow(
          network: group.name,
          proxy: group.proxy,
          port: child.port,
          alias: child.alias,
          lastChild: index == children.length - 1,
        );
      }
    }
    return MonitorNetworkTree(
      instances: List<String>.unmodifiable(ordered),
      rows: Map<String, MonitorNetworkRow>.unmodifiable(rows),
    );
  }

  final List<String> instances;
  final Map<String, MonitorNetworkRow> rows;
}

int reconcileMonitorFocus({
  required List<String> previous,
  required List<String> next,
  required int selectedIndex,
}) {
  if (next.isEmpty) return 0;
  if (selectedIndex >= 0 && selectedIndex < previous.length) {
    final int retained = next.indexOf(previous[selectedIndex]);
    if (retained >= 0) return retained;
  }
  return selectedIndex.clamp(0, next.length - 1);
}
