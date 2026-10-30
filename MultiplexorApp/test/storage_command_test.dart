import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/projects/project_store.dart';
import 'package:multiplexor/services/storage_settings.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerContext context;
  late NativeCommandService service;
  late String builds;
  late ProjectStore projects;

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-storage-');
    context = ManagerContext(rootDir: root.path, verbose: false);
    ConsumerService consumers = ConsumerService(context);
    consumers.ensureConsumerDirs(ConsumerProfile.plugin);
    builds = p.join(consumers.rootFor(ConsumerProfile.plugin), 'builds');
    projects = ProjectStore(root.path);
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
    );
  });

  tearDown(() {
    service.disposeRcon();
    if (projects.workDirectory.existsSync()) {
      projects.workDirectory.deleteSync(recursive: true);
    }
    root.deleteSync(recursive: true);
  });

  File jar(String path) => File(p.join(builds, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(path);

  Future<CapturedResult> run(List<String> args) =>
      service.execute(args, stream: false);

  test('storage shows that downloads are not kept by default', () async {
    CapturedResult result = await run(<String>['storage']);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Keep downloads cached: off'));
  });

  test('keeping downloads saves the setting and leaves caches alone', () async {
    File older = jar('paper/paper-26.2-135.jar');

    CapturedResult result = await run(<String>[
      'storage',
      'keep-downloads',
      'on',
    ]);

    expect(result.exitCode, 0);
    expect(StorageSettings(context.metadataDir).keepDownloads, isTrue);
    expect(older.existsSync(), isTrue);
    expect(
      (await run(<String>['storage'])).stdout,
      contains('Keep downloads cached: on'),
    );
  });

  test('an unknown keep-downloads value is rejected', () async {
    CapturedResult result = await run(<String>[
      'storage',
      'keep-downloads',
      'maybe',
    ]);

    expect(result.exitCode, 2);
    expect(StorageSettings(context.metadataDir).keepDownloads, isFalse);
  });

  test(
    'turning downloads off keeps only what instances and the latest builds use',
    () async {
      StorageSettings(context.metadataDir).saveKeepDownloads(true);
      File used = jar('paper/paper-1.20.1-196.jar');
      File unused = jar('paper/paper-26.2-135.jar');
      File latest = jar('paper/paper-26.3-230.jar');
      Link(p.join(builds, 'paper', 'latest.jar')).createSync(latest.path);
      File importedUnused = jar('custom/0b56ad54.jar');
      File proxyUnused = jar('velocity/velocity-3.4.0-500.jar');
      File buildTools = jar('spigot/tools/BuildTools.jar');
      Directory lobby = Directory(
        p.join(
          ConsumerService(context).rootFor(ConsumerProfile.plugin),
          'instances',
          'lobby',
        ),
      )..createSync(recursive: true);
      File(
        p.join(lobby.path, '.server-source'),
      ).writeAsStringSync('type=paper\njar=${used.path}\n');
      File gradle = File(
        p.join(projects.workDirectory.path, 'gradle-home', 'module.jar'),
      )..createSync(recursive: true);

      CapturedResult result = await run(<String>[
        'storage',
        'keep-downloads',
        'off',
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(StorageSettings(context.metadataDir).keepDownloads, isFalse);
      expect(used.existsSync(), isTrue);
      expect(latest.existsSync(), isTrue);
      expect(unused.existsSync(), isFalse);
      expect(importedUnused.existsSync(), isFalse);
      expect(proxyUnused.existsSync(), isFalse);
      expect(buildTools.existsSync(), isFalse);
      expect(gradle.existsSync(), isFalse);
    },
  );
}
