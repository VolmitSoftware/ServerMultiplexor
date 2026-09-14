import 'dart:convert';
import 'dart:io';

class BuildProcessResult {
  const BuildProcessResult({required this.exitCode, required this.outputTail});

  final int exitCode;
  final List<String> outputTail;
}

Future<BuildProcessResult> runBuildProcess({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required File logFile,
  void Function(String)? onLine,
}) async {
  logFile.parent.createSync(recursive: true);
  final IOSink log = logFile.openWrite();
  final List<String> outputTail = <String>[];
  void record(String line) {
    log.writeln(line);
    outputTail.add(line);
    if (outputTail.length > 80) outputTail.removeAt(0);
    onLine?.call(line);
  }

  try {
    log.writeln('Working directory: $workingDirectory');
    log.writeln('Executable: $executable');
    log.writeln('Arguments: ${jsonEncode(arguments)}');
    final Process process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    final Future<void> output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(record);
    final Future<void> errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(record);
    final int exitCode = await process.exitCode;
    await Future.wait(<Future<void>>[output, errors]);
    log.writeln('Exit code: $exitCode');
    return BuildProcessResult(
      exitCode: exitCode,
      outputTail: List<String>.unmodifiable(outputTail),
    );
  } on ProcessException catch (error) {
    log.writeln('Could not start build: ${error.message}');
    rethrow;
  } finally {
    await log.flush();
    await log.close();
  }
}
