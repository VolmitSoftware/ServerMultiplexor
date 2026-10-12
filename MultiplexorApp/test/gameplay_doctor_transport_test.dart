import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/cli/local_command.dart';
import 'package:multiplexor/services/gameplay_test_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'gameplay doctor accepts a target version and rejects missing values',
    () {
      expect(
        LocalCommand.parse(<String>[
          'gameplay',
          'doctor',
          '--version=26.1.2',
          '--json',
        ]).arguments,
        <String>['gameplay', 'doctor', '--version', '26.1.2', '--json'],
      );
      expect(
        () => LocalCommand.parse(<String>['gameplay', 'doctor', '--version']),
        throwsFormatException,
      );
    },
  );

  test(
    'doctor forwards an optional target intact through the Node process',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'multiplexor-doctor-transport-',
      );
      try {
        final GameplayTestService service = GameplayTestService(
          context: ManagerContext(rootDir: root.path, verbose: false),
        );
        File(p.join(service.harnessDirectory, 'src', 'cli.mjs'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "process.stdout.write(JSON.stringify(process.argv.slice(2)) + '\\n'); process.exitCode = 1;",
          );
        for (final String? version in <String?>[
          null,
          '26.1.2',
          '26.2',
          '26.3',
        ]) {
          final List<String> output = <String>[];
          final List<String> errors = <String>[];
          expect(
            await service.doctor(
              json: true,
              version: version,
              write: output.add,
              error: errors.add,
            ),
            1,
          );
          expect(errors, isEmpty);
          expect(jsonDecode(output.single), <String>[
            'doctor',
            '--json',
            if (version != null) ...<String>['--version', version],
          ]);
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
