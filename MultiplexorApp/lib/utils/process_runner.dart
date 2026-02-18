import 'dart:async';
import 'dart:io';

class StreamingResult {
  StreamingResult(this.exitCode);

  final int exitCode;
  bool get success => exitCode == 0;
}

class CapturedResult {
  CapturedResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}

class ProcessRunner {
  const ProcessRunner();

  Future<StreamingResult> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
      mode: ProcessStartMode.inheritStdio,
    );

    final exitCode = await process.exitCode;
    return StreamingResult(exitCode);
  }

  Future<StreamingResult> runStreaming(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
    );

    final stdoutSub = process.stdout.listen(stdout.add);
    final stderrSub = process.stderr.listen(stderr.add);

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    return StreamingResult(exitCode);
  }

  Future<CapturedResult> runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
    );

    return CapturedResult(
      exitCode: result.exitCode,
      stdout: (result.stdout ?? '').toString(),
      stderr: (result.stderr ?? '').toString(),
    );
  }
}
