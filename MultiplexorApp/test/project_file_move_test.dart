import 'dart:io';

import 'package:multiplexor/services/projects/project_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File source;
  late File target;

  setUp(() {
    root = Directory.systemTemp.createTempSync('project-file-move-');
    source = File(p.join(root.path, 'source'))..writeAsStringSync('complete');
    target = File(p.join(root.path, 'target'));
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('cross-device move copies contents and removes the source', () {
    _CrossDeviceFile crossing = _CrossDeviceFile(source);
    moveProjectFile(crossing, target.path);
    expect(crossing.copyDestination, isNot(target.path));
    expect(p.dirname(crossing.copyDestination!), target.parent.path);
    expect(target.readAsStringSync(), 'complete');
    expect(source.existsSync(), isFalse);
    expect(
      root.listSync().map((FileSystemEntity entry) => entry.path),
      <String>[target.path],
    );
  });

  test('failed cross-device copy removes partial output and keeps source', () {
    expect(
      () => moveProjectFile(
        _CrossDeviceFile(source, failure: _MoveFailure.copy),
        target.path,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'complete');
    expect(target.existsSync(), isFalse);
    expect(
      root.listSync().map((FileSystemEntity entry) => entry.path),
      <String>[source.path],
    );
  });

  test('failed source removal restores the cross-device move boundary', () {
    expect(
      () => moveProjectFile(
        _CrossDeviceFile(source, failure: _MoveFailure.delete),
        target.path,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'complete');
    expect(target.existsSync(), isFalse);
    expect(
      root.listSync().map((FileSystemEntity entry) => entry.path),
      <String>[source.path],
    );
  });

  test('cross-device move preserves an existing destination', () {
    target.writeAsStringSync('existing');
    expect(
      () => moveProjectFile(_CrossDeviceFile(source), target.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'complete');
    expect(target.readAsStringSync(), 'existing');
  });
}

enum _MoveFailure { copy, delete }

class _CrossDeviceFile implements File {
  _CrossDeviceFile(this.file, {this.failure});

  final File file;
  final _MoveFailure? failure;
  String? copyDestination;

  @override
  File renameSync(String newPath) => throw FileSystemException(
    'Cross-device move',
    file.path,
    OSError('Different device', Platform.isWindows ? 17 : 18),
  );

  @override
  File copySync(String newPath) {
    copyDestination = newPath;
    if (failure == _MoveFailure.copy) {
      File(newPath).writeAsStringSync('partial');
      throw FileSystemException('Copy failed', file.path);
    }
    return file.copySync(newPath);
  }

  @override
  void deleteSync({bool recursive = false}) {
    if (failure == _MoveFailure.delete) {
      throw FileSystemException('Delete failed', file.path);
    }
    file.deleteSync(recursive: recursive);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
