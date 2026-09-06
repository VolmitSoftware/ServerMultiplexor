import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/addons/addon_resolver.dart';
import 'package:multiplexor/services/content/content_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const List<int> _oldJar = <int>[0x50, 0x4b, 3, 4, 1, 2, 3];
const List<int> _newJar = <int>[0x50, 0x4b, 3, 4, 8, 9, 10];

void main() {
  late Directory root;
  late HttpServer server;
  late AddonResolver resolver;
  late ContentStore store;
  late Map<String, List<int>> artifacts;
  late List<Map<String, Object?>> versions;
  late List<Uri> metadataRequests;
  late List<String> downloadRequests;

  String url(String name) => 'http://127.0.0.1:${server.port}/$name';
  File jar(String name) => File(p.join(store.dropinsPath, name));
  File getManifest() => File(store.manifestPath);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-content-test-');
    artifacts = <String, List<int>>{};
    versions = <Map<String, Object?>>[];
    metadataRequests = <Uri>[];
    downloadRequests = <String>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String name = request.uri.path.substring(1);
      downloadRequests.add(name);
      final List<int>? bytes = artifacts[name];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });
    resolver = AddonResolver(
      root.path,
      jsonLoader: (Uri uri) async {
        metadataRequests.add(uri);
        if (uri.path.endsWith('/version')) return versions;
        return <String, Object?>{
          'id': 'project',
          'title': 'Test plugin',
          'project_type': 'plugin',
        };
      },
    );
    store = ContentStore(
      dropinsPath: p.join(root.path, 'dropins'),
      manifestPath: p.join(root.path, 'state', 'content-lock.yaml'),
      consumer: 'plugin',
      resolver: resolver,
    );
  });

  tearDown(() async {
    resolver.close();
    await server.close(force: true);
    root.deleteSync(recursive: true);
  });

  Map<String, Object?> release({
    String id = 'v2',
    String minecraft = '1.21.4',
    String loader = 'paper',
    String type = 'release',
    String published = '2026-01-01T00:00:00Z',
    String file = 'plugin.jar',
    String? hash,
  }) => <String, Object?>{
    'id': id,
    'project_id': 'project',
    'version_number': id,
    'version_type': type,
    'date_published': published,
    'game_versions': <String>[minecraft],
    'loaders': <String>[loader],
    'files': <Map<String, Object?>>[
      <String, Object?>{
        'filename': file,
        'url': url(file),
        'primary': true,
        'hashes': <String, Object?>{
          'sha512': hash ?? sha512.convert(_newJar).toString(),
        },
      },
    ],
  };

  Future<void> installModrinth({String loader = 'paper'}) =>
      store.installModrinth(
        slug: 'test',
        name: 'test',
        minecraft: '1.21.4',
        loader: loader,
      );

  test(
    'validates exact loader and Minecraft even if upstream ignores filters',
    () async {
      artifacts['plugin.jar'] = _newJar;
      versions = <Map<String, Object?>>[
        release(loader: 'fabric'),
        release(minecraft: '1.20.1'),
        release(type: 'beta'),
      ];
      await expectLater(installModrinth(), throwsStateError);
      expect(downloadRequests, isEmpty);
      expect(getManifest().existsSync(), isFalse);
      final List<Uri> queries = metadataRequests
          .where((Uri uri) => uri.path.endsWith('/version'))
          .toList();
      expect(queries, hasLength(3));
      for (final Uri uri in queries) {
        expect(uri.queryParameters['loaders'], isNotNull);
        expect(jsonDecode(uri.queryParameters['game_versions']!), <String>[
          '1.21.4',
        ]);
      }
    },
  );

  test('Folia does not fall back to incompatible Paper plugins', () async {
    versions = <Map<String, Object?>>[release()];
    await expectLater(installModrinth(loader: 'folia'), throwsStateError);
    expect(
      metadataRequests.where((Uri uri) => uri.path.endsWith('/version')),
      hasLength(1),
    );
    expect(downloadRequests, isEmpty);
  });

  test(
    'chooses newest stable exact release and records verified checksum',
    () async {
      artifacts['plugin.jar'] = _newJar;
      versions = <Map<String, Object?>>[
        release(id: 'old', published: '2025-01-01T00:00:00Z'),
        release(id: 'new'),
        release(id: 'beta', type: 'beta', published: '2027-01-01T00:00:00Z'),
      ];
      await installModrinth();
      expect(jar('plugin.jar').readAsBytesSync(), _newJar);
      expect(store.read().single['version_id'], 'new');
      expect(store.read().single['sha256'], sha256.convert(_newJar).toString());
    },
  );

  test(
    'second download failure leaves both jars and lockfile byte-identical',
    () async {
      artifacts['first.jar'] = _oldJar;
      artifacts['second.jar'] = _oldJar;
      await store.installUrl(
        url: url('first.jar'),
        name: 'first',
        fileName: 'first.jar',
      );
      await store.installUrl(
        url: url('second.jar'),
        name: 'second',
        fileName: 'second.jar',
      );
      final List<int> manifest = getManifest().readAsBytesSync();
      artifacts['first.jar'] = _newJar;
      artifacts.remove('second.jar');
      downloadRequests.clear();
      await expectLater(store.update(null), throwsA(isA<HttpException>()));
      expect(downloadRequests, <String>['first.jar', 'second.jar']);
      expect(jar('first.jar').readAsBytesSync(), _oldJar);
      expect(jar('second.jar').readAsBytesSync(), _oldJar);
      expect(getManifest().readAsBytesSync(), manifest);
      expect(
        Directory(
          p.dirname(store.manifestPath),
        ).listSync().whereType<Directory>(),
        isEmpty,
      );
    },
  );

  test('checksum failure preserves previous jar and manifest', () async {
    artifacts['plugin.jar'] = _newJar;
    versions = <Map<String, Object?>>[release()];
    await installModrinth();
    final List<int> manifest = getManifest().readAsBytesSync();
    artifacts['replacement.jar'] = _newJar;
    versions = <Map<String, Object?>>[
      release(file: 'replacement.jar', hash: '0' * 128),
    ];
    await expectLater(
      store.update('test'),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('checksum mismatch'),
        ),
      ),
    );
    expect(jar('plugin.jar').readAsBytesSync(), _newJar);
    expect(jar('replacement.jar').existsSync(), isFalse);
    expect(getManifest().readAsBytesSync(), manifest);
  });

  test(
    'successful replacement removes superseded filename with manifest commit',
    () async {
      artifacts['plugin.jar'] = _newJar;
      versions = <Map<String, Object?>>[release()];
      await installModrinth();
      artifacts['replacement.jar'] = _newJar;
      versions = <Map<String, Object?>>[release(file: 'replacement.jar')];
      await store.update('test');
      expect(jar('plugin.jar').existsSync(), isFalse);
      expect(jar('replacement.jar').readAsBytesSync(), _newJar);
      expect(store.read().single['file'], 'replacement.jar');
    },
  );

  test(
    'invalid JAR and unmanaged collision do not overwrite content',
    () async {
      artifacts['bad.jar'] = utf8.encode('<html>not a jar</html>');
      await expectLater(
        store.installUrl(url: url('bad.jar'), name: 'bad', fileName: 'bad.jar'),
        throwsStateError,
      );
      expect(jar('bad.jar').existsSync(), isFalse);
      jar('manual.jar').writeAsBytesSync(_oldJar);
      artifacts['manual.jar'] = _newJar;
      await expectLater(
        store.installUrl(
          url: url('manual.jar'),
          name: 'manual',
          fileName: 'manual.jar',
        ),
        throwsStateError,
      );
      expect(jar('manual.jar').readAsBytesSync(), _oldJar);
      expect(getManifest().existsSync(), isFalse);
    },
  );

  test(
    'duplicate destination is rejected without replacing either entry',
    () async {
      artifacts['first.jar'] = _oldJar;
      artifacts['second.jar'] = _oldJar;
      await store.installUrl(
        url: url('first.jar'),
        name: 'first',
        fileName: 'first.jar',
      );
      final List<int> manifest = getManifest().readAsBytesSync();
      await expectLater(
        store.installUrl(
          url: url('second.jar'),
          name: 'second',
          fileName: 'first.jar',
        ),
        throwsFormatException,
      );
      expect(jar('first.jar').readAsBytesSync(), _oldJar);
      expect(getManifest().readAsBytesSync(), manifest);
    },
  );

  for (final String failureTarget in <String>[
    'second.jar',
    'content-lock.yaml',
  ]) {
    test(
      'commit failure at $failureTarget restores installed jars and manifest',
      () async {
        artifacts['first.jar'] = _oldJar;
        artifacts['second.jar'] = _oldJar;
        await store.installUrl(
          url: url('first.jar'),
          name: 'first',
          fileName: 'first.jar',
        );
        await store.installUrl(
          url: url('second.jar'),
          name: 'second',
          fileName: 'second.jar',
        );
        final List<int> manifest = getManifest().readAsBytesSync();
        artifacts['first.jar'] = _newJar;
        artifacts['second.jar'] = _newJar;
        bool failed = false;
        store = ContentStore(
          dropinsPath: store.dropinsPath,
          manifestPath: store.manifestPath,
          consumer: 'plugin',
          resolver: resolver,
          moveFile: (File source, String target) {
            if (!failed &&
                p.basename(target) == failureTarget &&
                !p.basename(source.path).startsWith('backup-')) {
              failed = true;
              throw FileSystemException('Injected permission failure', target);
            }
            source.renameSync(target);
          },
        );
        await expectLater(
          store.update(null),
          throwsA(isA<FileSystemException>()),
        );
        expect(failed, isTrue);
        expect(jar('first.jar').readAsBytesSync(), _oldJar);
        expect(jar('second.jar').readAsBytesSync(), _oldJar);
        expect(getManifest().readAsBytesSync(), manifest);
      },
    );
  }

  test('remove commits jar deletion and manifest together', () async {
    artifacts['first.jar'] = _oldJar;
    await store.installUrl(
      url: url('first.jar'),
      name: 'first',
      fileName: 'first.jar',
    );
    await store.remove('first');
    expect(jar('first.jar').existsSync(), isFalse);
    expect(store.read(), isEmpty);
  });
}
