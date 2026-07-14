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
}
