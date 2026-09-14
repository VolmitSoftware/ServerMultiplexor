import 'dart:io';

import 'package:multiplexor/services/build_process.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-build-process-');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'retains compiler errors written to stdout and the process exit',
    () async {
      final File script = File('${root.path}/compiler fixture.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main() {
  for (int i = 0; i < 100; i++) stdout.writeln('Compiling source \$i');
  stdout.writeln('[ERROR] Unsupported release version 25');
  stderr.add(<int>[255, 10]);
  exitCode = 7;
}
''');
      final File log = File('${root.path}/logs/failed.log');
      final BuildProcessResult result = await runBuildProcess(
        executable: Platform.resolvedExecutable,
        arguments: <String>[script.path],
        workingDirectory: root.path,
        logFile: log,
      );
      expect(result.exitCode, 7);
      expect(
        result.outputTail,
        contains('[ERROR] Unsupported release version 25'),
      );
      expect(result.outputTail.length, lessThanOrEqualTo(80));
      final String text = log.readAsStringSync();
      expect(text, contains('Compiling source 0'));
      expect(text, contains('[ERROR] Unsupported release version 25'));
      expect(text, contains('Exit code: 7'));
    },
  );

  test('records launch failures in the build log', () async {
    final File log = File('${root.path}/logs/missing.log');
    await expectLater(
      runBuildProcess(
        executable: '${root.path}/missing-java',
        arguments: const <String>[],
        workingDirectory: root.path,
        logFile: log,
      ),
      throwsA(isA<ProcessException>()),
    );
    expect(log.readAsStringSync(), contains('Could not start build:'));
  });
}
