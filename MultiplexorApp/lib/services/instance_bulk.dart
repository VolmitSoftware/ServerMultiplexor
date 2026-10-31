import 'runtime_state.dart';

enum InstanceBulkAction { start, stop, restart, delete }

/// Binds destructive confirmation to the exact selected set, in stable order.
String instanceBulkDeleteToken(List<String> names) {
  if (names.isEmpty || names.any((String name) => name.isEmpty)) {
    throw ArgumentError('Bulk deletion requires explicit instance names.');
  }
  final List<String> selected = names.toSet().toList()..sort();
  return 'DELETE ${selected.join(',')}';
}

/// The one-line result of a bulk [action] that reached [count] servers and
/// passed over [skipped] that could not take it.
String instanceBulkOutcome(
  InstanceBulkAction action,
  int count, {
  required int skipped,
}) {
  if (count == 0) {
    return 'Nothing to ${action.name}: $skipped selected '
        '${skipped == 1 ? 'server' : 'servers'} skipped';
  }
  final String done = switch (action) {
    InstanceBulkAction.start => 'Started',
    InstanceBulkAction.stop => 'Stopped',
    InstanceBulkAction.restart => 'Restarted',
    InstanceBulkAction.delete => 'Deleted',
  };
  final String servers = count == 1 ? 'server' : 'servers';
  return skipped == 0
      ? '$done $count $servers'
      : '$done $count $servers · $skipped skipped';
}

/// A null reason means this action can apply to the current instance state.
String? instanceBulkSkipReason(
  InstanceBulkAction action,
  RuntimeState state, {
  required bool locked,
}) => switch (action) {
  InstanceBulkAction.start =>
    state == RuntimeState.stopped
        ? null
        : 'state is ${state.name}; start requires stopped',
  InstanceBulkAction.stop =>
    state == RuntimeState.stopped ? 'already stopped' : null,
  InstanceBulkAction.restart =>
    state == RuntimeState.running
        ? null
        : 'state is ${state.name}; restart requires running',
  InstanceBulkAction.delete => locked ? 'instance is locked' : null,
};
