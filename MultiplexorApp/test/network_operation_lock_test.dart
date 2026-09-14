import 'dart:async';
import 'dart:io';

import 'package:multiplexor/services/network_operation_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NetworkOperationLock lock;
  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-operation-lock-');
    lock = NetworkOperationLock(p.join(root.path, 'operation.lock'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'concurrent starts overlap while network mutation waits for both',
    () async {
      final Completer<void> first = Completer<void>();
      final Completer<void> second = Completer<void>();
      final List<String> admitted = <String>[];
      final Future<void> one = lock.run(() async {
        admitted.add('one');
        await first.future;
      }, exclusive: false);
      final Future<void> two = lock.run(() async {
        admitted.add('two');
        await second.future;
      }, exclusive: false);
      final Future<void> writer = lock.run(
        () async => admitted.add('network'),
        exclusive: true,
      );
      final Future<void> later = lock.run(
        () async => admitted.add('later'),
        exclusive: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(admitted, <String>['one', 'two']);
      first.complete();
      await one;
      expect(admitted, <String>['one', 'two']);
      second.complete();
      await Future.wait(<Future<void>>[two, writer, later]);
      expect(admitted, <String>['one', 'two', 'network', 'later']);
    },
  );

  test('failed network mutation releases waiting startup', () async {
    final Future<void> mutation = lock.run(() async {
      throw StateError('injected');
    }, exclusive: true);
    final Future<String> start = lock.run(
      () async => 'started',
      exclusive: false,
    );
    await expectLater(mutation, throwsStateError);
    expect(await start, 'started');
  });

  test(
    'last shared operation owns OS lock until its startup finishes',
    () async {
      final File probe = File(p.join(root.path, 'probe.dart'))
        ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final RandomAccessFile file = File(args.single).openSync(mode: FileMode.append);
  try {
    file.lockSync(FileLock.exclusive);
    stdout.write('acquired');
  } on FileSystemException {
    stdout.write('blocked');
  } finally {
    file.closeSync();
  }
}
''');
      Future<String> probeExclusive() async {
        final ProcessResult result = await Process.run(
          Platform.resolvedExecutable,
          <String>[probe.path, lock.path],
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result.stdout.toString();
      }

      final Completer<void> first = Completer<void>();
      final Completer<void> last = Completer<void>();
      final Future<void> one = lock.run(() => first.future, exclusive: false);
      final Future<void> two = lock.run(() => last.future, exclusive: false);
      await Future<void>.delayed(Duration.zero);
      expect(await probeExclusive(), 'blocked');
      first.complete();
      await one;
      expect(await probeExclusive(), 'blocked');
      last.complete();
      await two;
      expect(await probeExclusive(), 'acquired');
    },
  );
}
