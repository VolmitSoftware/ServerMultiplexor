import 'dart:io';

import 'package:multiplexor/services/java_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'probes a configured path with spaces and bounds stalled checks',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'multiplexor-java-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final File executable = File('${root.path}/java fixture')
        ..writeAsStringSync(
          '#!/bin/sh\nprintf \'openjdk version "25.0.1"\\n\' >&2\n',
        );
      expect(
        (await Process.run('chmod', <String>['+x', executable.path])).exitCode,
        0,
      );
      expect(await inspectJavaRuntime(executable.path), 25);
      executable.writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      await expectLater(
        inspectJavaRuntime(
          executable.path,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      await expectLater(
        inspectJavaRuntime('${root.path}/missing'),
        throwsStateError,
      );
    },
    skip: Platform.isWindows,
  );
  test('parses OpenJDK and legacy Oracle version output', () {
    expect(parseJavaMajor('openjdk version "25.0.1" 2025-10-21'), 25);
    expect(parseJavaMajor('java version "1.8.0_452"'), 8);
    expect(parseJavaMajor('openjdk 21.0.6 2025-01-21'), 21);
    expect(parseJavaMajor('openjdk version "26-ea"'), 26);
    expect(parseJavaMajor('not an executable'), isNull);
  });
  test('Minecraft Java minimum changes at release boundaries', () {
    expect(minimumMinecraftJava('1.16.5'), 8);
    expect(minimumMinecraftJava('1.17'), 16);
    expect(minimumMinecraftJava('1.18'), 17);
    expect(minimumMinecraftJava('1.20.4'), 17);
    expect(minimumMinecraftJava('1.20.5'), 21);
    expect(minimumMinecraftJava('1.21.11'), 21);
    expect(minimumMinecraftJava('26.1'), 25);
    expect(minimumMinecraftJava('26.2-pre-1'), 25);
    expect(minimumMinecraftJava('custom'), isNull);
    expect(minimumMinecraftJava(null), isNull);
    expect(minimumMinecraftJava('27.1'), isNull);
  });
}
