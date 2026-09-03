import 'dart:async';

import 'package:multiplexor/utils/async_work_pool.dart';
import 'package:test/test.dart';

void main() {
  test('workers refill immediately while results retain input order', () async {
    final List<Completer<int>> gates = List<Completer<int>>.generate(
      5,
      (_) => Completer<int>(),
    );
    final List<int> started = <int>[];
    final List<Completer<void>> observed = List<Completer<void>>.generate(
      5,
      (_) => Completer<void>(),
    );
    final Future<List<int>> result = boundedMap<int, int>(
      <int>[0, 1, 2, 3, 4],
      (int item) {
        started.add(item);
        observed[item].complete();
        return gates[item].future;
      },
      concurrency: 2,
    );
    await observed[1].future;
    expect(started, <int>[0, 1]);
    gates[1].complete(11);
    await observed[2].future;
    expect(started, <int>[0, 1, 2]);
    expect(gates[0].isCompleted, isFalse);
    gates[2].complete(12);
    await observed[3].future;
    gates[3].complete(13);
    await observed[4].future;
    gates[4].complete(14);
    gates[0].complete(10);
    expect(await result, <int>[10, 11, 12, 13, 14]);
  });

  test('errors wait for every queued operation before cleanup', () async {
    final Completer<void> blocked = Completer<void>();
    final Completer<void> queued = Completer<void>();
    final StateError failure = StateError('first failure');
    bool settled = false;
    final Future<List<void>> result = boundedMap<int, void>(<int>[0, 1, 2], (
      int item,
    ) async {
      if (item == 0) throw failure;
      if (item == 1) await blocked.future;
      if (item == 2) queued.complete();
    }, concurrency: 2);
    final Future<void> assertion = expectLater(
      result.whenComplete(() => settled = true),
      throwsA(same(failure)),
    );
    await queued.future;
    expect(settled, isFalse);
    blocked.complete();
    await assertion;
    expect(settled, isTrue);
  });

  test(
    'accepts nullable values and rejects invalid limits before work',
    () async {
      expect(
        await boundedMap<int, int?>(<int>[1], (int _) async => null),
        <int?>[null],
      );
      expect(
        await boundedMap<int, int>(<int>[], (int value) async => value),
        isEmpty,
      );
      await expectLater(
        boundedMap<int, int>(
          <int>[1],
          (int _) async => fail('must not run'),
          concurrency: 0,
        ),
        throwsArgumentError,
      );
    },
  );

  test('gate protects shared allocation and recovers after failures', () async {
    final AsyncGate gate = AsyncGate();
    final Completer<void> release = Completer<void>();
    final List<int> entered = <int>[];
    final Future<void> first = gate.run(() async {
      entered.add(1);
      await release.future;
      throw StateError('allocation failed');
    });
    final Future<void> assertion = expectLater(first, throwsStateError);
    final Future<int> second = gate.run(() async {
      entered.add(2);
      return 2;
    });
    await Future<void>.delayed(Duration.zero);
    expect(entered, <int>[1]);
    release.complete();
    await assertion;
    expect(await second, 2);
    expect(entered, <int>[1, 2]);
  });
}
