import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'remote_profiler_gateway.dart';
import 'remote_profiler_models.dart';

final class RemoteProfilerService {
  RemoteProfilerService({
    required RemoteProfilerGateway gateway,
    required String stateDirectory,
  }) : _gateway = gateway,
       _directory = Directory(stateDirectory);

  static final Set<String> _activeLocks = <String>{};
  final RemoteProfilerGateway _gateway;
  final Directory _directory;

  Future<RemoteProfilerCheck> check(String selector) async =>
      _gateway.inspect(await _gateway.resolveTarget(selector));

  Future<RemoteProfilerCapture> start(
    String selector,
    RemoteProfilerOptions options,
  ) async {
    options.validate();
    final RemoteProfilerTarget target = await _gateway.resolveTarget(selector);
    return _locked(target, () async {
      final RemoteProfilerCapture? previous = await _read(target);
      if (previous != null && previous.blocksCapture) {
        throw StateError(
          'Capture ${previous.id} is unfinished. Fetch its snapshot or recover its startup settings before another capture.',
        );
      }
      final RemoteProfilerCheck check = await _gateway.inspect(target);
      if (!check.ready) throw StateError(check.issues.join('\n'));
      if (options.attach && !check.isRunning) {
        throw StateError(
          'Server ${target.name} must be running for attachment. Start it normally first or select --startup.',
        );
      }
      if (!options.attach && check.isRunning && !options.restart) {
        throw StateError(
          'Server ${target.name} is running. Use --restart to authorize a graceful restart for startup profiling.',
        );
      }
      final DateTime now = DateTime.now().toUtc();
      final String id =
          '${now.microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
      RemoteProfilerCapture capture = RemoteProfilerCapture(
        id: id,
        target: target,
        createdAt: now,
        originalStartup: check.startupCommand,
        durationSeconds: options.duration.inSeconds,
        live: options.live,
        port: options.port,
        phase: RemoteProfilerPhase.preparing,
        attached: options.attach,
        startupRestored: options.attach,
      );
      await _save(capture);
      try {
        final RemoteProfilerStage stage = await _gateway.stage(
          target,
          id,
          options,
        );
        capture = capture.copyWith(
          stage: stage,
          phase: RemoteProfilerPhase.staged,
        );
        await _save(capture);
        if (options.attach) {
          capture = capture.copyWith(phase: RemoteProfilerPhase.starting);
          await _save(capture);
          await _gateway.attach(target, stage, options);
        } else {
          if (await _gateway.readStartup(target) != capture.originalStartup) {
            throw StateError(
              'Startup settings changed during preparation. No launch settings were applied.',
            );
          }
          if (check.isRunning) {
            await _gateway.stopGracefully(target, const Duration(minutes: 2));
          }
          if (await _gateway.readStartup(target) != capture.originalStartup) {
            throw StateError(
              'Startup settings changed before launch. No launch settings were applied.',
            );
          }
          capture = capture.copyWith(phase: RemoteProfilerPhase.starting);
          await _save(capture);
          await _gateway.writeStartup(target, stage.startupCommand);
          await _gateway.start(target);
        }
        if (!await _gateway.confirmLaunch(
          target,
          stage,
          const Duration(minutes: 2),
        )) {
          throw StateError(
            'The profiling agent did not confirm loading in the target JVM. Inspect the server logs before retrying.',
          );
        }
        capture = capture.copyWith(phase: RemoteProfilerPhase.recording);
        await _save(capture);
        capture = await _restore(capture);
        await _save(capture);
        return capture;
      } catch (error) {
        capture = capture.copyWith(
          phase: RemoteProfilerPhase.failed,
          error: error.toString(),
        );
        try {
          capture = await _restore(capture);
        } catch (restoreError) {
          capture = capture.copyWith(
            error: '$error; startup restoration failed: $restoreError',
          );
        }
        await _save(capture);
        rethrow;
      }
    });
  }

  Future<RemoteProfilerCapture> status(String selector) async {
    final RemoteProfilerTarget target = await _gateway.resolveTarget(selector);
    return _locked(target, () async {
      RemoteProfilerCapture capture = await _require(target);
      final RemoteProfilerStage? stage = capture.stage;
      if (stage != null &&
          (capture.phase == RemoteProfilerPhase.recording ||
              capture.phase == RemoteProfilerPhase.ready)) {
        final List<RemoteProfilerSnapshot> snapshots = await _gateway
            .listSnapshots(target, stage.remoteDirectory);
        final bool ready = snapshots.any(
          (RemoteProfilerSnapshot snapshot) =>
              snapshot.size > 0 &&
              p.posix.extension(snapshot.path) == '.jps' &&
              p.posix.isWithin(stage.remoteDirectory, snapshot.path),
        );
        capture = capture.copyWith(
          phase: ready
              ? RemoteProfilerPhase.ready
              : RemoteProfilerPhase.recording,
          error: capture.error,
        );
        await _save(capture);
      }
      return capture;
    });
  }

  Future<RemoteProfilerCapture> recover(String selector) async {
    final RemoteProfilerTarget target = await _gateway.resolveTarget(selector);
    return _locked(target, () async {
      RemoteProfilerCapture capture = await _require(target);
      capture = await _restore(capture);
      if (capture.startupRestored) {
        capture = capture.copyWith(phase: RemoteProfilerPhase.recovered);
      }
      await _save(capture);
      return capture;
    });
  }

  Future<RemoteProfilerFetch> fetch(
    String selector, {
    String? destinationDirectory,
  }) async {
    final RemoteProfilerTarget target = await _gateway.resolveTarget(selector);
    return _locked(target, () async {
      RemoteProfilerCapture capture = await _require(target);
      final RemoteProfilerStage? stage = capture.stage;
      if (stage == null) {
        throw StateError(
          'Capture preparation did not finish. Recover startup settings before retrying.',
        );
      }
      final List<RemoteProfilerSnapshot> snapshots = await _gateway
          .listSnapshots(target, stage.remoteDirectory);
      final List<RemoteProfilerSnapshot> available = snapshots
          .where(
            (RemoteProfilerSnapshot snapshot) =>
                snapshot.size > 0 && p.posix.extension(snapshot.path) == '.jps',
          )
          .toList();
      if (available.isEmpty) {
        throw StateError(
          'No completed snapshot is available yet for capture ${capture.id}.',
        );
      }
      final Directory destination = Directory(
        destinationDirectory ??
            p.join(_directory.path, 'artifacts', target.key, capture.id),
      );
      await destination.create(recursive: true);
      if (destinationDirectory == null) {
        await _permissions(destination.path, '700');
      }
      final List<String> files = <String>[];
      for (final RemoteProfilerSnapshot snapshot in available) {
        if (!p.posix.isWithin(stage.remoteDirectory, snapshot.path)) {
          throw StateError('Snapshot is outside the capture directory.');
        }
        final String localPath = p.join(
          destination.path,
          p.posix.basename(snapshot.path),
        );
        final File partial = File('$localPath.partial');
        try {
          await _gateway.download(target, snapshot.path, partial.path);
          final List<RemoteProfilerSnapshot> after = await _gateway
              .listSnapshots(target, stage.remoteDirectory);
          if (!await partial.exists() ||
              await partial.length() != snapshot.size ||
              !after.any(
                (RemoteProfilerSnapshot current) =>
                    current.path == snapshot.path &&
                    current.size == snapshot.size,
              )) {
            throw StateError(
              'Snapshot ${p.posix.basename(snapshot.path)} is incomplete or still changing. Retry fetch once recording has finished.',
            );
          }
          await _permissions(partial.path, '600');
          await partial.rename(localPath);
          files.add(localPath);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
      final String logsPath = p.join(destination.path, 'startup.log');
      final File logsPartial = File('$logsPath.partial');
      try {
        await _gateway.downloadLogs(
          target,
          stage.remoteDirectory,
          logsPartial.path,
        );
        await _permissions(logsPartial.path, '600');
        await logsPartial.rename(logsPath);
      } finally {
        if (await logsPartial.exists()) await logsPartial.delete();
      }
      capture = await _restore(capture);
      capture = capture.copyWith(
        phase: capture.startupRestored
            ? (capture.phase == RemoteProfilerPhase.failed
                  ? RemoteProfilerPhase.failed
                  : RemoteProfilerPhase.complete)
            : RemoteProfilerPhase.operatorChanged,
        error: capture.error,
        files: files,
      );
      await _save(capture);
      return RemoteProfilerFetch(
        capture: capture,
        files: List<String>.unmodifiable(files),
        logsPath: logsPath,
      );
    });
  }

  Future<RemoteProfilerTunnel> openTunnel(
    String selector, {
    int localPort = 8849,
  }) async {
    if (localPort < 1 || localPort > 65535) {
      throw ArgumentError.value(localPort, 'localPort');
    }
    final RemoteProfilerTarget target = await _gateway.resolveTarget(selector);
    return _locked(target, () async {
      final RemoteProfilerCapture capture = await _require(target);
      final RemoteProfilerStage? stage = capture.stage;
      if (!capture.live ||
          stage == null ||
          capture.phase == RemoteProfilerPhase.failed ||
          capture.phase == RemoteProfilerPhase.preparing ||
          capture.phase == RemoteProfilerPhase.staged) {
        throw StateError(
          'Start a live profiling capture before opening a tunnel.',
        );
      }
      if (!await _gateway.confirmLaunch(
        target,
        stage,
        const Duration(seconds: 5),
      )) {
        throw StateError(
          'The capture JVM is no longer running with the profiling agent.',
        );
      }
      return _gateway.openTunnel(target, capture.port, localPort);
    });
  }

  Future<RemoteProfilerCapture> _restore(RemoteProfilerCapture capture) async {
    if (capture.startupRestored) return capture;
    final RemoteProfilerStage? stage = capture.stage;
    if (stage == null) return capture.copyWith(startupRestored: true);
    final String current = await _gateway.readStartup(capture.target);
    if (current == capture.originalStartup) {
      return capture.copyWith(startupRestored: true, error: capture.error);
    }
    if (current != stage.startupCommand) {
      return capture.copyWith(
        phase: RemoteProfilerPhase.operatorChanged,
        error:
            'Startup settings were changed outside this capture and were preserved. Restore or keep those settings explicitly before starting another capture.',
      );
    }
    await _gateway.writeStartup(capture.target, capture.originalStartup);
    return capture.copyWith(startupRestored: true, error: capture.error);
  }

  Future<RemoteProfilerCapture> _require(RemoteProfilerTarget target) async {
    final RemoteProfilerCapture? capture = await _read(target);
    if (capture == null) {
      throw StateError('No profiling capture exists for ${target.name}.');
    }
    return capture;
  }

  Future<RemoteProfilerCapture?> _read(RemoteProfilerTarget target) async {
    final File file = File(p.join(_directory.path, target.key, 'capture.json'));
    if (!await file.exists()) return null;
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid remote capture state.');
    }
    final RemoteProfilerCapture capture = RemoteProfilerCapture.fromJson(
      decoded,
    );
    if (capture.target.key != target.key) {
      throw const FormatException(
        'Remote capture target does not match its state directory.',
      );
    }
    return capture;
  }

  Future<void> _save(RemoteProfilerCapture capture) async {
    final Directory directory = Directory(
      p.join(_directory.path, capture.target.key),
    );
    await directory.create(recursive: true);
    await _permissions(directory.path, '700');
    final File temporary = File(p.join(directory.path, 'capture.json.tmp'));
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(capture.toJson())}\n',
      flush: true,
    );
    await _permissions(temporary.path, '600');
    await temporary.rename(p.join(directory.path, 'capture.json'));
    final File history = File(p.join(directory.path, '${capture.id}.json.tmp'));
    await history.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(capture.toJson())}\n',
      flush: true,
    );
    await _permissions(history.path, '600');
    await history.rename(p.join(directory.path, '${capture.id}.json'));
  }

  Future<void> _permissions(String path, String mode) async {
    if (Platform.isWindows) return;
    final ProcessResult result = await Process.run('chmod', <String>[
      mode,
      path,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Cannot restrict profiling state permissions.',
        path,
      );
    }
  }

  Future<T> _locked<T>(
    RemoteProfilerTarget target,
    Future<T> Function() operation,
  ) async {
    final Directory directory = Directory(p.join(_directory.path, target.key));
    await _directory.create(recursive: true);
    await _permissions(_directory.path, '700');
    await directory.create(recursive: true);
    await _permissions(directory.path, '700');
    final String lockPath = p.normalize(
      p.absolute(p.join(directory.path, 'capture.lock')),
    );
    if (!_activeLocks.add(lockPath)) {
      throw StateError(
        'Another profiling operation is active for ${target.name}.',
      );
    }
    RandomAccessFile? lock;
    bool acquired = false;
    try {
      lock = await File(lockPath).open(mode: FileMode.append);
      await _permissions(lockPath, '600');
      await lock.lock(FileLock.exclusive);
      acquired = true;
      return await operation();
    } on FileSystemException catch (error) {
      if (!acquired) {
        throw StateError(
          'Cannot lock profiling state for ${target.name}: ${error.message}',
        );
      }
      rethrow;
    } finally {
      try {
        if (acquired) await lock?.unlock();
      } finally {
        await lock?.close();
        _activeLocks.remove(lockPath);
      }
    }
  }
}
