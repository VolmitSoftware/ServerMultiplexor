import 'dart:io';

import 'package:multiplexor/services/self_update_release.dart';
import 'package:multiplexor/services/self_update_service.dart';
import 'package:multiplexor/services/self_update_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SelfUpdateStore store;
  late _Client client;
  late DateTime now;
  late List<String> output;
  late List<String> errors;
  late List<List<String>> restarts;
  late List<List<String>> installs;
  late bool helper;
  late bool installFails;

  const UpdatePlatform platform = UpdatePlatform(
    archiveSuffix: 'macos-arm64.tar.gz',
    executableName: 'multiplexor',
  );
  SelfUpdateService service({bool release = true, bool supported = true}) =>
      SelfUpdateService(
        currentVersion: UpdateVersion.parse('0.2.9'),
        executablePath: p.join(directory.path, 'multiplexor'),
        releaseBuild: release,
        platform: supported ? platform : null,
        store: store,
        client: client,
        now: () => now,
        write: output.add,
        error: errors.add,
        install:
            ({
              required File archive,
              required String version,
              required String currentVersion,
              required String executableName,
              required String targetPath,
              required List<String> restartArguments,
              required String workingDirectory,
            }) async {
              expect(archive.readAsStringSync(), 'verified download');
              expect(version, '0.2.10');
              expect(currentVersion, '0.2.9');
              expect(executableName, 'multiplexor');
              expect(targetPath, p.join(directory.path, 'multiplexor'));
              expect(workingDirectory, Directory.current.path);
              installs.add(restartArguments);
              if (installFails) throw const FileSystemException('read only');
              return helper;
            },
        restart: (String path, List<String> args) async {
          expect(path, p.join(directory.path, 'multiplexor'));
          restarts.add(args);
          return 42;
        },
      );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('multiplexor-update-test-');
    store = SelfUpdateStore(directory, p.join(directory.path, 'multiplexor'));
    client = _Client();
    now = DateTime.utc(2026, 9, 8);
    output = <String>[];
    errors = <String>[];
    restarts = <List<String>>[];
    installs = <List<String>>[];
    helper = false;
    installFails = false;
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'automatic update installs and restarts with original arguments',
    () async {
      final List<String> args = <String>[
        '--root',
        'path with [brackets]',
        'wizard',
      ];
      expect(await service().automatic(args), 42);
      expect(installs, <List<String>>[args]);
      expect(restarts, <List<String>>[args]);
      expect(store.read().checkedVersion, '0.2.10');
    },
  );

  test('Windows helper handoff exits without a second restart', () async {
    helper = true;
    expect(await service().automatic(<String>[]), 0);
    expect(installs, hasLength(1));
    expect(restarts, isEmpty);
    expect(store.read().checkedVersion, '0.2.9');
    expect(store.read().succeeded, isFalse);
    expect(await service().automatic(<String>[]), isNull);
    expect(installs, hasLength(1));
  });

  test(
    'manual update bypasses disabled automatic updates and throttle',
    () async {
      store.write(
        SelfUpdateSettings(
          automatic: false,
          lastAttempt: now,
          checkedVersion: '0.2.9',
          succeeded: true,
        ),
      );
      expect(await service().command(<String>[]), 0);
      expect(installs, <List<String>>[
        <String>['version'],
      ]);
      expect(restarts, isEmpty);
      expect(store.read().automatic, isFalse);
    },
  );

  test('automatic settings persist and suppress network calls', () async {
    await service().command(<String>['auto', 'off']);
    expect(await service().automatic(<String>[]), isNull);
    expect(client.checks, 0);
    await service().command(<String>['auto', 'on']);
    expect(await service().automatic(<String>[]), 42);
  });

  test('no available update is quiet and throttled for six hours', () async {
    client.available = false;
    expect(await service().automatic(<String>[]), isNull);
    expect(await service().automatic(<String>[]), isNull);
    now = now.add(const Duration(hours: 6));
    expect(await service().automatic(<String>[]), isNull);
    expect(client.checks, 2);
    expect(output, isEmpty);
    expect(errors, isEmpty);
    expect(installs, isEmpty);
  });

  test(
    'network failure continues startup and retries after fifteen minutes',
    () async {
      client.fail = true;
      expect(await service().automatic(<String>[]), isNull);
      expect(errors.single, contains('Update skipped'));
      expect(await service().automatic(<String>[]), isNull);
      expect(client.checks, 1);
      now = now.add(const Duration(minutes: 15));
      client.fail = false;
      expect(await service().automatic(<String>[]), 42);
      expect(client.checks, 2);
    },
  );

  test(
    'installation failure keeps startup running and removes download',
    () async {
      installFails = true;
      expect(await service().automatic(<String>[]), isNull);
      expect(restarts, isEmpty);
      expect(store.read().succeeded, isFalse);
      expect(client.downloadedFile!.existsSync(), isFalse);
    },
  );

  test('check does not install or change preferences and cache', () async {
    expect(await service().command(<String>['check']), 0);
    expect(output.single, contains('v0.2.10'));
    expect(installs, isEmpty);
    expect(store.file.existsSync(), isFalse);
  });

  test('source builds and unsupported platforms do not auto-update', () async {
    expect(await service(release: false).automatic(<String>[]), isNull);
    expect(await service(supported: false).automatic(<String>[]), isNull);
    expect(client.checks, 0);
    expect(directory.listSync(), isEmpty);
    await expectLater(
      service(release: false).command(<String>[]),
      throwsFormatException,
    );
    await expectLater(
      service(supported: false).command(<String>[]),
      throwsFormatException,
    );
  });

  test(
    'source status explains disabled updates without writing state',
    () async {
      await service(release: false).command(<String>['status']);
      expect(output.join('\n'), contains('Source build'));
      expect(directory.listSync(), isEmpty);
    },
  );

  for (final List<String> args in <List<String>>[
    <String>['check', '--install'],
    <String>['install', 'extra'],
    <String>['auto', 'maybe'],
    <String>['auto', 'on', 'extra'],
    <String>['unknown'],
  ]) {
    test(
      'rejects invalid update arguments $args without side effects',
      () async {
        await expectLater(service().command(args), throwsFormatException);
        expect(client.checks, 0);
        expect(directory.listSync(), isEmpty);
      },
    );
  }

  test(
    'malformed preferences do not silently enable automatic updates',
    () async {
      store.file.writeAsStringSync('{"automatic":false}');
      expect(await service().automatic(<String>[]), isNull);
      expect(client.checks, 0);
      expect(errors.single, contains('Invalid Multiplexor update settings'));
    },
  );

  test('new executable versions and clock rollback permit a fresh check', () {
    final SelfUpdateSettings settings = SelfUpdateSettings(
      lastAttempt: now,
      checkedVersion: '0.2.9',
      succeeded: true,
    );
    expect(settings.isDue(now, '0.2.10'), isTrue);
    expect(
      settings.isDue(now.subtract(const Duration(seconds: 1)), '0.2.9'),
      isTrue,
    );
    expect(settings.isDue(now, '0.2.9'), isFalse);
  });

  test('only full dashboard commands participate in startup updates', () {
    for (final List<String> args in <List<String>>[
      <String>[],
      <String>['wizard'],
      <String>['runtime', 'watch'],
    ]) {
      expect(opensUpdateDashboard(args), isTrue);
    }
    for (final List<String> args in <List<String>>[
      <String>['version'],
      <String>['help'],
      <String>['runtime', 'watch', '--once'],
      <String>['runtime', 'start', 'demo'],
      <String>['plugins', 'watch-daemon'],
    ]) {
      expect(opensUpdateDashboard(args), isFalse);
    }
  });
}

class _Client implements GithubUpdateClient {
  int checks = 0;
  bool available = true;
  bool fail = false;
  File? downloadedFile;

  @override
  Future<SelfUpdateRelease?> latest(
    UpdateVersion current,
    UpdatePlatform platform,
  ) async {
    checks++;
    if (fail) throw const SocketException('offline');
    return available
        ? SelfUpdateRelease(
            version: UpdateVersion.parse('0.2.10'),
            downloadUrl: Uri.parse('https://example.invalid/update'),
            assetName: 'multiplexor-v0.2.10-macos-arm64.tar.gz',
            sha256: 'unused test digest',
            size: 17,
          )
        : null;
  }

  @override
  Future<void> download(SelfUpdateRelease release, File destination) async {
    destination.writeAsStringSync('verified download');
    downloadedFile = destination;
  }

  @override
  void close() {}
}
