import 'dart:io';

import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/long_path.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('instance reset', () {
    late Directory root;
    late String instancesDir;
    late String instancePath;

    NativeCommandService buildService({
      Future<void> Function(String)? resetBackupDeleter,
    }) {
      final ManagerContext context = ManagerContext(
        rootDir: root.path,
        verbose: false,
      );
      return NativeCommandService(
        context: context,
        consumerService: ConsumerService(context),
        resetBackupDeleter: resetBackupDeleter,
      );
    }

    /// A folder under [parent] whose path stays past 260 characters.
    String deepFolder(String parent) {
      String path = parent;
      while (path.length < 320) {
        path = p.join(path, 'net-kyori-adventure-text-minimessage');
      }
      Directory(extendedLengthPath(path)).createSync(recursive: true);
      File(
        extendedLengthPath(p.join(path, 'relocated.bin')),
      ).writeAsStringSync('library');
      return path;
    }

    /// Every entry under the instance, relative path to file contents.
    Map<String, String> snapshot() {
      final String base = extendedLengthPath(instancePath);
      return <String, String>{
        for (final FileSystemEntity entity in Directory(
          base,
        ).listSync(recursive: true, followLinks: false))
          p.relative(entity.path, from: base): entity is File
              ? entity.readAsStringSync()
              : '<directory>',
      };
    }

    List<String> resetBackups() => Directory(instancesDir)
        .listSync()
        .map((FileSystemEntity entity) => p.basename(entity.path))
        .where((String name) => name.contains('.reset-backup.'))
        .toList();

    setUp(() {
      root = Directory.systemTemp.createTempSync('multiplexor-reset-');
      instancesDir = p.join(
        root.path,
        'consumers',
        'plugin-consumers',
        'instances',
      );
      instancePath = p.join(instancesDir, 'qa');
      Directory(p.join(instancePath, 'plugins')).createSync(recursive: true);
      File(
        p.join(instancePath, '.server-source'),
      ).writeAsStringSync('type=paper\nlaunch=jar\nisolated=true\n');
      File(
        p.join(instancePath, 'server.properties'),
      ).writeAsStringSync('server-port=25601\nonline-mode=false\n');
      File(p.join(instancePath, 'paper.jar')).writeAsStringSync('jar');
    });

    tearDown(() {
      if (root.existsSync()) {
        Directory(extendedLengthPath(root.path)).deleteSync(recursive: true);
      }
    });

    test('handles folders past the Windows path limit', () async {
      deepFolder(p.join(instancePath, 'plugins', 'GamemodeSwitcher', '.libs'));
      final String kept = deepFolder(p.join(instancePath, 'libraries'));
      final NativeCommandService service = buildService();

      final result = await service.execute(<String>[
        'instance',
        'reset',
        'qa',
      ], stream: false);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(resetBackups(), isEmpty);
      expect(
        Directory(
          extendedLengthPath(
            p.join(instancePath, 'plugins', 'GamemodeSwitcher'),
          ),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          extendedLengthPath(p.join(kept, 'relocated.bin')),
        ).readAsStringSync(),
        'library',
      );
      expect(File(p.join(instancePath, 'paper.jar')).existsSync(), isTrue);

      final isolated = await service.execute(<String>[
        'instance',
        'isolated',
        'qa',
      ], stream: false);
      expect(isolated.stdout.trim(), 'true');
    });

    test('a failed reset restores every file', () async {
      deepFolder(p.join(instancePath, 'libraries'));
      // Reset creates a plugins folder, so restoring this file fails.
      Directory(p.join(instancePath, 'plugins')).deleteSync();
      File(p.join(instancePath, 'plugins')).writeAsStringSync('in the way');
      final Map<String, String> before = snapshot();
      final NativeCommandService service = buildService();

      final result = await service.execute(<String>[
        'instance',
        'reset',
        'qa',
      ], stream: false);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Failed to reset qa'));
      expect(snapshot(), before);
      expect(resetBackups(), isEmpty);

      final isolated = await service.execute(<String>[
        'instance',
        'isolated',
        'qa',
      ], stream: false);
      expect(isolated.stdout.trim(), 'true');
    });

    test('a failed backup delete keeps the finished reset', () async {
      File(
        p.join(instancePath, 'plugins', 'plugin.jar'),
      ).writeAsStringSync('x');
      final NativeCommandService service = buildService(
        resetBackupDeleter: (String backupPath) async {
          // Same order as the original failure: .server-source goes first.
          File(p.join(backupPath, '.server-source')).deleteSync();
          throw FileSystemException('Directory listing failed', backupPath);
        },
      );

      final result = await service.execute(<String>[
        'instance',
        'reset',
        'qa',
      ], stream: false);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stderr, contains('could not delete its old files'));
      expect(resetBackups(), hasLength(1));
      expect(
        File(p.join(instancePath, 'plugins', 'plugin.jar')).existsSync(),
        isFalse,
      );

      final isolated = await service.execute(<String>[
        'instance',
        'isolated',
        'qa',
      ], stream: false);
      expect(isolated.stdout.trim(), 'true');
    });

    test('an instance with an open file is left untouched', () async {
      final File held = File(p.join(instancePath, 'held.log'))
        ..writeAsStringSync('open');
      final Map<String, String> before = snapshot();
      final RandomAccessFile handle = held.openSync(mode: FileMode.append);
      addTearDown(handle.closeSync);
      final NativeCommandService service = buildService();

      final result = await service.execute(<String>[
        'instance',
        'reset',
        'qa',
      ], stream: false);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('so nothing changed'));
      expect(snapshot(), before);
      expect(resetBackups(), isEmpty);
    }, skip: Platform.isWindows ? false : 'Only Windows locks an open folder');
  });

  group('extendedLengthPath', () {
    test('prefixes local and network paths once', () {
      expect(extendedLengthPath(r'C:\a\b'), r'\\?\C:\a\b');
      expect(extendedLengthPath('C:/a/./b'), r'\\?\C:\a\b');
      expect(extendedLengthPath(r'\\?\C:\a\b'), r'\\?\C:\a\b');
      expect(extendedLengthPath(r'\\host\share\a'), r'\\?\UNC\host\share\a');
    }, skip: Platform.isWindows ? false : 'Windows paths only');

    test(
      'leaves paths unchanged off Windows',
      () => expect(extendedLengthPath('/a/b'), '/a/b'),
      skip: Platform.isWindows ? 'Non-Windows behavior' : false,
    );
  });
}
