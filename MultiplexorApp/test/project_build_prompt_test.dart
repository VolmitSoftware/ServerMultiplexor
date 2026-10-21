import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late File fixture;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('build-prompts-');
    fixture = File(p.join(scratch.path, 'prompt.dill'));
    ProcessResult result =
        await Process.run(Platform.resolvedExecutable, <String>[
          'compile',
          'kernel',
          'test/support/project_build_prompt.dart',
          '-o',
          fixture.path,
        ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  Future<List<Object?>?> prompt(String action, List<String> input) async {
    Process process = await Process.start(Platform.resolvedExecutable, <String>[
      fixture.path,
      action,
    ]);
    Future<String> output = utf8.decoder.bind(process.stdout).join();
    Future<String> errors = utf8.decoder.bind(process.stderr).join();
    process.stdin.writeln(input.join('\n'));
    await process.stdin.close();
    int code = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill();
        throw StateError('Build prompt did not finish');
      },
    );
    String text = await output;
    expect(code, 0, reason: '$text\n${await errors}');
    int marker = text.lastIndexOf('RESULT=');
    expect(marker, greaterThanOrEqualTo(0));
    return jsonDecode(text.substring(marker + 7)) as List<Object?>?;
  }

  test(
    'checked targets default to verified reuse and local packaging',
    () async {
      expect(await prompt('build', <String>['1']), <String>[
        'build',
        '--targets',
        'wormholes:bukkit,wormholes:fabric',
        '--changed',
        '--packaging',
        'local',
        '--jobs',
        '3',
        '--memory',
        '16384',
        '--workers',
        '6',
      ]);
    },
  );

  test('packaging and reuse toggles retain the checked scope', () async {
    expect(await prompt('build', <String>['5', '6', '1']), <String>[
      'build',
      '--targets',
      'wormholes:bukkit,wormholes:fabric',
      '--packaging',
      'compact',
      '--jobs',
      '3',
      '--memory',
      '16384',
      '--workers',
      '6',
    ]);
  });

  test('Back from limits returns to the build menu', () async {
    List<Object?>? result = await prompt('build', <String>['7', '5', '1']);
    expect(result, isNotNull);
    expect(result!.take(3), <String>[
      'build',
      '--targets',
      'wormholes:bukkit,wormholes:fabric',
    ]);
  });

  test('Back from build returns to the actions menu', () async {
    List<Object?>? result = await prompt('actions', <String>[
      '1',
      '8',
      'p',
      '4',
    ]);
    expect(result, <String>[
      'limits',
      '--jobs',
      '3',
      '--memory',
      '16384',
      '--workers',
      '6',
    ]);
  });

  test('q returns from each Projects menu without dispatching', () async {
    for (String action in <String>['actions', 'build', 'limits', 'history']) {
      expect(await prompt(action, <String>['q']), isNull, reason: action);
    }
  });

  test('q returns one level and discards unsaved limits', () async {
    expect(
      await prompt('actions', <String>['1', 'q', 'p', '1', '7', 'q', 'p', '4']),
      <String>['limits', '--jobs', '3', '--memory', '16384', '--workers', '6'],
    );
  });

  test('q remains ordinary text in source folder input', () async {
    expect(await prompt('scan', <String>['q']), <String>['scan', 'q']);
  });

  test('Back from build dispatches nothing', () async {
    expect(await prompt('build', <String>['8']), isNull);
  });
}
