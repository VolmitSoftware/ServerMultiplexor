import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_files.dart';

class ProjectJavaHomes {
  ProjectJavaHomes._(this.environment, this.fingerprint);

  final Map<String, String> environment;
  final String fingerprint;

  static Future<ProjectJavaHomes> capture({
    required Iterable<String> discoveredHomes,
    required Map<String, String> environment,
    bool? windows,
  }) async {
    bool useWindows = windows ?? Platform.isWindows;
    Map<String, _JavaHome> discovered = <String, _JavaHome>{};
    for (String path in discoveredHomes) {
      _JavaHome? home = await _JavaHome.read(path, windows: useWindows);
      if (home != null) discovered[home.path] = home;
    }
    List<String> paths = discovered.keys.toList()..sort();
    Map<int, _JavaHome> selected = <int, _JavaHome>{};
    for (String path in paths) {
      _JavaHome home = discovered[path]!;
      selected.putIfAbsent(home.major, () => home);
    }
    String? currentPath = environment['JAVA_HOME'];
    if (currentPath != null) {
      _JavaHome? current = await _JavaHome.read(
        currentPath,
        windows: useWindows,
      );
      if (current != null) selected[current.major] = current;
    }
    List<String> overrideKeys =
        environment.keys
            .where((String key) => key.startsWith('JAVA_HOME_'))
            .toList()
          ..sort();
    for (String key in overrideKeys) {
      RegExpMatch? match = RegExp(r'^JAVA_HOME_([1-9][0-9]*)$').firstMatch(key);
      if (match == null) continue;
      int? major = int.tryParse(match.group(1)!);
      if (major == null) continue;
      selected.remove(major);
      _JavaHome? home = await _JavaHome.read(
        environment[key]!,
        windows: useWindows,
      );
      if (home?.major == major) selected[major] = home!;
    }
    List<int> majors = selected.keys.toList()..sort();
    return ProjectJavaHomes._(
      Map<String, String>.unmodifiable(<String, String>{
        for (int major in majors) 'JAVA_HOME_$major': selected[major]!.path,
        for (String key in overrideKeys) key: environment[key]!,
      }),
      projectDigest(<String, Object?>{
        'homes': <String, Object?>{
          for (int major in majors)
            '$major': <String, String>{
              'path': selected[major]!.path,
              'release': selected[major]!.release,
            },
        },
        'overrides': <String, String>{
          for (String key in overrideKeys) key: environment[key]!,
        },
      }),
    );
  }
}

List<String> projectMacJavaHomes(String listing) => <String>[
  for (String line in listing.split('\n'))
    if (RegExp(
          r'^\s+\S+\s+\([^)]*\)\s+"[^"]*"\s+-\s+"[^"]*"\s+(/.+?)\s*$',
        ).firstMatch(line)
        case RegExpMatch match)
      match.group(1)!,
];

class _JavaHome {
  _JavaHome(this.path, this.major, this.release);

  final String path;
  final int major;
  final String release;

  static Future<_JavaHome?> read(String path, {required bool windows}) async {
    if (!p.isAbsolute(path)) return null;
    try {
      String canonical = Directory(path).resolveSymbolicLinksSync();
      String suffix = windows ? '.exe' : '';
      if (!File(p.join(canonical, 'bin', 'java$suffix')).existsSync() ||
          !File(p.join(canonical, 'bin', 'javac$suffix')).existsSync()) {
        return null;
      }
      File releaseFile = File(p.join(canonical, 'release'));
      String release;
      String? versionText;
      if (releaseFile.existsSync()) {
        release = releaseFile.readAsStringSync();
        versionText = RegExp(
          r'^JAVA_VERSION="([^"\r\n]+)"\s*$',
          multiLine: true,
        ).firstMatch(release)?.group(1);
      } else {
        if (windows ||
            !Platform.isMacOS ||
            p.basename(canonical) != 'Home' ||
            p.basename(p.dirname(canonical)) != 'Contents') {
          return null;
        }
        File plist = File(p.join(p.dirname(canonical), 'Info.plist'));
        if (!plist.existsSync()) return null;
        versionText = await _bundleVersion(plist);
        release = 'Info.plist:${projectDigest(plist.readAsBytesSync())}';
      }
      if (versionText == null) return null;
      RegExpMatch? version = RegExp(
        r'^(?:1\.([0-9]+)|([0-9]+))(?:[._+\-][0-9A-Za-z._+\-]+)?$',
      ).firstMatch(versionText);
      if (version == null) return null;
      int? major = int.tryParse(version.group(1) ?? version.group(2)!);
      if (major == null || major <= 0) return null;
      return _JavaHome(canonical, major, release);
    } on FileSystemException {
      return null;
    } on ProcessException {
      return null;
    }
  }

  static Future<String?> _bundleVersion(File plist) async {
    Process process = await Process.start('/usr/bin/plutil', <String>[
      '-extract',
      'JavaVM.JVMVersion',
      'raw',
      '-o',
      '-',
      plist.path,
    ]);
    try {
      List<Object?> result = await Future.wait<Object?>(<Future<Object?>>[
        process.exitCode,
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
        process.stderr.drain<void>(),
      ]).timeout(const Duration(seconds: 5));
      return result[0] == 0 ? (result[1] as String).trim() : null;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return null;
    }
  }
}
