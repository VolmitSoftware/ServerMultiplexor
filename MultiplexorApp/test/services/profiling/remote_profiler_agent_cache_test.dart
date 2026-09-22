import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:multiplexor/services/profiling/remote_profiler_agent_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profiler-agent-test-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('verified agent installs once and reuses cache without network', () async {
    final Archive archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'jprofiler16/bin/linux-x64/libjprofilerti.so',
          'agent',
        ),
      );
    final Uint8List bytes = Uint8List.fromList(
      GZipEncoder().encode(TarEncoder().encode(archive)),
    );
    int requests = 0;
    final RemoteProfilerAgentCache cache = RemoteProfilerAgentCache(
      directory.path,
      download: (Uri uri) async {
        requests++;
        if (uri.path.endsWith('.txt')) {
          return Uint8List.fromList(
            utf8.encode(
              '${sha256.convert(bytes)} *jprofiler_agent_linux-x86_16_2.tar.gz\n',
            ),
          );
        }
        return bytes;
      },
    );
    final String installed = await cache.resolve(architecture: 'x86_64');
    expect(
      await File(
        p.join(installed, 'bin/linux-x64/libjprofilerti.so'),
      ).readAsString(),
      'agent',
    );
    expect(await cache.resolve(architecture: 'amd64'), installed);
    expect(requests, 2);
  });

  test('checksum mismatch does not install executable bytes', () async {
    final RemoteProfilerAgentCache cache = RemoteProfilerAgentCache(
      directory.path,
      download: (Uri uri) async => Uint8List.fromList(
        utf8.encode(
          uri.path.endsWith('.txt')
              ? '${'0' * 64} *jprofiler_agent_linux-x86_16_2.tar.gz\n'
              : 'unverified',
        ),
      ),
    );
    await expectLater(cache.resolve(architecture: 'x86_64'), throwsStateError);
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.so')),
      isEmpty,
    );
  });

  test('archive traversal and symlinks are rejected', () async {
    for (final ArchiveFile entry in <ArchiveFile>[
      ArchiveFile.string('jprofiler16/../../outside', 'bad'),
      ArchiveFile.symlink('jprofiler16/link', '/etc/passwd'),
    ]) {
      final Archive archive = Archive()..addFile(entry);
      final Uint8List bytes = Uint8List.fromList(
        GZipEncoder().encode(TarEncoder().encode(archive)),
      );
      await expectLater(
        RemoteProfilerAgentCache.extract(bytes, directory),
        throwsFormatException,
      );
    }
  });

  test('unsupported version and architecture fail before networking', () async {
    final RemoteProfilerAgentCache cache = RemoteProfilerAgentCache(
      directory.path,
      download: (Uri uri) async => throw StateError('Unexpected request'),
    );
    await expectLater(
      cache.resolve(architecture: 'x86_64', version: '../../x'),
      throwsArgumentError,
    );
    await expectLater(
      cache.resolve(architecture: 'unknown'),
      throwsUnsupportedError,
    );
  });
}
