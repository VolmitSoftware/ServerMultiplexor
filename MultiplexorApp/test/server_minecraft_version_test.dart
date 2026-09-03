import 'dart:io';

import 'package:multiplexor/models/server_minecraft_version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final (String type, String filename, String expected) fixture
      in <(String, String, String)>[
        ('leaf', 'leaf-26.2-96.jar', '26.2'),
        ('leaf', 'leaf-26.1.2-73.jar', '26.1.2'),
        ('paper', 'paper-1.21.11-127.jar', '1.21.11'),
        (
          'paper',
          'paper-20260215-162758-paper-bundler-1.21.10-abcdef.jar',
          '1.21.10',
        ),
        ('folia', 'folia-1.21.8-12.jar', '1.21.8'),
        ('purpur', 'purpur-1.21.11-2531.jar', '1.21.11'),
        ('canvas', 'canvas-26.2-101.jar', '26.2'),
        ('spigot', 'spigot-1.21.4.jar', '1.21.4'),
        ('spigot', 'spigot-1.21.4-R0.1-SNAPSHOT.jar', '1.21.4'),
        ('forge', 'forge-1.21.4-54.1.0-installer.jar', '1.21.4'),
        ('mohist', 'mohist-1.20.1-923.jar', '1.20.1'),
        ('fabric', 'fabric-26.1.2-loader.0.18.6-installer.1.1.1.jar', '26.1.2'),
        (
          'fabric',
          'fabric-server-mc.1.21.4-loader.0.16.10-launcher.1.0.3.jar',
          '1.21.4',
        ),
        ('paper', 'paper-26.2-pre1-3.jar', '26.2-pre1'),
      ]) {
    test('infers Minecraft from ${fixture.$2}', () {
      expect(
        inferServerMinecraftVersion(
          serverType: fixture.$1,
          jarPaths: <String>[fixture.$2],
        ),
        fixture.$3,
      );
    });
  }

  test('explicit version is authoritative and trimmed', () {
    expect(
      inferServerMinecraftVersion(
        serverType: 'custom',
        minecraft: ' 1.21.11 ',
        jarPaths: <String>['leaf-26.2-96.jar'],
      ),
      '1.21.11',
    );
  });

  for (final (String type, String filename) fixture in <(String, String)>[
    ('neoforge', 'neoforge-21.11.35-installer.jar'),
    ('custom', 'custom-26.2-96.jar'),
    ('custom', 'paper-1.21.4-123.jar'),
    ('leaf', 'server.jar'),
    ('leaf', '${'a' * 64}.jar'),
    ('leaf', 'paper-26.2-96.jar'),
    ('leaf', 'my-leaf-26.2-96.jar'),
    ('leaf', 'leaf-26.2.3.4.jar'),
    ('fabric', 'fabric-loader-0.18.6.jar'),
  ]) {
    test('keeps ${fixture.$1}/${fixture.$2} unknown', () {
      expect(
        inferServerMinecraftVersion(
          serverType: fixture.$1,
          jarPaths: <String>[fixture.$2],
        ),
        isNull,
      );
    });
  }

  test('tries remaining candidate paths after an unversioned path', () {
    expect(
      inferServerMinecraftVersion(
        serverType: 'leaf',
        jarPaths: <String>['server.jar', 'leaf-26.1.2-73.jar'],
      ),
      '26.1.2',
    );
  });

  test(
    'resolves latest.jar and ignores a stale version in a symlink alias',
    () {
      final Directory root = Directory.systemTemp.createTempSync(
        'multiplexor-version-links-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final File actual = File(p.join(root.path, 'leaf-26.2-96.jar'))
        ..writeAsStringSync('server');
      for (final String alias in <String>['latest.jar', 'leaf-26.1.2-73.jar']) {
        final Link link = Link(p.join(root.path, alias))
          ..createSync(actual.path);
        expect(
          inferServerMinecraftVersion(
            serverType: 'leaf',
            jarPaths: <String>[link.path],
          ),
          '26.2',
        );
      }
    },
    skip: Platform.isWindows ? 'Requires symlink creation privileges.' : false,
  );
}
