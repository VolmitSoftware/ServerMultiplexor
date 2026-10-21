import 'dart:async';
import 'dart:io';

import 'package:multiplexor/services/projects/project_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('project-snapshot-');
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('large snapshots leave the worker event loop responsive', () async {
    Directory snapshot = Directory(p.join(fixture.path, 'snapshot'))
      ..createSync();
    for (int index = 0; index < 256; index++) {
      File(p.join(snapshot.path, '$index')).writeAsStringSync('$index');
    }
    int heartbeats = 0;
    Timer timer = Timer.periodic(Duration.zero, (_) => heartbeats++);
    try {
      await materializeProjectSnapshot(
        snapshot.path,
        p.join(fixture.path, 'sandbox'),
        boundary: snapshot.path,
      );
      expect(heartbeats, greaterThan(0));
    } finally {
      timer.cancel();
    }
  });

  test(
    'materialized snapshots preserve bytes, empty directories and isolation',
    () async {
      Directory snapshot = Directory(p.join(fixture.path, 'snapshot'));
      File input = File(p.join(snapshot.path, 'nested', 'payload.bin'));
      input.parent.createSync(recursive: true);
      input.writeAsBytesSync(
        List<int>.generate(131073, (int index) => index % 256),
      );
      Directory(p.join(snapshot.path, 'empty')).createSync();
      File(
        p.join(snapshot.path, '.env.example'),
      ).writeAsStringSync('captured input');
      Directory first = Directory(p.join(fixture.path, 'first'));
      Directory second = Directory(p.join(fixture.path, 'second'));
      for (Directory destination in <Directory>[first, second]) {
        await materializeProjectSnapshot(
          snapshot.path,
          destination.path,
          boundary: snapshot.path,
        );
        expect(
          File(
            p.join(destination.path, 'nested', 'payload.bin'),
          ).readAsBytesSync(),
          input.readAsBytesSync(),
        );
        expect(
          Directory(p.join(destination.path, 'empty')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(destination.path, '.env.example')).readAsStringSync(),
          'captured input',
        );
      }
      File(
        p.join(first.path, 'nested', 'payload.bin'),
      ).writeAsStringSync('changed');
      expect(
        File(p.join(second.path, 'nested', 'payload.bin')).readAsBytesSync(),
        input.readAsBytesSync(),
      );
      expect(input.lengthSync(), 131073);
    },
  );

  test('single-file snapshots preserve executable inputs', () async {
    File input = File(p.join(fixture.path, 'wrapper'))
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    ProcessResult permissions = await Process.run('chmod', <String>[
      '755',
      input.path,
    ]);
    expect(permissions.exitCode, 0);
    File output = File(p.join(fixture.path, 'sandbox', 'gradlew'));
    await materializeProjectSnapshot(
      input.path,
      output.path,
      boundary: fixture.path,
    );
    expect(output.readAsStringSync(), input.readAsStringSync());
    expect(output.statSync().mode & 0x49, 0x49);
    expect((await Process.run(output.path, <String>[])).exitCode, 0);
  }, skip: Platform.isWindows);

  test('snapshot links cannot leave their captured boundary', () async {
    Directory snapshot = Directory(p.join(fixture.path, 'snapshot'))
      ..createSync();
    File outside = File(p.join(fixture.path, 'outside'))
      ..writeAsStringSync('outside');
    Link(p.join(snapshot.path, 'link')).createSync(outside.path);
    await expectLater(
      materializeProjectSnapshot(
        snapshot.path,
        p.join(fixture.path, 'sandbox'),
        boundary: snapshot.path,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(outside.readAsStringSync(), 'outside');
  }, skip: Platform.isWindows);
}
