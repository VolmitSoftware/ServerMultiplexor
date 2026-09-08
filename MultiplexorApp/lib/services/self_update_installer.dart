import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'self_update_release.dart';

const int _maxExecutableBytes = 128 * 1024 * 1024;
const String _helperCommand = '--internal-self-update';
const String _cleanupEnvironment = 'MULTIPLEXOR_UPDATE_CLEANUP';
const Duration _validationTimeout = Duration(seconds: 15);
const Duration _helperTimeout = Duration(seconds: 60);
final Set<String> _activeInstalls = <String>{};

/// Returns true when Windows has handed installation to a helper and must exit.
Future<bool> installSelfUpdate({
  required File archive,
  required String currentVersion,
  required String version,
  required String executableName,
  required String targetPath,
  required List<String> restartArguments,
  required String workingDirectory,
}) async {
  final UpdateVersion installedVersion = UpdateVersion.parse(currentVersion);
  final UpdateVersion candidateVersion = UpdateVersion.parse(version);
  if (candidateVersion.compareTo(installedVersion) <= 0) {
    throw StateError(
      'The update must be newer than Multiplexor $currentVersion.',
    );
  }
  if (executableName != 'multiplexor' && executableName != 'multiplexor.exe') {
    throw const FormatException('Unexpected update executable name.');
  }
  final File target = File(await File(targetPath).resolveSymbolicLinks());
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FileSystemException('Update target is not a regular file.');
  }
  if (!_activeInstalls.add(target.path)) {
    throw StateError('Another update is already installing Multiplexor.');
  }
  RandomAccessFile? lock;
  Directory? stage;
  bool handedOff = false;
  bool preserveStage = false;
  try {
    lock = await _acquireLock(target);
    final String previousHash = await _hash(target);
    stage = await target.parent.createTemp('.multiplexor-update-');
    final File candidate = File(p.join(stage.path, executableName));
    await _extract(archive, candidate, executableName);
    if (!Platform.isWindows) {
      final ProcessResult mode = await Process.run('/bin/chmod', <String>[
        '0755',
        candidate.path,
      ]);
      if (mode.exitCode != 0) {
        throw const FileSystemException('Cannot make the update executable.');
      }
    }
    await _validateExecutable(candidate, candidateVersion.text);
    if (await _hash(target) != previousHash) {
      throw StateError('Multiplexor changed while the update was prepared.');
    }
    try {
      await _validateExecutable(target, installedVersion.text);
    } on Exception catch (error) {
      throw StateError(
        'The installed Multiplexor no longer matches this process. '
        'Reopen Multiplexor before updating: $error',
      );
    }
    if (await _hash(target) != previousHash) {
      throw StateError('Multiplexor changed while the update was prepared.');
    }
    final File backup = File(p.join(stage.path, 'previous.exe'));
    if (!Platform.isWindows) {
      await target.copy(backup.path);
      try {
        await candidate.rename(target.path);
      } on FileSystemException {
        preserveStage = true;
        if (!await target.exists() || await _hash(target) != previousHash) {
          try {
            await backup.rename(target.path);
          } on FileSystemException catch (error) {
            throw FileSystemException(
              'Update restore failed: $error. The previous executable was retained',
              backup.path,
            );
          }
        }
        preserveStage = false;
        rethrow;
      }
      return false;
    }

    final File helper = await target.copy(p.join(stage.path, 'helper.exe'));
    final File planFile = File(p.join(stage.path, 'plan.json'));
    final _UpdatePlan plan = _UpdatePlan(
      stage: stage,
      target: target,
      executableName: executableName,
      previousHash: previousHash,
      candidateHash: await _hash(candidate),
      version: candidateVersion.text,
      parentPid: pid,
      restartArguments: restartArguments,
      workingDirectory: workingDirectory,
    );
    await planFile.writeAsString(jsonEncode(plan.toJson()), flush: true);
    final Process process = await Process.start(
      helper.path,
      <String>[_helperCommand, planFile.path],
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    int? helperExitCode;
    unawaited(process.exitCode.then((int code) => helperExitCode = code));
    final File ready = File(p.join(stage.path, 'ready'));
    final Stopwatch wait = Stopwatch()..start();
    try {
      while (!await ready.exists()) {
        if (helperExitCode != null) {
          throw StateError(
            'The update helper exited with code $helperExitCode.',
          );
        }
        if (wait.elapsed >= const Duration(seconds: 10)) {
          throw StateError('The update helper did not start.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if ((await ready.readAsString()).trim() != '${process.pid}') {
        throw StateError('The update helper did not acknowledge installation.');
      }
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        preserveStage = true;
      }
      rethrow;
    }
    handedOff = true;
    return true;
  } finally {
    await lock?.close();
    _activeInstalls.remove(target.path);
    if (!handedOff && !preserveStage && stage != null) {
      try {
        if (await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } on FileSystemException {
        // Cleanup must not turn a completed replacement into a failed update.
      }
    }
  }
}

/// Dispatch before argument parsing or workspace initialization.
Future<int?> runSelfUpdateHelper(List<String> arguments) async {
  if (arguments.isEmpty || arguments.first != _helperCommand) {
    await _cleanupFinishedUpdate();
    return null;
  }
  if (!Platform.isWindows || arguments.length != 2) {
    stderr.writeln('[ERROR] Invalid self-update helper invocation.');
    return 2;
  }
  _UpdatePlan? plan;
  bool replaced = false;
  bool movedPrevious = false;
  RandomAccessFile? lock;
  try {
    plan = await _UpdatePlan.read(File(arguments[1]));
    if (!p.equals(
      await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
      p.join(plan.stage.path, 'helper.exe'),
    )) {
      throw StateError('The updater must run from its staged helper.');
    }
    final _WindowsProcess parent = _WindowsProcess.open(plan.parentPid);
    try {
      final File ready = File(p.join(plan.stage.path, 'ready.tmp'));
      await ready.writeAsString('$pid', flush: true);
      await ready.rename(p.join(plan.stage.path, 'ready'));
      await parent.wait(_helperTimeout);
    } finally {
      parent.close();
    }
    lock = await _acquireLock(plan.target);
    if (await _hash(plan.target) != plan.previousHash ||
        await _hash(plan.candidate) != plan.candidateHash) {
      throw StateError('An executable changed before update installation.');
    }
    await _validateExecutable(plan.candidate, plan.version);
    await _retryFileOperation(() => plan!.target.rename(plan.backup.path));
    movedPrevious = true;
    await _retryFileOperation(() => plan!.candidate.rename(plan.target.path));
    replaced = true;
    await File(
      p.join(plan.stage.path, 'complete'),
    ).writeAsString('$pid', flush: true);
    await _restart(plan, cleanStage: true);
    return 0;
  } catch (error) {
    stderr.writeln('[ERROR] Multiplexor update failed: $error');
    if (plan != null) {
      try {
        await File(
          p.join(plan.stage.path, 'error.txt'),
        ).writeAsString('$error\n', flush: true);
        if (movedPrevious) {
          if (replaced && await plan.target.exists()) {
            await _retryFileOperation(() => plan!.target.delete());
          }
          await _retryFileOperation(
            () => plan!.backup.rename(plan.target.path),
          );
        }
        if (lock != null) {
          await _restart(plan, cleanStage: false);
        }
      } catch (rollbackError) {
        stderr.writeln(
          '[ERROR] Restore failed: $rollbackError. '
          'The previous executable is at ${plan.backup.path}.',
        );
      }
    }
    return 1;
  } finally {
    await lock?.close();
  }
}

Future<void> _extract(File archive, File candidate, String name) async {
  final int archiveSize = await archive.length();
  if (archiveSize <= 0 || archiveSize > _maxExecutableBytes) {
    throw const FormatException('Update archive exceeds the size limit.');
  }
  if (archive.path.endsWith('.tar.gz')) {
    final File tar = File(p.join(candidate.parent.path, 'payload.tar'));
    try {
      await _writeBounded(
        archive.openRead().transform(gzip.decoder),
        tar,
        _maxExecutableBytes + 10240,
      );
      final RandomAccessFile input = await tar.open();
      late int size;
      try {
        final Uint8List header = await input.read(512);
        if (header.length != 512 ||
            _tarString(header, 0, 100) != name ||
            _tarString(header, 345, 155).isNotEmpty ||
            _tarString(header, 157, 100).isNotEmpty ||
            (header[156] != 0 && header[156] != 48)) {
          throw const FormatException(
            'Update archive must contain one regular executable.',
          );
        }
        int checksum = 0;
        for (int index = 0; index < 512; index++) {
          checksum += index >= 148 && index < 156 ? 32 : header[index];
        }
        if (_tarNumber(header, 148, 8) != checksum) {
          throw const FormatException('Update tar header checksum is invalid.');
        }
        size = _tarNumber(header, 124, 12);
        if (size <= 0 || size > _maxExecutableBytes) {
          throw const FormatException(
            'Update executable exceeds the size limit.',
          );
        }
        final int total = await input.length();
        final int trailerSize = total - 512 - size;
        if (total % 512 != 0 || trailerSize < 1024 || trailerSize > 10240) {
          throw const FormatException('Update tar archive is incomplete.');
        }
        await input.setPosition(512 + size);
        if ((await input.read(trailerSize)).any((int byte) => byte != 0)) {
          throw const FormatException(
            'Update archive must contain only the expected executable.',
          );
        }
      } finally {
        await input.close();
      }
      await _writeBounded(tar.openRead(512, 512 + size), candidate, size);
    } finally {
      if (await tar.exists()) {
        await tar.delete();
      }
    }
  } else if (archive.path.endsWith('.zip')) {
    await _extractZip(archive, candidate, name);
  } else {
    throw const FormatException('Unsupported update archive format.');
  }
}

String _tarString(Uint8List bytes, int start, int count) {
  final List<int> field = bytes.sublist(start, start + count);
  final int end = field.indexOf(0);
  return utf8.decode(end < 0 ? field : field.sublist(0, end));
}

int _tarNumber(Uint8List bytes, int start, int count) {
  final String value = _tarString(bytes, start, count).trim();
  if (!RegExp(r'^[0-7]+$').hasMatch(value)) {
    throw const FormatException('Invalid update tar size or checksum.');
  }
  return int.parse(value, radix: 8);
}

Future<void> _extractZip(File archive, File candidate, String name) async {
  final RandomAccessFile file = await archive.open();
  try {
    final int length = await file.length();
    final int tailStart = length > 65557 ? length - 65557 : 0;
    await file.setPosition(tailStart);
    final Uint8List tail = await file.read(length - tailStart);
    final ByteData data = ByteData.sublistView(tail);
    int end = tail.length - 22;
    while (end >= 0 && data.getUint32(end, Endian.little) != 0x06054b50) {
      end--;
    }
    if (end < 0 ||
        end + 22 + data.getUint16(end + 20, Endian.little) != tail.length ||
        data.getUint16(end + 4, Endian.little) != 0 ||
        data.getUint16(end + 6, Endian.little) != 0 ||
        data.getUint16(end + 8, Endian.little) != 1 ||
        data.getUint16(end + 10, Endian.little) != 1 ||
        data.getUint32(end + 12, Endian.little) > 65536 ||
        data.getUint32(end + 16, Endian.little) +
                data.getUint32(end + 12, Endian.little) !=
            tailStart + end) {
      throw const FormatException(
        'Update zip must contain one regular executable.',
      );
    }
  } finally {
    await file.close();
  }
  final InputFileStream input = InputFileStream(archive.path);
  try {
    final ZipDirectory directory = ZipDirectory()..read(input);
    if (directory.fileHeaders.length != 1) {
      throw const FormatException('Update zip must contain one executable.');
    }
    final ZipFileHeader header = directory.fileHeaders.single;
    final ZipFile? entry = header.file;
    final int type = (header.externalFileAttributes >> 16) & 0xf000;
    if (entry == null ||
        header.filename != name ||
        entry.filename != name ||
        (type != 0 && type != 0x8000) ||
        (header.externalFileAttributes & 0x10) != 0 ||
        (header.generalPurposeBitFlag & 1) != 0 ||
        (entry.flags & 1) != 0 ||
        (header.compressionMethod != 0 && header.compressionMethod != 8) ||
        header.localHeaderOffset != 0 ||
        header.uncompressedSize <= 0 ||
        header.uncompressedSize > _maxExecutableBytes ||
        header.uncompressedSize != entry.uncompressedSize ||
        header.compressedSize != entry.compressedSize ||
        header.crc32 != entry.crc32 ||
        input.position != directory.centralDirectoryOffset) {
      throw const FormatException('Invalid executable in update zip.');
    }
    final InputStream compressed = entry.getStream(decompress: false);
    Stream<List<int>> bytes = _archiveChunks(compressed);
    if (header.compressionMethod == 8) {
      bytes = bytes.transform(ZLibDecoder(raw: true));
    }
    int crc = 0;
    final int count = await _writeBounded(
      bytes.map((List<int> chunk) {
        crc = getCrc32(chunk, crc);
        return chunk;
      }),
      candidate,
      header.uncompressedSize,
    );
    if (count != header.uncompressedSize || crc != header.crc32) {
      throw const FormatException('Update zip content checksum is invalid.');
    }
  } finally {
    await input.close();
  }
}

Stream<List<int>> _archiveChunks(InputStream input) async* {
  while (!input.isEOS) {
    yield input
        .readBytes(input.length > 65536 ? 65536 : input.length)
        .toUint8List();
  }
}

Future<int> _writeBounded(
  Stream<List<int>> bytes,
  File target,
  int limit,
) async {
  final RandomAccessFile output = await target.open(mode: FileMode.write);
  int count = 0;
  try {
    await for (final List<int> chunk in bytes) {
      count += chunk.length;
      if (count > limit) {
        throw const FormatException('Update expansion exceeds the size limit.');
      }
      await output.writeFrom(chunk);
    }
    await output.flush();
    return count;
  } finally {
    await output.close();
  }
}

Future<void> _validateExecutable(File executable, String version) async {
  final Process process = await Process.start(executable.path, <String>[
    'version',
  ], workingDirectory: executable.parent.path);
  final BytesBuilder output = BytesBuilder(copy: false);
  int count = 0;
  bool overflow = false;
  void receive(List<int> bytes, {required bool stdout}) {
    count += bytes.length;
    if (count > 65536) {
      overflow = true;
      process.kill(ProcessSignal.sigkill);
    } else if (stdout) {
      output.add(bytes);
    }
  }

  final Completer<void> stdoutDone = Completer<void>();
  final Completer<void> stderrDone = Completer<void>();
  final StreamSubscription<List<int>> stdoutStream = process.stdout.listen(
    (List<int> bytes) => receive(bytes, stdout: true),
    onDone: stdoutDone.complete,
    onError: stdoutDone.completeError,
  );
  final StreamSubscription<List<int>> stderrStream = process.stderr.listen(
    (List<int> bytes) => receive(bytes, stdout: false),
    onDone: stderrDone.complete,
    onError: stderrDone.completeError,
  );
  try {
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      process.exitCode,
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(_validationTimeout);
    final int result = results.first! as int;
    final String firstLine =
        const LineSplitter()
            .convert(utf8.decode(output.takeBytes(), allowMalformed: true))
            .firstOrNull ??
        '';
    if (result != 0 || overflow || firstLine != 'Multiplexor CLI v$version') {
      throw StateError(
        'The update executable did not report version $version.',
      );
    }
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError('The update executable did not respond to version.');
  } finally {
    await stdoutStream.cancel();
    await stderrStream.cancel();
  }
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<RandomAccessFile> _acquireLock(File target) async {
  final File file = File(
    p.join(target.parent.path, '.${p.basename(target.path)}.update.lock'),
  );
  if (await FileSystemEntity.type(file.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FileSystemException('Update lock cannot be a symbolic link.');
  }
  final RandomAccessFile lock = await file.open(mode: FileMode.append);
  try {
    await _retryFileOperation(() => lock.lock(FileLock.exclusive));
    return lock;
  } catch (_) {
    await lock.close();
    rethrow;
  }
}

Future<void> _retryFileOperation(Future<Object?> Function() operation) async {
  final Stopwatch timer = Stopwatch()..start();
  while (true) {
    try {
      await operation();
      return;
    } on FileSystemException {
      if (timer.elapsed >= _helperTimeout) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _restart(_UpdatePlan plan, {required bool cleanStage}) async {
  await Process.start(
    plan.target.path,
    plan.restartArguments,
    workingDirectory: plan.workingDirectory,
    environment: <String, String>{
      _cleanupEnvironment: cleanStage
          ? p.join(plan.stage.path, 'plan.json')
          : '',
    },
    mode: ProcessStartMode.inheritStdio,
  );
}

Future<void> _cleanupFinishedUpdate() async {
  final String? path = Platform.environment[_cleanupEnvironment];
  if (!Platform.isWindows || path == null || path.isEmpty) {
    return;
  }
  try {
    final _UpdatePlan plan = await _UpdatePlan.read(File(path));
    if (!p.equals(
      plan.target.path,
      await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
    )) {
      return;
    }
    final File complete = File(p.join(plan.stage.path, 'complete'));
    final int helperPid = int.parse(await complete.readAsString());
    final _WindowsProcess? helper = _WindowsProcess.tryOpen(helperPid);
    if (helper != null) {
      try {
        await helper.wait(const Duration(seconds: 10));
      } finally {
        helper.close();
      }
    }
    for (final String name in <String>[
      'helper.exe',
      'previous.exe',
      'ready',
      'plan.json',
      'complete',
    ]) {
      final File file = File(p.join(plan.stage.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
    await plan.stage.delete();
  } catch (_) {
    // A locked helper can be removed with its completed staging directory later.
  }
}

class _UpdatePlan {
  _UpdatePlan({
    required this.stage,
    required this.target,
    required this.executableName,
    required this.previousHash,
    required this.candidateHash,
    required this.version,
    required this.parentPid,
    required this.restartArguments,
    required this.workingDirectory,
  });

  final Directory stage;
  final File target;
  final String executableName;
  final String previousHash;
  final String candidateHash;
  final String version;
  final int parentPid;
  final List<String> restartArguments;
  final String workingDirectory;
  File get candidate => File(p.join(stage.path, executableName));
  File get backup => File(p.join(stage.path, 'previous.exe'));

  Map<String, Object> toJson() => <String, Object>{
    'target': target.path,
    'executableName': executableName,
    'previousHash': previousHash,
    'candidateHash': candidateHash,
    'version': version,
    'parentPid': parentPid,
    'restartArguments': restartArguments,
    'workingDirectory': workingDirectory,
  };

  static Future<_UpdatePlan> read(File file) async {
    if (p.basename(file.path) != 'plan.json' || await file.length() > 65536) {
      throw const FormatException('Invalid self-update plan.');
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded['target'] is! String ||
        decoded['executableName'] != 'multiplexor.exe' ||
        decoded['previousHash'] is! String ||
        decoded['candidateHash'] is! String ||
        decoded['version'] is! String ||
        decoded['parentPid'] is! int ||
        decoded['restartArguments'] is! List<Object?> ||
        decoded['workingDirectory'] is! String) {
      throw const FormatException('Invalid self-update plan.');
    }
    final Directory stage = Directory(await file.parent.resolveSymbolicLinks());
    final File target = File(decoded['target']! as String);
    if (!p.isAbsolute(target.path) ||
        !p.equals(target.parent.path, stage.parent.path) ||
        !p.basename(stage.path).startsWith('.multiplexor-update-') ||
        p.equals(target.parent.path, target.path) ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(decoded['previousHash']! as String) ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(decoded['candidateHash']! as String) ||
        (decoded['parentPid']! as int) <= 0 ||
        (decoded['restartArguments']! as List<Object?>).any(
          (Object? value) => value is! String,
        )) {
      throw const FormatException(
        'Invalid self-update plan paths or metadata.',
      );
    }
    return _UpdatePlan(
      stage: stage,
      target: target,
      executableName: decoded['executableName']! as String,
      previousHash: decoded['previousHash']! as String,
      candidateHash: decoded['candidateHash']! as String,
      version: decoded['version']! as String,
      parentPid: decoded['parentPid']! as int,
      restartArguments: (decoded['restartArguments']! as List<Object?>)
          .cast<String>(),
      workingDirectory: decoded['workingDirectory']! as String,
    );
  }
}

class _WindowsProcess {
  _WindowsProcess(this.handle);

  static final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');
  static final Pointer<Void> Function(int, int, int) _open = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final int Function(Pointer<Void>, int) _wait = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  static final int Function(Pointer<Void>) _close = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');

  final Pointer<Void> handle;

  static _WindowsProcess? tryOpen(int processId) {
    final Pointer<Void> handle = _open(0x00100000, 0, processId);
    return handle == nullptr ? null : _WindowsProcess(handle);
  }

  static _WindowsProcess open(int processId) =>
      tryOpen(processId) ??
      (throw StateError('Cannot wait for the updating process.'));

  Future<void> wait(Duration timeout) async {
    final Stopwatch timer = Stopwatch()..start();
    while (true) {
      final int status = _wait(handle, 0);
      if (status == 0) {
        return;
      }
      if (status != 258 || timer.elapsed >= timeout) {
        throw StateError('Timed out waiting for the updating process to exit.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void close() => _close(handle);
}
