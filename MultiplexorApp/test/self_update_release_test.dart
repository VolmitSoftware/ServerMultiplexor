import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/self_update_release.dart';
import 'package:test/test.dart';

const UpdatePlatform _mac = UpdatePlatform(
  archiveSuffix: 'macos-arm64.tar.gz',
  executableName: 'multiplexor',
);
const String _assetName = 'multiplexor-v0.2.10-macos-arm64.tar.gz';
const List<int> _archive = <int>[1, 4, 8, 16, 32];

void main() {
  group('update versions', () {
    test('compares numeric components and ignores build metadata', () {
      expect(UpdateVersion.parse('v0.2.10').text, '0.2.10');
      expect(
        UpdateVersion.parse('0.2.10').compareTo(UpdateVersion.parse('0.2.9')),
        greaterThan(0),
      );
      expect(
        UpdateVersion.parse('0.3.0').compareTo(UpdateVersion.parse('0.2.90')),
        greaterThan(0),
      );
      expect(
        UpdateVersion.parse(
          '1.0.0+a',
        ).compareTo(UpdateVersion.parse('1.0.0+b')),
        0,
      );
      expect(UpdateVersion.parse('1.0.0+build.12').isStable, isTrue);
    });

    test('follows semantic prerelease precedence', () {
      final List<String> versions = <String>[
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (int index = 1; index < versions.length; index++) {
        expect(
          UpdateVersion.parse(
            versions[index - 1],
          ).compareTo(UpdateVersion.parse(versions[index])),
          lessThan(0),
        );
      }
      expect(UpdateVersion.parse(versions.first).isStable, isFalse);
      expect(
        UpdateVersion.parse(
          '1.0.0-2',
        ).compareTo(UpdateVersion.parse('1.0.0--1')),
        lessThan(0),
      );
    });

    for (final String value in <String>[
      '1.0',
      'latest',
      '01.2.3',
      '1.2.3-01',
      '1.2.3-',
      '1.2.3\n',
      '1.2.3.4',
    ]) {
      test('rejects invalid version $value', () {
        expect(() => UpdateVersion.parse(value), throwsFormatException);
      });
    }

    test('selects only an exact supported ABI', () {
      final UpdatePlatform? platform = UpdatePlatform.current();
      switch (Abi.current()) {
        case Abi.macosArm64:
          expect(platform?.archiveSuffix, 'macos-arm64.tar.gz');
          expect(platform?.executableName, 'multiplexor');
        case Abi.macosX64:
          expect(platform?.archiveSuffix, 'macos-x64.tar.gz');
          expect(platform?.executableName, 'multiplexor');
        case Abi.linuxArm64:
          expect(platform?.archiveSuffix, 'linux-arm64.tar.gz');
          expect(platform?.executableName, 'multiplexor');
        case Abi.linuxX64:
          expect(platform?.archiveSuffix, 'linux-x64.tar.gz');
          expect(platform?.executableName, 'multiplexor');
        case Abi.windowsX64:
          expect(platform?.archiveSuffix, 'windows-x64.zip');
          expect(platform?.executableName, 'multiplexor.exe');
        default:
          expect(platform, isNull);
      }
    });
  });

  group('GitHub compiled updates', () {
    late Directory root;
    late HttpServer server;
    late GithubUpdateClient client;
    late Map<String, Object?> metadata;
    late List<Map<String, Object?>> assets;
    late String checksums;
    late List<int> archiveBytes;
    late Map<String, String> redirects;
    late List<String> requests;
    late Set<String> stalled;
    late Map<String, int> statusCodes;
    late Map<String, int> contentLengths;
    late Map<String, List<int>> bodies;
    late Map<String, List<int>> partialBodies;
    late Map<String, Duration> delays;

    Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
    File destination() => File('${root.path}/update.archive');
    Future<SelfUpdateRelease?> latest([String version = '0.2.9']) =>
        client.latest(UpdateVersion.parse(version), _mac);

    Map<String, Object?> asset(String name, int size) => <String, Object?>{
      'name': name,
      'size': size,
      'state': 'uploaded',
      'browser_download_url': url('/$name').toString(),
    };

    void setChecksums(String value) {
      checksums = value;
      assets.last['size'] = utf8.encode(value).length;
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('multiplexor-update-http-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = GithubUpdateClient.forTesting(latestReleaseUrl: url('/latest'));
      checksums = '${sha256.convert(_archive)}  $_assetName\n';
      archiveBytes = List<int>.from(_archive);
      assets = <Map<String, Object?>>[
        asset(_assetName, _archive.length),
        asset('SHA256SUMS', utf8.encode(checksums).length),
      ];
      metadata = <String, Object?>{
        'tag_name': 'v0.2.10',
        'draft': false,
        'prerelease': false,
        'assets': assets,
      };
      requests = <String>[];
      redirects = <String, String>{};
      stalled = <String>{};
      statusCodes = <String, int>{};
      contentLengths = <String, int>{};
      bodies = <String, List<int>>{};
      partialBodies = <String, List<int>>{};
      delays = <String, Duration>{};
      server.listen((HttpRequest request) async {
        final String path = request.uri.path;
        requests.add(path);
        if (stalled.contains(path)) return;
        final Duration? delay = delays[path];
        if (delay != null) await Future<void>.delayed(delay);
        final List<int>? partialBody = partialBodies[path];
        if (partialBody != null) {
          request.response.add(partialBody);
          await request.response.flush();
          return;
        }
        final String? redirect = redirects[path];
        if (redirect != null) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, redirect);
        } else {
          request.response.statusCode = statusCodes[path] ?? HttpStatus.ok;
          final List<int> bytes =
              bodies[path] ??
              switch (path) {
                '/latest' => utf8.encode(jsonEncode(metadata)),
                '/SHA256SUMS' => utf8.encode(checksums),
                _ => archiveBytes,
              };
          final int? length = contentLengths[path];
          if (length != null) request.response.contentLength = length;
          request.response.add(bytes);
        }
        try {
          await request.response.close();
        } on HttpException {
          // Deliberately truncated responses are test inputs.
        } on SocketException {
          // The updater can reject a response before the server finishes.
        }
      });
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
      await root.delete(recursive: true);
    });

    test('resolves exact platform asset and verifies its download', () async {
      assets.insert(0, asset('multiplexor-v0.2.10-windows-x64.zip', 7));
      final SelfUpdateRelease release = (await latest())!;
      expect(release.version.text, '0.2.10');
      expect(release.assetName, _assetName);
      expect(release.size, _archive.length);
      expect(release.sha256, sha256.convert(_archive).toString());
      await client.download(release, destination());
      expect(await destination().readAsBytes(), _archive);
      expect(requests, <String>['/latest', '/SHA256SUMS', '/$_assetName']);
    });

    for (final String architecture in <String>['x64', 'arm64']) {
      test('verifies the Linux $architecture release download', () async {
        final String suffix = 'linux-$architecture.tar.gz';
        final String name = 'multiplexor-v0.2.10-$suffix';
        assets.insert(0, asset(name, _archive.length));
        setChecksums('$checksums${sha256.convert(_archive)}  $name\n');
        final SelfUpdateRelease release = (await client.latest(
          UpdateVersion.parse('0.2.9'),
          UpdatePlatform(archiveSuffix: suffix, executableName: 'multiplexor'),
        ))!;
        expect(release.assetName, name);
        expect(release.sha256, sha256.convert(_archive).toString());
        await client.download(release, destination());
        expect(await destination().readAsBytes(), _archive);
        expect(requests, <String>['/latest', '/SHA256SUMS', '/$name']);
      });
    }

    test(
      'accepts matching optional GitHub digest and binary checksum lines',
      () async {
        assets.first['digest'] = 'sha256:${sha256.convert(_archive)}';
        setChecksums('${sha256.convert(_archive)} *$_assetName\r\n');
        expect(await latest(), isNotNull);
      },
    );

    test(
      'returns no update for equal and newer versions without downloading',
      () async {
        expect(await latest('0.2.10'), isNull);
        expect(await latest('0.2.11'), isNull);
        expect(await latest('0.2.10+local'), isNull);
        expect(requests, everyElement('/latest'));
      },
    );

    test('stable release can replace its prerelease', () async {
      expect(await latest('0.2.10-rc.1'), isNotNull);
    });

    test('ignores draft and prerelease flags and prerelease tags', () async {
      metadata['draft'] = true;
      expect(await latest(), isNull);
      metadata['draft'] = false;
      metadata['prerelease'] = true;
      expect(await latest(), isNull);
      metadata['prerelease'] = false;
      metadata['tag_name'] = 'v0.2.10-beta.1';
      expect(await latest(), isNull);
      expect(requests, everyElement('/latest'));
    });

    test('returns no update when repository has no releases', () async {
      statusCodes['/latest'] = HttpStatus.notFound;
      expect(await latest(), isNull);
    });

    test('reports API rate limits and malformed metadata', () async {
      statusCodes['/latest'] = HttpStatus.forbidden;
      await expectLater(latest(), throwsA(isA<HttpException>()));
      statusCodes.clear();
      metadata.remove('draft');
      await expectLater(latest(), throwsFormatException);
    });

    test('rejects unsupported platform before requesting metadata', () async {
      await expectLater(
        client.latest(
          UpdateVersion.parse('0.2.9'),
          const UpdatePlatform(
            archiveSuffix: 'linux-arm.tar.gz',
            executableName: 'multiplexor',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(requests, isEmpty);
    });

    test('rejects missing, duplicated and incomplete archives', () async {
      final Map<String, Object?> original = assets.removeAt(0);
      await expectLater(latest(), throwsFormatException);
      assets.insertAll(0, <Map<String, Object?>>[original, original]);
      await expectLater(latest(), throwsFormatException);
      assets.removeAt(0);
      assets.first['state'] = 'new';
      await expectLater(latest(), throwsFormatException);
    });

    test('rejects archive version mismatch', () async {
      metadata['tag_name'] = 'v0.2.11';
      await expectLater(latest(), throwsFormatException);
    });

    test('rejects absent, duplicate or mismatched checksums', () async {
      setChecksums('${sha256.convert(_archive)}  wrong-archive.tar.gz\n');
      await expectLater(latest(), throwsFormatException);
      setChecksums(
        '${sha256.convert(_archive)}  $_assetName\n${sha256.convert(_archive)}  $_assetName\n',
      );
      await expectLater(latest(), throwsFormatException);
      setChecksums('${sha256.convert(_archive)}  $_assetName\n');
      assets.first['digest'] = 'sha256:${'0' * 64}';
      await expectLater(latest(), throwsFormatException);
    });

    test(
      'rejects missing checksum asset and malformed checksum paths',
      () async {
        setChecksums('${sha256.convert(_archive)}  ../$_assetName\n');
        await expectLater(latest(), throwsFormatException);
        assets.removeLast();
        await expectLater(latest(), throwsFormatException);
      },
    );

    test('rejects zero and oversized assets', () async {
      assets.first['size'] = 0;
      await expectLater(latest(), throwsFormatException);
      assets.first['size'] = 128 * 1024 * 1024 + 1;
      await expectLater(latest(), throwsFormatException);
      expect(requests, everyElement('/latest'));
    });

    test('rejects bounded metadata and checksum overflow', () async {
      bodies['/latest'] = List<int>.filled(1024 * 1024 + 1, 32);
      await expectLater(latest(), throwsFormatException);
      bodies.clear();
      bodies['/SHA256SUMS'] = utf8.encode('$checksums extra');
      await expectLater(latest(), throwsFormatException);
    });

    test('removes downloaded file on hash and size mismatch', () async {
      final SelfUpdateRelease release = (await latest())!;
      archiveBytes[0] = 99;
      await expectLater(
        client.download(release, destination()),
        throwsFormatException,
      );
      expect(destination().existsSync(), isFalse);
      archiveBytes = <int>[1, 2];
      await expectLater(
        client.download(release, destination()),
        throwsFormatException,
      );
      expect(destination().existsSync(), isFalse);
      archiveBytes = List<int>.filled(_archive.length + 1, 1);
      await expectLater(
        client.download(release, destination()),
        throwsFormatException,
      );
      expect(destination().existsSync(), isFalse);
    });

    test('preserves existing destination without requesting archive', () async {
      final SelfUpdateRelease release = (await latest())!;
      await destination().writeAsString('keep');
      await expectLater(
        client.download(release, destination()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination().readAsString(), 'keep');
      expect(requests, <String>['/latest', '/SHA256SUMS']);
    });

    test(
      'follows bounded redirects and rejects cross-origin redirects',
      () async {
        redirects['/latest'] = '/actual-release';
        bodies['/actual-release'] = utf8.encode(jsonEncode(metadata));
        expect(await latest(), isNotNull);
        redirects['/actual-release'] = '/latest';
        await expectLater(latest(), throwsA(isA<HttpException>()));
        redirects['/latest'] = 'http://127.0.0.1:1/untrusted';
        await expectLater(latest(), throwsFormatException);
      },
    );

    test('bounds response header waiting', () async {
      client.close();
      client = GithubUpdateClient.forTesting(
        latestReleaseUrl: url('/latest'),
        metadataTimeout: const Duration(milliseconds: 100),
      );
      stalled.add('/latest');
      await expectLater(latest(), throwsA(isA<TimeoutException>()));
    });

    test('bounds a stalled metadata body', () async {
      client.close();
      client = GithubUpdateClient.forTesting(
        latestReleaseUrl: url('/latest'),
        metadataTimeout: const Duration(milliseconds: 100),
      );
      partialBodies['/latest'] = utf8.encode('{');
      await expectLater(latest(), throwsA(isA<TimeoutException>()));
    });

    test('uses one deadline for metadata and checksum requests', () async {
      client.close();
      client = GithubUpdateClient.forTesting(
        latestReleaseUrl: url('/latest'),
        metadataTimeout: const Duration(milliseconds: 200),
      );
      delays['/latest'] = const Duration(milliseconds: 120);
      delays['/SHA256SUMS'] = const Duration(milliseconds: 120);
      await expectLater(latest(), throwsA(isA<TimeoutException>()));
    });

    test('removes partial archive after download timeout', () async {
      final SelfUpdateRelease release = (await latest())!;
      client.close();
      client = GithubUpdateClient.forTesting(
        latestReleaseUrl: url('/latest'),
        downloadTimeout: const Duration(milliseconds: 100),
      );
      partialBodies['/$_assetName'] = <int>[1, 4];
      await expectLater(
        client.download(release, destination()),
        throwsA(isA<TimeoutException>()),
      );
      expect(destination().existsSync(), isFalse);
    });

    test('rejects an excessive declared response size', () async {
      final SelfUpdateRelease release = (await latest())!;
      contentLengths['/$_assetName'] = 128 * 1024 * 1024 + 1;
      await expectLater(
        client.download(release, destination()),
        throwsFormatException,
      );
      expect(destination().existsSync(), isFalse);
    });

    test('does not allow nonlocal testing endpoints', () {
      expect(
        () => GithubUpdateClient.forTesting(
          latestReleaseUrl: Uri.parse('http://example.com/latest'),
        ),
        throwsArgumentError,
      );
    });

    test('production download rejects insecure or unrelated artifact URLs', () async {
      final GithubUpdateClient production = GithubUpdateClient();
      addTearDown(production.close);
      for (final String address in <String>[
        'http://github.com/VolmitSoftware/ServerMultiplexor/releases/download/v0.2.10/$_assetName',
        'https://github.com/Other/ServerMultiplexor/releases/download/v0.2.10/$_assetName',
        'https://github.com/VolmitSoftware/ServerMultiplexor/releases/download/v0.2.11/$_assetName',
        'https://example.com/$_assetName',
      ]) {
        final SelfUpdateRelease release = SelfUpdateRelease(
          version: UpdateVersion.parse('0.2.10'),
          downloadUrl: Uri.parse(address),
          assetName: _assetName,
          sha256: sha256.convert(_archive).toString(),
          size: _archive.length,
        );
        await expectLater(
          production.download(release, destination()),
          throwsFormatException,
        );
        expect(destination().existsSync(), isFalse);
      }
    });

    test('closed client cannot start another operation', () async {
      client.close();
      await expectLater(latest(), throwsStateError);
      expect(requests, isEmpty);
    });
  });
}
