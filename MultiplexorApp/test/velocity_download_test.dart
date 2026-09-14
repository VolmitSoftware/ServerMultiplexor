import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/networks/velocity_download.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'default selection uses latest stable version and stable build',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          contains('multiplexor/'),
        );
        final Object response;
        if (request.uri.path == '/projects/velocity') {
          response = <String, Object>{
            'versions': <String, Object>{
              '4': <String>['4.9.0-SNAPSHOT', '4.1.1', '4.0.0'],
              '3': <String>['3.5.1'],
            },
          };
        } else {
          expect(request.uri.path, '/projects/velocity/versions/4.1.1/builds');
          response = <Object>[
            for (final int id in <int>[25, 24])
              <String, Object>{
                'id': id,
                'channel': id == 24 ? 'STABLE' : 'EXPERIMENTAL',
                'downloads': <String, Object>{
                  'server:default': <String, Object>{
                    'url': 'https://example.com/$id.jar',
                    'checksums': <String, String>{'sha256': 'a' * 64},
                  },
                },
              },
          ];
        }
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final VelocityArtifact artifact = await VelocityDownloads(
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/'),
      ).resolve();
      expect(artifact.version, '4.1.1');
      expect(artifact.build, 24);
    },
  );

  test(
    'verified cache is reused and corrupted download preserves existing jar',
    () async {
      final Directory cache = Directory.systemTemp.createTempSync(
        'multiplexor-velocity-cache-',
      );
      addTearDown(() => cache.deleteSync(recursive: true));
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      int requests = 0;
      server.listen((HttpRequest request) async {
        requests++;
        request.response.write('corrupt');
        await request.response.close();
      });
      final VelocityArtifact artifact = VelocityArtifact(
        version: '4.1.1',
        build: 24,
        url: Uri.parse('http://127.0.0.1:${server.port}/velocity.jar'),
        sha256: sha256.convert(utf8.encode('verified')).toString(),
      );
      final File jar = File(p.join(cache.path, artifact.filename))
        ..writeAsStringSync('verified');
      expect(
        (await VelocityDownloads().download(artifact, cache)).path,
        jar.path,
      );
      expect(requests, 0);
      jar.writeAsStringSync('old cache');
      await expectLater(
        VelocityDownloads().download(artifact, cache),
        throwsStateError,
      );
      expect(jar.readAsStringSync(), 'old cache');
      expect(cache.listSync(), hasLength(1));
    },
  );
}
