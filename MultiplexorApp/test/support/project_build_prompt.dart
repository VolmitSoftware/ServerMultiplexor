import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_dashboard_model.dart';
import 'package:multiplexor/services/projects/project_dashboard_prompts.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:multiplexor/utils/user_prompt.dart';

Future<void> main(List<String> arguments) async {
  Ui.themeOverride = MonitorTheme.plainAscii();
  ProjectDashboardPrompts prompts = ProjectDashboardPrompts(
    (
      List<String> args, {
      required void Function(String) output,
      required void Function(String) error,
    }) async => 0,
  );
  List<String>? result;
  try {
    result = await prompts.request(
      ProjectDashboardAction.values.byName(arguments.first),
      ProjectDashboardSelection(
        row: const ProjectDashboardRow(
          project: 'wormholes',
          target: 'bukkit',
          name: 'Wormholes',
          job: <String, Object?>{},
          registered: true,
        ),
        run: null,
        runs: const <Map<String, Object?>>[],
        catalog: const <Map<String, Object?>>[
          <String, Object?>{'id': 'wormholes'},
        ],
        limits: ProjectBuildLimits(jobs: 3, memoryMiB: 16384, workers: 6),
        checkedTargets: const <String>['wormholes:bukkit', 'wormholes:fabric'],
      ),
    );
  } on PromptBackNavigation {
    result = null;
  }
  stdout.writeln('RESULT=${jsonEncode(result)}');
}
