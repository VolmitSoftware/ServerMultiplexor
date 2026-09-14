import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final class VelocityArtifact {
  const VelocityArtifact({
    required this.version,
    required this.build,
    required this.url,
    required this.sha256,
  });

  final String version;
  final int build;
  final Uri url;
  final String sha256;

  String get filename => 'velocity-$version-$build.jar';
}

final class VelocityDownloads {
  VelocityDownloads({Uri? apiBase})
    : apiBase = apiBase ?? Uri.parse('https://fill.papermc.io/v3/');

  final Uri apiBase;
  static const String _userAgent =
      'multiplexor/0.2.0 (https://github.com/brianfopiano/multiplexor)';

  Future<Object?> _json(String path) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest request = await client.getUrl(
        apiBase.resolve(path),
      );
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Velocity metadata returned HTTP ${response.statusCode}',
        );
      }
      return jsonDecode(
        await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 30)),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<VelocityArtifact> resolve({String? version}) async {
    if (version != null &&
        !RegExp(r'^\d+\.\d+\.\d+(?:-SNAPSHOT)?$').hasMatch(version)) {
      throw const FormatException('Invalid Velocity version');
    }
    final List<String> versions;
    if (version != null) {
      versions = <String>[version];
    } else {
      final Object? project = await _json('projects/velocity');
      if (project is! Map<String, dynamic> || project['versions'] is! Map) {
        throw const FormatException('Invalid Velocity version catalog');
      }
      final Map<Object?, Object?> groups = project['versions'] as Map;
      versions =
          <String>[
            for (final Object? group in groups.values)
              if (group is List)
                for (final Object? item in group)
                  if (item is String &&
                      RegExp(r'^[34]\.\d+\.\d+$').hasMatch(item))
                    item,
          ]..sort((String a, String b) {
            final List<int> left = a.split('.').map(int.parse).toList();
            final List<int> right = b.split('.').map(int.parse).toList();
            for (int index = 0; index < 3; index++) {
              final int comparison = right[index].compareTo(left[index]);
              if (comparison != 0) return comparison;
            }
            return 0;
          });
    }
    for (final String candidate in versions) {
      final Object? raw = await _json(
        'projects/velocity/versions/$candidate/builds',
      );
      if (raw is! List) {
        throw const FormatException('Invalid Velocity build catalog');
      }
      final List<VelocityArtifact> artifacts = <VelocityArtifact>[];
      for (final Object? item in raw) {
        if (item is! Map || item['id'] is! int) continue;
        if (item['channel'] != 'STABLE' && version == null) continue;
        final Object? downloads = item['downloads'];
        final Object? primary = downloads is Map
            ? downloads['server:default']
            : null;
        if (primary is! Map) continue;
        final Object? checksums = primary['checksums'];
        final Object? checksum = checksums is Map ? checksums['sha256'] : null;
        final Uri? url = primary['url'] is String
            ? Uri.tryParse(primary['url'] as String)
            : null;
        if (url == null ||
            url.scheme != 'https' ||
            checksum is! String ||
            !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(checksum)) {
          continue;
        }
        artifacts.add(
          VelocityArtifact(
            version: candidate,
            build: item['id'] as int,
            url: url,
            sha256: checksum.toLowerCase(),
          ),
        );
      }
      artifacts.sort(
        (VelocityArtifact a, VelocityArtifact b) => b.build.compareTo(a.build),
      );
      if (artifacts.isNotEmpty) return artifacts.first;
    }
    throw StateError(
      'No downloadable ${version == null ? 'stable ' : ''}Velocity build found',
    );
  }

  Future<File> download(VelocityArtifact artifact, Directory cache) async {
    cache.createSync(recursive: true);
    final File target = File(p.join(cache.path, artifact.filename));
    if (target.existsSync() &&
        (await sha256.bind(target.openRead()).first).toString() ==
            artifact.sha256) {
      return target;
    }
    final Directory staging = cache.createTempSync('.velocity-download-');
    final File temporary = File(p.join(staging.path, artifact.filename));
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest request = await client.getUrl(artifact.url);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Velocity download returned HTTP ${response.statusCode}',
        );
      }
      await response
          .timeout(const Duration(seconds: 60))
          .pipe(temporary.openWrite());
      final String actual = (await sha256.bind(temporary.openRead()).first)
          .toString();
      if (actual != artifact.sha256) {
        throw StateError('Velocity download checksum mismatch');
      }
      await temporary.rename(target.path);
      return target;
    } finally {
      client.close(force: true);
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }
}
