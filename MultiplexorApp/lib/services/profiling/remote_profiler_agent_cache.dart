import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

typedef ProfilerAgentDownload = Future<Uint8List> Function(Uri uri);

final class RemoteProfilerAgentCache {
  RemoteProfilerAgentCache(
    String metadataDirectoryPath, {
    ProfilerAgentDownload? download,
  }) : directory = Directory(p.join(metadataDirectoryPath, 'profiler-agents')),
       _download = download ?? _downloadOfficial;

  static const String defaultVersion = '16.2';
  final Directory directory;
  final ProfilerAgentDownload _download;

  Future<String> resolve({
    required String architecture,
    String version = defaultVersion,
  }) async {
    if (!RegExp(r'^16\.[0-9]+(?:\.[0-9]+)?$').hasMatch(version)) {
      throw ArgumentError('JProfiler agent version must be a 16.x release.');
    }
    final String platform = switch (architecture.toLowerCase()) {
      'amd64' || 'x86_64' || 'x64' => 'linux-x86',
      'aarch64' || 'arm64' => 'linux-arm',
      _ => throw UnsupportedError(
        'Unsupported Linux architecture: $architecture',
      ),
    };
    final String nativePlatform = platform == 'linux-x86'
        ? 'linux-x64'
        : 'linux-arm64';
    final String tag = version.replaceAll('.', '_');
    final String archiveName = 'jprofiler_agent_${platform}_$tag.tar.gz';
    final Directory target = Directory(
      p.join(directory.path, '$platform-$version'),
    );
    final Directory bundle = Directory(p.join(target.path, 'jprofiler16'));
    final File marker = File(p.join(target.path, 'verified.sha256'));
    final File library = File(
      p.join(bundle.path, 'bin', nativePlatform, 'libjprofilerti.so'),
    );
    await directory.create(recursive: true);
    final RandomAccessFile lock = await File(
      '${target.path}.lock',
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      if (await marker.exists() && await library.exists()) {
        return bundle.path;
      }
      final String checksums = utf8.decode(
        await _download(
          Uri.https(
            'download.ej-technologies.com',
            '/jprofiler/sha256sums_$tag.txt',
          ),
        ),
      );
      final String? expected = checksumFor(checksums, archiveName);
      if (expected == null) {
        throw StateError('No published SHA-256 checksum for $archiveName.');
      }
      final Uint8List bytes = await _download(
        Uri.https('download.ej-technologies.com', '/jprofiler/$archiveName'),
      );
      if (sha256.convert(bytes).toString() != expected) {
        throw StateError('JProfiler agent download checksum does not match.');
      }
      final Directory temporary = await directory.createTemp('extract-');
      try {
        await extract(bytes, temporary);
        final File extracted = File(
          p.join(
            temporary.path,
            'jprofiler16',
            'bin',
            nativePlatform,
            'libjprofilerti.so',
          ),
        );
        if (!await extracted.exists() || await extracted.length() == 0) {
          throw const FormatException(
            'JProfiler archive is missing the native agent.',
          );
        }
        await File(
          p.join(temporary.path, 'verified.sha256'),
        ).writeAsString(expected, flush: true);
        if (await target.exists()) await target.delete(recursive: true);
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
      return bundle.path;
    } finally {
      await lock.close();
    }
  }

  static String? checksumFor(String manifest, String filename) {
    for (final String line in const LineSplitter().convert(manifest)) {
      final RegExpMatch? match = RegExp(
        r'^([a-fA-F0-9]{64})\s+\*?(.+)$',
      ).firstMatch(line.trim());
      if (match != null && match.group(2) == filename) {
        return match.group(1)!.toLowerCase();
      }
    }
    return null;
  }

  static Future<void> extract(Uint8List compressed, Directory target) async {
    final Archive archive = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(compressed),
    );
    final Set<String> paths = <String>{};
    int totalBytes = 0;
    for (final ArchiveFile entry in archive) {
      final String name = entry.name;
      final String path = p.join(target.path, p.fromUri(Uri(path: name)));
      totalBytes += entry.size;
      if (entry.isSymbolicLink ||
          name.contains('\\') ||
          name.startsWith('/') ||
          name.split('/').contains('..') ||
          !name.startsWith('jprofiler16/') ||
          !p.isWithin(target.path, path) ||
          !paths.add(p.normalize(path)) ||
          totalBytes > 128 * 1024 * 1024) {
        throw const FormatException(
          'Unsafe or oversized JProfiler agent archive.',
        );
      }
      if (!entry.isFile) {
        await Directory(path).create(recursive: true);
        continue;
      }
      final File file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.content);
      if (!Platform.isWindows && (entry.unixPermissions & 0x49) != 0) {
        final ProcessResult result = await Process.run('chmod', <String>[
          '755',
          path,
        ]);
        if (result.exitCode != 0) {
          throw StateError('Unable to set agent executable permissions.');
        }
      }
    }
  }

  static Future<Uint8List> _downloadOfficial(Uri uri) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      request.followRedirects = false;
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'JProfiler download returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(
        const Duration(seconds: 30),
      )) {
        if (bytes.length + chunk.length > 32 * 1024 * 1024) {
          throw const FormatException(
            'JProfiler download exceeds the size limit.',
          );
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
