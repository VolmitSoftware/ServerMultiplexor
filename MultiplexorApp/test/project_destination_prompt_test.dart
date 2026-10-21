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

  test(
    'locations lists saved filters and Back leaves configuration untouched',
    () async {
      _PromptResult result = await _prompt('locations', <String>['3']);
      expect(result.output, contains('exports'));
      expect(result.output, contains('/tmp/example-exports'));
      expect(result.output, contains('plugin / Minecraft 26.3'));
      expect(result.data['result'], isNull);
      expect(result.data['calls'], isEmpty);
    },
  );

  test(
    'editing preserves defaults and does not prompt for a different name',
    () async {
      _PromptResult result = await _prompt('locations', <String>[
        '1',
        '1',
        '1',
        '',
        '2',
        '2',
        '',
      ]);
      expect(result.data['result'], <String>[
        'destination',
        'exports',
        '--path',
        '/tmp/example-exports',
        '--platform',
        'plugin',
        '--mc',
        '26.3',
      ]);
      expect(result.output, isNot(contains('Destination name:')));
      expect(result.data['calls'], isEmpty);
    },
  );

  test(
    'editing allows clearing optional platform and version filters',
    () async {
      _PromptResult result = await _prompt('locations', <String>[
        '1',
        '1',
        '1',
        '',
        '1',
        '1',
      ]);
      expect(result.data['result'], <String>[
        'destination',
        'exports',
        '--path',
        '/tmp/example-exports',
      ]);
    },
  );

  test(
    'removal requires explicit confirmation and requests only configuration removal',
    () async {
      _PromptResult declined = await _prompt('locations', <String>[
        '1',
        '3',
        '',
        '4',
        '3',
      ]);
      expect(declined.data['result'], isNull);
      expect(declined.data['calls'], isEmpty);
      _PromptResult confirmed = await _prompt('locations', <String>[
        '1',
        '3',
        'yes',
      ]);
      expect(confirmed.data['result'], <String>[
        'destination',
        'exports',
        '--remove',
      ]);
      expect(confirmed.data['calls'], isEmpty);
      expect(
        confirmed.output,
        contains('Files at the destination stay unchanged.'),
      );
    },
  );

  test(
    'delivery chooses a saved destination and remains a preview until confirmed',
    () async {
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
      expect(confirmed.output, isNot(contains('Destination name:')));
    },
  );

  test('preview from an existing location uses that destination', () async {
    _PromptResult result = await _prompt('locations', <String>[
      '1',
      '2',
      'no',
      '4',
      '3',
    ]);
    expect(result.data['calls'], <List<String>>[
      <String>['deploy', 'run-one', '--to', 'exports', '--preview'],
    ]);
    expect(result.data['result'], isNull);
  });

  test(
    'nested location Back and Escape return to their immediate parent',
    () async {
      for (List<String> input in <List<String>>[
        <String>['1', '4', '3'],
        <String>['1', 'esc', '3'],
        <String>['1', '1', 'esc', '4', '3'],
        <String>['2', 'new-place', 'esc', '3'],
      ]) {
        _PromptResult result = await _prompt('locations', input);
        expect(result.data['result'], isNull);
        expect(result.data['calls'], isEmpty);
        expect(RegExp(r'\? Locations').allMatches(result.output), hasLength(2));
        if (input.length == 5) {
          expect(RegExp(r'\? exports').allMatches(result.output), hasLength(2));
        }
      }
    },
  );

  test(
    'Escape from adding a delivery destination returns to destination selection',
    () async {
      _PromptResult result = await _prompt('deploy', <String>[
        '2',
        'new-place',
        'esc',
        '3',
      ]);
      expect(result.data['result'], isNull);
      expect(result.data['calls'], isEmpty);
      expect(RegExp(r'\? Deliver to').allMatches(result.output), hasLength(2));
    },
  );

  test('q returns from destination menus without a command', () async {
    for (String action in <String>['locations', 'deploy']) {
      _PromptResult result = await _prompt(action, <String>['q']);
      expect(result.data['result'], isNull);
      expect(result.data['calls'], isEmpty);
    }
    _PromptResult nested = await _prompt('locations', <String>['1', 'q', 'q']);
    expect(nested.data['result'], isNull);
    expect(nested.data['calls'], isEmpty);
    expect(RegExp(r'\? Locations').allMatches(nested.output), hasLength(2));
  });

  test('destination choice Back discards the form at every choice', () async {
    List<({List<String> input, String back, String title})> choices =
        <({List<String> input, String back, String title})>[
          (input: <String>[], back: '4', title: 'Destination kind'),
          (
            input: <String>['1', '/tmp/new-exports'],
            back: '8',
            title: 'Accept artifacts for',
          ),
          (
            input: <String>['1', '/tmp/new-exports', '1'],
            back: '3',
            title: 'Minecraft compatibility',
          ),
        ];
    for (({List<String> input, String back, String title}) choice in choices) {
      for (String back in <String>[choice.back, 'q', 'esc']) {
        _PromptResult result = await _prompt('locations', <String>[
          '2',
          'new-place',
          ...choice.input,
          back,
          'q',
        ]);
        expect(result.output, contains('? ${choice.title}'));
        expect(result.output, contains('${choice.back}) Back'));
        expect(result.data['result'], isNull);
        expect(result.data['calls'], isEmpty);
        expect(RegExp(r'\? Locations').allMatches(result.output), hasLength(2));
      }
      _PromptResult edit = await _prompt('locations', <String>[
        '1',
        '1',
        ...choice.input,
        choice.back,
        'q',
        'q',
      ]);
      expect(edit.data['result'], isNull);
      expect(edit.data['calls'], isEmpty);
      expect(RegExp(r'\? exports').allMatches(edit.output), hasLength(2));
      _PromptResult delivery = await _prompt('deploy', <String>[
        '2',
        'new-place',
        ...choice.input,
        choice.back,
        'q',
      ]);
      expect(delivery.data['result'], isNull);
      expect(delivery.data['calls'], isEmpty);
      expect(
        RegExp(r'\? Deliver to').allMatches(delivery.output),
        hasLength(2),
      );
    }
  });

  test('q remains ordinary text in destination fields', () async {
    _PromptResult result = await _prompt('locations', <String>[
      '2',
      'q',
      '1',
      'q',
      '1',
      '1',
    ]);
    expect(result.data['result'], <String>['destination', 'q', '--path', 'q']);
    expect(result.data['calls'], isEmpty);
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

  test(
    'empty destination menus support Back and adding without automatic delivery',
    () async {
      for (String action in <String>['locations', 'deploy']) {
        _PromptResult back = await _prompt(
          action,
          <String>['2'],
          options: <String>['empty'],
        );
        expect(back.data['result'], isNull);
        expect(back.data['calls'], isEmpty);
      }
      _PromptResult added = await _prompt(
        'deploy',
        <String>['1', 'export-new', '1', '/tmp/new-exports', '1', '1'],
        options: <String>['empty'],
      );
      expect(added.data['result'], <String>[
        'destination',
        'export-new',
        '--path',
        '/tmp/new-exports',
      ]);
      expect(added.data['calls'], isEmpty);
    },
  );
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
