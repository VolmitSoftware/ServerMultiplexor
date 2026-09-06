import 'dart:io';

import 'package:multiplexor/services/recovery_snapshot.dart';
import 'package:multiplexor/services/runtime_stop.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('recovery-snapshot-test-');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test(
    'snapshot materializes file and directory links and empty directories',
    () {
      final Directory source = Directory('${root.path}/source')..createSync();
      final Directory shared = Directory('${root.path}/shared')..createSync();
      File('${shared.path}/pack.json').writeAsStringSync('original');
      Directory('${source.path}/empty').createSync();
      final File jar = File('${root.path}/build.jar')..writeAsStringSync('jar');
      Link('${source.path}/server.jar').createSync(jar.path);
      Link('${source.path}/packs').createSync(shared.path);
      final Directory snapshot = Directory('${root.path}/snapshot');
      RecoverySnapshot.copy(source, snapshot);
      final List<Map<String, Object>> entries = RecoverySnapshot.entries(
        snapshot,
      );
      jar.deleteSync();
      shared.deleteSync(recursive: true);
      RecoverySnapshot.verify(snapshot, entries);
      expect(File('${snapshot.path}/server.jar').readAsStringSync(), 'jar');
      expect(
        File('${snapshot.path}/packs/pack.json').readAsStringSync(),
        'original',
      );
      expect(Directory('${snapshot.path}/empty').existsSync(), isTrue);
    },
    skip: Platform.isWindows,
  );

  test(
    'broken external dependency and link cycles fail capture',
    () {
      final Directory source = Directory('${root.path}/source')..createSync();
      final Link link = Link('${source.path}/link')
        ..createSync('${root.path}/missing');
      expect(
        () => RecoverySnapshot.copy(
          source,
          Directory('${root.path}/missing-copy'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      link.deleteSync();
      link.createSync(source.path);
      expect(
        () =>
            RecoverySnapshot.copy(source, Directory('${root.path}/cycle-copy')),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'verify rejects changes, extra files, links, and missing directories',
    () {
      final Directory snapshot = Directory('${root.path}/snapshot')
        ..createSync();
      final File file = File('${snapshot.path}/data')
        ..writeAsStringSync('before');
      final Directory empty = Directory('${snapshot.path}/empty')..createSync();
      final List<Map<String, Object>> entries = RecoverySnapshot.entries(
        snapshot,
      );
      file.writeAsStringSync('changed');
      expect(
        () => RecoverySnapshot.verify(snapshot, entries),
        throwsFormatException,
      );
      file.writeAsStringSync('before');
      final File extra = File('${snapshot.path}/extra')
        ..writeAsStringSync('extra');
      expect(
        () => RecoverySnapshot.verify(snapshot, entries),
        throwsFormatException,
      );
      extra.deleteSync();
      empty.deleteSync();
      expect(
        () => RecoverySnapshot.verify(snapshot, entries),
        throwsFormatException,
      );
      empty.createSync();
      if (!Platform.isWindows) {
        file.deleteSync();
        Link(file.path).createSync('${root.path}/outside');
        expect(
          () => RecoverySnapshot.verify(snapshot, entries),
          throwsA(isA<FileSystemException>()),
        );
      }
    },
  );

  test('failed installation bookkeeping restores the old tree', () {
    final Directory target = Directory('${root.path}/target')..createSync();
    File('${target.path}/world').writeAsStringSync('old');
    final Directory prepared = Directory('${root.path}/prepared')..createSync();
    File('${prepared.path}/world').writeAsStringSync('new');
    expect(
      () => RecoverySnapshot.replace(
        prepared,
        target,
        afterInstall: () => throw StateError('failure'),
      ),
      throwsStateError,
    );
    expect(File('${target.path}/world').readAsStringSync(), 'old');
  });

  test('consistent shutdown times out without forcing the process', () async {
    bool forced = false;
    await expectLater(
      stopRuntime(
        requestStop: () async {},
        isStopped: () async => false,
        forceStop: () async {
          forced = true;
        },
        timeout: const Duration(milliseconds: 20),
        allowForce: false,
      ),
      throwsA(isA<Exception>()),
    );
    expect(forced, isFalse);
  });
}
