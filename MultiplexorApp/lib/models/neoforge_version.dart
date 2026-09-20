/// NeoForge 20/21 ids omit Minecraft's leading `1.`; their third component is
/// the loader build. Year-based ids include three game components followed by
/// the loader build, including zero for releases such as Minecraft 26.3.
String? minecraftVersionFromNeoForgeLoader(String loaderVersion) {
  final RegExpMatch? match = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:-beta)?$',
  ).firstMatch(loaderVersion.trim());
  if (match == null) return null;
  final int major = int.parse(match[1]!);
  final int minor = int.parse(match[2]!);
  if (major == 20 || major == 21) {
    if (match[4] != null) return null;
    return minor == 0 ? '1.$major' : '1.$major.$minor';
  }
  if (major < 26 || match[4] == null) return null;
  final int patch = int.parse(match[3]!);
  return patch == 0 ? '$major.$minor' : '$major.$minor.$patch';
}
