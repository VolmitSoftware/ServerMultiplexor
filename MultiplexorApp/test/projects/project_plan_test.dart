import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_service.dart';
import 'package:multiplexor/services/projects/project_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late ProjectBuildService service;
  setUp(() {
    workspace = Directory.systemTemp.createTempSync('multiplexor-plan-');
    service = ProjectBuildService(rootDirectory: workspace.path);
    projectAtomicJson(service.store.catalogFile, <String, Object?>{
      'projects': <Object?>[
        _project('library', <Map<String, Object?>>[
          _target('api'),
        ], workspace.path),
        _project('iris', <Map<String, Object?>>[
          _target('bukkit'),
          _target('fabric-26.3', dependencies: <String>['library:api']),
          _target('forge-26.3'),
        ], workspace.path),
        _project('gloss', <Map<String, Object?>>[
          _target('bukkit'),
          _target('api'),
        ], workspace.path),
      ],
    });
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  test(
    'selects multiple targets with their dependencies in requested order',
    () async {
      List<String> output = <String>[];
      List<String> errors = <String>[];
      int code = await service.command(
        <String>['plan', 'iris', '--target', 'fabric-26.3, bukkit', '--json'],
        output: output.add,
        error: errors.add,
      );
      expect(code, 0);
      expect(errors, isEmpty);
      Map<String, Object?> plan =
          jsonDecode(output.single) as Map<String, Object?>;
      expect(plan['targets'], <String>[
        'library:api',
        'iris:fabric-26.3',
        'iris:bukkit',
      ]);
    },
  );

  test('single target remains valid', () async {
    List<String> output = <String>[];
    expect(
      await service.command(
        <String>['plan', 'iris', '--target', 'bukkit', '--json'],
        output: output.add,
        error: fail,
      ),
      0,
    );
    expect(
      (jsonDecode(output.single) as Map<String, Object?>)['targets'],
      <String>['iris:bukkit'],
    );
  });

  test(
    'selects exact targets across projects and includes dependencies',
    () async {
      List<String> output = <String>[];
      expect(
        await service.command(
          <String>[
            'plan',
            '--targets',
            'gloss:bukkit, iris:fabric-26.3, library:api',
            '--json',
          ],
          output: output.add,
          error: fail,
        ),
        0,
      );
      expect(
        (jsonDecode(output.single) as Map<String, Object?>)['targets'],
        <String>['gloss:bukkit', 'library:api', 'iris:fabric-26.3'],
      );
    },
  );

  test(
    'explicit selection does not include other targets in a project',
    () async {
      List<String> output = <String>[];
      expect(
        await service.command(
          <String>['plan', '--targets', 'iris:bukkit', '--json'],
          output: output.add,
          error: fail,
        ),
        0,
      );
      expect(
        (jsonDecode(output.single) as Map<String, Object?>)['targets'],
        <String>['iris:bukkit'],
      );
    },
  );

  for (String command in <String>['plan', 'build']) {
    for (String targets in <String>[
      '',
      ' ',
      ',iris:bukkit',
      'iris:bukkit,',
      'iris:bukkit,,gloss:api',
      'iris:bukkit,iris:bukkit',
      'iris:bukkit, iris:bukkit',
      'iris:bukkit,gloss:missing',
      'missing:bukkit',
      'iris',
      'iris:',
      ':bukkit',
      'iris:bukkit:extra',
      'iris: buk kit',
      'Iris:bukkit',
      '../iris:bukkit',
    ]) {
      test('$command rejects invalid explicit selection "$targets"', () async {
        List<String> errors = <String>[];
        expect(
          await service.command(
            <String>[command, '--targets', targets, '--json'],
            output: fail,
            error: errors.add,
          ),
          2,
        );
        expect(errors, hasLength(1));
        expect(service.store.runs(), isEmpty);
      });
    }

    for (List<String> scope in <List<String>>[
      <String>['iris'],
      <String>['--all'],
      <String>['--all-targets'],
      <String>['--target', 'bukkit'],
    ]) {
      test(
        '$command rejects explicit selection with ${scope.join(' ')}',
        () async {
          List<String> errors = <String>[];
          expect(
            await service.command(
              <String>[command, ...scope, '--targets', 'iris:bukkit', '--json'],
              output: fail,
              error: errors.add,
            ),
            2,
          );
          expect(errors.single, contains('Choose --targets'));
          expect(service.store.runs(), isEmpty);
        },
      );
    }
  }

  for (String targets in <String>[
    '',
    ',bukkit',
    'bukkit,',
    'bukkit,,fabric-26.3',
    'bukkit,bukkit',
    'bukkit, bukkit',
    'bukkit,missing',
  ]) {
    test('rejects invalid target selection "$targets"', () async {
      List<String> errors = <String>[];
      expect(
        await service.command(
          <String>['plan', 'iris', '--target', targets, '--json'],
          output: fail,
          error: errors.add,
        ),
        2,
      );
      expect(errors, hasLength(1));
    });
  }

  test('rejects target list combined with all-targets', () async {
    List<String> errors = <String>[];
    expect(
      await service.command(
        <String>[
          'plan',
          'iris',
          '--target',
          'bukkit,fabric-26.3',
          '--all-targets',
        ],
        output: fail,
        error: errors.add,
      ),
      2,
    );
    expect(errors.single, contains('Choose --target or --all-targets'));
  });
}

Map<String, Object?> _project(
  String id,
  List<Map<String, Object?>> targets,
  String root,
) => <String, Object?>{
  'schema': 1,
  'id': id,
  'name': id,
  'sandbox': 'per-target',
  'parallelTargets': true,
  'sourceDependencies': <String>[],
  'sourceRoot': root,
  'relativePath': id,
  'targets': targets,
};

Map<String, Object?> _target(
  String id, {
  List<String> dependencies = const <String>[],
}) => <String, Object?>{
  'id': id,
  'tasks': <String>['build'],
  'dependsOn': dependencies,
  'artifacts': <Object?>[],
};
