enum ConsumerProfile {
  plugin('plugin', 'plugin-consumers'),
  forge('forge', 'forge-mod-consumers'),
  fabric('fabric', 'fabric-mod-consumers'),
  neoforge('neoforge', 'neoforge-mod-consumers');

  const ConsumerProfile(this.shortName, this.dirName);

  final String shortName;
  final String dirName;

  static ConsumerProfile? parse(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case 'plugin':
      case 'plugins':
      case 'plugin-consumers':
        return ConsumerProfile.plugin;
      case 'forge':
      case 'forgemod':
      case 'forge-mod':
      case 'forge-mod-consumers':
        return ConsumerProfile.forge;
      case 'fabric':
      case 'fabricmod':
      case 'fabric-mod':
      case 'fabric-mod-consumers':
        return ConsumerProfile.fabric;
      case 'neoforge':
      case 'neo':
      case 'neoforgemod':
      case 'neoforge-mod':
      case 'neoforge-mod-consumers':
        return ConsumerProfile.neoforge;
      default:
        return null;
    }
  }

  static List<String> get names =>
      ConsumerProfile.values.map((e) => e.shortName).toList(growable: false);
}
