import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-cli-test-');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    <String>['run', 'bin/main.dart', '--root', root.path, ...args],
    environment: <String, String>{
      'JVM_ARGS': '',
      'JVM_PROFILE': '',
      'HEAP_SIZE': '',
      'JAVA_EXECUTABLE': '',
    },
  );

  test(
    'positional clone reaches the same implementation as named clone',
    () async {
      final ProcessResult create = await run(<String>[
        'instance',
        'create',
        'source',
        '--isolated',
      ]);
      expect(create.exitCode, 0, reason: '${create.stderr}');
      final String instances = p.join(
        root.path,
        'consumers',
        'plugin-consumers',
        'instances',
      );
      File(
        p.join(instances, 'source', 'marker.txt'),
      ).writeAsStringSync('source contents');
      for (final List<String> args in <List<String>>[
        <String>['source', 'positional'],
        <String>['--source', 'source', '--target', 'named'],
      ]) {
        final ProcessResult clone = await run(<String>[
          'instance',
          'clone',
          ...args,
        ]);
        expect(clone.exitCode, 0, reason: '${clone.stderr}');
      }
      expect(
        File(p.join(instances, 'positional', 'marker.txt')).readAsStringSync(),
        'source contents',
      );
      expect(
        File(p.join(instances, 'named', 'marker.txt')).readAsStringSync(),
        'source contents',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'invalid options exit 2 and cannot create an instance',
    () async {
      for (final List<String> args in <List<String>>[
        <String>['instance', 'create', 'typo', '--isolate'],
        <String>['server', 'create', 'missing', '--mc'],
      ]) {
        final ProcessResult result = await run(args);
        expect(
          result.exitCode,
          2,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stderr, contains('[ERROR]'));
      }
      final Directory instances = Directory(
        p.join(root.path, 'consumers', 'plugin-consumers', 'instances'),
      );
      expect(instances.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'per-instance runtime tuning survives executable dispatch',
    () async {
      expect(
        (await run(<String>[
          'instance',
          'create',
          'demo',
          '--isolated',
        ])).exitCode,
        0,
      );
      final ProcessResult set = await run(<String>[
        'runtime',
        'settings',
        'set-heap',
        '6G',
        '--instance=demo',
      ]);
      expect(set.exitCode, 0, reason: '${set.stderr}');
      final ProcessResult show = await run(<String>[
        'runtime',
        'settings',
        'show',
        '--instance',
        'demo',
      ]);
      expect(show.exitCode, 0, reason: '${show.stderr}');
      expect(show.stdout, contains('6G'));
      expect(show.stdout, contains('demo'));
      final ProcessResult defaults = await run(<String>[
        'runtime',
        'settings',
        'show',
      ]);
      expect(defaults.exitCode, 0, reason: '${defaults.stderr}');
      expect(defaults.stdout, contains('4G'));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
