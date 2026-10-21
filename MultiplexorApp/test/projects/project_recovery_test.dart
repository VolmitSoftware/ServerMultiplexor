@Tags(<String>['project-cli'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_service.dart';
import 'package:multiplexor/services/projects/project_files.dart';
import 'package:multiplexor/services/projects/project_model.dart';
import 'package:multiplexor/services/projects/project_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'cancel recovers an orphaned build after its worker exits',
    () async {
      Directory fixture = Directory(
        Directory.systemTemp
            .createTempSync('multiplexor-recovery-')
            .resolveSymbolicLinksSync(),
      );
      Directory source = Directory(p.join(fixture.path, 'sources', 'sample'))
        ..createSync(recursive: true);
      File wrapper = File(p.join(source.path, 'gradlew'))
        ..writeAsStringSync(r'''#!/bin/sh
printf 'gradle-root=%s\n' "$$"
sleep 120 &
printf 'gradle-child=%s\n' "$!"
printf '> Task :hold\n'
wait
''');
      expect(
        Process.runSync('chmod', <String>['755', wrapper.path]).exitCode,
        0,
      );
      ProjectBuildService service = ProjectBuildService(
        rootDirectory: p.join(fixture.path, 'workspace'),
      );
      File runFile = service.store.runFile('recovery');
      projectAtomicJson(runFile, <String, Object?>{
        'schema': 1,
        'id': 'recovery',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'status': 'queued',
        'projects': <Object?>[
          <String, Object?>{
            'schema': 1,
            'id': 'sample',
            'name': 'Sample',
            'sandbox': 'per-target',
            'parallelTargets': true,
            'sourceDependencies': <String>[],
            'sourceRoot': p.dirname(source.path),
            'relativePath': 'sample',
            'targets': <Object?>[
              <String, Object?>{
                'id': 'plugin',
                'tasks': <String>['hold'],
                'java': 25,
                'memoryMiB': 512,
                'workers': 1,
                'artifacts': <Object?>[],
              },
            ],
          },
        ],
        'targets': <String>['sample:plugin'],
        'jobsLimit': 1,
        'memoryMiB': 512,
        'workers': 1,
        'jobs': <Object?>[
          <String, Object?>{
            'key': 'sample:plugin',
            'project': 'sample',
            'target': 'plugin',
            'status': 'queued',
            'artifacts': <Object?>[],
          },
        ],
      });
      Process? worker;
      Process? unrelated;
      File? log;
      List<int> buildPids = <int>[];
      StringBuffer workerOutput = StringBuffer();
      int? workerExitCode;
      try {
        unrelated = await Process.start('/bin/sleep', <String>['120']);
        worker = await Process.start(
          Platform.resolvedExecutable,
          <String>[
            p.absolute('bin/main.dart'),
            '--root',
            service.store.workspace,
            'projects',
            'worker',
            'recovery',
          ],
          environment: <String, String>{...Platform.environment}
            ..remove('GIT_CONFIG_COUNT'),
          includeParentEnvironment: false,
        );
        unawaited(
          worker.stdout.transform(utf8.decoder).forEach(workerOutput.write),
        );
        unawaited(
          worker.stderr.transform(utf8.decoder).forEach(workerOutput.write),
        );
        unawaited(worker.exitCode.then((int code) => workerExitCode = code));
        await _waitFor(
          () {
            if (workerExitCode != null) {
              fail('Worker exited $workerExitCode: $workerOutput');
            }
            Map<String, Object?> state = projectReadJson(runFile);
            if (state['status'] == 'failed') {
              fail('Worker failed: ${state['error']}\n$workerOutput');
            }
            Map<String, Object?> job = projectObject(
              (state['jobs'] as List<Object?>).single,
            );
            String? path = job['logPath'] as String?;
            if (path == null) {
              return false;
            }
            log = File(path);
            File ownership = File('$path.process.json');
            if (!log!.existsSync() || !ownership.existsSync()) {
              return false;
            }
            buildPids = RegExp(r'gradle-(?:root|child)=(\d+)')
                .allMatches(log!.readAsStringSync())
                .map((RegExpMatch match) => int.parse(match.group(1)!))
                .toList();
            Map<String, Object?> recorded = projectReadJson(ownership);
            Map<String, Object?> identities = projectObject(
              recorded['identities'],
            );
            return buildPids.length == 2 &&
                identities.containsKey('${buildPids.first}') &&
                recorded['group'] is int;
          },
          reason: () =>
              'Worker did not record the running build: $workerOutput\n${runFile.readAsStringSync()}\n${log?.readAsStringSync()}',
        );
        expect(projectReadJson(runFile)['workerPid'], worker.pid);
        expect(worker.kill(ProcessSignal.sigkill), isTrue);
        expect(
          await worker.exitCode.timeout(const Duration(seconds: 5)),
          isNot(0),
        );
        for (int id in buildPids) {
          expect(
            await _running(id),
            isTrue,
            reason: 'Build $id did not outlive its worker',
          );
        }
        Map<String, Object?> stale = projectReadJson(runFile);
        stale['heartbeatAt'] = DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 2))
            .toIso8601String();
        projectAtomicJson(runFile, stale);
        expect(
          projectObject(
            (service.status('recovery')['runs'] as List<Object?>).single,
          )['status'],
          'interrupted',
        );
        List<String> output = <String>[];
        List<String> errors = <String>[];
        expect(
          await service.command(
            <String>['cancel', 'recovery'],
            output: output.add,
            error: errors.add,
          ),
          0,
          reason: errors.join('\n'),
        );
        expect(errors, isEmpty);
        expect(output.single, contains('recovery'));
        for (int id in buildPids) {
          expect(
            await _running(id),
            isFalse,
            reason: 'Recovered build $id is still running',
          );
        }
        expect(await _running(unrelated.pid), isTrue);
        expect(File('${log!.path}.process.json').existsSync(), isFalse);
        Map<String, Object?> recovered = projectReadJson(runFile);
        expect(recovered['status'], 'cancelled');
        expect(recovered['finishedAt'], isA<String>());
        expect(
          projectObject((recovered['jobs'] as List<Object?>).single)['status'],
          'cancelled',
        );
        expect(service.status()['activeRunId'], isNull);
      } finally {
        worker?.kill(ProcessSignal.sigkill);
        if (worker != null) {
          await worker.exitCode;
        }
        try {
          if (log != null) {
            await stopRecordedProjectProcess(log!);
          }
        } finally {
          for (int id in buildPids) {
            if (await _running(id)) {
              Process.killPid(id, ProcessSignal.sigkill);
            }
          }
          unrelated?.kill(ProcessSignal.sigkill);
          if (unrelated != null) {
            await unrelated.exitCode;
          }
          if (service.store.workDirectory.existsSync()) {
            service.store.workDirectory.deleteSync(recursive: true);
          }
          fixture.deleteSync(recursive: true);
        }
      }
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _waitFor(
  bool Function() ready, {
  required String Function() reason,
}) async {
  DateTime deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason());
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<bool> _running(int id) async {
  ProcessResult result = await Process.run('ps', <String>[
    '-p',
    '$id',
    '-o',
    'stat=',
  ]);
  return result.exitCode == 0 && !'${result.stdout}'.trim().startsWith('Z');
}
