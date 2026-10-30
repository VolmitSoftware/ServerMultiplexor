import 'dart:io';

import 'package:multiplexor/services/projects/project_gradle_cache.dart';
import 'package:multiplexor/services/projects/project_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late ProjectStore store;
  late ProjectGradleCache cache;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('project-cache-test-');
    store = ProjectStore(fixture.path);
    store.workDirectory.createSync(recursive: true);
    cache = ProjectGradleCache(store, store.workDirectory);
  });
  tearDown(() {
    if (store.workDirectory.existsSync()) {
      store.workDirectory.deleteSync(recursive: true);
    }
    fixture.deleteSync(recursive: true);
  });

  test('every target shares one Gradle home with cache retention', () {
    cache.prepare();
    expect(cache.home.path, p.join(store.workDirectory.path, 'gradle-home'));
    expect(cache.taskCache.existsSync(), isTrue);
    File retention = File(
      p.join(cache.home.path, 'init.d', 'multiplexor-cache-retention.gradle'),
    );
    expect(retention.readAsStringSync(), projectCacheRetentionInit);
    expect(
      projectCacheRetentionInit,
      allOf(<Matcher>[
        contains('beforeSettings { settings ->'),
        contains('settings.caches {'),
        contains('cleanup.set(Cleanup.DEFAULT)'),
        contains('releasedWrappers.removeUnusedEntriesAfterDays = 7'),
        contains('snapshotWrappers.removeUnusedEntriesAfterDays = 7'),
        contains('downloadedResources.removeUnusedEntriesAfterDays = 14'),
        contains('createdResources.removeUnusedEntriesAfterDays = 7'),
      ]),
    );
    retention.writeAsStringSync('edited');
    cache.prepare();
    expect(retention.readAsStringSync(), projectCacheRetentionInit);
  });

  test('a run-local Gradle home stays inside its run', () {
    Directory run = Directory(p.join(store.workDirectory.path, 'runs', 'one'));
    ProjectGradleCache local = ProjectGradleCache(store, run)..prepare();
    expect(local.home.path, p.join(run.path, 'gradle-home'));
    expect(local.taskCache.path, p.join(run.path, 'task-cache'));
    expect(local.taskCache.existsSync(), isTrue);
    expect(
      Directory(p.join(store.workDirectory.path, 'gradle-home')).existsSync(),
      isFalse,
    );
  });

  test('a linked Gradle home outside the work directory is rejected', () {
    Directory outside = Directory(p.join(fixture.path, 'outside'))
      ..createSync();
    Link(cache.home.path).createSync(outside.path);
    expect(cache.prepare, throwsA(isA<FileSystemException>()));
    expect(Directory(p.join(outside.path, 'init.d')).existsSync(), isFalse);
  }, skip: Platform.isWindows);
}
