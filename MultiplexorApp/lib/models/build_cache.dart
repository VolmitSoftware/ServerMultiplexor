/// Cached-build freshness model for the wizard's automatic refresh flow.
///
/// `build cache-info` emits one machine-readable line per cached jar:
/// `<type>\t<jarBasename>\t<ageSeconds>`. The wizard parses those lines,
/// decides whether a create/update should pull a fresh build from upstream,
/// and renders "updated Xh ago" notes instead of asking the user.
library;

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

  /// Whether this jar looks like a build of [version] (filename match, the
  /// same heuristic the native jar-cache lookup uses).
  bool matchesVersion(String version) => jarName.contains(version);
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
  static bool shouldRefresh({required String type, required Duration? cachedAge}) {
    if (cachedAge == null) {
      return true;
    }
    if (expensiveRebuild.contains(type)) {
      return false;
    }
    return cachedAge > ttl;
  }
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
