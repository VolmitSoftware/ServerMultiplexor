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
    return arguments.contains('failed-preview') ? 1 : 0;
  });
  List<String>? result;
  try {
    result = await prompts.request(
      ProjectDashboardAction.values.byName(arguments.first),
      ProjectDashboardSelection(
        row: null,
        run: <String, Object?>{'id': 'run-one'},
        runs: const <Map<String, Object?>>[],
        catalog: const <Map<String, Object?>>[],
        limits: ProjectBuildLimits(jobs: 2, memoryMiB: 8192, workers: 4),
        destinations: arguments.contains('empty')
            ? const <Map<String, Object?>>[]
            : <Map<String, Object?>>[
                <String, Object?>{
                  'name': 'exports',
                  'kind': 'directory',
                  'path': '/tmp/example-exports',
                  'platform': 'plugin',
                  'minecraft': '26.3',
                },
              ],
      ),
    );
  } on PromptBackNavigation {
    result = null;
  }
  stdout.writeln(
    'RESULT=${jsonEncode(<String, Object?>{'result': result, 'calls': calls})}',
  );
}
