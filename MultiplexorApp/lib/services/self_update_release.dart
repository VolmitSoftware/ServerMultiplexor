import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

class UpdateVersion implements Comparable<UpdateVersion> {
  UpdateVersion._(this.text, this._numbers, this._prerelease);

  factory UpdateVersion.parse(String value) {
    final RegExpMatch? match = RegExp(
      r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value);
    if (match == null || value.length > 128) {
      throw FormatException('Invalid update version: $value');
    }
    final List<String> prerelease = match[4]?.split('.') ?? <String>[];
    for (final String identifier in prerelease) {
      if (RegExp(r'^[0-9]+$').hasMatch(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0')) {
        throw FormatException('Invalid update version: $value');
      }
    }
    return UpdateVersion._(
      value.startsWith('v') ? value.substring(1) : value,
      <BigInt>[
        for (int index = 1; index <= 3; index++) BigInt.parse(match[index]!),
      ],
      prerelease,
    );
  }

  final String text;
  final List<BigInt> _numbers;
  final List<String> _prerelease;

  bool get isStable => _prerelease.isEmpty;

  @override
  int compareTo(UpdateVersion other) {
    for (int index = 0; index < _numbers.length; index++) {
      final int comparison = _numbers[index].compareTo(other._numbers[index]);
      if (comparison != 0) return comparison;
    }
    if (isStable || other.isStable) {
      return isStable == other.isStable ? 0 : (isStable ? 1 : -1);
    }
    for (
      int index = 0;
      index < _prerelease.length && index < other._prerelease.length;
      index++
    ) {
      final String left = _prerelease[index];
      final String right = other._prerelease[index];
      final BigInt? leftNumber = RegExp(r'^[0-9]+$').hasMatch(left)
          ? BigInt.parse(left)
          : null;
      final BigInt? rightNumber = RegExp(r'^[0-9]+$').hasMatch(right)
          ? BigInt.parse(right)
          : null;
      final int comparison;
      if (leftNumber != null && rightNumber != null) {
        comparison = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null || rightNumber != null) {
        comparison = leftNumber != null ? -1 : 1;
      } else {
        comparison = left.compareTo(right);
      }
      if (comparison != 0) return comparison;
    }
    return _prerelease.length.compareTo(other._prerelease.length);
  }

  @override
  String toString() => text;
}

class UpdatePlatform {
  const UpdatePlatform({
    required this.archiveSuffix,
    required this.executableName,
  });

  final String archiveSuffix;
  final String executableName;

  static UpdatePlatform? current() => switch (Abi.current()) {
    Abi.macosArm64 => const UpdatePlatform(
      archiveSuffix: 'macos-arm64.tar.gz',
      executableName: 'multiplexor',
    ),
    Abi.macosX64 => const UpdatePlatform(
      archiveSuffix: 'macos-x64.tar.gz',
      executableName: 'multiplexor',
    ),
    Abi.linuxArm64 => const UpdatePlatform(
      archiveSuffix: 'linux-arm64.tar.gz',
      executableName: 'multiplexor',
    ),
    Abi.linuxX64 => const UpdatePlatform(
      archiveSuffix: 'linux-x64.tar.gz',
      executableName: 'multiplexor',
    ),
    Abi.windowsX64 => const UpdatePlatform(
      archiveSuffix: 'windows-x64.zip',
      executableName: 'multiplexor.exe',
    ),
    _ => null,
  };
}

class SelfUpdateRelease {
  const SelfUpdateRelease({
    required this.version,
    required this.downloadUrl,
    required this.assetName,
    required this.sha256,
    required this.size,
  });

  final UpdateVersion version;
  final Uri downloadUrl;
  final String assetName;
  final String sha256;
  final int size;
}

class GithubUpdateClient {
  GithubUpdateClient()
    : _latestReleaseUrl = Uri.https(
        'api.github.com',
        '/repos/VolmitSoftware/ServerMultiplexor/releases/latest',
      ),
      _testingOrigin = null,
      _metadataTimeout = const Duration(seconds: 8),
      _downloadTimeout = const Duration(minutes: 2);

  GithubUpdateClient.forTesting({
    required Uri latestReleaseUrl,
    Duration metadataTimeout = const Duration(seconds: 8),
    Duration downloadTimeout = const Duration(minutes: 2),
  }) : _latestReleaseUrl = latestReleaseUrl,
       _testingOrigin = latestReleaseUrl.origin,
       _metadataTimeout = metadataTimeout,
       _downloadTimeout = downloadTimeout {
    if (!<String>{'127.0.0.1', '::1'}.contains(latestReleaseUrl.host) ||
        !<String>{'http', 'https'}.contains(latestReleaseUrl.scheme) ||
        latestReleaseUrl.userInfo.isNotEmpty) {
      throw ArgumentError('Update test endpoints must use a loopback address.');
    }
  }

  static const int _maxArchiveBytes = 128 * 1024 * 1024;
  static const int _maxMetadataBytes = 1024 * 1024;
  static const int _maxChecksumsBytes = 64 * 1024;
  static const Set<String> _archiveSuffixes = <String>{
    'macos-arm64.tar.gz',
    'macos-x64.tar.gz',
    'linux-arm64.tar.gz',
    'linux-x64.tar.gz',
    'windows-x64.zip',
  };
  static final RegExp _digestPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final Uri _latestReleaseUrl;
  final String? _testingOrigin;
  final Duration _metadataTimeout;
  final Duration _downloadTimeout;
  final Set<HttpClient> _clients = <HttpClient>{};
  bool _closed = false;

  Future<SelfUpdateRelease?> latest(
    UpdateVersion current,
    UpdatePlatform platform,
  ) => _run(_metadataTimeout, (HttpClient client, _Deadline deadline) async {
    if (!_archiveSuffixes.contains(platform.archiveSuffix) ||
        platform.executableName !=
            (platform.archiveSuffix == 'windows-x64.zip'
                ? 'multiplexor.exe'
                : 'multiplexor')) {
      throw UnsupportedError('No compiled update supports this platform.');
    }
    final Uint8List? data = await _read(
      _latestReleaseUrl,
      _maxMetadataBytes,
      client,
      deadline,
      allowNotFound: true,
    );
    if (data == null) return null;
    final Object? decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map<String, Object?> ||
        decoded['draft'] is! bool ||
        decoded['prerelease'] is! bool ||
        decoded['tag_name'] is! String) {
      throw const FormatException('GitHub returned invalid release metadata.');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) return null;
    final String tag = decoded['tag_name']! as String;
    final UpdateVersion version = UpdateVersion.parse(tag);
    if (!version.isStable || version.compareTo(current) <= 0) return null;
    final String name =
        'multiplexor-v${version.text}-${platform.archiveSuffix}';
    final Object? assets = decoded['assets'];
    if (assets is! List<Object?>) {
      throw const FormatException('GitHub release assets are missing.');
    }
    final Map<String, Object?> archive = _asset(assets, name);
    final Map<String, Object?> checksums = _asset(assets, 'SHA256SUMS');
    final int size = _assetSize(archive, _maxArchiveBytes);
    final int checksumSize = _assetSize(checksums, _maxChecksumsBytes);
    final Uri downloadUrl = _assetUrl(archive, tag, name);
    final Uri checksumUrl = _assetUrl(checksums, tag, 'SHA256SUMS');
    final Uint8List checksumBytes = (await _read(
      checksumUrl,
      checksumSize,
      client,
      deadline,
    ))!;
    if (checksumBytes.length != checksumSize) {
      throw const FormatException('Release checksum file size does not match.');
    }
    final Map<String, String> digests = <String, String>{};
    for (final String line in const LineSplitter().convert(
      utf8.decode(checksumBytes),
    )) {
      if (line.isEmpty) continue;
      final RegExpMatch? match = RegExp(
        r'^([0-9a-fA-F]{64}) [ *]([^/\\\r\n]+)$',
      ).firstMatch(line);
      if (match == null || digests.containsKey(match[2])) {
        throw const FormatException(
          'Release checksums are invalid or duplicated.',
        );
      }
      digests[match[2]!] = match[1]!.toLowerCase();
    }
    final String? checksum = digests[name];
    if (checksum == null) {
      throw FormatException('Release checksum is missing for $name.');
    }
    final Object? apiDigest = archive['digest'];
    if (apiDigest != null && apiDigest != 'sha256:$checksum') {
      throw const FormatException('GitHub and release checksums do not match.');
    }
    return SelfUpdateRelease(
      version: version,
      downloadUrl: downloadUrl,
      assetName: name,
      sha256: checksum,
      size: size,
    );
  });

  Future<void> download(SelfUpdateRelease release, File destination) async {
    if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Update destination already exists.',
        destination.path,
      );
    }
    bool created = false;
    try {
      await _run(_downloadTimeout, (
        HttpClient client,
        _Deadline deadline,
      ) async {
        if (!release.version.isStable ||
            !_archiveSuffixes.any(
              (String suffix) =>
                  release.assetName ==
                  'multiplexor-v${release.version.text}-$suffix',
            ) ||
            !_digestPattern.hasMatch(release.sha256) ||
            release.size <= 0 ||
            release.size > _maxArchiveBytes) {
          throw const FormatException('Invalid compiled update artifact.');
        }
        _validateAssetUrl(
          release.downloadUrl,
          release.version,
          release.assetName,
        );
        final HttpClientResponse response = await _response(
          release.downloadUrl,
          client,
          deadline,
        );
        _checkResponse(response, release.size);
        await destination.create(exclusive: true);
        created = true;
        final RandomAccessFile output = await destination.open(
          mode: FileMode.write,
        );
        final _DigestSink digest = _DigestSink();
        final ByteConversionSink hash = crypto.sha256.startChunkedConversion(
          digest,
        );
        int bytes = 0;
        try {
          await _chunks(response, deadline, (List<int> chunk) async {
            bytes += chunk.length;
            if (bytes > release.size) {
              throw const FormatException(
                'Downloaded update exceeds its declared size.',
              );
            }
            hash.add(chunk);
            await output.writeFrom(chunk);
          });
        } finally {
          hash.close();
          await output.close();
        }
        if (bytes != release.size) {
          throw const FormatException('Downloaded update size does not match.');
        }
        if (digest.value.toString() != release.sha256.toLowerCase()) {
          throw const FormatException(
            'Downloaded update checksum does not match.',
          );
        }
      });
    } catch (_) {
      if (created && destination.existsSync()) await destination.delete();
      rethrow;
    }
  }

  void close() {
    _closed = true;
    for (final HttpClient client in _clients) {
      client.close(force: true);
    }
  }

  Map<String, Object?> _asset(List<Object?> assets, String name) {
    final List<Map<String, Object?>> matches = assets
        .whereType<Map<String, Object?>>()
        .where((Map<String, Object?> asset) => asset['name'] == name)
        .toList();
    if (matches.length != 1 || matches.single['state'] != 'uploaded') {
      throw FormatException(
        'Release asset is missing, incomplete, or duplicated: $name',
      );
    }
    return matches.single;
  }

  int _assetSize(Map<String, Object?> asset, int limit) {
    final Object? size = asset['size'];
    if (size is! int || size <= 0 || size > limit) {
      throw const FormatException('Release asset size is invalid.');
    }
    return size;
  }

  Uri _assetUrl(Map<String, Object?> asset, String tag, String name) {
    final Object? value = asset['browser_download_url'];
    if (value is! String) {
      throw const FormatException('Release asset URL is missing.');
    }
    final Uri uri = Uri.parse(value);
    _validateAssetUrl(uri, UpdateVersion.parse(tag), name);
    return uri;
  }

  void _validateAssetUrl(Uri uri, UpdateVersion version, String name) {
    _validateUrl(uri);
    if (_testingOrigin != null) return;
    final List<String> segments = uri.pathSegments;
    if (uri.host != 'github.com' ||
        uri.hasQuery ||
        segments.length != 6 ||
        segments[0] != 'VolmitSoftware' ||
        segments[1] != 'ServerMultiplexor' ||
        segments[2] != 'releases' ||
        segments[3] != 'download' ||
        UpdateVersion.parse(segments[4]).text != version.text ||
        segments[5] != name) {
      throw const FormatException(
        'Release asset URL does not match its release.',
      );
    }
  }

  void _validateUrl(Uri uri) {
    final bool allowed = _testingOrigin != null
        ? uri.origin == _testingOrigin
        : uri.scheme == 'https' &&
              uri.port == 443 &&
              <String>{
                'api.github.com',
                'github.com',
                'release-assets.githubusercontent.com',
                'objects.githubusercontent.com',
              }.contains(uri.host);
    if (!allowed || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const FormatException('Untrusted update URL or redirect.');
    }
  }

  Future<T> _run<T>(
    Duration timeout,
    Future<T> Function(HttpClient, _Deadline) action,
  ) async {
    if (_closed) throw StateError('Update client is closed.');
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    try {
      return await action(client, _Deadline(timeout));
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<HttpClientResponse> _response(
    Uri uri,
    HttpClient client,
    _Deadline deadline,
  ) async {
    for (int redirects = 0; redirects <= 5; redirects++) {
      _validateUrl(uri);
      final HttpClientRequest request = await deadline.wait(client.getUrl(uri));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Multiplexor-Updater');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final HttpClientResponse response = await deadline.wait(request.close());
      if (!<int>{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final String? location = response.headers.value(
        HttpHeaders.locationHeader,
      );
      await response.listen(null).cancel();
      if (location == null || redirects == 5) {
        throw const HttpException(
          'Update redirect limit reached or location missing.',
        );
      }
      uri = uri.resolve(location);
    }
    throw const HttpException('Update redirect limit reached.');
  }

  Future<Uint8List?> _read(
    Uri uri,
    int limit,
    HttpClient client,
    _Deadline deadline, {
    bool allowNotFound = false,
  }) async {
    final HttpClientResponse response = await _response(uri, client, deadline);
    if (allowNotFound && response.statusCode == HttpStatus.notFound) {
      return null;
    }
    _checkResponse(response, limit);
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await _chunks(response, deadline, (List<int> chunk) async {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Update metadata exceeds the size limit.');
      }
      bytes.add(chunk);
    });
    return bytes.takeBytes();
  }

  void _checkResponse(HttpClientResponse response, int limit) {
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Update request failed (HTTP ${response.statusCode}).',
      );
    }
    if (response.contentLength > limit) {
      throw const FormatException('Update response exceeds the size limit.');
    }
  }

  Future<void> _chunks(
    HttpClientResponse response,
    _Deadline deadline,
    Future<void> Function(List<int>) consume,
  ) async {
    final StreamIterator<List<int>> iterator = StreamIterator<List<int>>(
      response,
    );
    try {
      while (await deadline.wait(iterator.moveNext())) {
        await consume(iterator.current);
      }
    } finally {
      await iterator.cancel();
    }
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

class _Deadline {
  _Deadline(this.timeout) : _watch = Stopwatch()..start();

  final Duration timeout;
  final Stopwatch _watch;

  Future<T> wait<T>(Future<T> operation) {
    final Duration remaining = timeout - _watch.elapsed;
    return operation.timeout(
      remaining > Duration.zero ? remaining : Duration.zero,
    );
  }
}
