import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory _scratch;
late File _fixture;

void main() {
  setUpAll(() async {
    _scratch = Directory.systemTemp.createTempSync('destination-prompts-');
    _fixture = File(p.join(_scratch.path, 'prompt.dill'));
    ProcessResult result =
        await Process.run(Platform.resolvedExecutable, <String>[
          'compile',
          'kernel',
          'test/support/project_destination_prompt.dart',
          '-o',
          _fixture.path,
        ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  tearDownAll(() {
    if (_scratch.existsSync()) _scratch.deleteSync(recursive: true);
  });

  test('delivery remains a preview until confirmed', () async {
    _PromptResult declined = await _prompt('deploy', <String>['1', 'no']);
    expect(declined.data['calls'], <List<String>>[
      <String>['deploy', 'run-one', '--to', 'exports', '--preview'],
    ]);
    expect(declined.data['result'], isNull);
    _PromptResult confirmed = await _prompt('deploy', <String>['1', 'yes']);
    expect(confirmed.data['result'], <String>[
      'deploy',
      'run-one',
      '--to',
      'exports',
    ]);
    expect(confirmed.data['calls'], declined.data['calls']);
  });

  test('delivery Back and Escape leave destinations unchanged', () async {
    for (String key in <String>['q', 'esc', '3']) {
      _PromptResult result = await _prompt('deploy', <String>[key]);
      expect(result.data['result'], isNull);
      expect(result.data['calls'], isEmpty);
    }
  });

  test('failed preview cannot return a deploy command', () async {
    _PromptResult result = await _prompt(
      'deploy',
      <String>['1'],
      options: <String>['failed-preview'],
    );
    expect(result.data['calls'], hasLength(1));
    expect(result.data['result'], isNull);
    expect(result.output, isNot(contains('Deliver these artifacts?')));
  });

  test('empty delivery selection can return without changes', () async {
    _PromptResult result = await _prompt(
      'deploy',
      <String>['2'],
      options: <String>['empty'],
    );
    expect(result.data['result'], isNull);
    expect(result.data['calls'], isEmpty);
  });
}

Future<_PromptResult> _prompt(
  String action,
  List<String> input, {
  List<String> options = const <String>[],
}) async {
  Map<String, String> environment = Map<String, String>.from(
    Platform.environment,
  )..remove('GIT_CONFIG_COUNT');
  Process process = await Process.start(
    Platform.resolvedExecutable,
    <String>[_fixture.path, action, ...options],
    environment: environment,
    includeParentEnvironment: false,
  );
  Future<String> output = utf8.decoder.bind(process.stdout).join();
  Future<String> errors = utf8.decoder.bind(process.stderr).join();
  process.stdin.writeln(input.join('\n'));
  await process.stdin.close();
  int code = await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      throw StateError('Destination prompt did not finish');
    },
  );
  String result = await output;
  expect(code, 0, reason: '$result\n${await errors}');
  int marker = result.lastIndexOf('RESULT=');
  expect(marker, greaterThanOrEqualTo(0));
  return _PromptResult(
    result,
    Map<String, Object?>.from(
      jsonDecode(result.substring(marker + 7)) as Map<String, Object?>,
    ),
  );
}

class _PromptResult {
  const _PromptResult(this.output, this.data);

  final String output;
  final Map<String, Object?> data;
}
