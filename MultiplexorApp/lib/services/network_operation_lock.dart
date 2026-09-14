import 'dart:async';
import 'dart:collection';
import 'dart:io';

/// Concurrent instance operations share one OS lock; network edits exclude them.
final class NetworkOperationLock {
  NetworkOperationLock(this.path);

  final String path;
  final Queue<_OperationWaiter> _waiting = Queue<_OperationWaiter>();
  RandomAccessFile? _file;
  int _readers = 0;
  bool _writer = false;

  Future<T> run<T>(
    Future<T> Function() operation, {
    required bool exclusive,
  }) async {
    await _acquire(exclusive);
    try {
      return await operation();
    } finally {
      if (exclusive) {
        _writer = false;
      } else {
        _readers--;
      }
      if (!_writer && _readers == 0) {
        _file?.closeSync();
        _file = null;
        _drain();
      }
    }
  }

  Future<void> _acquire(bool exclusive) {
    final _OperationWaiter waiter = _OperationWaiter(exclusive);
    _waiting.add(waiter);
    _drain();
    return waiter.ready.future;
  }

  void _drain() {
    if (_writer) return;
    while (_waiting.isNotEmpty) {
      final _OperationWaiter next = _waiting.first;
      if (next.exclusive && _readers > 0) return;
      _waiting.removeFirst();
      try {
        if (_file == null) {
          final File file = File(path)..parent.createSync(recursive: true);
          final RandomAccessFile handle = file.openSync(mode: FileMode.append);
          try {
            handle.lockSync(
              next.exclusive ? FileLock.exclusive : FileLock.shared,
            );
          } catch (_) {
            handle.closeSync();
            rethrow;
          }
          _file = handle;
        }
        if (next.exclusive) {
          _writer = true;
        } else {
          _readers++;
        }
        next.ready.complete();
        if (_writer) return;
      } catch (error, stack) {
        next.ready.completeError(error, stack);
      }
    }
  }
}

final class _OperationWaiter {
  _OperationWaiter(this.exclusive);
  final bool exclusive;
  final Completer<void> ready = Completer<void>();
}
