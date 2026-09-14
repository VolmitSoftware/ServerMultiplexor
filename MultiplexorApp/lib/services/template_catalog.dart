import '../models/template_summary.dart';

sealed class BundledTemplate {
  const BundledTemplate({required this.name, required this.description});

  final String name;
  final String description;

  Map<String, Object?> toMap();
  TemplateSummary get summary;
}

class ServerExampleTemplate extends BundledTemplate {
  const ServerExampleTemplate({
    required super.name,
    required super.description,
    required this.type,
    this.minecraft = '1.21.11',
    this.heap = '2G',
    this.isolated = false,
    this.properties = const <String, String>{},
  });

  final String type;
  final String minecraft;
  final String heap;
  final bool isolated;
  final Map<String, String> properties;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'description': description,
    'kind': 'server',
    'type': type,
    'mc': minecraft,
    'heap': heap,
    'jvm_preset': 'aikar',
    'isolated': isolated,
    'server_properties': properties,
    'dropins': const <String, bool>{'clean': false},
  };

  @override
  TemplateSummary get summary => TemplateSummary(
    name: name,
    description: description,
    type: type,
    minecraft: minecraft,
    bundled: true,
    buildTypes: <String>[type],
  );
}

class NetworkExampleTemplate extends BundledTemplate {
  const NetworkExampleTemplate({
    required super.name,
    required super.description,
    required this.backends,
    this.offline = false,
  });

  final List<ServerExampleTemplate> backends;
  final bool offline;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'description': description,
    'kind': 'network',
    'proxy': <String, Object?>{
      'type': 'velocity',
      'bind': '127.0.0.1',
      'port': 'auto',
      'offline': offline,
      'default': 'lobby',
      'fallback': <String>['survival'],
      'heap': '1G',
      'jvm_preset': 'vanilla',
    },
    'backends': <String, Object?>{
      for (final ServerExampleTemplate backend in backends)
        backend.name: backend.toMap(),
    },
  };

  @override
  TemplateSummary get summary => TemplateSummary(
    name: name,
    description: description,
    kind: 'network',
    type: 'velocity',
    minecraft: backends.first.minecraft,
    bundled: true,
    buildTypes: backends
        .map((ServerExampleTemplate item) => item.type)
        .toSet()
        .toList(),
    backendCount: backends.length,
  );
}

const Map<String, String> _botProperties = <String, String>{
  'server-ip': '127.0.0.1',
  'online-mode': 'false',
  'enforce-secure-profile': 'false',
  'white-list': 'false',
  'spawn-protection': '0',
  'gamemode': 'survival',
  'difficulty': 'peaceful',
  'level-type': 'minecraft:flat',
  'generate-structures': 'false',
  'view-distance': '6',
  'simulation-distance': '4',
  'max-players': '48',
};

const List<BundledTemplate> bundledTemplates = <BundledTemplate>[
  ServerExampleTemplate(
    name: 'paper-dev',
    description:
        'Paper 1.21.11 for local plugin development; shared plugin drop-ins.',
    type: 'paper',
    properties: <String, String>{
      'server-ip': '127.0.0.1',
      'online-mode': 'true',
      'view-distance': '8',
      'simulation-distance': '6',
      'max-players': '20',
    },
  ),
  ServerExampleTemplate(
    name: 'purpur-survival',
    description:
        'Purpur 1.21.11 survival world with normal terrain and online authentication.',
    type: 'purpur',
    properties: <String, String>{
      'server-ip': '127.0.0.1',
      'online-mode': 'true',
      'gamemode': 'survival',
      'difficulty': 'normal',
      'view-distance': '8',
      'simulation-distance': '6',
      'max-players': '20',
    },
  ),
  ServerExampleTemplate(
    name: 'bot-settlement',
    description:
        'Isolated offline Purpur on loopback; start a settlement session to create its fixture and bots.',
    type: 'purpur',
    isolated: true,
    properties: _botProperties,
  ),
  NetworkExampleTemplate(
    name: 'velocity-lobby-survival',
    description:
        'Velocity with a lobby and survival backend on 1.21.11; online authentication, loopback entry.',
    backends: <ServerExampleTemplate>[
      ServerExampleTemplate(
        name: 'lobby',
        description: 'Flat peaceful lobby.',
        type: 'purpur',
        properties: <String, String>{
          'gamemode': 'adventure',
          'difficulty': 'peaceful',
          'level-type': 'minecraft:flat',
          'generate-structures': 'false',
          'view-distance': '6',
          'simulation-distance': '4',
        },
      ),
      ServerExampleTemplate(
        name: 'survival',
        description: 'Normal survival terrain.',
        type: 'purpur',
        properties: <String, String>{
          'gamemode': 'survival',
          'difficulty': 'normal',
          'view-distance': '8',
          'simulation-distance': '6',
        },
      ),
    ],
  ),
  NetworkExampleTemplate(
    name: 'velocity-bot-lab',
    description:
        'Isolated offline Velocity with lobby/survival routes; start a velocity-settlement session to create fixtures and bots.',
    offline: true,
    backends: <ServerExampleTemplate>[
      ServerExampleTemplate(
        name: 'lobby',
        description: 'Isolated flat lobby for bot sessions.',
        type: 'purpur',
        isolated: true,
        properties: _botProperties,
      ),
      ServerExampleTemplate(
        name: 'survival',
        description: 'Isolated flat survival world for settlement sessions.',
        type: 'purpur',
        isolated: true,
        properties: _botProperties,
      ),
    ],
  ),
];
