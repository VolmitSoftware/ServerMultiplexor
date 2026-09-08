import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class SelfUpdateSettings {
  const SelfUpdateSettings({
    this.automatic = true,
    this.lastAttempt,
    this.checkedVersion,
    this.succeeded = false,
  });

  final bool automatic;
  final DateTime? lastAttempt;
  final String? checkedVersion;
  final bool succeeded;

  bool isDue(DateTime now, String version) {
    final DateTime? last = lastAttempt;
    if (last == null || version != checkedVersion || now.isBefore(last)) {
      return true;
    }
    return now.difference(last) >=
        (succeeded ? const Duration(hours: 6) : const Duration(minutes: 15));
  }

  SelfUpdateSettings withAutomatic(bool enabled) => SelfUpdateSettings(
    automatic: enabled,
    lastAttempt: lastAttempt,
    checkedVersion: checkedVersion,
    succeeded: succeeded,
  );

  SelfUpdateSettings attempted(DateTime time, String version, bool success) =>
      SelfUpdateSettings(
        automatic: automatic,
        lastAttempt: time.toUtc(),
        checkedVersion: version,
        succeeded: success,
      );
}

class SelfUpdateStore {
  SelfUpdateStore(Directory directory, String executablePath)
    : file = File(
        p.join(
          directory.path,
          '${sha256.convert(utf8.encode(p.normalize(executablePath)))}.json',
        ),
      );

  final File file;

  static Directory defaultDirectory() {
    final String? home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('Cannot locate the user directory for update settings.');
    }
    return Directory(p.join(home, '.multiplexor', 'self-update'));
  }

  SelfUpdateSettings read() {
    if (!file.existsSync()) return const SelfUpdateSettings();
    final Object? data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, Object?> ||
        data['schema'] != 1 ||
        data['automatic'] is! bool ||
        data['succeeded'] is! bool ||
        (data['checkedVersion'] != null && data['checkedVersion'] is! String) ||
        (data['lastAttempt'] != null && data['lastAttempt'] is! String)) {
      throw const FormatException('Invalid Multiplexor update settings.');
    }
    return SelfUpdateSettings(
      automatic: data['automatic'] as bool,
      succeeded: data['succeeded'] as bool,
      checkedVersion: data['checkedVersion'] as String?,
      lastAttempt: data['lastAttempt'] == null
          ? null
          : DateTime.parse(data['lastAttempt'] as String),
    );
  }

  void write(SelfUpdateSettings settings) {
    file.parent.createSync(recursive: true);
    final File temporary = File('${file.path}.$pid.tmp');
    try {
      temporary.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'automatic': settings.automatic,
          'lastAttempt': settings.lastAttempt?.toUtc().toIso8601String(),
          'checkedVersion': settings.checkedVersion,
          'succeeded': settings.succeeded,
        }),
        flush: true,
      );
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  Future<T> locked<T>(Future<T> Function() action) async {
    file.parent.createSync(recursive: true);
    final RandomAccessFile lock = File(
      '${file.path}.lock',
    ).openSync(mode: FileMode.append);
    try {
      try {
        lock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw const UpdateBusyException();
      }
      return await action();
    } finally {
      lock.closeSync();
    }
  }
}

class UpdateBusyException implements Exception {
  const UpdateBusyException();

  @override
  String toString() => 'Another Multiplexor update is in progress.';
}
