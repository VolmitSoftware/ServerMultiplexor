import 'dart:io';

/// Returns explicit Minecraft metadata, otherwise the version in a recognized
/// server jar name. Paths are tried in order and symlink targets take precedence
/// over their aliases. Missing paths can still supply a canonical filename.
///
/// Returns null for custom/hash names and NeoForge's loader-version filenames;
/// loader versions must never become Minecraft version metadata.
String? inferServerMinecraftVersion({
  required String serverType,
  String? minecraft,
  Iterable<String> jarPaths = const <String>[],
}) {
  final String? explicit = minecraft?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final String type = serverType.trim().toLowerCase();
  if (!const <String>{
    'paper',
    'purpur',
    'folia',
    'canvas',
    'leaf',
    'spigot',
    'forge',
    'mohist',
    'fabric',
  }.contains(type)) {
    return null;
  }
  for (final String path in jarPaths) {
    if (path.trim().isEmpty) continue;
    String actualPath = path;
    try {
      actualPath = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      // A cache filename remains useful when its file is not available locally.
    }
    final String filename = actualPath
        .split(RegExp(r'[/\\]'))
        .last
        .toLowerCase();
    if (!filename.endsWith('.jar')) continue;
    final String stem = filename.substring(0, filename.length - 4);
    final String prefix = switch (type) {
      'paper' || 'folia' => '$type-(?:[0-9]{8}-[0-9]{6}-$type-bundler-)?',
      'fabric' => r'fabric-(?:server-mc\.)?',
      _ => '$type-',
    };
    const String version =
        r'(?:1|[2-9]\d)\.\d+(?:\.\d+)?(?:-(?:pre|rc)-?\d+|-snapshot-\d+)?';
    final RegExpMatch? match = RegExp(
      '^$prefix($version)(?:-|\$)',
    ).firstMatch(stem);
    if (match != null) return match.group(1);
  }
  return null;
}
