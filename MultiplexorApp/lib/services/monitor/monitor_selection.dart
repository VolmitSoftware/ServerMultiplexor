import '../instance_bulk.dart';
import '../runtime_state.dart';
import 'monitor_frame_util.dart';

/// Checked identities are independent of the keyboard's focused row.
/// Refreshes prune disappeared identities without selecting new servers.
final class MonitorSelection {
  final Set<String> _checked = <String>{};
  String? _scope;

  Set<String> get checked => Set<String>.unmodifiable(_checked);
  bool get isEmpty => _checked.isEmpty;

  void reconcile(MonitorSnapshot snapshot) {
    final String scope = '${snapshot.view.name}:${snapshot.consumerName}';
    if (_scope != scope) {
      _checked.clear();
      _scope = scope;
    }
    _checked.retainAll(snapshot.instances);
  }

  void toggle(String instance, MonitorSnapshot snapshot) {
    reconcile(snapshot);
    if (!snapshot.instances.contains(instance)) return;
    if (!_checked.remove(instance)) _checked.add(instance);
  }

  void toggleAll(MonitorSnapshot snapshot) {
    reconcile(snapshot);
    if (_checked.length == snapshot.instances.length) {
      _checked.clear();
    } else {
      _checked.addAll(snapshot.instances);
    }
  }

  void clear() => _checked.clear();

  List<String> targets(MonitorSnapshot snapshot) {
    reconcile(snapshot);
    return List<String>.unmodifiable(
      snapshot.instances.where(_checked.contains),
    );
  }
}

/// Presentation eligibility. Commands recheck current state and permissions.
bool monitorBulkEligible(
  MonitorSnapshot snapshot,
  String instance,
  InstanceBulkAction action,
) {
  if (!snapshot.instances.contains(instance)) return false;
  if (action == InstanceBulkAction.delete) {
    return snapshot.view == MonitorView.remote ||
        !snapshot.flagsFor(instance).locked;
  }
  if (snapshot.operationBlockReasonFor(instance) != null) return false;
  final RuntimeState? state = snapshot.latestFor(instance)?.state;
  return switch (action) {
    InstanceBulkAction.start => state == RuntimeState.stopped,
    InstanceBulkAction.stop => state != null && state != RuntimeState.stopped,
    InstanceBulkAction.restart => state == RuntimeState.running,
    InstanceBulkAction.delete => false,
  };
}
