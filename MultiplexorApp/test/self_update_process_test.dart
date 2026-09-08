@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:multiplexor/services/self_update_release.dart';

const String _oldVersion = '0.2.98';
const String _newVersion = '0.2.99';

void main() {
  final UpdatePlatform? platform = UpdatePlatform.current();
  group(
    'compiled automatic updater',
    () {
      late Directory buildRoot;
      late File oldExecutable;
      late File newExecutable;
      late List<int> archiveBytes;
      late String archiveName;
      late Directory root;
      late File target;
      late File marker;
      late File processLog;
      late Directory workingDirectory;
      HttpServer? server;
      final List<String> requests = <String>[];

      setUpAll(() async {
        buildRoot = Directory.systemTemp.createTempSync(
          'multiplexor-update-build-',
        );
        final File source = File(p.join(buildRoot.path, 'fixture.dart'))
          ..writeAsStringSync(_fixtureSource);
        final String packages = p.absolute('.dart_tool', 'package_config.json');
        oldExecutable = File(
          p.join(buildRoot.path, 'old-${platform!.executableName}'),
        );
        newExecutable = File(
          p.join(buildRoot.path, 'new-${platform.executableName}'),
        );
        for (final (String, File) build in <(String, File)>[
          (_oldVersion, oldExecutable),
          (_newVersion, newExecutable),
        ]) {
          final ProcessResult result =
              await _runProcess(Platform.resolvedExecutable, <String>[
                'compile',
                'exe',
                '--packages=$packages',
                '-DMULTIPLEXOR_FIXTURE_VERSION=${build.$1}',
                source.path,
                '-o',
                build.$2.path,
              ], timeout: const Duration(minutes: 2));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        }
        archiveName = 'multiplexor-v$_newVersion-${platform.archiveSuffix}';
        final Directory package = Directory(p.join(buildRoot.path, 'package'))
          ..createSync();
        final File payload = newExecutable.copySync(
          p.join(package.path, platform.executableName),
        );
        final File archive = File(p.join(buildRoot.path, archiveName));
        final ProcessResult packaged = Platform.isWindows
            ? await _runProcess(
                'powershell.exe',
                <String>[
                  '-NoProfile',
                  '-NonInteractive',
                  '-Command',
                  r'''
                  $ErrorActionPreference = 'Stop'
                  Compress-Archive -LiteralPath $env:MULTIPLEXOR_TEST_PACKAGE_SOURCE -DestinationPath $env:MULTIPLEXOR_TEST_PACKAGE_ARCHIVE -Force
                  ''',
                ],
                environment: <String, String>{
                  'MULTIPLEXOR_TEST_PACKAGE_SOURCE': payload.path,
                  'MULTIPLEXOR_TEST_PACKAGE_ARCHIVE': archive.path,
                },
              )
            : await _runProcess(
                '/usr/bin/tar',
                <String>[
                  '--format=ustar',
                  '--no-xattrs',
                  '-czf',
                  archive.path,
                  '-C',
                  package.path,
                  platform.executableName,
                ],
                environment: const <String, String>{'COPYFILE_DISABLE': '1'},
              );
        expect(
          packaged.exitCode,
          0,
          reason: '${packaged.stdout}\n${packaged.stderr}',
        );
        archiveBytes = archive.readAsBytesSync();
      });

      tearDownAll(() {
        if (buildRoot.existsSync()) buildRoot.deleteSync(recursive: true);
      });

      setUp(() {
        root = Directory.systemTemp.createTempSync(
          'multiplexor-update-process-',
        );
        final Directory installation = Directory(
          p.join(root.path, "installed [release]'s"),
        )..createSync();
        target = oldExecutable.copySync(
          p.join(installation.path, platform!.executableName),
        );
        marker = File(p.join(root.path, 'continued.json'));
        processLog = File(p.join(root.path, 'processes.log'));
        workingDirectory = Directory(p.join(root.path, 'working [directory]'))
          ..createSync();
        requests.clear();
      });

      tearDown(() async {
        await server?.close(force: true);
        server = null;
        for (final int processId in _activeProcesses(processLog)) {
          Process.killPid(processId, ProcessSignal.sigkill);
        }
        final Stopwatch cleanup = Stopwatch()..start();
        while (root.existsSync()) {
          try {
            root.deleteSync(recursive: true);
          } on FileSystemException {
            if (cleanup.elapsed > const Duration(seconds: 10)) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      });

      Future<Uri> serveRelease({bool corrupt = false}) async {
        final HttpServer listening = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        server = listening;
        final Uri origin = Uri.parse('http://127.0.0.1:${listening.port}');
        final List<int> checksums = utf8.encode(
          '${sha256.convert(archiveBytes)}  $archiveName\n',
        );
        final List<int> payload = List<int>.of(archiveBytes);
        if (corrupt) payload[payload.length ~/ 2] ^= 1;
        listening.listen((HttpRequest request) async {
          requests.add(request.uri.path);
          final List<int> bytes;
          switch (request.uri.path) {
            case '/latest':
              bytes = utf8.encode(
                jsonEncode(<String, Object?>{
                  'tag_name': 'v$_newVersion',
                  'draft': false,
                  'prerelease': false,
                  'assets': <Map<String, Object?>>[
                    <String, Object?>{
                      'name': archiveName,
                      'state': 'uploaded',
                      'size': archiveBytes.length,
                      'browser_download_url': origin
                          .resolve('/$archiveName')
                          .toString(),
                    },
                    <String, Object?>{
                      'name': 'SHA256SUMS',
                      'state': 'uploaded',
                      'size': checksums.length,
                      'browser_download_url': origin
                          .resolve('/SHA256SUMS')
                          .toString(),
                    },
                  ],
                }),
              );
            case '/SHA256SUMS':
              bytes = checksums;
            default:
              if (request.uri.path != '/$archiveName') {
                request.response.statusCode = HttpStatus.notFound;
                await request.response.close();
                return;
              }
              bytes = payload;
          }
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        return origin.resolve('/latest');
      }

      List<String> arguments(Uri endpoint) => <String>[
        endpoint.toString(),
        marker.path,
        p.join(root.path, 'update settings'),
        'argument with spaces',
        'quoted "value"',
        'trailing\\',
        '',
      ];

      Future<ProcessResult> launch(Uri endpoint) => _runProcess(
        target.path,
        arguments(endpoint),
        workingDirectory: workingDirectory.path,
        environment: <String, String>{
          'MULTIPLEXOR_TEST_PROCESS_LOG': processLog.path,
        },
      );

      test(
        'downloads, replaces, and restarts with original arguments and cwd',
        () async {
          final Uri endpoint = await serveRelease();
          final File sentinel = File(
            p.join(workingDirectory.path, 'server-data.txt'),
          )..writeAsStringSync('preserve workspace data');
          final ProcessResult result = await launch(endpoint);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          await _waitUntil(
            () => marker.existsSync(),
            'updated executable did not restart',
          );
          final Map<String, Object?> continued =
              jsonDecode(marker.readAsStringSync()) as Map<String, Object?>;
          expect(
            continued['version'],
            _newVersion,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(continued['arguments'], arguments(endpoint));
          expect(continued['cwd'], workingDirectory.resolveSymbolicLinksSync());
          expect(continued['pid'], isNot(result.pid));
          expect(
            sha256.convert(target.readAsBytesSync()),
            sha256.convert(newExecutable.readAsBytesSync()),
          );
          final ProcessResult version = await _runProcess(target.path, <String>[
            'version',
          ]);
          expect(version.exitCode, 0, reason: '${version.stderr}');
          expect(
            version.stdout.toString().trim(),
            'Multiplexor CLI v$_newVersion',
          );
          expect(sentinel.readAsStringSync(), 'preserve workspace data');
          expect(requests, <String>['/latest', '/SHA256SUMS', '/$archiveName']);
          await _waitUntil(
            () => _activeProcesses(processLog).isEmpty,
            'update child process did not exit',
          );
        },
      );

      test(
        'a corrupt download keeps the old executable and continues startup',
        () async {
          final Uri endpoint = await serveRelease(corrupt: true);
          final ProcessResult result = await launch(endpoint);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stderr, contains('checksum does not match'));
          expect(marker.existsSync(), isTrue);
          final Map<String, Object?> continued =
              jsonDecode(marker.readAsStringSync()) as Map<String, Object?>;
          expect(continued['version'], _oldVersion);
          expect(continued['pid'], result.pid);
          expect(continued['arguments'], arguments(endpoint));
          expect(
            sha256.convert(target.readAsBytesSync()),
            sha256.convert(oldExecutable.readAsBytesSync()),
          );
          expect(requests, <String>['/latest', '/SHA256SUMS', '/$archiveName']);
          expect(_activeProcesses(processLog), isEmpty);
        },
      );
    },
    skip: platform == null
        ? 'No compiled update exists for this platform.'
        : false,
  );
}

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final Future<String> output = process.stdout.transform(utf8.decoder).join();
  final Future<String> errors = process.stderr.transform(utf8.decoder).join();
  await process.stdin.close();
  try {
    return await (() async {
      final int status = await process.exitCode;
      return ProcessResult(process.pid, status, await output, await errors);
    })().timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    rethrow;
  }
}

Set<int> _activeProcesses(File log) {
  final Set<int> active = <int>{};
  if (!log.existsSync()) return active;
  for (final String line in log.readAsLinesSync()) {
    final int? processId = int.tryParse(line);
    if (processId == null) continue;
    if (processId > 0) {
      active.add(processId);
    } else {
      active.remove(-processId);
    }
  }
  return active;
}

Future<void> _waitUntil(bool Function() condition, String failure) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 30)) fail(failure);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

const String _fixtureSource = r'''
import 'dart:convert';
import 'dart:io';
import 'package:multiplexor/services/self_update_installer.dart';
import 'package:multiplexor/services/self_update_release.dart';
import 'package:multiplexor/services/self_update_service.dart';
import 'package:multiplexor/services/self_update_settings.dart';

Future<void> main(List<String> args) async {
  final String? processLog = Platform.environment['MULTIPLEXOR_TEST_PROCESS_LOG'];
  if (processLog != null) {
    File(processLog).writeAsStringSync('$pid\n', mode: FileMode.append, flush: true);
  }
  late int result;
  try {
    result = await runFixture(args);
  } finally {
    if (processLog != null) {
      File(processLog).writeAsStringSync('${-pid}\n', mode: FileMode.append, flush: true);
    }
  }
  exit(result);
}

Future<int> runFixture(List<String> args) async {
    final int? helper = await runSelfUpdateHelper(args);
    if (helper != null) {
      return helper;
    }
    const String version = String.fromEnvironment('MULTIPLEXOR_FIXTURE_VERSION');
    if (args.length == 1 && args.single == 'version') {
      stdout.writeln('Multiplexor CLI v$version');
      return 0;
    }
    final GithubUpdateClient client = GithubUpdateClient.forTesting(
      latestReleaseUrl: Uri.parse(args[0]),
    );
    try {
      final SelfUpdateService updater = SelfUpdateService(
        currentVersion: UpdateVersion.parse(version),
        executablePath: Platform.resolvedExecutable,
        releaseBuild: true,
        platform: UpdatePlatform.current(),
        store: SelfUpdateStore(Directory(args[2]), Platform.resolvedExecutable),
        client: client,
      );
      final int? status = await updater.automatic(args);
      if (status != null) {
        return status;
      }
    } finally {
      client.close();
    }
    final File marker = File(args[1]);
    final File pending = File('${marker.path}.$pid.tmp');
    pending.writeAsStringSync(jsonEncode(<String, Object?>{
      'version': version,
      'arguments': args,
      'cwd': Directory.current.resolveSymbolicLinksSync(),
      'pid': pid,
    }), flush: true);
    pending.renameSync(marker.path);
    return 0;
}
''';
