import 'dart:async';

const Duration runtimeStopTimeout = Duration(seconds: 5);

/// Allows one bounded graceful shutdown, then forces any remaining runtime.
/// The deadline includes requesting shutdown and checking whether it exited.
Future<bool> stopRuntime({
  required Future<void> Function() requestStop,
  required Future<bool> Function() isStopped,
  required Future<void> Function() forceStop,
  Duration timeout = runtimeStopTimeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  try {
    await requestStop().timeout(timeout);
    while (elapsed.elapsed < timeout) {
      final Duration remaining = timeout - elapsed.elapsed;
      if (await isStopped().timeout(remaining)) return true;
      final Duration delay = timeout - elapsed.elapsed;
      if (delay <= Duration.zero) break;
      await Future<void>.delayed(delay < pollInterval ? delay : pollInterval);
    }
  } on TimeoutException {
    // A stalled command or health check must not postpone the force stop.
  } finally {
    elapsed.stop();
  }
  await forceStop();
  return false;
}
