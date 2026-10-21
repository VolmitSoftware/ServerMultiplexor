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
