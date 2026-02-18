import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final appRoot = Directory(
    p.normalize(p.join(File.fromUri(Platform.script).parent.path, '..')),
  ).absolute;

  String? requestedOutput;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output' || arg == '-o') {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for $arg');
        exit(2);
      }
      requestedOutput = args[++i];
      continue;
    }

    if (arg.startsWith('--output=')) {
      requestedOutput = arg.substring('--output='.length);
      continue;
    }

    stderr.writeln('Unknown argument: $arg');
    stderr.writeln('Usage: dart run tool/build_exe.dart [--output <path>]');
    exit(2);
  }

  final defaultOutput = p.join(appRoot.parent.path, 'multiplexor');
  final outputPath = requestedOutput == null
      ? defaultOutput
      : p.normalize(
          p.isAbsolute(requestedOutput)
              ? requestedOutput
              : p.join(Directory.current.path, requestedOutput),
        );

  stdout.writeln('Compiling executable...');
  stdout.writeln('Project: ${appRoot.path}');
  stdout.writeln('Output:  $outputPath');

  final result = await Process.start(
    'dart',
    <String>[
      'compile',
      'exe',
      'bin/main.dart',
      '-o',
      outputPath,
    ],
    workingDirectory: appRoot.path,
    runInShell: true,
  );

  await stdout.addStream(result.stdout);
  await stderr.addStream(result.stderr);

  final exitCode = await result.exitCode;
  if (exitCode != 0) {
    exit(exitCode);
  }

  stdout.writeln('Done.');
}
