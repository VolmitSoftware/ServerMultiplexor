import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_dashboard_prompts.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:multiplexor/utils/user_prompt.dart';

Future<void> main(List<String> arguments) async {
  Ui.themeOverride = MonitorTheme.plainAscii();
  List<List<String>> calls = <List<String>>[];
  ProjectDashboardPrompts prompts = ProjectDashboardPrompts((
    List<String> args, {
    required void Function(String) output,
    required void Function(String) error,
  }) async {
    calls.add(args);
    if (arguments.contains('preview-failure') ||
        (arguments.contains('apply-failure') && args.contains('--apply'))) {
      error('Project setup refused');
      return 1;
    }
    output(
      jsonEncode(<String, Object?>{
        'path': args[1],
        'targets': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'bukkit',
            'platform': 'plugin',
            'projectDirectory': '.',
          },
        ],
        'files': <Map<String, Object?>>[
          <String, Object?>{
            'path': 'gradle/multiplexor.gradle',
            'action': 'create',
            'content': 'ext.multiplexor = [schemaVersion: 1]',
          },
          <String, Object?>{
            'path': 'build.gradle',
            'action': 'append',
            'content': "apply from: 'gradle/multiplexor.gradle'",
          },
        ],
        'warnings': <String>['Review custom packaging before building.'],
      }),
    );
    return 0;
  });
  List<String>? result = await prompts.request(
    ProjectDashboardAction.setup,
    ProjectDashboardSelection(
      row: null,
      run: null,
      runs: const <Map<String, Object?>>[],
      catalog: const <Map<String, Object?>>[],
      limits: ProjectBuildLimits(jobs: 2, memoryMiB: 8192, workers: 4),
    ),
  );
  stdout.writeln(
    'RESULT=${jsonEncode(<String, Object?>{'result': result, 'calls': calls})}',
  );
}
