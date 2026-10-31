import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late File fixture;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('project-setup-prompt-');
    fixture = File(p.join(scratch.path, 'prompt.dill'));
    ProcessResult result =
        await Process.run(Platform.resolvedExecutable, <String>[
          'compile',
          'kernel',
          'test/support/project_setup_prompt.dart',
          '-o',
          fixture.path,
        ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  Future<({String output, Map<String, Object?> data})> prompt(
    List<String> input, {
    String? failure,
  }) async {
    Process process = await Process.start(Platform.resolvedExecutable, <String>[
      fixture.path,
      ?failure,
    ]);
    Future<String> output = utf8.decoder.bind(process.stdout).join();
    Future<String> errors = utf8.decoder.bind(process.stderr).join();
    process.stdin.writeln(input.join('\n'));
    await process.stdin.close();
    int code = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill();
        throw StateError('Project setup prompt did not finish');
      },
    );
    String text = await output;
    expect(code, 0, reason: '$text\n${await errors}');
    int marker = text.lastIndexOf('RESULT=');
    expect(marker, greaterThanOrEqualTo(0));
    return (
      output: text,
      data: jsonDecode(text.substring(marker + 7)) as Map<String, Object?>,
    );
  }

  test(
    'setup displays proposed files and leaves a declined project unchanged',
    () async {
      final ({String output, Map<String, Object?> data}) result = await prompt(
        <String>['/example/Plugin', 'no'],
      );
      expect(result.data['calls'], <List<String>>[
        <String>['init', '/example/Plugin', '--json'],
      ]);
      expect(result.data['result'], isNull);
      expect(result.output, contains('CONVERT GRADLE PROJECT'));
      expect(
        result.output,
        contains('project root containing gradlew and build.gradle'),
      );
      expect(
        result.output,
        contains('confirm to write them and scan the project'),
      );
      expect(result.output, contains('CONVERSION PREVIEW'));
      expect(result.output, contains('bukkit: plugin (.)'));
      expect(result.output, contains('create: gradle/multiplexor.gradle'));
      expect(result.output, contains('ext.multiplexor = [schemaVersion: 1]'));
      expect(result.output, contains('append: build.gradle'));
      expect(
        result.output,
        contains("apply from: 'gradle/multiplexor.gradle'"),
      );
      expect(
        result.output,
        contains('Review custom packaging before building.'),
      );
    },
  );

  test('confirmed setup applies metadata then requests a scan', () async {
    final ({String output, Map<String, Object?> data}) result = await prompt(
      <String>['/example/Plugin', 'yes'],
    );
    expect(result.data['calls'], <List<String>>[
      <String>['init', '/example/Plugin', '--json'],
      <String>['init', '/example/Plugin', '--json', '--apply'],
    ]);
    expect(result.data['result'], <String>['scan', '/example/Plugin']);
  });

  test('setup confirmation defaults to applying and scanning', () async {
    final ({String output, Map<String, Object?> data}) result = await prompt(
      <String>['/example/Plugin', ''],
    );
    expect(result.data['calls'], <List<String>>[
      <String>['init', '/example/Plugin', '--json'],
      <String>['init', '/example/Plugin', '--json', '--apply'],
    ]);
    expect(result.data['result'], <String>['scan', '/example/Plugin']);
  });

  test('preview failure does not apply or scan', () async {
    final ({String output, Map<String, Object?> data}) result = await prompt(
      <String>['/example/Plugin', ''],
      failure: 'preview-failure',
    );
    expect(result.data['calls'], hasLength(1));
    expect(result.data['result'], isNull);
    expect(result.output, contains('Project setup refused'));
    expect(result.output, isNot(contains('Write this configuration')));
  });

  test('apply failure does not scan', () async {
    final ({String output, Map<String, Object?> data}) result = await prompt(
      <String>['/example/Plugin', 'yes', ''],
      failure: 'apply-failure',
    );
    expect(result.data['calls'], hasLength(2));
    expect(result.data['result'], isNull);
    expect(result.output, contains('Project setup refused'));
  });
}
