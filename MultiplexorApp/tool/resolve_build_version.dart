import 'dart:io';

/// Resolves the version embedded in one CI executable build.
///
/// Branch, pull-request, and manual builds add the monotonically increasing
/// workflow run number to the checked-in patch component. Release tag builds
/// use the exact `vX.Y.Z` tag and require it to match the checked-in source
/// version.
String resolveBuildVersion({
  required String sourceVersion,
  int? runNumber,
  String? tag,
}) {
  final RegExp semanticVersion = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');
  final RegExpMatch? sourceMatch = semanticVersion.firstMatch(sourceVersion);
  if (sourceMatch == null) {
    throw FormatException('Invalid source version: $sourceVersion');
  }

  if (tag != null) {
    final String tagVersion = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!semanticVersion.hasMatch(tagVersion)) {
      throw FormatException('Invalid release tag: $tag');
    }
    if (tagVersion != sourceVersion) {
      throw FormatException(
        'Release tag $tag does not match source version $sourceVersion',
      );
    }
    return tagVersion;
  }

  if (runNumber == null || runNumber < 1) {
    throw FormatException('A positive workflow run number is required.');
  }
  final int patch = int.parse(sourceMatch.group(3)!) + runNumber;
  return '${sourceMatch.group(1)}.${sourceMatch.group(2)}.$patch';
}

void main(List<String> arguments) {
  int? runNumber;
  String? tag;
  for (int index = 0; index < arguments.length; index += 1) {
    final String argument = arguments[index];
    if (argument == '--run-number' && index + 1 < arguments.length) {
      runNumber = int.tryParse(arguments[++index]);
      continue;
    }
    if (argument == '--tag' && index + 1 < arguments.length) {
      tag = arguments[++index];
      continue;
    }
    stderr.writeln(
      'Usage: dart run tool/resolve_build_version.dart '
      '<--run-number N|--tag vX.Y.Z>',
    );
    exitCode = 2;
    return;
  }

  final Directory appRoot = File.fromUri(Platform.script).parent.parent;
  final String pubspecText = File(
    '${appRoot.path}/pubspec.yaml',
  ).readAsStringSync();
  final String commandHelpText = File(
    '${appRoot.path}/lib/cli/command_help.dart',
  ).readAsStringSync();
  final RegExpMatch? pubspecMatch = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+)\s*$',
    multiLine: true,
  ).firstMatch(pubspecText);
  final RegExpMatch? sourceMatch = RegExp(
    r"const String multiplexorSourceVersion = '(\d+\.\d+\.\d+)';",
  ).firstMatch(commandHelpText);
  if (pubspecMatch == null || sourceMatch == null) {
    stderr.writeln('Could not find both Multiplexor version declarations.');
    exitCode = 2;
    return;
  }
  final String manifestVersion = pubspecMatch.group(1)!;
  final String sourceVersion = sourceMatch.group(1)!;
  if (manifestVersion != sourceVersion) {
    stderr.writeln(
      'Version mismatch: pubspec=$manifestVersion cli=$sourceVersion',
    );
    exitCode = 1;
    return;
  }

  try {
    stdout.writeln(
      resolveBuildVersion(
        sourceVersion: sourceVersion,
        runNumber: runNumber,
        tag: tag,
      ),
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
  }
}
