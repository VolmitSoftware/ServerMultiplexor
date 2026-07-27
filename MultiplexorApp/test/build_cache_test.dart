import 'package:multiplexor/models/build_cache.dart';
import 'package:test/test.dart';

void main() {
  group('BuildCacheEntry.parse', () {
    test('parses a well-formed cache-info line', () {
      final BuildCacheEntry? entry = BuildCacheEntry.parse(
        'paper\tpaper-1.21.11-123.jar\t7200',
      );
      expect(entry, isNotNull);
      expect(entry!.type, 'paper');
      expect(entry.jarName, 'paper-1.21.11-123.jar');
      expect(entry.age, const Duration(seconds: 7200));
    });

    test('returns null for blank lines', () {
      expect(BuildCacheEntry.parse(''), isNull);
      expect(BuildCacheEntry.parse('   '), isNull);
    });

    test('returns null for lines with too few fields', () {
      expect(BuildCacheEntry.parse('paper\tpaper-1.21.11.jar'), isNull);
    });

    test('returns null when age is not an integer', () {
      expect(BuildCacheEntry.parse('paper\tpaper-1.21.11.jar\tsoon'), isNull);
    });

    test('returns null for negative age', () {
      expect(BuildCacheEntry.parse('paper\tpaper-1.21.11.jar\t-5'), isNull);
    });
  });

  group('BuildCacheEntry.parseAll', () {
    test('parses multiple lines and skips malformed ones', () {
      const String output = '''
paper\tpaper-1.21.11-123.jar\t7200
garbage line
purpur\tpurpur-1.21.11-2233.jar\t90000
''';
      final List<BuildCacheEntry> entries = BuildCacheEntry.parseAll(output);
      expect(entries, hasLength(2));
      expect(entries[0].type, 'paper');
      expect(entries[1].type, 'purpur');
    });

    test('returns empty list for empty output', () {
      expect(BuildCacheEntry.parseAll(''), isEmpty);
    });
  });

  group('buildJarVersionKey', () {
    test('reads the version out of a normal build jar', () {
      expect(buildJarVersionKey('paper-26.2-71.jar'), '26.2');
      expect(buildJarVersionKey('purpur-26.1.2-2591.jar'), '26.1.2');
      expect(buildJarVersionKey('leaf-1.21.8-106.jar'), '1.21.8');
    });

    test('reads the version out of a build-less spigot jar', () {
      expect(buildJarVersionKey('spigot-26.2.jar'), '26.2');
    });

    test('skips a leading date stamp in legacy bundler names', () {
      expect(
        buildJarVersionKey(
          'paper-20260215-162758-paper-bundler-1.21.10-R0.1-SNAPSHOT-mojmap.jar',
        ),
        '1.21.10',
      );
      expect(
        buildJarVersionKey(
          'folia-20260215-163543-folia-server-1.21.11-R0.1-SNAPSHOT.jar',
        ),
        '1.21.11',
      );
    });

    test('reads the game version, not the loader version, off an installer', () {
      expect(buildJarVersionKey('forge-26.2-65.0.1-installer.jar'), '26.2');
      expect(
        buildJarVersionKey('fabric-26.2-loader.0.19.3-installer.1.1.1.jar'),
        '26.2',
      );
    });

    test('returns null when no version token is present', () {
      expect(buildJarVersionKey('latest.jar'), isNull);
      expect(buildJarVersionKey('BuildTools.jar'), isNull);
    });
  });

  group('planBuildPrune', () {
    CachedBuildJar jar(String name, int day) => CachedBuildJar(
      path: '/builds/paper/$name',
      name: name,
      modified: DateTime.utc(2026, 7, day),
    );

    test('keeps only the newest jar of each version', () {
      final List<CachedBuildJar> stale = planBuildPrune(
        jars: <CachedBuildJar>[
          jar('paper-26.2-46.jar', 3),
          jar('paper-26.2-71.jar', 25),
          jar('paper-26.2-62.jar', 20),
        ],
      );
      expect(
        stale.map((CachedBuildJar j) => j.name),
        <String>['paper-26.2-46.jar', 'paper-26.2-62.jar'],
      );
    });

    test('never prunes across Minecraft versions', () {
      final List<CachedBuildJar> stale = planBuildPrune(
        jars: <CachedBuildJar>[
          jar('paper-26.2-71.jar', 25),
          jar('paper-26.1.2-69.jar', 9),
          jar('paper-1.21.11-69.jar', 9),
        ],
      );
      expect(stale, isEmpty);
    });

    test('keeps a jar an instance still points at', () {
      final List<CachedBuildJar> stale = planBuildPrune(
        jars: <CachedBuildJar>[
          jar('leaf-26.2-37.jar', 25),
          jar('leaf-26.2-33.jar', 20),
          jar('leaf-26.2-25.jar', 15),
        ],
        keepPaths: <String>{'/builds/paper/leaf-26.2-33.jar'},
      );
      expect(
        stale.map((CachedBuildJar j) => j.name),
        <String>['leaf-26.2-25.jar'],
      );
    });

    test('never prunes latest.jar or an unversioned file', () {
      final List<CachedBuildJar> stale = planBuildPrune(
        jars: <CachedBuildJar>[
          jar('latest.jar', 1),
          jar('BuildTools.jar', 1),
          jar('paper-26.2-71.jar', 25),
        ],
      );
      expect(stale, isEmpty);
    });

    test('honours a larger keepPerVersion', () {
      final List<CachedBuildJar> stale = planBuildPrune(
        jars: <CachedBuildJar>[
          jar('paper-26.2-46.jar', 3),
          jar('paper-26.2-71.jar', 25),
          jar('paper-26.2-62.jar', 20),
        ],
        keepPerVersion: 2,
      );
      expect(
        stale.map((CachedBuildJar j) => j.name),
        <String>['paper-26.2-46.jar'],
      );
    });

    test('returns nothing for an empty or single-jar cache', () {
      expect(planBuildPrune(jars: const <CachedBuildJar>[]), isEmpty);
      expect(
        planBuildPrune(jars: <CachedBuildJar>[jar('paper-26.2-71.jar', 25)]),
        isEmpty,
      );
    });
  });

  group('BuildCacheEntry.matchesVersion', () {
    const BuildCacheEntry entry = BuildCacheEntry(
      type: 'paper',
      jarName: 'paper-1.21.11-123.jar',
      age: Duration(hours: 2),
    );

    test('matches when the jar name contains the version', () {
      expect(entry.matchesVersion('1.21.11'), isTrue);
    });

    test('does not match a different version', () {
      expect(entry.matchesVersion('1.20.4'), isFalse);
    });
  });

  group('newestCachedAge', () {
    final List<BuildCacheEntry> entries = <BuildCacheEntry>[
      const BuildCacheEntry(
        type: 'paper',
        jarName: 'paper-1.21.11-123.jar',
        age: Duration(hours: 2),
      ),
      const BuildCacheEntry(
        type: 'paper',
        jarName: 'paper-1.21.11-100.jar',
        age: Duration(days: 3),
      ),
      const BuildCacheEntry(
        type: 'paper',
        jarName: 'paper-1.20.4-99.jar',
        age: Duration(minutes: 5),
      ),
    ];

    test('returns the newest age across all entries when version is null', () {
      expect(newestCachedAge(entries), const Duration(minutes: 5));
    });

    test('returns the newest age among entries matching the version', () {
      expect(
        newestCachedAge(entries, version: '1.21.11'),
        const Duration(hours: 2),
      );
    });

    test('returns null when nothing matches the version', () {
      expect(newestCachedAge(entries, version: '1.19.2'), isNull);
    });

    test('returns null for an empty list', () {
      expect(newestCachedAge(const <BuildCacheEntry>[]), isNull);
    });
  });

  group('BuildCachePolicy.shouldRefresh', () {
    test('refreshes when nothing is cached', () {
      expect(
        BuildCachePolicy.shouldRefresh(type: 'paper', cachedAge: null),
        isTrue,
      );
    });

    test('uses the cache when it is fresh', () {
      expect(
        BuildCachePolicy.shouldRefresh(
          type: 'paper',
          cachedAge: const Duration(hours: 2),
        ),
        isFalse,
      );
    });

    test('refreshes when the cache is older than the TTL', () {
      expect(
        BuildCachePolicy.shouldRefresh(
          type: 'paper',
          cachedAge: const Duration(hours: 25),
        ),
        isTrue,
      );
    });

    test('treats exactly-TTL age as fresh', () {
      expect(
        BuildCachePolicy.shouldRefresh(
          type: 'paper',
          cachedAge: BuildCachePolicy.ttl,
        ),
        isFalse,
      );
    });

    test('never forces a rebuild for spigot when a cache exists', () {
      expect(
        BuildCachePolicy.shouldRefresh(
          type: 'spigot',
          cachedAge: const Duration(days: 30),
        ),
        isFalse,
      );
    });

    test('still refreshes spigot when nothing is cached', () {
      expect(
        BuildCachePolicy.shouldRefresh(type: 'spigot', cachedAge: null),
        isTrue,
      );
    });
  });

  group('formatBuildAge', () {
    test('formats null as never', () {
      expect(formatBuildAge(null), 'never');
    });

    test('formats sub-minute ages as just now', () {
      expect(formatBuildAge(const Duration(seconds: 20)), 'just now');
    });

    test('formats minutes', () {
      expect(formatBuildAge(const Duration(minutes: 12)), '12m ago');
    });

    test('formats hours', () {
      expect(formatBuildAge(const Duration(hours: 3, minutes: 40)), '3h ago');
    });

    test('formats days', () {
      expect(formatBuildAge(const Duration(days: 2, hours: 3)), '2d ago');
    });
  });

  group('formatBuildAgeShort', () {
    test('formats null as an em dash', () {
      expect(formatBuildAgeShort(null), '—');
    });

    test('formats sub-minute ages as now', () {
      expect(formatBuildAgeShort(const Duration(seconds: 5)), 'now');
    });

    test('formats minutes, hours, and days compactly', () {
      expect(formatBuildAgeShort(const Duration(minutes: 12)), '12m');
      expect(formatBuildAgeShort(const Duration(hours: 3)), '3h');
      expect(formatBuildAgeShort(const Duration(days: 4)), '4d');
    });
  });

  group('buildVersionCandidates', () {
    test('puts the resolved latest version first', () {
      final List<String> candidates = buildVersionCandidates(
        latest: '26.1.2',
        supported: const <String>['1.21.8', '1.21.11', '26.1.2'],
      );
      expect(candidates.first, '26.1.2');
    });

    test('falls back to older supported versions, newest first', () {
      final List<String> candidates = buildVersionCandidates(
        latest: '26.1.2',
        supported: const <String>['1.21.8', '1.21.11', '26.1.2'],
      );
      expect(candidates, <String>['26.1.2', '1.21.11', '1.21.8']);
    });

    test(
      'keeps a latest version the platform does not list as the first try',
      () {
        // Folia lags Paper: when version discovery falls back to Mojang's
        // latest release, the platform has no build for it at all.
        final List<String> candidates = buildVersionCandidates(
          latest: '26.2',
          supported: const <String>['1.21.11', '26.1.2'],
        );
        expect(candidates, <String>['26.2', '26.1.2', '1.21.11']);
      },
    );

    test('caps the candidate list at the requested limit', () {
      final List<String> candidates = buildVersionCandidates(
        latest: '26.2',
        supported: const <String>['1.20.6', '1.21.8', '1.21.11', '26.1.2'],
        limit: 2,
      );
      expect(candidates, <String>['26.2', '26.1.2']);
    });

    test('returns just the latest version when nothing else is supported', () {
      expect(
        buildVersionCandidates(latest: '26.2', supported: const <String>[]),
        <String>['26.2'],
      );
    });

    test('drops blank entries and duplicates', () {
      final List<String> candidates = buildVersionCandidates(
        latest: '26.1.2',
        supported: const <String>['', '1.21.11', '26.1.2', '1.21.11'],
      );
      expect(candidates, <String>['26.1.2', '1.21.11']);
    });
  });
}
