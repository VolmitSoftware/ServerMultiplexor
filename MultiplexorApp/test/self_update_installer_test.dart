import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:multiplexor/services/self_update_installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File target;
  const String script = '#!/bin/sh\nprintf "Multiplexor CLI v0.3.0\\n"\n';
  const String previousScript =
      '#!/bin/sh\nprintf "Multiplexor CLI v0.2.0\\n"\n';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('multiplexor update [test] ');
    target = File(p.join(root.path, 'installed executable'));
    await target.writeAsString(previousScript);
    if (!Platform.isWindows) {
      final ProcessResult mode = await Process.run('/bin/chmod', <String>[
        '0755',
        target.path,
      ]);
      expect(mode.exitCode, 0);
    }
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> archive(List<ArchiveFile> entries, String format) async {
    final Archive contents = Archive();
    for (final ArchiveFile entry in entries) {
      contents.add(entry);
    }
    final File file = File(p.join(root.path, 'update.$format'));
    await file.writeAsBytes(
      format == 'zip'
          ? ZipEncoder().encodeBytes(contents)
          : gzip.encode(TarEncoder().encodeBytes(contents)),
    );
    return file;
  }

  Future<bool> install(
    File file, {
    String version = '0.3.0',
    String currentVersion = '0.2.0',
  }) => installSelfUpdate(
    archive: file,
    currentVersion: currentVersion,
    version: version,
    executableName: 'multiplexor',
    targetPath: target.path,
    restartArguments: <String>['version'],
    workingDirectory: root.path,
  );

  Future<void> unchanged() async {
    expect(await target.readAsString(), previousScript);
    expect(
      await root
          .list()
          .where((FileSystemEntity entry) => entry is Directory)
          .toList(),
      isEmpty,
    );
  }

  for (final String format in <String>['tar.gz', 'zip']) {
    test(
      'installs the single verified executable from $format',
      () async {
        final File payload = await archive(<ArchiveFile>[
          ArchiveFile.string('multiplexor', script),
        ], format);
        final File settings = File(p.join(root.path, 'settings.env'));
        await settings.writeAsString('preserved settings');
        expect(await install(payload), isFalse);
        expect(await target.readAsString(), script);
        expect((await target.stat()).mode & 0x1ff, 0x1ed);
        expect(await settings.readAsString(), 'preserved settings');
        expect(
          await root
              .list()
              .where((FileSystemEntity entry) => entry is Directory)
              .toList(),
          isEmpty,
        );
      },
      skip: Platform.isWindows
          ? 'Compiled Windows replacement is covered by the process test.'
          : false,
    );

    for (final String name in <String>[
      '../multiplexor',
      '/multiplexor',
      r'..\multiplexor',
      'unexpected',
    ]) {
      test(
        'rejects $format entry $name without replacing the target',
        () async {
          final File payload = await archive(<ArchiveFile>[
            ArchiveFile.string(name, script),
          ], format);
          await expectLater(install(payload), throwsFormatException);
          await unchanged();
        },
      );
    }

    test('rejects a $format symlink', () async {
      final File payload = await archive(<ArchiveFile>[
        if (format == 'zip')
          ArchiveFile.string('multiplexor', '../existing')..mode = 0xa1ff
        else
          ArchiveFile.symlink('multiplexor', '../existing'),
      ], format);
      await expectLater(install(payload), throwsFormatException);
      await unchanged();
    });

    test('rejects extra $format entries', () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string('multiplexor', script),
        ArchiveFile.string('extra', 'unexpected'),
      ], format);
      await expectLater(install(payload), throwsFormatException);
      await unchanged();
    });

    test('rejects empty $format archives', () async {
      await expectLater(
        install(await archive(<ArchiveFile>[], format)),
        throwsFormatException,
      );
      await unchanged();
    });

    test('rejects $format directories', () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.directory('multiplexor'),
      ], format);
      await expectLater(install(payload), throwsFormatException);
      await unchanged();
    });
  }

  test(
    'installs the exact archive format produced by system tar',
    () async {
      final File executable = File(p.join(root.path, 'multiplexor'));
      await executable.writeAsString(script);
      final File payload = File(p.join(root.path, 'system.tar.gz'));
      final ProcessResult result = await Process.run(
        'tar',
        <String>[
          '--format=ustar',
          '--no-xattrs',
          '-czf',
          payload.path,
          '-C',
          root.path,
          'multiplexor',
        ],
        environment: <String, String>{'COPYFILE_DISABLE': '1'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await install(payload), isFalse);
      expect(await target.readAsString(), script);
    },
    skip: Platform.isWindows,
  );

  test(
    'rejects an incorrect version before replacing the executable',
    () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string('multiplexor', script),
      ], 'tar.gz');
      await expectLater(install(payload, version: '0.4.0'), throwsStateError);
      await unchanged();
    },
    skip: Platform.isWindows,
  );

  test(
    'an older running process cannot replace a newer installed executable',
    () async {
      final String newerScript = script.replaceAll('0.3.0', '0.4.0');
      await target.writeAsString(newerScript);
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string('multiplexor', script),
      ], 'tar.gz');
      await expectLater(install(payload), throwsStateError);
      expect(await target.readAsString(), newerScript);
    },
    skip: Platform.isWindows,
  );

  for (final String version in <String>['0.1.0', '0.2.0', '0.2.0+rebuilt']) {
    test(
      'refuses candidate $version at or below the current version',
      () async {
        final File payload = await archive(<ArchiveFile>[
          ArchiveFile.string('multiplexor', script),
        ], 'tar.gz');
        await expectLater(install(payload, version: version), throwsStateError);
        await unchanged();
      },
    );
  }

  test(
    'requires the exact first version line and successful exit',
    () async {
      for (final String contents in <String>[
        '#!/bin/sh\nprintf "warning\\nMultiplexor CLI v0.3.0\\n"\n',
        '#!/bin/sh\nprintf "Multiplexor CLI v0.3.0\\n"\nexit 1\n',
        '#!/bin/sh\nprintf "Multiplexor CLI v0.3.0 extra\\n"\n',
      ]) {
        final File payload = await archive(<ArchiveFile>[
          ArchiveFile.string('multiplexor', contents),
        ], 'tar.gz');
        await expectLater(install(payload), throwsStateError);
        await unchanged();
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'kills an unresponsive version check and keeps the original',
    () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string('multiplexor', '#!/bin/sh\nexec sleep 60\n'),
      ], 'tar.gz');
      await expectLater(install(payload), throwsStateError);
      await unchanged();
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('caps version command output', () async {
    final File payload = await archive(<ArchiveFile>[
      ArchiveFile.string('multiplexor', '#!/bin/sh\nexec yes output\n'),
    ], 'tar.gz');
    await expectLater(install(payload), throwsStateError);
    await unchanged();
  }, skip: Platform.isWindows);

  test(
    'rejects changed target during candidate verification',
    () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string(
          'multiplexor',
          '#!/bin/sh\nprintf changed > ../"installed executable"\nprintf "Multiplexor CLI v0.3.0\\n"\n',
        ),
      ], 'tar.gz');
      await expectLater(install(payload), throwsStateError);
      expect(await target.readAsString(), 'changed');
    },
    skip: Platform.isWindows,
  );

  test(
    'keeps the old executable if the staged file disappears',
    () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string(
          'multiplexor',
          '#!/bin/sh\nrm -- "\$0"\nprintf "Multiplexor CLI v0.3.0\\n"\n',
        ),
      ], 'tar.gz');
      await expectLater(install(payload), throwsA(isA<FileSystemException>()));
      await unchanged();
    },
    skip: Platform.isWindows,
  );

  test('serializes two updates in the same process', () async {
    final File validating = File(p.join(root.path, 'validating'));
    final File payload = await archive(<ArchiveFile>[
      ArchiveFile.string(
        'multiplexor',
        '#!/bin/sh\ntouch ../validating\nsleep 1\nprintf "Multiplexor CLI v0.3.0\\n"\n',
      ),
    ], 'tar.gz');
    final Future<bool> first = install(payload);
    final Stopwatch timer = Stopwatch()..start();
    while (!await validating.exists()) {
      if (timer.elapsed > const Duration(seconds: 5)) {
        fail('The first updater did not reach candidate verification.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await expectLater(install(payload), throwsStateError);
    expect(await first, isFalse);
  }, skip: Platform.isWindows);

  test('rejects oversized compressed archives without reading them', () async {
    final File payload = File(p.join(root.path, 'oversized.zip'));
    final RandomAccessFile file = await payload.open(mode: FileMode.write);
    await file.truncate(128 * 1024 * 1024 + 1);
    await file.close();
    await expectLater(install(payload), throwsFormatException);
    await unchanged();
  });

  test('rejects oversized advertised tar content before execution', () async {
    final Uint8List tar = TarEncoder().encodeBytes(
      Archive()..add(ArchiveFile.string('multiplexor', script)),
    );
    tar.setRange(124, 136, ascii.encode('01000000001\u0000'));
    tar.fillRange(148, 156, 32);
    final int checksum = tar.sublist(0, 512).fold(0, (int a, int b) => a + b);
    tar.setRange(
      148,
      156,
      ascii.encode('${checksum.toRadixString(8).padLeft(6, '0')}\u0000 '),
    );
    final File payload = File(p.join(root.path, 'large.tar.gz'));
    await payload.writeAsBytes(gzip.encode(tar));
    await expectLater(install(payload), throwsFormatException);
    await unchanged();
  });

  test(
    'checks actual zip expansion even if the advertised size is small',
    () async {
      final File payload = await archive(<ArchiveFile>[
        ArchiveFile.string('multiplexor', script),
      ], 'zip');
      final Uint8List bytes = await payload.readAsBytes();
      final ByteData data = ByteData.sublistView(bytes);
      data.setUint32(22, 1, Endian.little);
      final int end = bytes.length - 22;
      final int central = data.getUint32(end + 16, Endian.little);
      data.setUint32(central + 24, 1, Endian.little);
      await payload.writeAsBytes(bytes);
      await expectLater(install(payload), throwsFormatException);
      await unchanged();
    },
  );

  test('checks zip content CRC independently of executable output', () async {
    final File payload = await archive(<ArchiveFile>[
      ArchiveFile.string('multiplexor', script),
    ], 'zip');
    final Uint8List bytes = await payload.readAsBytes();
    final ByteData data = ByteData.sublistView(bytes);
    data.setUint32(14, 0, Endian.little);
    final int end = bytes.length - 22;
    final int central = data.getUint32(end + 16, Endian.little);
    data.setUint32(central + 16, 0, Endian.little);
    await payload.writeAsBytes(bytes);
    await expectLater(install(payload), throwsFormatException);
    await unchanged();
  });

  test('ordinary helper dispatch has no workspace side effects', () async {
    expect(await runSelfUpdateHelper(<String>['version']), isNull);
    expect(await runSelfUpdateHelper(<String>[]), isNull);
    expect((await root.list().toList()).length, 1);
  });
}
