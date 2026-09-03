part of 'native_command_service.dart';

const String _instanceBulkUsage =
    'Usage: instance bulk <start|stop|restart|delete> <name>... [--confirm <token>]';

extension _NativeBulkCommands on NativeCommandService {
  Future<int> _dispatchInstanceBulk(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final InstanceBulkAction? action = args.isEmpty
        ? null
        : InstanceBulkAction.values
              .where((InstanceBulkAction action) => action.name == args.first)
              .firstOrNull;
    if (action == null) {
      throw _NativeCommandException(_instanceBulkUsage, 2);
    }
    final Set<String> selected = <String>{};
    String? confirmation;
    for (int index = 1; index < args.length; index++) {
      final String argument = args[index];
      if (argument == '--confirm') {
        if (confirmation != null || index + 1 >= args.length) {
          throw _NativeCommandException(_instanceBulkUsage, 2);
        }
        confirmation = args[++index];
      } else {
        if (argument.startsWith('-') || argument.trim() != argument) {
          throw _NativeCommandException(_instanceBulkUsage, 2);
        }
        selected.add(_validateSimpleName(argument, label: 'instance'));
      }
    }
    if (selected.isEmpty ||
        action != InstanceBulkAction.delete && confirmation != null) {
      throw _NativeCommandException(_instanceBulkUsage, 2);
    }
    final List<String> names = selected.toList(growable: false);
    // Validate every explicit target before touching runtime or instance state.
    for (final String name in names) {
      if (!_instanceExists(profile, name)) {
        throw _NativeCommandException('Instance not found: $name', 2);
      }
    }
    io.write(
      '[INFO] Bulk ${action.name} selected (${names.length}): ${names.join(', ')}',
    );
    if (action == InstanceBulkAction.delete) {
      final String expected = instanceBulkDeleteToken(names);
      if (confirmation != expected) {
        throw _NativeCommandException(
          'Deletion requires --confirm "$expected" for these exact targets.',
          2,
        );
      }
    }

    final List<_InstanceBulkTarget> plan = <_InstanceBulkTarget>[];
    for (final String name in names) {
      try {
        plan.add(
          _InstanceBulkTarget(
            name,
            skipReason: await _instanceBulkCurrentSkip(profile, name, action),
          ),
        );
      } catch (error) {
        plan.add(_InstanceBulkTarget(name, error: error));
      }
    }

    int succeeded = 0;
    int skipped = 0;
    int failed = 0;
    for (final _InstanceBulkTarget target in plan) {
      try {
        if (target.error != null) throw target.error!;
        final String? reason =
            target.skipReason ??
            await _instanceBulkCurrentSkip(profile, target.name, action);
        if (reason != null) {
          skipped++;
          io.write('[SKIP] ${target.name}: $reason');
          continue;
        }
        switch (action) {
          case InstanceBulkAction.start:
            await _runtimeStart(profile, target.name, io);
          case InstanceBulkAction.stop:
            await _runtimeStop(profile, target.name, io);
          case InstanceBulkAction.restart:
            await _runtimeStop(profile, target.name, io);
            await _runtimeStart(profile, target.name, io);
          case InstanceBulkAction.delete:
            await _instanceDelete(profile, target.name, io: io);
        }
        succeeded++;
        io.write('[OK] ${target.name}: ${action.name}');
      } catch (error) {
        failed++;
        final String message = error is _NativeCommandException
            ? error.message
            : error.toString();
        io.error('[ERROR] ${target.name}: ${action.name} failed: $message');
      }
    }
    io.write(
      '[INFO] Bulk ${action.name}: $succeeded succeeded, $skipped skipped, $failed failed',
    );
    return failed == 0 ? 0 : 1;
  }

  Future<String?> _instanceBulkCurrentSkip(
    ConsumerProfile profile,
    String name,
    InstanceBulkAction action,
  ) async {
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    final bool locked = _instanceLocked(profile, name);
    if (action == InstanceBulkAction.delete && locked) {
      return instanceBulkSkipReason(action, RuntimeState.stopped, locked: true);
    }
    return instanceBulkSkipReason(
      action,
      await _runtimeStateOf(profile, name),
      locked: locked,
    );
  }
}

final class _InstanceBulkTarget {
  const _InstanceBulkTarget(this.name, {this.skipReason, this.error});

  final String name;
  final String? skipReason;
  final Object? error;
}
