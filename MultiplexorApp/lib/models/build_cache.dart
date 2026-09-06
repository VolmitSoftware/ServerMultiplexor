/// Cached-build freshness model for the wizard's automatic refresh flow.
///
/// `build cache-info` emits one machine-readable line per cached jar:
/// `<type>\t<jarBasename>\t<ageSeconds>`. The wizard parses those lines,
/// decides whether a create/update should pull a fresh build from upstream,
/// and renders "updated Xh ago" notes instead of asking the user.
library;

import 'server_minecraft_version.dart';

/// One cached build jar reported by `build cache-info`.
class BuildCacheEntry {
  const BuildCacheEntry({
    required this.type,
    required this.jarName,
    required this.age,
  });

  final String type;
  final String jarName;
  final Duration age;

  /// Parses a single `<type>\t<jarBasename>\t<ageSeconds>` line, or null if
  /// the line is not well-formed.
  static BuildCacheEntry? parse(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final List<String> parts = trimmed.split('\t');
    if (parts.length < 3) {
      return null;
    }
    final int? seconds = int.tryParse(parts[2].trim());
    if (seconds == null || seconds < 0) {
      return null;
    }
    return BuildCacheEntry(
      type: parts[0].trim(),
      jarName: parts[1].trim(),
      age: Duration(seconds: seconds),
    );
  }

  /// Parses full `build cache-info` output, skipping malformed lines.
  static List<BuildCacheEntry> parseAll(String output) {
    return output
        .split('\n')
        .map(parse)
        .whereType<BuildCacheEntry>()
        .toList(growable: false);
  }

  bool matchesVersion(String version) =>
      inferServerMinecraftVersion(
        serverType: type,
        jarPaths: <String>[jarName],
      ) ==
      version;
}

/// Age of the most recently fetched jar in [entries], optionally restricted
/// to jars matching [version]. Null when nothing matches.
Duration? newestCachedAge(List<BuildCacheEntry> entries, {String? version}) {
  Duration? newest;
  for (final BuildCacheEntry entry in entries) {
    if (version != null && !entry.matchesVersion(version)) {
      continue;
    }
    if (newest == null || entry.age < newest) {
      newest = entry.age;
    }
  }
  return newest;
}

/// Decides when the wizard refreshes a platform build from upstream instead
/// of asking the user.
class BuildCachePolicy {
  BuildCachePolicy._();

  /// Cached builds older than this are refreshed automatically on create
  /// and update.
  static const Duration ttl = Duration(hours: 24);

  /// Types whose forced rebuild is expensive (local BuildTools compile takes
  /// many minutes); an existing cache is always used no matter its age.
  static const Set<String> expensiveRebuild = <String>{'spigot'};

  /// True when a create/update should pass `--auto-build` for [type] given
  /// the newest cached age for the requested version ([cachedAge] is null
  /// when nothing is cached).
  static bool shouldRefresh({
    required String type,
    required Duration? cachedAge,
  }) {
    if (cachedAge == null) {
      return true;
    }
    if (expensiveRebuild.contains(type)) {
      return false;
    }
    return cachedAge > ttl;
  }
}

/// Minecraft versions a build attempt should try for one platform, newest
/// first, starting from the resolved [latest].
///
/// Upstream metadata regularly advertises a version before a platform has a
/// downloadable build for it, and version discovery falls back to Mojang's
/// newest release whenever a platform's own API is unreachable. Folia hits
/// both cases routinely because it trails Paper by a release. Rather than
/// hard-failing on the first miss, a pull walks back through [supported]
/// (ascending, as upstream version lists are sorted) until a version yields a
/// build.
List<String> buildVersionCandidates({
  required String latest,
  required List<String> supported,
  int limit = 3,
}) {
  final List<String> candidates = <String>[];

  void add(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty ||
        candidates.contains(trimmed) ||
        candidates.length >= limit) {
      return;
    }
    candidates.add(trimmed);
  }

  add(latest);
  for (final String version in supported.reversed) {
    add(version);
  }
  return List<String>.unmodifiable(candidates);
}

/// One jar sitting in a platform's build directory, as the prune planner
/// sees it.
class CachedBuildJar {
  const CachedBuildJar({
    required this.path,
    required this.name,
    required this.modified,
  });

  final String path;
  final String name;
  final DateTime modified;
}

/// Matches a dotted version token (`26.2`, `1.21.11`, `26.1.2`).
///
/// Anchoring is deliberately absent: legacy bundler jars lead with a date
/// stamp (`paper-20260215-162758-paper-bundler-1.21.10-...`), and a date has
/// no dots, so the first dotted token in the name is still the game version.
final RegExp _versionToken = RegExp(r'\d+\.\d+(?:\.\d+)*');

/// The Minecraft version a cached jar belongs to, or null when the name
/// carries no version at all (`latest.jar`, `BuildTools.jar`).
///
/// Only used to group jars for pruning, so it has to be conservative: an
/// unrecognised name groups under null and is never a prune candidate.
String? buildJarVersionKey(String fileName) {
  final String stem = fileName.toLowerCase().endsWith('.jar')
      ? fileName.substring(0, fileName.length - 4)
      : fileName;
  return _versionToken.firstMatch(stem)?.group(0);
}

/// Jars in one build directory that a newer build has superseded.
///
/// Build caches otherwise grow without bound — every upstream build number
/// leaves another 60-90 MB jar behind forever. Pruning keeps the
/// [keepPerVersion] newest jars *per Minecraft version*, so the build-number
/// churn goes away while switching back to an older game version still hits
/// the cache instead of re-downloading (or, for spigot, re-compiling).
///
/// Two things are never returned: anything in [keepPaths] (an instance still
/// launches from it) and anything [buildJarVersionKey] cannot place.
List<CachedBuildJar> planBuildPrune({
  required List<CachedBuildJar> jars,
  Set<String> keepPaths = const <String>{},
  int keepPerVersion = 1,
}) {
  final Map<String, List<CachedBuildJar>> byVersion =
      <String, List<CachedBuildJar>>{};
  for (final CachedBuildJar jar in jars) {
    final String? version = buildJarVersionKey(jar.name);
    if (version == null) {
      continue;
    }
    byVersion.putIfAbsent(version, () => <CachedBuildJar>[]).add(jar);
  }

  final List<CachedBuildJar> stale = <CachedBuildJar>[];
  for (final List<CachedBuildJar> group in byVersion.values) {
    if (group.length <= keepPerVersion) {
      continue;
    }
    // Newest first; name breaks mtime ties so the result is deterministic.
    group.sort((CachedBuildJar a, CachedBuildJar b) {
      final int byDate = b.modified.compareTo(a.modified);
      return byDate != 0 ? byDate : a.name.compareTo(b.name);
    });
    for (int i = keepPerVersion; i < group.length; i++) {
      if (!keepPaths.contains(group[i].path)) {
        stale.add(group[i]);
      }
    }
  }

  stale.sort((CachedBuildJar a, CachedBuildJar b) => a.path.compareTo(b.path));
  return List<CachedBuildJar>.unmodifiable(stale);
}

/// Human phrasing for a cached-build age: `never`, `just now`, `12m ago`,
/// `3h ago`, `2d ago`.
String formatBuildAge(Duration? age) {
  if (age == null) {
    return 'never';
  }
  if (age.inMinutes < 1) {
    return 'just now';
  }
  if (age.inHours < 1) {
    return '${age.inMinutes}m ago';
  }
  if (age.inDays < 1) {
    return '${age.inHours}h ago';
  }
  return '${age.inDays}d ago';
}

/// Compact age token for status footers: `—`, `now`, `12m`, `3h`, `4d`.
String formatBuildAgeShort(Duration? age) {
  if (age == null) {
    return '—';
  }
  if (age.inMinutes < 1) {
    return 'now';
  }
  if (age.inHours < 1) {
    return '${age.inMinutes}m';
  }
  if (age.inDays < 1) {
    return '${age.inHours}h';
  }
  return '${age.inDays}d';
}
