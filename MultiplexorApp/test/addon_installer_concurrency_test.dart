import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/addons/addon_catalog.dart';
import 'package:multiplexor/services/addons/addon_installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const List<int> _jar = <int>[0x50, 0x4b, 3, 4, 10, 20, 30, 40];
const Duration _deadline = Duration(seconds: 3);

void main() {
  group('addon file identity', () {
    test('uses a plain default filename and accepts explicit names', () {
      expect(_definition('example').file, 'plugins/example.jar');
      expect(
        _definition('example', fileName: 'ExamplePlugin.jar').file,
        'plugins/ExamplePlugin.jar',
      );
    });

    for (final String filename in <String>[
      '',
      '../escape.jar',
      'plugins/escape.jar',
      r'plugins\escape.jar',
      '/escape.jar',
      'Example.txt',
      'Example.jar\n',
    ]) {
      test('rejects unsafe addon filename ${jsonEncode(filename)}', () {
        expect(
          () => _definition('example', fileName: filename),
          throwsFormatException,
        );
      });
    }

    test('rejects canonical filename collisions without case sensitivity', () {
      expect(
        () => AddonCatalog(<AddonDefinition>[
          _definition('first', fileName: 'Example.jar'),
          _definition('second', fileName: 'example.jar'),
        ]),
        throwsFormatException,
      );
    });

    test('accepts canonical manifest names in either addon directory', () {
      for (final String file in <String>[
        'plugins/ViaVersion.jar',
        'mods/Example-Mod_1.jar',
      ]) {
        expect(_installed('example', file).file, file);
      }
    });

    for (final String path in <String>[
      '../plugins/Example.jar',
      'plugins/../Example.jar',
      'plugins/nested/Example.jar',
      '/plugins/Example.jar',
      r'plugins\Example.jar',
      'plugins/Example.txt',
      'plugins/Example.jar\n',
      'world/Example.jar',
    ]) {
      test('rejects unsafe installed path ${jsonEncode(path)}', () {
        expect(() => _installed('example', path), throwsFormatException);
      });
    }

    test('matches canonical and version aliases only at name boundaries', () {
      final InstalledAddon via = _installed(
        'viaversion',
        'plugins/ViaVersion.jar',
        filePrefixes: <String>['viaversion'],
      );
      for (final String name in <String>[
        'ViaVersion.jar',
        'ViaVersion-5.11.0.jar',
        'viaversion_5.11.0.jar',
        'ViaVersion 5.11.0.jar',
        'ViaVersion.5.11.0.jar',
      ]) {
        expect(via.protects('plugins/$name'), isTrue, reason: name);
      }
      expect(via.protects('plugins/ViaVersionExtras.jar'), isFalse);
      expect(via.protects('mods/ViaVersion.jar'), isFalse);
      expect(via.protects('plugins/ViaVersion/config.yml'), isFalse);
      final InstalledAddon fawe = _installed(
        'fawe',
        'plugins/FastAsyncWorldEdit.jar',
        filePrefixes: <String>['fastasyncworldedit', 'worldedit'],
      );
      expect(fawe.protects('plugins/WorldEdit-7.3.0.jar'), isTrue);
      expect(fawe.protects('plugins/WorldEditCUI.jar'), isFalse);
    });
  });

  group('parallel addon preparation', () {
    late Directory root;
    late Directory instance;
    late _AddonApi fixture;

    setUp(() async {
      root = Directory.systemTemp.createTempSync(
        'multiplexor-addon-pool-test-',
      );
      instance = Directory(p.join(root.path, 'instance'))..createSync();
      fixture = await _AddonApi.create();
    });

    tearDown(() async {
      await fixture.close();
      root.deleteSync(recursive: true);
    });

    Future<Set<String>> apply(
      AddonCatalog catalog,
      Set<String> selected, {
      void Function(String)? report,
      void Function()? onCommit,
    }) => HttpOverrides.runZoned<Future<Set<String>>>(
      () =>
          AddonInstaller(
            workspace: root.path,
            instancePath: instance.path,
            serverType: 'paper',
            minecraft: '1.21.11',
            catalog: catalog,
          ).apply(
            selected,
            report: report ?? (String _) {},
            beforeCommit: () async {},
            commit: (void Function() operation) {
              onCommit?.call();
              operation();
            },
          ),
      createHttpClient: (SecurityContext? _) => fixture.client,
    );

    test(
      'overlaps resolution and downloads with at most four workers',
      () async {
        final List<String> ids = List<String>.generate(
          7,
          (int index) => 'addon-$index',
        );
        final AddonCatalog catalog = AddonCatalog(ids.map(_definition));
        final Completer<void> fourMetadata = Completer<void>();
        final Completer<void> releaseMetadata = Completer<void>();
        final Completer<void> fourDownloads = Completer<void>();
        final Completer<void> releaseDownloads = Completer<void>();
        fixture.beforeMetadata = (String _) async {
          if (fixture.activeMetadata == 4 && !fourMetadata.isCompleted) {
            fourMetadata.complete();
          }
          await releaseMetadata.future;
        };
        fixture.beforeDownload = (String _) async {
          if (fixture.activeDownloads == 4 && !fourDownloads.isCompleted) {
            fourDownloads.complete();
          }
          await releaseDownloads.future;
        };
        bool committed = false;
        final Future<Set<String>> result = apply(
          catalog,
          ids.toSet(),
          onCommit: () => committed = true,
        );
        try {
          await fourMetadata.future.timeout(_deadline);
          expect(fixture.metadataIds.length, 4);
          expect(fixture.downloadIds, isEmpty);
          expect(committed, isFalse);
          releaseMetadata.complete();

          await fourDownloads.future.timeout(_deadline);
          expect(fixture.metadataIds, hasLength(ids.length));
          expect(fixture.downloadIds.length, 4);
          expect(committed, isFalse);
          releaseDownloads.complete();

          expect(await result.timeout(_deadline), ids.toSet());
          expect(fixture.maxMetadata, 4);
          expect(fixture.maxDownloads, 4);
          expect(committed, isTrue);
          expect(AddonState.read(instance.path).entries.keys, ids);
        } finally {
          if (!releaseMetadata.isCompleted) releaseMetadata.complete();
          if (!releaseDownloads.isCompleted) releaseDownloads.complete();
          await result;
        }
      },
    );

    test(
      'completion order cannot reorder dependency validation or installed state',
      () async {
        final AddonCatalog catalog = AddonCatalog(<AddonDefinition>[
          _definition('dependent', dependencies: <String>['dependency']),
          _definition('dependency'),
          _definition('unrelated'),
        ]);
        fixture.dependencies['dependent'] = <Map<String, Object?>>[
          <String, Object?>{
            'dependency_type': 'required',
            'project_id': 'project-dependency',
            'version_id': 'version-dependency',
          },
        ];
        final Completer<void> dependentMetadata = Completer<void>();
        final Completer<void> dependentDownloaded = Completer<void>();
        fixture.beforeMetadata = (String id) async {
          if (id == 'dependent') dependentMetadata.complete();
          if (id == 'dependency') await dependentMetadata.future;
        };
        fixture.beforeDownload = (String id) async {
          if (id == 'dependency') await dependentDownloaded.future;
        };
        fixture.afterDownload = (String id) {
          if (id == 'dependent') dependentDownloaded.complete();
        };
        final List<String> reports = <String>[];

        await apply(catalog, <String>{
          'dependent',
          'unrelated',
        }, report: reports.add).timeout(_deadline);

        expect(
          fixture.finishedDownloadIds.indexOf('dependent'),
          lessThan(fixture.finishedDownloadIds.indexOf('dependency')),
        );
        expect(AddonState.read(instance.path).entries.keys, <String>[
          'dependency',
          'dependent',
          'unrelated',
        ]);
        expect(
          reports.where((String line) => line.startsWith('[INFO] Ready:')),
          <String>[
            '[INFO] Ready: dependency release-dependency',
            '[INFO] Ready: dependent release-dependent',
            '[INFO] Ready: unrelated release-unrelated',
          ],
        );
      },
    );

    test(
      'rejects incompatible exact dependencies before starting downloads',
      () async {
        final AddonCatalog catalog = AddonCatalog(<AddonDefinition>[
          _definition('dependent', dependencies: <String>['dependency']),
          _definition('dependency'),
        ]);
        fixture.dependencies['dependent'] = <Map<String, Object?>>[
          <String, Object?>{
            'dependency_type': 'required',
            'project_id': 'project-dependency',
            'version_id': 'required-older-version',
          },
        ];
        bool committed = false;

        await expectLater(
          apply(catalog, <String>{
            'dependent',
          }, onCommit: () => committed = true),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('required-older-version'),
            ),
          ),
        );

        expect(fixture.downloadIds, isEmpty);
        expect(committed, isFalse);
        expect(AddonState.read(instance.path).entries, isEmpty);
        expect(_stages(instance), isEmpty);
      },
    );

    test(
      'builtins replace versioned jars without removing similarly named plugins',
      () async {
        final AddonCatalog catalog = AddonCatalog.load(root.path);
        final Map<String, List<int>> originals = <String, List<int>>{
          'ViaVersion.jar': <int>[..._jar, 1],
          'ViaVersion-5.11.0.jar': <int>[..._jar, 2],
          'ViaVersion_5.10.0.jar': <int>[..._jar, 3],
          'FastAsyncWorldEdit-Paper-2.13.0.jar': <int>[..._jar, 4],
          'WorldEdit-7.3.0.jar': <int>[..._jar, 5],
          'ViaVersionExtras.jar': <int>[..._jar, 6],
          'WorldEditCUI.jar': <int>[..._jar, 7],
        };
        for (final MapEntry<String, List<int>> original in originals.entries) {
          File(p.join(instance.path, 'plugins', original.key))
            ..createSync(recursive: true)
            ..writeAsBytesSync(original.value);
        }

        await apply(catalog, <String>{'viaversion', 'fawe'});

        for (final String canonical in <String>[
          'ViaVersion.jar',
          'FastAsyncWorldEdit.jar',
        ]) {
          expect(
            File(p.join(instance.path, 'plugins', canonical)).readAsBytesSync(),
            _jar,
          );
        }
        for (final String alias in <String>[
          'ViaVersion-5.11.0.jar',
          'ViaVersion_5.10.0.jar',
          'FastAsyncWorldEdit-Paper-2.13.0.jar',
          'WorldEdit-7.3.0.jar',
        ]) {
          expect(
            File(p.join(instance.path, 'plugins', alias)).existsSync(),
            isFalse,
          );
        }
        for (final String separate in <String>[
          'ViaVersionExtras.jar',
          'WorldEditCUI.jar',
        ]) {
          expect(
            File(p.join(instance.path, 'plugins', separate)).readAsBytesSync(),
            originals[separate],
          );
        }
        expect(
          AddonState.read(
            instance.path,
          ).entries.values.map((InstalledAddon addon) => addon.file),
          <String>['plugins/ViaVersion.jar', 'plugins/FastAsyncWorldEdit.jar'],
        );
      },
    );

    test(
      'a commit failure restores canonical jars and every duplicate alias',
      () async {
        final AddonCatalog catalog = AddonCatalog(<AddonDefinition>[
          _definition(
            'first',
            fileName: 'First.jar',
            filePrefixes: <String>['first'],
          ),
          _definition(
            'second',
            fileName: 'Second.jar',
            filePrefixes: <String>['second'],
          ),
        ]);
        final Map<String, List<int>> originals = <String, List<int>>{
          'First.jar': <int>[..._jar, 1],
          'First-1.0.jar': <int>[..._jar, 2],
          'First_0.9.jar': <int>[..._jar, 3],
          'Second.jar': <int>[..._jar, 4],
          'Second-2.0.jar': <int>[..._jar, 5],
          'kept.jar': <int>[..._jar, 6],
        };
        for (final MapEntry<String, List<int>> original in originals.entries) {
          File(p.join(instance.path, 'plugins', original.key))
            ..createSync(recursive: true)
            ..writeAsBytesSync(original.value);
        }
        final File state = File(p.join(instance.path, AddonState.filename));
        final String originalState = jsonEncode(
          AddonState(<String, InstalledAddon>{
            'first': _installed(
              'first',
              'plugins/First.jar',
              filePrefixes: <String>['first'],
            ),
            'kept': _installed('kept', 'plugins/kept.jar'),
          }).toJson(),
        );
        state.writeAsStringSync(originalState);
        final File dropin =
            File(
                p.join(
                  root.path,
                  'consumers',
                  'plugin-consumers',
                  'dropins',
                  'plugins',
                  'First-1.0.jar',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsBytesSync(<int>[..._jar, 77]);
        bool commitEntered = false;

        await expectLater(
          apply(
            catalog,
            <String>{'first', 'second'},
            onCommit: () {
              commitEntered = true;
              final FileSystemEntity stage = _stages(instance).single;
              // The first jar and alias backups are committed before the
              // missing second staged jar makes its rename fail.
              File(p.join(stage.path, 'second.jar')).deleteSync();
            },
          ),
          throwsA(isA<FileSystemException>()),
        );

        expect(commitEntered, isTrue);
        expect(
          fixture.finishedDownloadIds,
          unorderedEquals(<String>['first', 'second']),
        );
        for (final MapEntry<String, List<int>> original in originals.entries) {
          expect(
            File(
              p.join(instance.path, 'plugins', original.key),
            ).readAsBytesSync(),
            original.value,
            reason: original.key,
          );
        }
        expect(state.readAsStringSync(), originalState);
        expect(dropin.readAsBytesSync(), <int>[..._jar, 77]);
        expect(_stages(instance), isEmpty);
      },
    );

    test(
      'a failed download drains other workers before cleaning up staging',
      () async {
        final AddonCatalog catalog = AddonCatalog(<AddonDefinition>[
          _definition('broken'),
          _definition('slow-one', filePrefixes: <String>['slow-one']),
          _definition('slow-two'),
          _definition('slow-three'),
        ]);
        final File original = File(p.join(instance.path, 'plugins', 'kept.jar'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(_jar);
        final String originalState = jsonEncode(
          AddonState(<String, InstalledAddon>{
            'kept': InstalledAddon(<String, Object?>{
              'id': 'kept',
              'file': 'plugins/kept.jar',
              'sha256': sha256.convert(_jar).toString(),
            }),
          }).toJson(),
        );
        final File state = File(p.join(instance.path, AddonState.filename))
          ..writeAsStringSync(originalState);
        final List<File> duplicateOriginals = <File>[
          File(p.join(instance.path, 'plugins', 'slow-one.jar')),
          File(p.join(instance.path, 'plugins', 'slow-one-1.0.jar')),
        ];
        for (final File duplicate in duplicateOriginals) {
          duplicate.writeAsBytesSync(<int>[..._jar, 99]);
        }
        final Completer<void> fourDownloads = Completer<void>();
        final Completer<void> failureSent = Completer<void>();
        final Completer<void> finishSlow = Completer<void>();
        fixture.failedDownloads.add('broken');
        fixture.beforeDownload = (String id) async {
          if (fixture.downloadIds.length == 4) fourDownloads.complete();
          await fourDownloads.future;
          if (id != 'broken') await finishSlow.future;
        };
        fixture.afterDownload = (String id) {
          if (id == 'broken') failureSent.complete();
        };
        bool settled = false;
        bool committed = false;
        Object? failure;
        final Future<void> result =
            apply(
              catalog,
              catalog.entries.keys.toSet(),
              onCommit: () => committed = true,
            ).then<void>(
              (Set<String> _) => settled = true,
              onError: (Object error, StackTrace _) {
                settled = true;
                failure = error;
              },
            );
        try {
          await failureSent.future.timeout(_deadline);
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          expect(fixture.activeDownloads, 3);
          expect(_stages(instance), hasLength(1));
          expect(state.readAsStringSync(), originalState);
          finishSlow.complete();
          await result.timeout(_deadline);

          expect(failure, isA<HttpException>());
          expect(fixture.activeDownloads, 0);
          expect(committed, isFalse);
          expect(original.readAsBytesSync(), _jar);
          for (final File duplicate in duplicateOriginals) {
            expect(duplicate.readAsBytesSync(), <int>[..._jar, 99]);
          }
          expect(state.readAsStringSync(), originalState);
          expect(_stages(instance), isEmpty);
        } finally {
          if (!fourDownloads.isCompleted) fourDownloads.complete();
          if (!finishSlow.isCompleted) finishSlow.complete();
          await result;
        }
      },
    );
  });
}

List<FileSystemEntity> _stages(Directory instance) => instance
    .listSync()
    .where(
      (FileSystemEntity entry) =>
          p.basename(entry.path).startsWith('.multiplexor-addons-stage-'),
    )
    .toList();

AddonDefinition _definition(
  String id, {
  List<String> dependencies = const <String>[],
  String? fileName,
  List<String> filePrefixes = const <String>[],
}) => AddonDefinition(<String, Object?>{
  'id': id,
  'name': id,
  'kind': 'plugin',
  'serverTypes': <String>['paper'],
  'dependencies': dependencies,
  'fileName': ?fileName,
  'filePrefixes': filePrefixes,
  'source': <String, Object?>{'type': 'modrinth', 'project': id},
});

InstalledAddon _installed(
  String id,
  String file, {
  List<String> filePrefixes = const <String>[],
}) => InstalledAddon(<String, Object?>{
  'id': id,
  'file': file,
  'sha256': sha256.convert(_jar).toString(),
  'filePrefixes': filePrefixes,
});

final class _AddonApi {
  _AddonApi(this.server, HttpClient delegate) {
    client = _RedirectClient(delegate, server.port);
    server.listen(_respond);
  }

  static Future<_AddonApi> create() async {
    final HttpClient delegate = HttpClient()..findProxy = (Uri _) => 'DIRECT';
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _AddonApi(server, delegate);
  }

  final HttpServer server;
  late final _RedirectClient client;
  final Map<String, List<Map<String, Object?>>> dependencies =
      <String, List<Map<String, Object?>>>{};
  final Set<String> failedDownloads = <String>{};
  final List<String> metadataIds = <String>[];
  final List<String> downloadIds = <String>[];
  final List<String> finishedDownloadIds = <String>[];
  Future<void> Function(String)? beforeMetadata;
  Future<void> Function(String)? beforeDownload;
  void Function(String)? afterDownload;
  int activeMetadata = 0;
  int activeDownloads = 0;
  int maxMetadata = 0;
  int maxDownloads = 0;

  Future<void> _respond(HttpRequest request) async {
    final List<String> path = request.uri.pathSegments;
    final bool metadata = path.first == 'v2';
    final String id = metadata
        ? path[2]
        : p.basenameWithoutExtension(path.last);
    if (metadata) {
      metadataIds.add(id);
      activeMetadata++;
      if (activeMetadata > maxMetadata) maxMetadata = activeMetadata;
    } else {
      downloadIds.add(id);
      activeDownloads++;
      if (activeDownloads > maxDownloads) maxDownloads = activeDownloads;
    }
    try {
      if (metadata) {
        await beforeMetadata?.call(id);
        request.response.write(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'version-$id',
              'project_id': 'project-$id',
              'version_number': 'release-$id',
              'version_type': 'release',
              'date_published': '2026-09-01T00:00:00Z',
              'game_versions': <String>['1.21.11'],
              'loaders': <String>['paper'],
              'dependencies': dependencies[id] ?? const <Object?>[],
              'files': <Map<String, Object?>>[
                <String, Object?>{
                  'filename': '$id.jar',
                  'primary': true,
                  'url': 'https://cdn.modrinth.com/downloads/$id.jar',
                  'hashes': <String, String>{
                    'sha512': sha512.convert(_jar).toString(),
                  },
                },
              ],
            },
          ]),
        );
      } else {
        await beforeDownload?.call(id);
        if (failedDownloads.contains(id)) {
          request.response.statusCode = HttpStatus.internalServerError;
        } else {
          request.response.add(_jar);
        }
      }
      await request.response.close();
    } finally {
      if (metadata) {
        activeMetadata--;
      } else {
        activeDownloads--;
        finishedDownloadIds.add(id);
        afterDownload?.call(id);
      }
    }
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

final class _RedirectClient implements HttpClient {
  _RedirectClient(this.delegate, this.port);
  final HttpClient delegate;
  final int port;

  @override
  Future<HttpClientRequest> getUrl(Uri url) => delegate.getUrl(
    url.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );

  @override
  Duration? get connectionTimeout => delegate.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;

  @override
  void close({bool force = false}) => delegate.close(force: force);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
