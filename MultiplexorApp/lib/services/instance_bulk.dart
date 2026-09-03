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
