import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File log;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('project-process-');
    log = File(p.join(directory.path, 'command.log'));
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('captures output and removes completed process ownership', () async {
    ProjectProcessResult result = await runProjectProcess(
      executable: '/bin/sh',
      arguments: <String>['-c', 'echo output; echo error >&2; exit 7'],
      directory: directory.path,
      log: log,
    );
    expect(result.exitCode, 7);
    expect(result.lines, containsAll(<String>['output', 'error']));
    expect(File('${log.path}.process.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('pre-cancelled command never starts', () async {
    ProjectProcessResult result = await runProjectProcess(
      executable: 'does-not-exist',
      arguments: const <String>[],
      directory: directory.path,
      log: log,
      cancelled: () => true,
    );
    expect(result.exitCode, 130);
    expect(log.existsSync(), isFalse);
  });

  test('missing executable clears ownership', () async {
    ProjectProcessResult result = await runProjectProcess(
      executable: p.join(directory.path, 'does-not-exist'),
      arguments: const <String>[],
      directory: directory.path,
      log: log,
    );
    expect(result.exitCode, 127);
    expect(File('${log.path}.process.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('timeout stops only owned descendants', () async {
    Process unrelated = await Process.start('/bin/sleep', <String>['60']);
    File child = File(p.join(directory.path, 'child.pid'));
    try {
      ProjectProcessResult result = await runProjectProcess(
        executable: '/bin/sh',
        arguments: <String>[
          '-c',
          'sleep 60 & echo \$! > "${child.path}"; wait',
        ],
        directory: directory.path,
        log: log,
        timeout: const Duration(milliseconds: 500),
      );
      expect(result.exitCode, 124);
      await _expectStopped(int.parse(child.readAsStringSync().trim()));
      expect(Process.killPid(unrelated.pid, ProcessSignal.sigcont), isTrue);
    } finally {
      unrelated.kill(ProcessSignal.sigkill);
      await unrelated.exitCode;
    }
  }, skip: Platform.isWindows);

  test('cancellation remains cancellation through termination grace', () async {
    bool cancel = false;
    ProjectProcessResult result = await runProjectProcess(
      executable: '/bin/sh',
      arguments: <String>[
        '-c',
        'trap "" TERM; echo ready; while :; do sleep 1; done',
      ],
      directory: directory.path,
      log: log,
      timeout: const Duration(milliseconds: 600),
      cancelled: () => cancel,
      onLine: (String line) {
        if (line == 'ready') {
          cancel = true;
        }
      },
    );
    expect(result.exitCode, 130);
    expect(File('${log.path}.process.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('root exit cleans reparented children holding output pipes', () async {
    File child = File(p.join(directory.path, 'orphan.pid'));
    ProjectProcessResult result = await runProjectProcess(
      executable: '/bin/sh',
      arguments: <String>[
        '-c',
        'sleep 60 & echo \$! > "${child.path}"; exit 0',
      ],
      directory: directory.path,
      log: log,
      timeout: const Duration(seconds: 10),
    ).timeout(const Duration(seconds: 10));
    expect(result.exitCode, 0);
    await _expectStopped(int.parse(child.readAsStringSync().trim()));
  }, skip: Platform.isWindows);

  test('output callback failure stops the command tree', () async {
    File child = File(p.join(directory.path, 'child.pid'));
    await expectLater(
      runProjectProcess(
        executable: '/bin/sh',
        arguments: <String>[
          '-c',
          'sleep 60 & echo \$! > "${child.path}"; echo ready; wait',
        ],
        directory: directory.path,
        log: log,
        onLine: (String line) {
          if (line == 'ready') {
            throw StateError('observer failed');
          }
        },
      ),
      throwsA(isA<StateError>()),
    );
    await _expectStopped(int.parse(child.readAsStringSync().trim()));
    expect(File('${log.path}.process.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('recovery uses ownership token instead of a stale root pid', () async {
    String token = '0123456789abcdef0123456789abcdef';
    File script = File(p.join(directory.path, 'sleep.dart'))
      ..writeAsStringSync(
        "import 'dart:io'; void main() { sleep(const Duration(seconds: 60)); }",
      );
    Process owned = await Process.start(
      Platform.resolvedExecutable,
      <String>[script.path],
      environment: <String, String>{'MULTIPLEXOR_PROCESS_TOKEN': token},
    );
    Process unrelated = await Process.start('/bin/sleep', <String>['60']);
    File state = File('${log.path}.process.json')
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'token': token,
          'pid': unrelated.pid,
          'started': 'stale identity',
        }),
      );
    try {
      await stopRecordedProjectProcess(log);
      await owned.exitCode.timeout(const Duration(seconds: 5));
      expect(Process.killPid(unrelated.pid, ProcessSignal.sigcont), isTrue);
      expect(state.existsSync(), isFalse);
    } finally {
      owned.kill(ProcessSignal.sigkill);
      unrelated.kill(ProcessSignal.sigkill);
      await unrelated.exitCode;
    }
  }, skip: Platform.isWindows);
}

Future<void> _expectStopped(int id) async {
  ProcessResult result = await Process.run('ps', <String>[
    '-p',
    '$id',
    '-o',
    'stat=',
  ]);
  expect(
    result.exitCode != 0 || '${result.stdout}'.trim().startsWith('Z'),
    isTrue,
    reason: 'Process $id is still alive',
  );
}
