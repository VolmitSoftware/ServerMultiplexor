import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'addon_catalog.dart';

final class ResolvedAddon {
  const ResolvedAddon({
    required this.location,
    required this.version,
    this.hash,
    this.hashType,
    this.projectId,
    this.versionId,
    this.requiredProjects = const <String>[],
    this.requiredVersions = const <String, String>{},
  });

  final String location;
  final String version;
  final String? hash;
  final String? hashType;
  final String? projectId;
  final String? versionId;
  final List<String> requiredProjects;
  final Map<String, String> requiredVersions;
}

/// Provider selection is independent of menus, consumers and filesystem state.
final class AddonResolver {
  AddonResolver(this.workspace);
  final String workspace;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);

  void close() => _client.close(force: true);

  Future<ResolvedAddon> resolve(
    AddonDefinition addon,
    String serverType,
    String minecraft,
  ) async {
    final List<String> unavailable = <String>[];
    for (final AddonSource source in addon.sources) {
      if (!source.supports(serverType, minecraft)) continue;
      try {
        return await _resolveSource(addon, source, serverType, minecraft);
      } on _NoCompatibleAddonRelease catch (error) {
        // A published-version miss may use the next declared source. Network,
        // malformed metadata and checksum failures must still fail the install.
        unavailable.add(error.message);
      }
    }
    throw StateError(
      unavailable.isEmpty
          ? 'No verified ${addon.name} source for $serverType Minecraft $minecraft.'
          : unavailable.join(' '),
    );
  }

  Future<ResolvedAddon> _resolveSource(
    AddonDefinition addon,
    AddonSource source,
    String serverType,
    String minecraft,
  ) async {
    final Map<String, Object?> json = source.json;
    switch (source.type) {
      case 'file':
        final String path = addonString(json, 'path');
        return ResolvedAddon(
          location: p.isAbsolute(path) ? path : p.join(workspace, path),
          version: 'local',
        );
      case 'url':
        return ResolvedAddon(
          location: addonString(json, 'url'),
          version: json['version'] as String? ?? 'direct',
          hash: json['sha256'] as String?,
          hashType: 'sha256',
        );
      case 'jenkins':
        return _jenkins(json);
      case 'github':
        final String repo = addonString(json, 'repo');
        final String tag = json['tag'] as String? ?? 'latest';
        final Uri uri = Uri.https(
          'api.github.com',
          '/repos/$repo/releases/${tag == 'latest' ? 'latest' : 'tags/$tag'}',
        );
        final Map<String, Object?> release = addonObject(await _json(uri));
        final Object? assets = release['assets'];
        if (assets is! List<Object?> || release['draft'] == true) {
          throw StateError('No published assets for $repo $tag');
        }
        final String assetName = addonString(json, 'asset');
        final List<Map<String, Object?>> matches = assets
            .map(addonObject)
            .where((Map<String, Object?> asset) => asset['name'] == assetName)
            .toList();
        if (matches.length != 1) {
          throw StateError('Expected exactly one $assetName in $repo $tag');
        }
        final Map<String, Object?> asset = matches.single;
        final String? digest = asset['digest'] as String?;
        final String label = json['label'] as String? ?? '';
        return ResolvedAddon(
          location: addonString(asset, 'browser_download_url'),
          version:
              '${addonString(release, 'tag_name')}${label.isEmpty ? '' : ' ($label)'}',
          hash: digest != null && digest.startsWith('sha256:')
              ? digest.substring(7)
              : null,
          hashType: 'sha256',
        );
      case 'modrinth':
        if (minecraft.isEmpty) {
          throw StateError(
            'Minecraft version is unknown. Use addons set --mc <version>.',
          );
        }
        final String project = addonString(json, 'project');
        final List<String> overrideLoaders = addonStrings(
          json,
          'loaders',
          optional: true,
        );
        final List<String> loaders = overrideLoaders.isNotEmpty
            ? overrideLoaders
            : switch (serverType) {
                'paper' ||
                'purpur' ||
                'leaf' => <String>['paper', 'spigot', 'bukkit'],
                'folia' || 'canvas' => <String>['folia'],
                'spigot' => <String>['spigot', 'bukkit'],
                'mohist' =>
                  addon.kind == 'mod'
                      ? <String>['forge']
                      : <String>['spigot', 'bukkit'],
                _ => <String>[serverType],
              };
        for (final String loader in loaders) {
          final Uri uri = Uri.https(
            'api.modrinth.com',
            '/v2/project/$project/version',
            <String, String>{
              'loaders': jsonEncode(<String>[loader]),
              'game_versions': jsonEncode(<String>[minecraft]),
            },
          );
          final Object? raw = await _json(uri);
          if (raw is! List<Object?>) {
            throw const FormatException('Invalid Modrinth versions');
          }
          final List<Map<String, Object?>> versions =
              raw
                  .map(addonObject)
                  .where(
                    (Map<String, Object?> version) =>
                        version['version_type'] == 'release' &&
                        (json['versionId'] == null ||
                            version['id'] == json['versionId']) &&
                        addonStrings(
                          version,
                          'game_versions',
                        ).contains(minecraft) &&
                        addonStrings(version, 'loaders').contains(loader),
                  )
                  .toList()
                ..sort(
                  (Map<String, Object?> a, Map<String, Object?> b) =>
                      addonString(
                        b,
                        'date_published',
                      ).compareTo(addonString(a, 'date_published')),
                );
          for (final Map<String, Object?> version in versions) {
            final Object? files = version['files'];
            if (files is! List<Object?>) {
              throw const FormatException('Invalid Modrinth release files');
            }
            final List<Map<String, Object?>> jars = files
                .map(addonObject)
                .where(
                  (Map<String, Object?> file) => addonString(
                    file,
                    'filename',
                  ).toLowerCase().endsWith('.jar'),
                )
                .toList();
            final List<Map<String, Object?>> primary = jars
                .where((Map<String, Object?> file) => file['primary'] == true)
                .toList();
            final Map<String, Object?>? file = primary.length == 1
                ? primary.single
                : jars.length == 1
                ? jars.single
                : null;
            if (file == null) {
              throw StateError(
                'Expected exactly one primary JAR for ${addon.name}',
              );
            }
            final Map<String, Object?> hashes = addonObject(file['hashes']);
            final List<String> dependencies = <String>[];
            final Map<String, String> requiredVersions = <String, String>{};
            for (final Object? rawDependency
                in version['dependencies'] as List<Object?>? ??
                    const <Object?>[]) {
              final Map<String, Object?> dependency = addonObject(
                rawDependency,
              );
              if (dependency['dependency_type'] == 'required') {
                final String? versionId = dependency['version_id'] as String?;
                final String dependencyProject;
                if (dependency['project_id'] is String) {
                  dependencyProject = addonString(dependency, 'project_id');
                } else if (versionId != null) {
                  dependencyProject = addonString(
                    addonObject(
                      await _json(
                        Uri.https('api.modrinth.com', '/v2/version/$versionId'),
                      ),
                    ),
                    'project_id',
                  );
                } else {
                  throw const FormatException(
                    'Required Modrinth dependency has no project or version',
                  );
                }
                dependencies.add(dependencyProject);
                if (versionId != null) {
                  requiredVersions[dependencyProject] = versionId;
                }
              }
            }
            return ResolvedAddon(
              location: addonString(file, 'url'),
              version: addonString(version, 'version_number'),
              hash: addonString(hashes, 'sha512'),
              hashType: 'sha512',
              projectId: addonString(version, 'project_id'),
              versionId: addonString(version, 'id'),
              requiredProjects: dependencies,
              requiredVersions: requiredVersions,
            );
          }
        }
        throw _NoCompatibleAddonRelease(
          'No stable ${addon.name} release for $serverType Minecraft $minecraft.',
        );
      default:
        throw StateError('Unknown addon provider: ${source.type}');
    }
  }

  Future<ResolvedAddon> _jenkins(Map<String, Object?> source) async {
    final Uri configured = Uri.parse(addonString(source, 'url'));
    if (configured.hasQuery || configured.hasFragment) {
      throw const FormatException(
        'Jenkins job URL cannot have a query or fragment',
      );
    }
    final Uri job = configured.replace(
      path: configured.path.endsWith('/')
          ? configured.path
          : '${configured.path}/',
    );
    final Map<String, Object?> build = addonObject(
      await _json(
        job
            .resolve('lastSuccessfulBuild/api/json')
            .replace(
              queryParameters: <String, String>{
                'tree':
                    'number,result,building,artifacts[fileName,relativePath]',
              },
            ),
      ),
    );
    final Object? number = build['number'];
    final Object? artifacts = build['artifacts'];
    if (number is! int ||
        number < 1 ||
        build['result'] != 'SUCCESS' ||
        build['building'] != false ||
        artifacts is! List<Object?>) {
      throw const FormatException('Invalid successful Jenkins build');
    }
    final RegExp pattern = RegExp(addonString(source, 'artifactPattern'));
    final List<Map<String, Object?>> matches = artifacts.map(addonObject).where(
      (Map<String, Object?> artifact) {
        final String filename = addonString(artifact, 'fileName');
        return filename.toLowerCase().endsWith('.jar') &&
            pattern.hasMatch(filename);
      },
    ).toList();
    if (matches.length != 1) {
      throw StateError(
        'Expected exactly one matching JAR in Jenkins build $number',
      );
    }
    final Map<String, Object?> artifact = matches.single;
    final String relativePath = addonString(artifact, 'relativePath');
    final List<String> segments = relativePath.split('/');
    if (relativePath.contains('\\') ||
        segments.any(
          (String part) => part.isEmpty || part == '.' || part == '..',
        )) {
      throw const FormatException('Invalid Jenkins artifact path');
    }
    final String label = source['label'] as String? ?? '';
    final String filename = addonString(artifact, 'fileName');
    return ResolvedAddon(
      // Resolve against the immutable build number, never a moving latest URL.
      location: job
          .resolve('$number/')
          .resolveUri(Uri(pathSegments: <String>['artifact', ...segments]))
          .toString(),
      version:
          '${filename.substring(0, filename.length - 4)} #$number'
          '${label.isEmpty ? '' : ' ($label)'}',
    );
  }

  Future<void> download(ResolvedAddon resolved, File target) async {
    final Uri? uri = Uri.tryParse(resolved.location);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final HttpClientResponse response = await _response(uri);
      final IOSink sink = target.openWrite();
      int bytes = 0;
      try {
        await for (final List<int> chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          bytes += chunk.length;
          if (bytes > 256 * 1024 * 1024) {
            throw StateError('Addon exceeds 256 MiB');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } else {
      await File(resolved.location).copy(target.path);
    }
    final RandomAccessFile input = target.openSync();
    final List<int> magic;
    try {
      magic = input.readSync(4);
    } finally {
      input.closeSync();
    }
    if (magic.length != 4 ||
        magic[0] != 0x50 ||
        magic[1] != 0x4b ||
        magic[2] != 3 ||
        magic[3] != 4) {
      throw StateError(
        'Downloaded addon is not a JAR/ZIP: ${resolved.location}',
      );
    }
    if (resolved.hash != null) {
      final Hash algorithm = resolved.hashType == 'sha512' ? sha512 : sha256;
      final String actual = (await algorithm.bind(target.openRead()).first)
          .toString();
      if (actual != resolved.hash!.toLowerCase()) {
        throw StateError('Addon checksum mismatch: ${resolved.location}');
      }
    }
  }

  Future<HttpClientResponse> _response(Uri uri) async {
    if (!const <String>{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw FormatException('Invalid addon download URL: $uri');
    }
    final HttpClientRequest request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 30));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Multiplexor/0.2 (github.com/brianfopiano/multiplexor)',
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 45),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Addon download returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    return response;
  }

  Future<Object?> _json(Uri uri) async {
    final HttpClientResponse response = await _response(uri);
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 30),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024 * 1024) {
        throw StateError('Addon metadata exceeds 8 MiB');
      }
    }
    return jsonDecode(utf8.decode(bytes));
  }
}

final class _NoCompatibleAddonRelease implements Exception {
  const _NoCompatibleAddonRelease(this.message);
  final String message;
}
