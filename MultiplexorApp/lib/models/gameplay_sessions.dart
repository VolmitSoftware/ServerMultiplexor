import 'dart:convert';
import 'dart:io';

final class GameplaySessionValidation {
  const GameplaySessionValidation({
    required this.profile,
    required this.playerNames,
    required this.maximumPopulation,
    required this.requiresController,
  });

  final Map<String, Object?> profile;
  final List<String> playerNames;
  final int maximumPopulation;
  final bool requiresController;

  factory GameplaySessionValidation.decode(String text) {
    final Map<String, Object?> data = sessionObject(jsonDecode(text));
    final Object? names = data['playerNames'];
    if (data['status'] != 'passed' ||
        names is! List<Object?> ||
        !names.every((Object? name) => name is String) ||
        data['maximumPopulation'] is! int ||
        data['requiresController'] is! bool) {
      throw const FormatException('Invalid session validation result.');
    }
    return GameplaySessionValidation(
      profile: sessionObject(data['profile']),
      playerNames: names.cast<String>(),
      maximumPopulation: data['maximumPopulation']! as int,
      requiresController: data['requiresController']! as bool,
    );
  }
}

final class GameplaySessionBackend {
  const GameplaySessionBackend({
    required this.alias,
    required this.instance,
    required this.port,
    required this.logPath,
    required this.observerPath,
  });

  final String alias;
  final String instance;
  final int port;
  final String logPath;
  final String observerPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'alias': alias,
    'instance': instance,
    'port': port,
    'logPath': logPath,
    'observerPath': observerPath,
  };

  factory GameplaySessionBackend.fromJson(Map<String, Object?> data) =>
      GameplaySessionBackend(
        alias: data['alias']! as String,
        instance: data['instance']! as String,
        port: data['port']! as int,
        logPath: data['logPath']! as String,
        observerPath: data['observerPath']! as String,
      );
}

final class GameplaySessionTarget {
  const GameplaySessionTarget({
    required this.kind,
    required this.name,
    required this.host,
    required this.port,
    required this.backends,
    this.proxy,
    this.version,
    this.defaultBackend,
    this.proxyLogPath,
    this.observerPath,
  });

  final String kind;
  final String name;
  final String host;
  final int port;
  final List<GameplaySessionBackend> backends;
  final String? proxy;
  final String? version;
  final String? defaultBackend;
  final String? proxyLogPath;
  final String? observerPath;

  List<String> get instances => <String>[
    ...backends.map((GameplaySessionBackend backend) => backend.instance),
    ?proxy,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'host': host,
    'port': port,
    'backends': backends
        .map((GameplaySessionBackend backend) => backend.toJson())
        .toList(),
    if (proxy != null) 'proxy': proxy,
    if (version != null) 'version': version,
    if (defaultBackend != null) 'defaultBackend': defaultBackend,
    if (proxyLogPath != null) 'proxyLogPath': proxyLogPath,
    if (observerPath != null) 'observerPath': observerPath,
  };

  factory GameplaySessionTarget.fromJson(Map<String, Object?> data) =>
      GameplaySessionTarget(
        kind: data['kind']! as String,
        name: data['name']! as String,
        host: data['host']! as String,
        port: data['port']! as int,
        backends: (data['backends']! as List<Object?>)
            .map(
              (Object? backend) =>
                  GameplaySessionBackend.fromJson(sessionObject(backend)),
            )
            .toList(),
        proxy: data['proxy'] as String?,
        version: data['version'] as String?,
        defaultBackend: data['defaultBackend'] as String?,
        proxyLogPath: data['proxyLogPath'] as String?,
        observerPath: data['observerPath'] as String?,
      );
}

Map<String, Object?> sessionObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected a session JSON object.');
  }
  return value;
}

Map<String, Object?> readSessionObject(File file) =>
    sessionObject(jsonDecode(file.readAsStringSync()));

void writeSessionObject(File file, Map<String, Object?> data) {
  file.parent.createSync(recursive: true);
  final File temporary = File('${file.path}.$pid.tmp');
  try {
    temporary.writeAsStringSync('${jsonEncode(data)}\n', flush: true);
    temporary.renameSync(file.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
