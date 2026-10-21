import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_files.dart';
import 'project_model.dart';
import 'project_store.dart';

class ProjectGradleCache {
  ProjectGradleCache(this.store, this.runId, {this.cancelled});

  final ProjectStore store;
  final String runId;
  final bool Function()? cancelled;
  Directory get taskCache =>
      Directory(p.join(store.workDirectory.path, 'task-cache'));
  Directory get _seed =>
      Directory(p.join(store.runWork(runId).path, 'cache-seed'));
  Directory? dependencyCache;
  int _filesCopied = 0;

  Directory home(String key) => Directory(
    p.join(
      store.workDirectory.path,
      'gradle',
      projectDigest(key).substring(0, 16),
    ),
  );

  Future<void> prepare() async {
    taskCache.createSync(recursive: true);
    if (!_ownedDirectory(taskCache)) {
      throw FileSystemException('Invalid project task cache', taskCache.path);
    }
    List<Map<String, Object?>> runs = store.runs();
    Set<String> active = <String>{
      for (Map<String, Object?> run in runs)
        if (run['id'] != runId)
          for (Object? value in run['jobs'] as List<Object?>)
            if (<String>{
              'queued',
              'preparing',
              'running',
            }.contains(projectObject(value)['status']))
              projectObject(value)['key'] as String,
    };
    Set<String> seen = <String>{};
    for (Map<String, Object?> run in runs) {
      if (cancelled?.call() == true) {
        return;
      }
      if (run['id'] == runId) {
        continue;
      }
      for (Object? value in run['jobs'] as List<Object?>) {
        if (cancelled?.call() == true) {
          return;
        }
        Map<String, Object?> job = projectObject(value);
        String key = job['key'] as String;
        if (job['status'] != 'succeeded' ||
            active.contains(key) ||
            !seen.add(key)) {
          continue;
        }
        String project = projectIdentifier(job['project']);
        String target = projectIdentifier(job['target']);
        String log = p.join(
          store.runWork(run['id'] as String).path,
          'logs',
          project,
          '$target.log',
        );
        if (job['logPath'] != log || File('$log.process.json').existsSync()) {
          continue;
        }
        Directory donor = home(key);
        if (!_ownedDirectory(donor)) continue;
        RandomAccessFile? lock;
        try {
          lock = _lock(donor);
          await _captureWrappers(donor);
          await _captureTaskEntries(donor);
          Directory modules = Directory(
            p.join(donor.path, 'caches', 'modules-2'),
          );
          if (dependencyCache == null &&
              _ownedDirectory(modules) &&
              Directory(p.join(modules.path, 'files-2.1')).existsSync()) {
            Directory staging = Directory(
              p.join(_seed.path, 'dependencies.pending'),
            );
            await _copyTree(
              modules,
              Directory(p.join(staging.path, 'modules-2')),
            );
            dependencyCache = await staging.rename(
              p.join(_seed.path, 'dependencies'),
            );
          }
        } on FileSystemException {
          Directory pending = Directory(
            p.join(_seed.path, 'dependencies.pending'),
          );
          if (pending.existsSync()) await pending.delete(recursive: true);
        } finally {
          lock?.closeSync();
        }
      }
    }
  }

  Future<T> withHome<T>(
    String key,
    Future<T> Function(Directory home) action,
  ) async {
    Directory directory = home(key)..createSync(recursive: true);
    if (!_ownedDirectory(directory)) {
      throw FileSystemException('Invalid project Gradle home', directory.path);
    }
    RandomAccessFile lock = _lock(directory);
    try {
      Directory seedWrappers = Directory(p.join(_seed.path, 'wrapper'));
      if (seedWrappers.existsSync()) {
        await _installWrappers(seedWrappers, directory);
      }
      _checkCancellation();
      return await action(directory);
    } finally {
      lock.closeSync();
    }
  }

  RandomAccessFile _lock(Directory directory) {
    File file = File(p.join(directory.path, 'multiplexor.lock'));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('Invalid project cache lock', file.path);
    }
    RandomAccessFile lock = file.openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      return lock;
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
  }

  bool _ownedDirectory(Directory directory) =>
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      p.isWithin(
        store.workDirectory.resolveSymbolicLinksSync(),
        directory.resolveSymbolicLinksSync(),
      );

  void _checkCancellation() {
    if (cancelled?.call() == true) {
      throw const FileSystemException('Project cache capture cancelled');
    }
  }

  Future<void> _captureTaskEntries(Directory donor) async {
    Directory source = Directory(p.join(donor.path, 'caches', 'build-cache-1'));
    if (!_ownedDirectory(source)) {
      return;
    }
    for (File file in source.listSync(followLinks: false).whereType<File>()) {
      _checkCancellation();
      String name = p.basename(file.path);
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(name)) {
        continue;
      }
      File destination = File(p.join(taskCache.path, name));
      if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      RandomAccessFile bytes = file.openSync();
      bool valid;
      try {
        List<int> signature = bytes.readSync(3);
        valid =
            signature.length == 3 &&
            signature[0] == 0x1f &&
            signature[1] == 0x8b &&
            signature[2] == 8;
      } finally {
        bytes.closeSync();
      }
      if (!valid) {
        continue;
      }
      File staging = File(p.join(taskCache.path, '$name.$runId.tmp'));
      try {
        await _copyFile(file, staging);
        _checkCancellation();
        await staging.rename(destination.path);
      } finally {
        if (staging.existsSync()) {
          await staging.delete();
        }
      }
    }
  }

  Future<void> _captureWrappers(Directory donor) async {
    Directory wrappers = Directory(p.join(donor.path, 'wrapper', 'dists'));
    if (!_ownedDirectory(wrappers)) return;
    _checkCancellation();
    for (Directory distribution
        in wrappers.listSync(followLinks: false).whereType<Directory>()) {
      for (Directory version
          in distribution.listSync(followLinks: false).whereType<Directory>()) {
        _checkCancellation();
        List<File> markers = version
            .listSync(followLinks: false)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.zip.ok'))
            .toList();
        List<Directory> installs = version
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where(
              (Directory dir) =>
                  File(p.join(dir.path, 'bin', 'gradle')).existsSync() &&
                  Directory(p.join(dir.path, 'lib')).existsSync() &&
                  Directory(p.join(dir.path, 'lib'))
                      .listSync(followLinks: false)
                      .whereType<File>()
                      .any(
                        (File file) =>
                            p
                                .basename(file.path)
                                .startsWith('gradle-launcher-') &&
                            file.path.endsWith('.jar') &&
                            file.lengthSync() > 0,
                      ),
            )
            .toList();
        if (markers.length != 1 || installs.length != 1) continue;
        Directory destination = Directory(
          p.join(
            _seed.path,
            'wrapper',
            'dists',
            p.basename(distribution.path),
            p.basename(version.path),
          ),
        );
        if (destination.existsSync()) continue;
        Directory staging = Directory('${destination.path}.pending');
        try {
          await _copyTree(
            installs.single,
            Directory(p.join(staging.path, p.basename(installs.single.path))),
          );
          await cloneProjectFile(
            markers.single,
            File(p.join(staging.path, p.basename(markers.single.path))),
          );
          _checkCancellation();
          await staging.rename(destination.path);
        } on FileSystemException {
          if (staging.existsSync()) await staging.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _installWrappers(Directory seed, Directory home) async {
    Directory distributions = Directory(p.join(seed.path, 'dists'));
    for (Directory distribution
        in distributions.listSync(followLinks: false).whereType<Directory>()) {
      for (Directory version
          in distribution.listSync(followLinks: false).whereType<Directory>()) {
        _checkCancellation();
        Directory destination = Directory(
          p.join(
            home.path,
            'wrapper',
            'dists',
            p.basename(distribution.path),
            p.basename(version.path),
          ),
        );
        if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        Directory staging = Directory('${destination.path}.pending');
        try {
          await _copyTree(version, staging);
          _checkCancellation();
          await staging.rename(destination.path);
        } on FileSystemException {
          if (staging.existsSync()) {
            await staging.delete(recursive: true);
          }
        }
      }
    }
  }

  Future<void> _copyTree(Directory source, Directory destination) async {
    _checkCancellation();
    if (!_ownedDirectory(source)) {
      throw FileSystemException(
        'Cache source is outside the workspace',
        source.path,
      );
    }
    destination.createSync(recursive: true);
    if (!_ownedDirectory(destination)) {
      throw FileSystemException(
        'Cache destination is outside the workspace',
        destination.path,
      );
    }
    for (FileSystemEntity entry in source.listSync(followLinks: false)) {
      _checkCancellation();
      String name = p.basename(entry.path);
      if (name.endsWith('.lock') ||
          name.endsWith('.lck') ||
          name == 'gc.properties') {
        continue;
      }
      String target = p.join(destination.path, name);
      FileSystemEntityType existing = FileSystemEntity.typeSync(
        target,
        followLinks: false,
      );
      if (existing == FileSystemEntityType.link) {
        throw FileSystemException('Cache destination contains a link', target);
      }
      if (entry is Directory) {
        await _copyTree(entry, Directory(target));
      } else if (entry is File) {
        await _copyFile(entry, File(target));
      } else {
        throw FileSystemException('Unsupported cache source entry', entry.path);
      }
    }
  }

  Future<void> _copyFile(File source, File destination) async {
    _checkCancellation();
    if (++_filesCopied % 128 == 0) {
      await Future<void>.delayed(Duration.zero);
      _checkCancellation();
    }
    FileStat before = source.statSync();
    await cloneProjectFile(source, destination);
    FileStat after = source.statSync();
    if (before.size != after.size ||
        before.modified != after.modified ||
        destination.lengthSync() != before.size) {
      throw FileSystemException(
        'Cache source changed during capture',
        source.path,
      );
    }
  }
}
