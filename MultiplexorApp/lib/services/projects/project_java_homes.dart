import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_files.dart';

const int _gradleMinimumJava = 17;

class ProjectJavaHomes {
  ProjectJavaHomes._(this.environment, this.fingerprint, this._launcher);

  final Map<String, String> environment;
  final String fingerprint;
  final String? _launcher;

  /// Variables for starting a Gradle wrapper. JAVA_HOME is only supplied when
  /// neither JAVA_HOME nor the PATH provides a Java able to run Gradle.
  Map<String, String> get gradleEnvironment => <String, String>{
    ...environment,
    if (_launcher != null) 'JAVA_HOME': _launcher,
  };

  /// Gradle ignores JAVA_HOME_* variables unless they are named explicitly.
  List<String> get gradleArguments => environment.isEmpty
      ? const <String>[]
      : <String>[
          '-Porg.gradle.java.installations.fromEnv=${environment.keys.join(',')}',
        ];

  static Future<ProjectJavaHomes> discover() async {
    List<String> paths = <String>[];
    if (Platform.isMacOS) {
      ProcessResult result = await Process.run(
        '/usr/libexec/java_home',
        <String>['-V'],
      );
      paths.addAll(projectMacJavaHomes('${result.stdout}${result.stderr}'));
      paths.addAll(
        projectHomebrewJavaHomes(const <String>[
          '/opt/homebrew/opt',
          '/usr/local/opt',
        ]),
      );
    } else if (Platform.isLinux && Directory('/usr/lib/jvm').existsSync()) {
      for (FileSystemEntity entry in Directory('/usr/lib/jvm').listSync()) {
        if (Directory(entry.path).existsSync()) paths.add(entry.path);
      }
    }
    return capture(
      discoveredHomes: paths,
      environment: Platform.environment,
      pathJava: await _pathJavaWorks(),
    );
  }

  static Future<bool> _pathJavaWorks() async {
    try {
      ProcessResult result = await Process.run('java', <String>[
        '-version',
      ]).timeout(const Duration(seconds: 15));
      int? major = projectJavaVersionMajor('${result.stderr}${result.stdout}');
      return result.exitCode == 0 &&
          major != null &&
          major >= _gradleMinimumJava;
    } on ProcessException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  static Future<ProjectJavaHomes> capture({
    required Iterable<String> discoveredHomes,
    required Map<String, String> environment,
    bool pathJava = false,
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
    _JavaHome? current = currentPath == null
        ? null
        : await _JavaHome.read(currentPath, windows: useWindows);
    if (current != null) selected[current.major] = current;
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
      (current != null && current.major >= _gradleMinimumJava) ||
              pathJava ||
              majors.isEmpty ||
              majors.last < _gradleMinimumJava
          ? null
          : selected[majors.last]!.path,
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

int? projectJavaVersionMajor(String output) {
  RegExpMatch? match = RegExp(
    r'version "(?:1\.([0-9]+)|([0-9]+))',
  ).firstMatch(output);
  return match == null ? null : int.parse(match.group(1) ?? match.group(2)!);
}

List<String> projectHomebrewJavaHomes(Iterable<String> roots) => <String>[
  for (String root in roots)
    if (Directory(root).existsSync())
      for (Directory entry in Directory(root).listSync().whereType<Directory>())
        if (RegExp(r'^openjdk(@\d+)?$').hasMatch(p.basename(entry.path)))
          if (p.join(entry.path, 'libexec', 'openjdk.jdk', 'Contents', 'Home')
              case String home when Directory(home).existsSync())
            home,
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
