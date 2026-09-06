import 'build_cache.dart';
import 'server_minecraft_version.dart';

class BuildVersionCatalog {
  BuildVersionCatalog({
    required this.type,
    required this.supported,
    required this.latest,
    required this.cache,
  });

  final String type;
  final List<String> supported;
  final String? latest;
  final List<BuildCacheEntry> cache;

  bool get metadataUnavailable => latest == null;

  List<String> get versions {
    final Set<String> versions = <String>{...supported, ?latest};
    for (final BuildCacheEntry entry in cache) {
      final String? version = inferServerMinecraftVersion(
        serverType: type,
        jarPaths: <String>[entry.jarName],
      );
      if (version != null) versions.add(version);
    }
    final List<String> sorted = versions.toList();
    sorted.sort((String a, String b) {
      final List<int> left = _versionOrder(a);
      final List<int> right = _versionOrder(b);
      for (int i = 0; i < left.length || i < right.length; i++) {
        final int order = (i < right.length ? right[i] : 0).compareTo(
          i < left.length ? left[i] : 0,
        );
        if (order != 0) return order;
      }
      return b.compareTo(a);
    });
    return sorted;
  }
}

List<int> _versionOrder(String version) {
  final RegExpMatch? match = RegExp(
    r'^(\d+)\.(\d+)(?:\.(\d+))?(?:-(pre|rc|snapshot)-?(\d+))?$',
  ).firstMatch(version);
  if (match == null) return const <int>[];
  return <int>[
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3] ?? '0'),
    switch (match[4]) {
      'snapshot' => 0,
      'pre' => 1,
      'rc' => 2,
      _ => 3,
    },
    int.parse(match[5] ?? '0'),
  ];
}
