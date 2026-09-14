import '../../models/consumer_profile.dart';

class NetworkMember {
  const NetworkMember({
    required this.consumer,
    required this.instance,
    required this.alias,
    required this.port,
  });

  final ConsumerProfile consumer;
  final String instance;
  final String alias;
  final int port;

  String get identity => '${consumer.shortName}/$instance';

  Map<String, Object?> toJson() => <String, Object?>{
    'consumer': consumer.shortName,
    'instance': instance,
    'alias': alias,
    'port': port,
  };

  factory NetworkMember.fromJson(Map<String, Object?> json) {
    final String consumer = json['consumer'] as String;
    return NetworkMember(
      consumer: ConsumerProfile.values.firstWhere(
        (ConsumerProfile profile) => profile.shortName == consumer,
        orElse: () => throw const FormatException('Invalid network consumer'),
      ),
      instance: json['instance'] as String,
      alias: json['alias'] as String,
      port: json['port'] as int,
    );
  }
}

class NetworkDefinition {
  NetworkDefinition({
    required this.name,
    required this.proxy,
    this.bind = '127.0.0.1',
    this.port = 25565,
    this.onlineMode = true,
    required this.defaultServer,
    List<String> fallbackServers = const <String>[],
    required List<NetworkMember> members,
  }) : fallbackServers = List<String>.unmodifiable(fallbackServers),
       members = List<NetworkMember>.unmodifiable(members);

  final String name;
  final String proxy;
  final String bind;
  final int port;
  final bool onlineMode;
  final String defaultServer;
  final List<String> fallbackServers;
  final List<NetworkMember> members;

  List<String> get connectionOrder => <String>[
    defaultServer,
    ...fallbackServers,
  ];

  static bool validName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(name);

  List<String> validate() {
    final List<String> errors = <String>[];
    if (!validName(name)) errors.add('Invalid network name.');
    if (!validName(proxy)) errors.add('Invalid proxy instance name.');
    if (bind != '127.0.0.1' && bind != '0.0.0.0') {
      errors.add('Proxy bind must be 127.0.0.1 or 0.0.0.0.');
    }
    if (!onlineMode && bind != '127.0.0.1') {
      errors.add('Offline networks must bind to 127.0.0.1.');
    }
    if (port < 1 || port > 65535) errors.add('Invalid proxy port.');
    if (members.isEmpty) errors.add('A network needs at least one backend.');
    final Set<String> aliases = <String>{};
    final Set<String> identities = <String>{};
    final Set<int> ports = <int>{port};
    for (final NetworkMember member in members) {
      if (!validName(member.instance)) errors.add('Invalid backend name.');
      if (!validName(member.alias) || member.alias.toLowerCase() == 'try') {
        errors.add('Invalid backend alias: ${member.alias}.');
      }
      if (!aliases.add(member.alias.toLowerCase())) {
        errors.add('Duplicate backend alias: ${member.alias}.');
      }
      if (!identities.add(member.identity.toLowerCase())) {
        errors.add('Duplicate backend: ${member.instance}.');
      }
      if (member.consumer != ConsumerProfile.plugin) {
        errors.add('Networks currently support plugin consumers only.');
      }
      if (member.instance.toLowerCase() == proxy.toLowerCase()) {
        errors.add('The proxy cannot also be a backend.');
      }
      if (member.port < 1 || member.port > 65535) {
        errors.add('Invalid backend port: ${member.instance}.');
      }
      if (!ports.add(member.port)) {
        errors.add('Network ports must be unique: ${member.port}.');
      }
    }
    final Set<String> exactAliases = members
        .map((NetworkMember member) => member.alias)
        .toSet();
    final Set<String> routes = <String>{};
    for (final String alias in connectionOrder) {
      if (!exactAliases.contains(alias)) errors.add('Unknown route: $alias.');
      if (!routes.add(alias)) errors.add('Duplicate route: $alias.');
    }
    return errors;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'proxy': proxy,
    'bind': bind,
    'port': port,
    'onlineMode': onlineMode,
    'defaultServer': defaultServer,
    'fallbackServers': fallbackServers,
    'members': members.map((NetworkMember member) => member.toJson()).toList(),
  };

  factory NetworkDefinition.fromJson(
    Map<String, Object?> json,
  ) => NetworkDefinition(
    name: json['name'] as String,
    proxy: json['proxy'] as String,
    bind: json['bind'] as String,
    port: json['port'] as int,
    onlineMode: json['onlineMode'] as bool,
    defaultServer: json['defaultServer'] as String,
    fallbackServers: (json['fallbackServers'] as List<Object?>).cast<String>(),
    members: (json['members'] as List<Object?>)
        .map(
          (Object? member) =>
              NetworkMember.fromJson(Map<String, Object?>.from(member as Map)),
        )
        .toList(),
  );
}
