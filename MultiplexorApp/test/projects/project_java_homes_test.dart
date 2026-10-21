import 'dart:io';

import 'package:multiplexor/services/projects/project_java_homes.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('project-java-homes-');
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  String home(String name, String version, {bool windows = false}) {
    Directory directory = Directory(p.join(fixture.path, name))
      ..createSync(recursive: true);
    Directory(p.join(directory.path, 'bin')).createSync();
    for (String tool in <String>['java', 'javac']) {
      File(
        p.join(directory.path, 'bin', '$tool${windows ? '.exe' : ''}'),
      ).writeAsStringSync('executable');
    }
    File(
      p.join(directory.path, 'release'),
    ).writeAsStringSync('JAVA_VERSION="$version"\nIMPLEMENTOR="Example"\n');
    return directory.resolveSymbolicLinksSync();
  }

  Future<ProjectJavaHomes> capture(
    List<String> homes, {
    Map<String, String> environment = const <String, String>{},
    bool windows = false,
  }) => ProjectJavaHomes.capture(
    discoveredHomes: homes,
    environment: environment,
    windows: windows,
  );

  test('recognizes legacy and current release versions', () async {
    String eight = home('eight', '1.8.0_442');
    String seventeen = home('seventeen', '17.0.15+6');
    String twentyFive = home('twenty-five', '25.0.2');
    String early = home('early', '26-ea');
    expect(
      (await capture(<String>[
        eight,
        seventeen,
        twentyFive,
        early,
      ])).environment,
      <String, String>{
        'JAVA_HOME_8': eight,
        'JAVA_HOME_17': seventeen,
        'JAVA_HOME_25': twentyFive,
        'JAVA_HOME_26': early,
      },
    );
  });

  test(
    'selects duplicate majors by canonical path independently of order',
    () async {
      String first = home('a-jdk', '25.0.1');
      String second = home('z-jdk', '25.0.2');
      ProjectJavaHomes forward = await capture(<String>[first, second]);
      ProjectJavaHomes reversed = await capture(<String>[
        second,
        first,
        second,
      ]);
      expect(forward.environment, <String, String>{'JAVA_HOME_25': first});
      expect(reversed.environment, forward.environment);
      expect(reversed.fingerprint, forward.fingerprint);
    },
  );

  test('current JAVA_HOME takes precedence over discovered homes', () async {
    String discovered = home('a-discovered', '25.0.1');
    String current = home('z-current', '25.0.2');
    expect(
      (await capture(
        <String>[discovered],
        environment: <String, String>{'JAVA_HOME': current},
      )).environment,
      <String, String>{'JAVA_HOME_25': current},
    );
  });

  test('explicit major overrides discovery and current JAVA_HOME', () async {
    String discovered = home('a-discovered', '25.0.1');
    String current = home('b-current', '25.0.2');
    String explicit = home('z-explicit', '25.0.3');
    ProjectJavaHomes selected = await capture(
      <String>[discovered],
      environment: <String, String>{
        'JAVA_HOME': current,
        'JAVA_HOME_25': explicit,
      },
    );
    expect(selected.environment, <String, String>{'JAVA_HOME_25': explicit});
  });

  test('finds explicit homes without platform discovery', () async {
    String eight = home('eight', '1.8.0_442');
    String modern = home('modern', '25');
    expect(
      (await capture(
        <String>[],
        environment: <String, String>{
          'JAVA_HOME': modern,
          'JAVA_HOME_8': eight,
        },
      )).environment,
      <String, String>{'JAVA_HOME_8': eight, 'JAVA_HOME_25': modern},
    );
  });

  test('ignores absent, malformed, and JRE-only discovered homes', () async {
    String missingRelease = home('missing-release', '25');
    File(p.join(missingRelease, 'release')).deleteSync();
    String malformed = home('malformed', 'unknown');
    String unquoted = home('unquoted', '25');
    File(p.join(unquoted, 'release')).writeAsStringSync('JAVA_VERSION=25\n');
    String jre = home('jre', '25');
    File(p.join(jre, 'bin', 'javac')).deleteSync();
    String missingJava = home('missing-java', '25');
    File(p.join(missingJava, 'bin', 'java')).deleteSync();
    expect(
      (await capture(<String>[
        p.join(fixture.path, 'absent'),
        'relative-home',
        missingRelease,
        malformed,
        unquoted,
        jre,
        missingJava,
      ])).environment,
      isEmpty,
    );
  });

  test('invalid explicit overrides are preserved without fallback', () async {
    String available = home('available', '25');
    String wrongVersion = home('wrong-version', '21');
    String jre = home('jre', '25');
    File(p.join(jre, 'bin', 'javac')).deleteSync();
    Set<String> fingerprints = <String>{};
    for (String value in <String>[
      '',
      'relative-home',
      p.join(fixture.path, 'absent'),
      wrongVersion,
      jre,
    ]) {
      ProjectJavaHomes selected = await capture(
        <String>[available],
        environment: <String, String>{'JAVA_HOME_25': value},
      );
      expect(selected.environment, <String, String>{'JAVA_HOME_25': value});
      expect(fingerprints.add(selected.fingerprint), isTrue);
    }
  });

  test(
    'fingerprints selected release identity and explicit overrides',
    () async {
      String selected = home('selected', '25.0.1');
      ProjectJavaHomes original = await capture(<String>[selected]);
      File(
        p.join(selected, 'release'),
      ).writeAsStringSync('JAVA_VERSION="25.0.2"\nIMPLEMENTOR="Example"\n');
      ProjectJavaHomes upgraded = await capture(<String>[selected]);
      expect(upgraded.environment, original.environment);
      expect(upgraded.fingerprint, isNot(original.fingerprint));
      ProjectJavaHomes explicit = await capture(
        <String>[selected],
        environment: <String, String>{'JAVA_HOME_25': selected},
      );
      expect(explicit.environment, upgraded.environment);
      expect(explicit.fingerprint, isNot(upgraded.fingerprint));
      ProjectJavaHomes architectureOverride = await capture(
        <String>[selected],
        environment: <String, String>{'JAVA_HOME_25_arm64': selected},
      );
      expect(architectureOverride.fingerprint, isNot(upgraded.fingerprint));
    },
  );

  test(
    'canonicalizes symlinked homes before choosing and exporting them',
    () async {
      String original = home('original', '25');
      String alias = p.join(fixture.path, 'alias');
      Link(alias).createSync(original);
      ProjectJavaHomes selected = await capture(<String>[alias, original]);
      expect(selected.environment, <String, String>{'JAVA_HOME_25': original});
      expect(
        selected.fingerprint,
        (await capture(<String>[original])).fingerprint,
      );
      expect(
        (await capture(
          <String>[original],
          environment: <String, String>{'JAVA_HOME_25': alias},
        )).environment,
        <String, String>{'JAVA_HOME_25': alias},
      );
    },
    skip: Platform.isWindows,
  );

  test('uses Windows JDK executables for explicitly supplied homes', () async {
    String selected = home('jdk', '25', windows: true);
    expect(
      (await capture(
        <String>[],
        environment: <String, String>{'JAVA_HOME_25': selected},
        windows: true,
      )).environment,
      <String, String>{'JAVA_HOME_25': selected},
    );
  });

  test(
    'uses version metadata from a macOS JDK bundle without release',
    () async {
      String selected = home('sample.jdk/Contents/Home', '8');
      File(p.join(selected, 'release')).deleteSync();
      File plist = File(p.join(p.dirname(selected), 'Info.plist'));
      String metadata = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>JavaVM</key><dict>
<key>JVMVersion</key><string>1.8.0_442</string>
<key>JVMVendor</key><string>Example</string>
</dict></dict></plist>''';
      plist.writeAsStringSync(metadata);
      ProjectJavaHomes original = await capture(<String>[selected]);
      expect(original.environment, <String, String>{'JAVA_HOME_8': selected});
      plist.writeAsStringSync(metadata.replaceFirst('Example', 'Other'));
      ProjectJavaHomes changed = await capture(<String>[selected]);
      expect(changed.environment, original.environment);
      expect(changed.fingerprint, isNot(original.fingerprint));
      File(
        p.join(selected, 'release'),
      ).writeAsStringSync('JAVA_VERSION="unknown"');
      expect((await capture(<String>[selected])).environment, isEmpty);
      File(p.join(selected, 'release')).deleteSync();
      plist.writeAsStringSync('invalid plist');
      expect((await capture(<String>[selected])).environment, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test('reads macOS inventory paths without losing spaces', () {
    expect(
      projectMacJavaHomes('''Matching Java Virtual Machines (2):
    25.0.2 (arm64) "Vendor" - "OpenJDK 25" /Library/Java/Java Virtual Machines/jdk-25/Contents/Home
    1.8.0_442 (arm64) "Vendor" - "JDK 8" /Users/example/Library/Java/jdk-8/Contents/Home
/Library/Java/Java Virtual Machines/jdk-25/Contents/Home
'''),
      <String>[
        '/Library/Java/Java Virtual Machines/jdk-25/Contents/Home',
        '/Users/example/Library/Java/jdk-8/Contents/Home',
      ],
    );
  });
}
