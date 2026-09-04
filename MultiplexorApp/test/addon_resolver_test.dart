import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/addons/addon_catalog.dart';
import 'package:multiplexor/services/addons/addon_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final List<int> _jar = base64Decode(
  'UEsDBBQAAAAAAAAAIVCyfwLuGQAAABkAAAAUAAAATUVUQS1JTkYvTUFOSUZFU1QuTUZN'
  'YW5pZmVzdC1WZXJzaW9uOiAxLjANCg0KUEsBAhQDFAAAAAAAAAAhULJ/Au4ZAAAAGQAA'
  'ABQAAAAAAAAAAAAAAIABAAAAAE1FVEEtSU5GL01BTklGRVNULk1GUEsFBgAAAAABAAEAQgAA'
  'AEsAAAAAAA==',
);
const String _downloadUrl = 'https://cdn.modrinth.com/data/example.jar';

void main() {
  group('addon providers', () {
    late Directory root;
    late _HttpFixture fixture;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('multiplexor-provider-test-');
      fixture = await _HttpFixture.create();
    });

    tearDown(() async {
      await fixture.close();
      root.deleteSync(recursive: true);
    });

    Future<void> resolveWith(
      Future<void> Function(AddonResolver resolver) check,
    ) => HttpOverrides.runZoned<Future<void>>(() async {
      final AddonResolver resolver = AddonResolver(root.path);
      try {
        await check(resolver);
      } finally {
        resolver.close();
      }
    }, createHttpClient: (SecurityContext? _) => fixture.client);

    void versions(List<Map<String, Object?>> entries) {
      fixture.json('api.modrinth.com/v2/project/example/version', entries);
    }

    const String jenkinsApi =
        'ci.ender.zone/job/EssentialsX/lastSuccessfulBuild/api/json';
    const String essentialsJar = 'EssentialsX-2.22.1-dev+23-test.jar';
    const String essentialsPath =
        'ci.ender.zone/job/EssentialsX/1827/artifact/jars/$essentialsJar';

    void essentialsBuild({List<Map<String, Object?>>? artifacts}) {
      fixture.json(jenkinsApi, <String, Object?>{
        'number': 1827,
        'result': 'SUCCESS',
        'building': false,
        'artifacts':
            artifacts ??
            <Map<String, Object?>>[
              <String, Object?>{
                'fileName': essentialsJar,
                'relativePath': 'jars/$essentialsJar',
              },
              <String, Object?>{
                'fileName': 'EssentialsXChat-2.22.1-dev.jar',
                'relativePath': 'jars/EssentialsXChat-2.22.1-dev.jar',
              },
            ],
      });
    }

    test(
      'EssentialsX falls back to an immutable official CI artifact on 26.2',
      () async {
        fixture.json(
          'api.modrinth.com/v2/project/hXiIvTyT/version',
          <Object?>[],
        );
        essentialsBuild();
        fixture.bytes(essentialsPath, _jar);

        await resolveWith((AddonResolver resolver) async {
          final ResolvedAddon result = await resolver.resolve(
            AddonCatalog.load(root.path).entries['essentialsx']!,
            'leaf',
            '26.2',
          );
          expect(
            Uri.parse(result.location).path,
            '/job/EssentialsX/1827/artifact/jars/$essentialsJar',
          );
          expect(result.version, contains('#1827 (development)'));
          final File target = File(p.join(root.path, 'essentials.jar'));
          await resolver.download(result, target);
          expect(target.readAsBytesSync(), _jar);
        });
      },
    );

    test('selects the BlueMap Paper artifact for Leaf 26.2', () async {
      const String blueMapUrl =
          'https://cdn.modrinth.com/data/swbUV1cr/versions/fixture/bluemap-paper.jar';
      fixture.json(
        'api.modrinth.com/v2/project/swbUV1cr/version',
        <Map<String, Object?>>[
          _version(
              'bluemap-paper',
              minecraft: <String>['26.1.1', '26.1.2', '26.2'],
              loaders: <String>['folia', 'paper', 'purpur'],
            )
            ..['project_id'] = 'swbUV1cr'
            ..['files'] = <Map<String, Object?>>[_file(blueMapUrl)],
        ],
      );
      fixture.bytes(
        'cdn.modrinth.com/data/swbUV1cr/versions/fixture/bluemap-paper.jar',
        _jar,
      );

      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          AddonCatalog.load(root.path).entries['bluemap']!,
          'leaf',
          '26.2',
        );
        expect(result.location, blueMapUrl);
        expect(result.version, 'bluemap-paper');
        expect(result.projectId, 'swbUV1cr');
        final File target = File(p.join(root.path, 'BlueMap.jar'));
        await resolver.download(result, target);
        expect(target.readAsBytesSync(), _jar);
      });

      final Uri request = fixture.requests.first;
      expect(jsonDecode(request.queryParameters['loaders']!), <String>[
        'paper',
      ]);
      expect(jsonDecode(request.queryParameters['game_versions']!), <String>[
        '26.2',
      ]);
    });

    test('EssentialsX prefers a compatible stable release over CI', () async {
      fixture.json(
        'api.modrinth.com/v2/project/hXiIvTyT/version',
        <Map<String, Object?>>[
          _version('stable-essentials', minecraft: <String>['26.2']),
        ],
      );
      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          AddonCatalog.load(root.path).entries['essentialsx']!,
          'leaf',
          '26.2',
        );
        expect(result.version, 'stable-essentials');
      });
      expect(
        fixture.requests.every((Uri uri) => uri.host != 'ci.ender.zone'),
        isTrue,
      );
    });

    test(
      'EssentialsX does not use CI for an unverified game version',
      () async {
        fixture.json(
          'api.modrinth.com/v2/project/hXiIvTyT/version',
          <Object?>[],
        );
        await resolveWith((AddonResolver resolver) async {
          await expectLater(
            resolver.resolve(
              AddonCatalog.load(root.path).entries['essentialsx']!,
              'leaf',
              '99.0',
            ),
            throwsStateError,
          );
        });
        expect(
          fixture.requests.every((Uri uri) => uri.host != 'ci.ender.zone'),
          isTrue,
        );
      },
    );

    test('provider HTTP failures do not silently switch to CI', () async {
      essentialsBuild();
      await resolveWith((AddonResolver resolver) async {
        await expectLater(
          resolver.resolve(
            AddonCatalog.load(root.path).entries['essentialsx']!,
            'leaf',
            '26.2',
          ),
          throwsA(isA<HttpException>()),
        );
      });
      expect(
        fixture.requests.every((Uri uri) => uri.host != 'ci.ender.zone'),
        isTrue,
      );
    });

    test(
      'malformed compatible release metadata does not fall back to CI',
      () async {
        fixture.json(
          'api.modrinth.com/v2/project/hXiIvTyT/version',
          <Map<String, Object?>>[
            _version('broken-release', minecraft: <String>['26.2'])
              ..['files'] = null,
          ],
        );
        essentialsBuild();
        await resolveWith((AddonResolver resolver) async {
          await expectLater(
            resolver.resolve(
              AddonCatalog.load(root.path).entries['essentialsx']!,
              'leaf',
              '26.2',
            ),
            throwsFormatException,
          );
        });
        expect(
          fixture.requests.every((Uri uri) => uri.host != 'ci.ender.zone'),
          isTrue,
        );
      },
    );

    test('Jenkins rejects ambiguous core artifacts', () async {
      fixture.json('api.modrinth.com/v2/project/hXiIvTyT/version', <Object?>[]);
      essentialsBuild(
        artifacts: <Map<String, Object?>>[
          <String, Object?>{
            'fileName': essentialsJar,
            'relativePath': 'jars/$essentialsJar',
          },
          <String, Object?>{
            'fileName': 'EssentialsX-2.22.1.jar',
            'relativePath': 'jars/EssentialsX-2.22.1.jar',
          },
        ],
      );
      await resolveWith((AddonResolver resolver) async {
        await expectLater(
          resolver.resolve(
            AddonCatalog.load(root.path).entries['essentialsx']!,
            'leaf',
            '26.2',
          ),
          throwsStateError,
        );
      });
    });

    test(
      'selects the newest stable exact Minecraft and loader match',
      () async {
        versions(<Map<String, Object?>>[
          _version('old', published: '2026-01-01T00:00:00Z'),
          _version('wrong-loader', loaders: <String>['spigot']),
          _version('wrong-minecraft', minecraft: <String>['26.2']),
          _version('beta', channel: 'beta'),
          _version('chosen', published: '2026-02-01T00:00:00Z')
            ..['files'] = <Map<String, Object?>>[
              _file(
                'https://cdn.modrinth.com/data/sources.jar',
                primary: false,
              ),
              _file(_downloadUrl),
            ],
        ]);
        fixture.bytes('cdn.modrinth.com/data/example.jar', _jar);

        await resolveWith((AddonResolver resolver) async {
          final ResolvedAddon result = await resolver.resolve(
            _modrinth(),
            'purpur',
            '1.21.11',
          );
          expect(result.version, 'chosen');
          expect(result.versionId, 'chosen');
          expect(result.projectId, 'CanonicalProject');
          expect(result.location, _downloadUrl);
          expect(result.hashType, 'sha512');
          expect(result.hash, sha512.convert(_jar).toString());
          final File target = File(p.join(root.path, 'download.jar'));
          await resolver.download(result, target);
          expect(target.readAsBytesSync(), _jar);
        });

        final Uri request = fixture.requests.first;
        expect(request.host, 'api.modrinth.com');
        expect(jsonDecode(request.queryParameters['loaders']!), <String>[
          'paper',
        ]);
        expect(jsonDecode(request.queryParameters['game_versions']!), <String>[
          '1.21.11',
        ]);
      },
    );

    test('uses a pinned Modrinth version instead of a newer release', () async {
      versions(<Map<String, Object?>>[
        _version('newer'),
        _version('pinned', published: '2026-01-01T00:00:00Z'),
      ]);

      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          _modrinth(versionId: 'pinned'),
          'paper',
          '1.21.11',
        );
        expect(result.versionId, 'pinned');
      });
    });

    test('rejects versions that have no stable compatible release', () async {
      versions(<Map<String, Object?>>[
        _version('beta', channel: 'beta'),
        _version('other-version', minecraft: <String>['26.2']),
        _version('other-loader', loaders: <String>['fabric']),
      ]);

      await resolveWith((AddonResolver resolver) async {
        await expectLater(
          resolver.resolve(_modrinth(), 'paper', '1.21.11'),
          throwsA(isA<StateError>()),
        );
      });
    });

    test('preserves required projects and exact dependency versions', () async {
      versions(<Map<String, Object?>>[
        _version('dependent')
          ..['dependencies'] = <Map<String, Object?>>[
            <String, Object?>{
              'dependency_type': 'required',
              'project_id': 'ProjectOnly',
              'version_id': null,
            },
            <String, Object?>{
              'dependency_type': 'required',
              'project_id': 'PinnedProject',
              'version_id': 'PinnedVersion',
            },
            <String, Object?>{
              'dependency_type': 'required',
              'project_id': null,
              'version_id': 'LookupVersion',
            },
            <String, Object?>{
              'dependency_type': 'optional',
              'project_id': 'OptionalProject',
              'version_id': 'OptionalVersion',
            },
          ],
      ]);
      fixture.json(
        'api.modrinth.com/v2/version/LookupVersion',
        <String, Object?>{'id': 'LookupVersion', 'project_id': 'LookupProject'},
      );

      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          _modrinth(),
          'paper',
          '1.21.11',
        );
        expect(result.requiredProjects, <String>[
          'ProjectOnly',
          'PinnedProject',
          'LookupProject',
        ]);
        expect(result.requiredVersions, <String, String>{
          'PinnedProject': 'PinnedVersion',
          'LookupProject': 'LookupVersion',
        });
      });
      expect(
        fixture.requests.map((Uri uri) => uri.path),
        contains('/v2/version/LookupVersion'),
      );
    });

    test('rejects a Modrinth download with the wrong SHA512', () async {
      versions(<Map<String, Object?>>[_version('checksum')]);
      fixture.bytes('cdn.modrinth.com/data/example.jar', <int>[..._jar, 1]);

      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          _modrinth(),
          'paper',
          '1.21.11',
        );
        await expectLater(
          resolver.download(result, File(p.join(root.path, 'bad.jar'))),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('checksum mismatch'),
            ),
          ),
        );
      });
    });

    for (final ({String minecraft, String server, String tag, String asset})
        example
        in <({String minecraft, String server, String tag, String asset})>[
          (
            minecraft: '1.21.8',
            server: 'paper',
            tag: '5.4.0',
            asset: 'ProtocolLib.jar',
          ),
          (
            minecraft: '1.21.11',
            server: 'paper',
            tag: 'dev-build',
            asset: 'ProtocolLib-Spigot.jar',
          ),
          (
            minecraft: '26.2',
            server: 'paper',
            tag: 'dev-build',
            asset: 'ProtocolLib.jar',
          ),
          (
            minecraft: '26.2',
            server: 'spigot',
            tag: 'dev-build',
            asset: 'ProtocolLib-Spigot.jar',
          ),
        ]) {
      test(
        'selects ProtocolLib ${example.asset} for ${example.server} ${example.minecraft}',
        () async {
          final List<Map<String, Object?>> assets = <Map<String, Object?>>[
            _asset('ProtocolLib-Spigot.jar'),
            _asset('ProtocolLib-sources.jar'),
            _asset('ProtocolLib.jar'),
          ];
          fixture.json(
            'api.github.com/repos/dmulloy2/ProtocolLib/releases/tags/${example.tag}',
            <String, Object?>{
              'tag_name': example.tag,
              'draft': false,
              'prerelease': false,
              'assets': assets,
            },
          );
          final String download = 'https://github.com/fixture/${example.asset}';
          fixture.bytes('github.com/fixture/${example.asset}', _jar);

          await resolveWith((AddonResolver resolver) async {
            final AddonDefinition definition = AddonCatalog.load(
              root.path,
            ).entries['protocollib']!;
            final ResolvedAddon result = await resolver.resolve(
              definition,
              example.server,
              example.minecraft,
            );
            expect(result.location, download);
            expect(
              result.version,
              example.tag == 'dev-build' ? 'dev-build (development)' : '5.4.0',
            );
            expect(result.hashType, 'sha256');
            expect(result.hash, sha256.convert(_jar).toString());
            final File target = File(p.join(root.path, 'protocol.jar'));
            await resolver.download(result, target);
            expect(target.readAsBytesSync(), _jar);
          });
        },
      );
    }

    test('rejects a GitHub download with the wrong SHA256', () async {
      fixture.json(
        'api.github.com/repos/dmulloy2/ProtocolLib/releases/tags/dev-build',
        <String, Object?>{
          'tag_name': 'dev-build',
          'draft': false,
          'assets': <Map<String, Object?>>[_asset('ProtocolLib-Spigot.jar')],
        },
      );
      fixture.bytes('github.com/fixture/ProtocolLib-Spigot.jar', <int>[
        ..._jar,
        1,
      ]);

      await resolveWith((AddonResolver resolver) async {
        final ResolvedAddon result = await resolver.resolve(
          AddonCatalog.load(root.path).entries['protocollib']!,
          'paper',
          '1.21.11',
        );
        await expectLater(
          resolver.download(result, File(p.join(root.path, 'bad.jar'))),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('checksum mismatch'),
            ),
          ),
        );
      });
    });
  });
}

AddonDefinition _modrinth({String? versionId}) =>
    AddonDefinition(<String, Object?>{
      'id': 'example',
      'name': 'Example',
      'kind': 'plugin',
      'serverTypes': <String>['paper', 'purpur'],
      'source': <String, Object?>{
        'type': 'modrinth',
        'project': 'example',
        'versionId': ?versionId,
      },
    });

Map<String, Object?> _version(
  String id, {
  String published = '2026-03-01T00:00:00Z',
  String channel = 'release',
  List<String> minecraft = const <String>['1.21.11'],
  List<String> loaders = const <String>['paper'],
}) => <String, Object?>{
  'id': id,
  'project_id': 'CanonicalProject',
  'version_number': id,
  'version_type': channel,
  'date_published': published,
  'game_versions': minecraft,
  'loaders': loaders,
  'dependencies': <Object?>[],
  'files': <Map<String, Object?>>[_file(_downloadUrl)],
};

Map<String, Object?> _file(String url, {bool primary = true}) =>
    <String, Object?>{
      'filename': Uri.parse(url).pathSegments.last,
      'url': url,
      'primary': primary,
      'hashes': <String, Object?>{'sha512': sha512.convert(_jar).toString()},
    };

Map<String, Object?> _asset(String name) => <String, Object?>{
  'name': name,
  'browser_download_url': 'https://github.com/fixture/$name',
  'digest': 'sha256:${sha256.convert(_jar)}',
};

/// All provider requests are routed to this server, including download URLs.
final class _HttpFixture {
  _HttpFixture(this.server, HttpClient delegate) {
    client = _FixtureClient(delegate, server.port, requests);
    server.listen((HttpRequest request) async {
      final String key =
          '${request.headers.value('x-fixture-host')}${request.uri.path}';
      final List<int>? body = responses[key];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(body);
      }
      await request.response.close();
    });
  }

  static Future<_HttpFixture> create() async {
    // Construct the real client before entering HttpOverrides.runZoned.
    final HttpClient delegate = HttpClient()..findProxy = (Uri _) => 'DIRECT';
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _HttpFixture(server, delegate);
  }

  final HttpServer server;
  final Map<String, List<int>> responses = <String, List<int>>{};
  final List<Uri> requests = <Uri>[];
  late final _FixtureClient client;

  void json(String key, Object? value) =>
      bytes(key, utf8.encode(jsonEncode(value)));
  void bytes(String key, List<int> value) => responses[key] = value;

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

final class _FixtureClient implements HttpClient {
  _FixtureClient(this.delegate, this.port, this.requests);
  final HttpClient delegate;
  final int port;
  final List<Uri> requests;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    final HttpClientRequest request = await delegate.getUrl(
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
    request.headers.set('x-fixture-host', url.host);
    return request;
  }

  @override
  Duration? get connectionTimeout => delegate.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;

  @override
  void close({bool force = false}) => delegate.close(force: force);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
