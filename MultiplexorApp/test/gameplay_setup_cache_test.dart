import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/storage_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late GameplayTestService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-setup-cache-');
    service = GameplayTestService(
      context: ManagerContext(rootDir: root.path, verbose: false),
    );
    Directory(service.harnessDirectory).createSync(recursive: true);
    File(p.join(service.harnessDirectory, 'package.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'name': 'setup-cache-fixture',
        'version': '1.0.0',
        'private': true,
        'scripts': <String, String>{'postinstall': 'node report.mjs'},
      }),
    );
    File(
      p.join(service.harnessDirectory, 'package-lock.json'),
    ).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'name': 'setup-cache-fixture',
        'version': '1.0.0',
        'lockfileVersion': 3,
        'requires': true,
        'packages': <String, Object?>{
          '': <String, String>{
            'name': 'setup-cache-fixture',
            'version': '1.0.0',
          },
        },
      }),
    );
    File(p.join(service.harnessDirectory, 'report.mjs')).writeAsStringSync(
      "process.stdout.write('cache=' + (process.env.npm_config_cache ?? '') + '\\n')",
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<String> install() async {
    final List<String> output = <String>[];
    final List<String> errors = <String>[];
    expect(
      await service.setup(write: output.add, error: errors.add),
      0,
      reason: errors.join('\n'),
    );
    return output
        .singleWhere((String line) => line.startsWith('cache='))
        .substring('cache='.length);
  }

  test('setup installs through a temporary npm cache it removes', () async {
    final String cache = await install();
    expect(p.basename(cache), startsWith('multiplexor-npm-cache-'));
    expect(
      p.equals(
        Directory(p.dirname(cache)).resolveSymbolicLinksSync(),
        Directory.systemTemp.resolveSymbolicLinksSync(),
      ),
      isTrue,
    );
    expect(Directory(cache).existsSync(), isFalse);
  });

  test('setup keeps the npm cache when downloads are kept', () async {
    StorageSettings(service.context.metadataDir).saveKeepDownloads(true);
    final String cache = await install();
    expect(cache, isNot(contains('multiplexor-npm-cache-')));
  });
}
