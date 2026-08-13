import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class PterodactylSmbCommandResult {
  const PterodactylSmbCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get diagnostic {
    final String raw = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    final String text = raw
        .replaceAll(
          RegExp(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))'),
          '',
        )
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
    return text.length <= 1000 ? text : '${text.substring(0, 1000)}...';
  }
}

abstract interface class PterodactylSmbProcessHandle {
  int get pid;

  String get diagnostic;

  Future<int?> waitForExit(Duration timeout);

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

abstract interface class PterodactylSmbProcessRunner {
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  });

  Future<PterodactylSmbProcessHandle> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  });

  Future<bool> executableExists(String executable);

  Future<String?> describeProcess(int pid);

  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]);
}

final class DartIoPterodactylSmbProcessRunner
    implements PterodactylSmbProcessRunner {
  const DartIoPterodactylSmbProcessRunner();

  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    try {
      if (stdinText != null) {
        final Process process = await Process.start(
          executable,
          arguments,
          environment: environment,
          includeParentEnvironment: true,
          mode: ProcessStartMode.normal,
          runInShell: false,
        );
        final Future<String> stdout = utf8.decoder.bind(process.stdout).join();
        final Future<String> stderr = utf8.decoder.bind(process.stderr).join();
        process.stdin.write(stdinText);
        process.stdin.write('\n');
        await process.stdin.close();
        final int exitCode = await process.exitCode;
        return PterodactylSmbCommandResult(
          exitCode: exitCode,
          stdout: await stdout,
          stderr: await stderr,
        );
      }
      final ProcessResult result = await Process.run(
        executable,
        arguments,
        environment: environment,
        includeParentEnvironment: true,
        runInShell: false,
      );
      return PterodactylSmbCommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    } on ProcessException catch (error) {
      return PterodactylSmbCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: error.message,
      );
    }
  }

  @override
  Future<PterodactylSmbProcessHandle> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final Process process = await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: true,
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    return _DartIoPterodactylSmbProcessHandle(process);
  }

  @override
  Future<bool> executableExists(String executable) async {
    if (executable.contains(Platform.pathSeparator)) {
      return File(executable).existsSync();
    }
    final String locator = Platform.isWindows ? 'where.exe' : 'which';
    final PterodactylSmbCommandResult result = await run(locator, <String>[
      executable,
    ]);
    return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
  }

  @override
  Future<String?> describeProcess(int pid) async {
    if (pid <= 0) return null;
    if (Platform.isWindows) {
      final PterodactylSmbCommandResult
      result = await run('powershell.exe', <String>[
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").CommandLine',
      ]);
      if (result.exitCode != 0 || result.stdout.trim().isEmpty) return null;
      return result.stdout.trim();
    }
    final PterodactylSmbCommandResult result = await run('ps', <String>[
      '-p',
      '$pid',
      '-o',
      'command=',
    ]);
    if (result.exitCode != 0 || result.stdout.trim().isEmpty) return null;
    return result.stdout.trim();
  }

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) =>
      Process.killPid(pid, signal);
}

final class _DartIoPterodactylSmbProcessHandle
    implements PterodactylSmbProcessHandle {
  _DartIoPterodactylSmbProcessHandle(this._process) {
    _capture(_process.stdout);
    _capture(_process.stderr);
  }

  static const int _diagnosticLimit = 8192;

  final Process _process;
  final StringBuffer _diagnostics = StringBuffer();

  @override
  int get pid => _process.pid;

  @override
  String get diagnostic => _diagnostics.toString().trim();

  void _capture(Stream<List<int>> source) {
    source.transform(utf8.decoder).listen((String chunk) {
      final int remaining = _diagnosticLimit - _diagnostics.length;
      if (remaining <= 0) return;
      _diagnostics.write(
        chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
      );
    });
  }

  @override
  Future<int?> waitForExit(Duration timeout) async {
    final Object result = await Future.any<Object>(<Future<Object>>[
      _process.exitCode,
      Future<void>.delayed(timeout).then<Object>((void _) => _stillRunning),
    ]);
    return identical(result, _stillRunning) ? null : result as int;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

const Object _stillRunning = Object();
