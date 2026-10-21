import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_build_service.dart';
import 'package:multiplexor/services/projects/project_files.dart';
import 'package:multiplexor/services/projects/project_model.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late ProjectBuildService service;

  setUp(() {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('multiplexor-limits-')
          .resolveSymbolicLinksSync(),
    );
    service = ProjectBuildService(
      rootDirectory: p.join(fixture.path, 'workspace'),
    );
  });

  tearDown(() {
    if (service.store.workDirectory.existsSync()) {
      service.store.workDirectory.deleteSync(recursive: true);
    }
    fixture.deleteSync(recursive: true);
  });

  test(
    'reads positive host defaults without writing a settings file',
    () async {
      ProjectBuildLimits defaults = ProjectBuildLimits.defaults();
      List<String> output = <String>[];
      expect(
        await service.command(
          <String>['limits', '--json'],
          output: output.add,
          error: fail,
        ),
        0,
      );
      expect(jsonDecode(output.single), defaults.toJson());
      expect(defaults.jobs, inInclusiveRange(1, 4));
      expect(defaults.memoryMiB, greaterThanOrEqualTo(4096));
      expect(defaults.workers, greaterThanOrEqualTo(1));
      expect(service.store.limitsFile.existsSync(), isFalse);
    },
  );

  test(
    'saves limits across service instances and preserves omitted fields',
    () async {
      expect(
        await service.command(
          <String>[
            'limits',
            '--jobs',
            '3',
            '--memory',
            '12288',
            '--workers',
            '6',
          ],
          output: (_) {},
          error: fail,
        ),
        0,
      );
      ProjectBuildService reopened = ProjectBuildService(
        rootDirectory: service.store.workspace,
      );
      expect(reopened.limits().toJson(), <String, Object?>{
        'schema': 1,
        'jobs': 3,
        'memoryMiB': 12288,
        'workers': 6,
      });
      expect(
        await reopened.command(
          <String>['limits', '--jobs', '2'],
          output: (_) {},
          error: fail,
        ),
        0,
      );
      expect(service.limits().toJson(), <String, Object?>{
        'schema': 1,
        'jobs': 2,
        'memoryMiB': 12288,
        'workers': 6,
      });
    },
  );

  for (List<String> invalid in <List<String>>[
    <String>['--jobs', '0'],
    <String>['--jobs', '-1'],
    <String>['--jobs', '1.5'],
    <String>['--memory', '0'],
    <String>['--memory', '16G'],
    <String>['--workers', '0'],
    <String>['--jobs', '2', '--memory', 'invalid'],
  ]) {
    test(
      'rejects ${invalid.join(' ')} without changing saved limits',
      () async {
        projectAtomicJson(
          service.store.limitsFile,
          ProjectBuildLimits(jobs: 4, memoryMiB: 8192, workers: 8).toJson(),
        );
        String before = service.store.limitsFile.readAsStringSync();
        List<String> errors = <String>[];
        expect(
          await service.command(
            <String>['limits', ...invalid],
            output: fail,
            error: errors.add,
          ),
          2,
        );
        expect(errors.single, contains('positive integer'));
        expect(service.store.limitsFile.readAsStringSync(), before);
      },
    );
  }

  for (Map<String, Object?> invalid in <Map<String, Object?>>[
    <String, Object?>{'schema': 2, 'jobs': 1, 'memoryMiB': 8192, 'workers': 2},
    <String, Object?>{'schema': 1, 'jobs': 0, 'memoryMiB': 8192, 'workers': 2},
    <String, Object?>{'schema': 1, 'jobs': 1, 'memoryMiB': -1, 'workers': 2},
    <String, Object?>{
      'schema': 1,
      'jobs': 1,
      'memoryMiB': '8192',
      'workers': 2,
    },
    <String, Object?>{'schema': 1, 'jobs': 1, 'memoryMiB': 8192},
  ]) {
    test('rejects malformed persisted limits $invalid', () {
      projectAtomicJson(service.store.limitsFile, invalid);
      expect(service.limits, throwsFormatException);
    });
  }

  test(
    'saved memory limits reject oversized targets before creating a run',
    () async {
      projectAtomicJson(
        service.store.limitsFile,
        ProjectBuildLimits(jobs: 2, memoryMiB: 256, workers: 3).toJson(),
      );
      projectAtomicJson(service.store.catalogFile, <String, Object?>{
        'projects': <Object?>[_project(fixture.path, 'alpha')],
      });
      List<String> errors = <String>[];
      expect(
        await service.command(
          <String>['build', '--targets', 'alpha:plugin'],
          output: fail,
          error: errors.add,
        ),
        2,
      );
      expect(errors.single, contains('alpha:plugin needs 512 MiB'));
      expect(service.store.runs(), isEmpty);
    },
  );

  test('rejects invalid packaging before creating a run', () async {
    projectAtomicJson(service.store.catalogFile, <String, Object?>{
      'projects': <Object?>[_project(fixture.path, 'alpha')],
    });
    List<String> errors = <String>[];
    expect(
      await service.command(
        <String>['build', 'alpha', '--packaging', 'fast'],
        output: fail,
        error: errors.add,
      ),
      2,
    );
    expect(errors.single, 'Packaging must be local or compact');
    expect(service.store.runs(), isEmpty);
  });

  test(
    'builds selected projects with saved limits, overrides, and stable retry limits',
    () async {
      for (String id in <String>['alpha', 'beta']) {
        Directory source = Directory(p.join(fixture.path, 'sources', id))
          ..createSync(recursive: true);
        File wrapper = File(p.join(source.path, 'gradlew'))
          ..writeAsStringSync('#!/bin/sh\nprintf "> Task :build\\n"\n');
        expect(
          Process.runSync('chmod', <String>['755', wrapper.path]).exitCode,
          0,
        );
      }
      projectAtomicJson(service.store.catalogFile, <String, Object?>{
        'projects': <Object?>[
          _project(p.join(fixture.path, 'sources'), 'alpha'),
          _project(
            p.join(fixture.path, 'sources'),
            'beta',
            dependencies: <String>['alpha:api'],
          ),
        ],
      });
      projectAtomicJson(
        service.store.limitsFile,
        ProjectBuildLimits(jobs: 2, memoryMiB: 2048, workers: 3).toJson(),
      );
      Map<String, Object?> first = await _runCli(service, <String>[
        'build',
        '--targets',
        'alpha:plugin,beta:plugin',
        '--wait',
        '--json',
      ]);
      expect(first['status'], 'succeeded');
      expect(first['targets'], <String>[
        'alpha:plugin',
        'alpha:api',
        'beta:plugin',
      ]);
      expect(first['jobsLimit'], 2);
      expect(first['memoryMiB'], 2048);
      expect(first['workers'], 3);
      expect(first['packaging'], 'local');

      projectAtomicJson(
        service.store.limitsFile,
        ProjectBuildLimits(jobs: 1, memoryMiB: 4096, workers: 4).toJson(),
      );
      Map<String, Object?> retry = await _runCli(service, <String>[
        'retry',
        first['id'] as String,
        '--wait',
        '--json',
      ]);
      expect(retry['status'], 'succeeded');
      expect(retry['jobsLimit'], 2);
      expect(retry['memoryMiB'], 2048);
      expect(retry['workers'], 3);
      expect(retry['packaging'], 'local');

      Map<String, Object?> overridden = await _runCli(service, <String>[
        'build',
        '--targets',
        'beta:plugin',
        '--packaging',
        'compact',
        '--jobs',
        '1',
        '--memory',
        '1024',
        '--workers',
        '2',
        '--wait',
        '--json',
      ]);
      expect(overridden['status'], 'succeeded');
      expect(overridden['targets'], <String>['alpha:api', 'beta:plugin']);
      expect(overridden['jobsLimit'], 1);
      expect(overridden['memoryMiB'], 1024);
      expect(overridden['workers'], 2);
      expect(overridden['packaging'], 'compact');
      Map<String, Object?> compactRetry = await _runCli(service, <String>[
        'retry',
        overridden['id'] as String,
        '--wait',
        '--json',
      ]);
      expect(compactRetry['packaging'], 'compact');
      expect(compactRetry['status'], 'succeeded');
      expect(service.limits().toJson(), <String, Object?>{
        'schema': 1,
        'jobs': 1,
        'memoryMiB': 4096,
        'workers': 4,
      });
    },
    skip: Platform.isWindows ? 'Uses a POSIX fixture wrapper' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, Object?> _project(
  String root,
  String id, {
  List<String> dependencies = const <String>[],
}) => <String, Object?>{
  'schema': 1,
  'id': id,
  'name': id,
  'sandbox': 'per-target',
  'parallelTargets': true,
  'sourceDependencies': <String>[],
  'sourceRoot': root,
  'relativePath': id,
  'targets': <Object?>[
    for (String target in <String>['plugin', 'api', 'unused'])
      <String, Object?>{
        'id': target,
        'tasks': <String>['build'],
        'memoryMiB': 512,
        'workers': 1,
        'dependsOn': target == 'plugin' ? dependencies : <String>[],
        'artifacts': <Object?>[],
      },
  ],
};

Future<Map<String, Object?>> _runCli(
  ProjectBuildService service,
  List<String> arguments,
) async {
  ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>[
      p.absolute('bin/main.dart'),
      '--root',
      service.store.workspace,
      'projects',
      ...arguments,
    ],
    environment: <String, String>{...Platform.environment}
      ..remove('GIT_CONFIG_COUNT'),
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
  Map<String, Object?> response = projectObject(jsonDecode('${result.stdout}'));
  return projectReadJson(service.store.runFile(response['id'] as String));
}
