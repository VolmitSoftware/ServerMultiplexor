import 'dart:async';

import 'package:multiplexor/services/runtime_stop.dart';
import 'package:test/test.dart';

void main() {
  test('runtime shutdown grace period is five seconds', () {
    expect(runtimeStopTimeout, const Duration(seconds: 5));
  });

  test('clean shutdown returns without forcing', () async {
    final List<String> calls = <String>[];
    final bool graceful = await stopRuntime(
      requestStop: () async => calls.add('stop'),
      isStopped: () async {
        calls.add('check');
        return true;
      },
      forceStop: () async => calls.add('force'),
    );

    expect(graceful, isTrue);
    expect(calls, <String>['stop', 'check']);
  });

  test('unresponsive runtime is forced once after the deadline', () async {
    final Stopwatch elapsed = Stopwatch()..start();
    int forceCount = 0;
    final bool graceful = await stopRuntime(
      requestStop: () async {},
      isStopped: () async => false,
      forceStop: () async => forceCount++,
      timeout: const Duration(milliseconds: 30),
      pollInterval: const Duration(milliseconds: 5),
    );

    expect(graceful, isFalse);
    expect(forceCount, 1);
    expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(30));
  });

  test('stalled graceful request cannot prevent force stop', () async {
    bool forced = false;
    final bool graceful = await stopRuntime(
      requestStop: () => Completer<void>().future,
      isStopped: () async => false,
      forceStop: () async => forced = true,
      timeout: const Duration(milliseconds: 20),
    );

    expect(graceful, isFalse);
    expect(forced, isTrue);
  });

  test('stalled runtime check cannot prevent force stop', () async {
    bool forced = false;
    final bool graceful = await stopRuntime(
      requestStop: () async {},
      isStopped: () => Completer<bool>().future,
      forceStop: () async => forced = true,
      timeout: const Duration(milliseconds: 20),
    );

    expect(graceful, isFalse);
    expect(forced, isTrue);
  });

  test('rejected shutdown is reported without bypassing the rejection', () {
    return expectLater(
      stopRuntime(
        requestStop: () async => throw StateError('permission denied'),
        isStopped: () async => false,
        forceStop: () async => fail('must not force a rejected operation'),
      ),
      throwsStateError,
    );
  });
}
