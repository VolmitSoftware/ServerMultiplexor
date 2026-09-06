import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimum game runtime, not a guarantee that a loader or plugin supports it.
/// Mojang release notes: 1.17 uses 16, 1.18 uses 17, 1.20.5 uses 21,
/// and 26.1 uses 25. Unknown version formats need an explicit operator check.
int? minimumMinecraftJava(String? minecraft) {
  final RegExpMatch? match = RegExp(
    r'^(\d+)\.(\d+)(?:\.(\d+))?(?:-(?:pre|rc|snapshot)-?\d+)?$',
  ).firstMatch(minecraft?.trim() ?? '');
  if (match == null) return null;
  final int major = int.parse(match[1]!);
  final int minor = int.parse(match[2]!);
  final int patch = int.parse(match[3] ?? '0');
  if (major == 26) return 25;
  if (major != 1) return null;
  if (minor >= 21 || (minor == 20 && patch >= 5)) return 21;
  if (minor >= 18) return 17;
  if (minor == 17) return 16;
  if (minor >= 12) return 8;
  return null;
}

int? parseJavaMajor(String output) {
  final RegExpMatch? match = RegExp(
    r'(?:openjdk|java)\s+(?:version\s+)?"?(\d+)(?:\.(\d+))?',
    caseSensitive: false,
  ).firstMatch(output);
  if (match == null) return null;
  final int major = int.parse(match[1]!);
  return major == 1 ? int.tryParse(match[2] ?? '') : major;
}

Future<int> inspectJavaRuntime(
  String executable, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final Process process;
  try {
    process = await Process.start(executable, const <String>['-version']);
  } on ProcessException catch (error) {
    throw StateError(
      'Cannot run Java executable "$executable": ${error.message}',
    );
  }
  final Future<String> output = process.stdout.transform(utf8.decoder).join();
  final Future<String> errors = process.stderr.transform(utf8.decoder).join();
  try {
    final int exitCode = await process.exitCode.timeout(timeout);
    final String text = '${await output}\n${await errors}';
    final int? major = parseJavaMajor(text);
    if (exitCode != 0 || major == null) {
      throw StateError(
        'Cannot identify Java from "$executable -version" (exit $exitCode).',
      );
    }
    return major;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError('Java version check timed out for "$executable".');
  }
}
