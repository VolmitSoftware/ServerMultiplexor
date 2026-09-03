import 'dart:async';

/// Runs independent operations with a shared limit and returns input order.
/// Workers immediately pick up another item when they finish. If any operation
/// fails, all items still settle before the first error is rethrown, so callers
/// can safely clean up resources in finally without work continuing afterward.
Future<List<R>> boundedMap<T, R>(
  Iterable<T> items,
  Future<R> Function(T item) operation, {
  int concurrency = 4,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'Must be positive');
  }
  final List<T> inputs = List<T>.of(items, growable: false);
  final List<R?> results = List<R?>.filled(inputs.length, null);
  int next = 0;
  Object? firstError;
  StackTrace? firstStack;

  Future<void> worker() async {
    while (next < inputs.length) {
      final int index = next++;
      try {
        results[index] = await operation(inputs[index]);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
  }

  await Future.wait<void>(<Future<void>>[
    for (int index = 0; index < concurrency && index < inputs.length; index++)
      worker(),
  ]);
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
  return results.cast<R>();
}

/// Serializes only operations that share mutable resources. A failed operation
/// releases the next waiter just like a successful one.
final class AsyncGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) async {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }
}
