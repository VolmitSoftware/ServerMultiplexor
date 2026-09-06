import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/addons/addon_resolver.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late HttpServer server;
  late int metadataCalls;
  late String loader;
  const List<int> bytes = <int>[0x50, 0x4b, 3, 4, 1, 2, 3];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-content-command-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    metadataCalls = 0;
    loader = 'paper';
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    service = NativeCommandService(
      context: context,
      consumerService: ConsumerService(context),
      contentResolverFactory: (String workspace) => AddonResolver(
        workspace,
        jsonLoader: (Uri uri) async {
          metadataCalls++;
          if (!uri.path.endsWith('/version')) {
            return <String, Object?>{
              'id': 'test',
              'title': 'Test',
              'project_type': 'plugin',
            };
          }
          return <Map<String, Object?>>[
            <String, Object?>{
              'id': 'v1',
              'project_id': 'test',
              'version_number': '1.0',
              'version_type': 'release',
              'date_published': '2026-01-01T00:00:00Z',
              'game_versions': <String>['1.21.4'],
              'loaders': <String>[loader],
              'files': <Map<String, Object?>>[
                <String, Object?>{
                  'filename': 'plugin.jar',
                  'primary': true,
                  'url': 'http://127.0.0.1:${server.port}/plugin.jar',
                  'hashes': <String, Object?>{
                    'sha512': sha512.convert(bytes).toString(),
                  },
                },
              ],
            },
          ];
        },
      ),
    );
  });

  tearDown(() async {
    service.disposeRcon();
    await server.close(force: true);
    root.deleteSync(recursive: true);
  });

  Future<CapturedResult> run(List<String> args) =>
      service.execute(<String>['content', ...args], stream: false);

  test('unknown Minecraft version fails before provider resolution', () async {
    final CapturedResult result = await run(<String>['install', 'test']);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('--mc'));
    expect(metadataCalls, 0);
  });

  test('CLI install and update use strict shared content resolver', () async {
    final CapturedResult installed = await run(<String>[
      'install',
      'test',
      '--mc',
      '1.21.4',
    ]);
    expect(installed.exitCode, 0, reason: installed.stderr);
    final String consumer = p.join(root.path, 'consumers', 'plugin-consumers');
    final File artifact = File(
      p.join(consumer, 'dropins', 'plugins', 'plugin.jar'),
    );
    final File manifest = File(p.join(consumer, 'state', 'content-lock.yaml'));
    expect(artifact.readAsBytesSync(), bytes);
    final String previous = manifest.readAsStringSync();
    loader = 'fabric';
    final CapturedResult update = await run(<String>['update', '--all']);
    expect(update.exitCode, 1);
    expect(update.stderr, contains('No stable'));
    expect(manifest.readAsStringSync(), previous);
    expect(artifact.readAsBytesSync(), bytes);
  });

  test(
    'URL filename option reaches the transaction through CLI parsing',
    () async {
      final CapturedResult result = await run(<String>[
        'install',
        'http://127.0.0.1:${server.port}/download',
        '--file',
        'custom.jar',
        '--name',
        'custom',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File(
          p.join(
            root.path,
            'consumers',
            'plugin-consumers',
            'dropins',
            'plugins',
            'custom.jar',
          ),
        ).readAsBytesSync(),
        bytes,
      );
      expect(metadataCalls, 0);
    },
  );
}
