import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_store.dart';

const String projectCacheRetentionInit = r'''
if (GradleVersion.current() >= GradleVersion.version('8.0')) {
    beforeSettings { settings ->
        settings.caches {
            cleanup.set(Cleanup.DEFAULT)
            releasedWrappers.removeUnusedEntriesAfterDays = 7
            snapshotWrappers.removeUnusedEntriesAfterDays = 7
            downloadedResources.removeUnusedEntriesAfterDays = 14
            createdResources.removeUnusedEntriesAfterDays = 7
        }
    }
}
''';

class ProjectGradleCache {
  ProjectGradleCache(this.store, this.root);

  final ProjectStore store;
  final Directory root;
  Directory get home => Directory(p.join(root.path, 'gradle-home'));
  Directory get taskCache => Directory(p.join(root.path, 'task-cache'));

  void prepare() {
    for (Directory directory in <Directory>[
      taskCache,
      home,
      Directory(p.join(home.path, 'init.d')),
    ]) {
      directory.createSync(recursive: true);
      if (!_ownedDirectory(directory)) {
        throw FileSystemException(
          'Invalid project Gradle cache',
          directory.path,
        );
      }
    }
    File retention = File(
      p.join(home.path, 'init.d', 'multiplexor-cache-retention.gradle'),
    );
    if (retention.existsSync() &&
        retention.readAsStringSync() == projectCacheRetentionInit) {
      return;
    }
    File('${retention.path}.$pid.tmp')
      ..writeAsStringSync(projectCacheRetentionInit, flush: true)
      ..renameSync(retention.path);
  }

  bool _ownedDirectory(Directory directory) =>
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      p.isWithin(
        store.workDirectory.resolveSymbolicLinksSync(),
        directory.resolveSymbolicLinksSync(),
      );
}
