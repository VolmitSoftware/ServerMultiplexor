import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_service.dart';
import 'package:multiplexor/services/projects/project_initializer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late Directory project;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('project-initializer-');
    project = Directory(p.join(fixture.path, 'Sample Plugin'))..createSync();
    _write(project, 'build.gradle', "plugins { id 'java' }\n");
    _write(project, 'gradlew', '#!/bin/sh\nexit 99\n');
    _write(
      project,
      'gradle/wrapper/gradle-wrapper.properties',
      'distributionUrl=unused\n',
    );
    _write(
      project,
      'src/main/resources/plugin.yml',
      'name: Sample\nmain: example.Plugin\n',
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'preview identifies plugin without writing or executing the wrapper',
    () {
      String original = File(
        p.join(project.path, 'build.gradle'),
      ).readAsStringSync();
      Map<String, Object?> preview = ProjectInitializer().initialize(
        project.path,
      );
      expect(preview['id'], 'sample-plugin');
      expect(preview['applied'], isFalse);
      expect(preview['targets'], <Map<String, Object?>>[
        <String, Object?>{
          'id': 'bukkit',
          'projectDirectory': '.',
          'platform': 'plugin',
          'java': null,
          'minecraftVersions': <String>[],
          'artifact': 'resolved by Gradle',
        },
      ]);
      expect(
        File(p.join(project.path, 'gradle/multiplexor.gradle')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(project.path, 'build.gradle')).readAsStringSync(),
        original,
      );
      expect(
        preview['warnings'],
        contains(contains('unknown Minecraft compatibility')),
      );
    },
  );

  test(
    'apply preserves Groovy source and rejects replacing an existing declaration',
    () {
      File build = File(p.join(project.path, 'build.gradle'));
      String original = build.readAsStringSync();
      Map<String, Object?> applied = ProjectInitializer().initialize(
        project.path,
        id: 'sample',
        name: "Sam's \$Plugin",
        java: 21,
        apply: true,
      );
      expect(applied['applied'], isTrue);
      expect(
        build.readAsStringSync(),
        "$original\napply from: 'gradle/multiplexor.gradle'\n",
      );
      File metadata = File(p.join(project.path, 'gradle/multiplexor.gradle'));
      String content = metadata.readAsStringSync();
      expect(content, contains('Sam\\\'s \$Plugin'));
      expect(content, contains('"java":21'));
      expect(
        () => ProjectInitializer().initialize(project.path, apply: true),
        throwsFormatException,
      );
      expect(metadata.readAsStringSync(), content);
    },
  );

  test('Kotlin build uses its native apply syntax', () {
    File(p.join(project.path, 'build.gradle')).deleteSync();
    _write(project, 'build.gradle.kts', 'plugins { java }');
    ProjectInitializer().initialize(project.path, apply: true);
    expect(
      File(p.join(project.path, 'build.gradle.kts')).readAsStringSync(),
      'plugins { java }\n\napply(from = "gradle/multiplexor.gradle")\n',
    );
  });

  test('module targets retain directories and only exact Fabric versions', () {
    Directory(p.join(project.path, 'src')).deleteSync(recursive: true);
    _write(
      project,
      'platforms/fabric/src/main/resources/fabric.mod.json',
      '{"depends":{"minecraft":["1.21.1","1.21.2"]}}',
    );
    _write(
      project,
      'platforms/forge/src/main/resources/META-INF/mods.toml',
      'modLoader="javafml"',
    );
    _write(project, 'common/src/main/java/Example.java', 'class Example {}');
    Map<String, Object?> result = ProjectInitializer().initialize(project.path);
    List<Map<String, Object?>> targets = (result['targets'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(targets.map((Map<String, Object?> target) => target['id']), <String>[
      'common',
      'platforms-fabric',
      'platforms-forge',
    ]);
    expect(targets[0]['platform'], isNull);
    expect(targets[1]['projectDirectory'], 'platforms/fabric');
    expect(targets[1]['minecraftVersions'], <String>['1.21.1', '1.21.2']);
    expect(targets[2]['minecraftVersions'], isEmpty);
    _write(
      project,
      'platforms/fabric/src/main/resources/fabric.mod.json',
      '{"depends":{"minecraft":">=1.21"}}',
    );
    targets =
        (ProjectInitializer().initialize(project.path)['targets']
                as List<Object?>)
            .cast<Map<String, Object?>>();
    expect(targets[1]['minecraftVersions'], isEmpty);
  });

  test('apply writes the exact declaration shown in preview', () {
    Map<String, Object?> result = ProjectInitializer().initialize(project.path);
    String content =
        ((result['files'] as List<Object?>).first
                as Map<String, Object?>)['content']
            as String;
    ProjectInitializer().initialize(project.path, apply: true);
    expect(
      File(
        p.join(project.path, 'gradle/multiplexor.gradle'),
      ).readAsStringSync(),
      content,
    );
    expect(
      project.listSync().where(
        (FileSystemEntity file) =>
            p.basename(file.path).startsWith('.multiplexor-init-'),
      ),
      isEmpty,
    );
  });

  test('ambiguous runtime descriptors fail without changes', () {
    _write(project, 'src/main/resources/fabric.mod.json', '{}');
    expect(
      () => ProjectInitializer().initialize(project.path, apply: true),
      throwsFormatException,
    );
    expect(
      File(p.join(project.path, 'gradle/multiplexor.gradle')).existsSync(),
      isFalse,
    );
  });

  test('generated output and nested independent roots are not converted', () {
    _write(project, 'build/example/src/main/resources/fabric.mod.json', '{}');
    _write(project, 'examples/other/gradlew', '');
    _write(project, 'examples/other/src/main/resources/fabric.mod.json', '{}');
    List<Object?> targets =
        ProjectInitializer().initialize(project.path)['targets']
            as List<Object?>;
    expect(targets, hasLength(1));
  });

  test('filesystem preview identifies candidate membership as unverified', () {
    _write(
      project,
      'examples/demo/src/main/java/Example.java',
      'class Example {}',
    );
    Map<String, Object?> preview = ProjectInitializer().initialize(
      project.path,
    );
    expect(
      (preview['targets'] as List<Object?>).cast<Map<String, Object?>>().map(
        (Map<String, Object?> target) => target['projectDirectory'],
      ),
      <String>['.', 'examples/demo'],
    );
    expect(
      preview['warnings'],
      contains(
        'Scan verifies candidate module membership; source folders outside this Gradle build are omitted.',
      ),
    );
    expect(
      File(p.join(project.path, 'gradle/multiplexor.gradle')).existsSync(),
      isFalse,
    );
  });

  test('missing wrapper and conflicting root build files are rejected', () {
    File wrapper = File(p.join(project.path, 'gradlew'))..deleteSync();
    expect(
      () => ProjectInitializer().initialize(project.path),
      throwsFormatException,
    );
    wrapper.writeAsStringSync('');
    _write(project, 'build.gradle.kts', 'plugins { java }');
    expect(
      () => ProjectInitializer().initialize(project.path),
      throwsFormatException,
    );
  });

  test('linked build files are not replaced', () {
    File source = File(p.join(fixture.path, 'shared.gradle'))
      ..writeAsStringSync('unchanged');
    File(p.join(project.path, 'build.gradle')).deleteSync();
    Link(p.join(project.path, 'build.gradle')).createSync(source.path);
    expect(
      () => ProjectInitializer().initialize(project.path, apply: true),
      throwsFormatException,
    );
    expect(source.readAsStringSync(), 'unchanged');
  }, skip: Platform.isWindows);

  test(
    'command previews then applies without registering or running Gradle',
    () async {
      ProjectBuildService service = ProjectBuildService(
        rootDirectory: fixture.path,
      );
      List<String> output = <String>[];
      List<String> errors = <String>[];
      expect(
        await service.command(
          <String>['init', project.path, '--json'],
          output: output.add,
          error: errors.add,
        ),
        0,
      );
      expect(
        (jsonDecode(output.single) as Map<String, Object?>)['applied'],
        isFalse,
      );
      expect(service.catalog(), isEmpty);
      output.clear();
      expect(
        await service.command(
          <String>['init', project.path, '--java', '21', '--apply', '--json'],
          output: output.add,
          error: errors.add,
        ),
        0,
      );
      expect(
        (jsonDecode(output.single) as Map<String, Object?>)['applied'],
        isTrue,
      );
      expect(errors, isEmpty);
      expect(service.catalog(), isEmpty);
    },
  );
}

void _write(Directory directory, String relative, String content) {
  File file = File(p.join(directory.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
