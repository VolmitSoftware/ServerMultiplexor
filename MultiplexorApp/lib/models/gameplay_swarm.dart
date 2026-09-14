class GameplaySwarmSettings {
  const GameplaySwarmSettings._({
    required this.profile,
    required this.bots,
    required this.durationSeconds,
    required this.seed,
    required this.joinIntervalMilliseconds,
    required this.radius,
    required this.prefix,
    required this.origin,
    required this.buildArena,
    required this.scatter,
    required this.chat,
    required this.startupTimeoutSeconds,
    required this.connectTimeoutSeconds,
    required this.actionTimeoutSeconds,
    required this.workload,
    required this.bounds,
    required this.goals,
    required this.completion,
  });

  static const List<String> profiles = <String>[
    'idle',
    'wander',
    'redstone',
    'workshop',
    'mixed',
    'stress',
  ];

  static const Set<String> stressActivities = <String>{
    'patrol',
    'explore',
    'mine',
    'build',
    'redstone',
    'farm',
    'craft',
    'storage',
    'chat',
    'idle',
  };

  factory GameplaySwarmSettings.parse({
    required String profile,
    required Map<String, String> options,
    required Set<String> flags,
    required String generatedPrefix,
  }) {
    if (!profiles.contains(profile) &&
        !profile.toLowerCase().endsWith('.json')) {
      throw const FormatException(
        'Choose idle, wander, redstone, workshop, mixed, stress, or a .json plan.',
      );
    }
    int integer(String key, int fallback, int minimum, int maximum) {
      final String raw = options[key] ?? '$fallback';
      final int? value = RegExp(r'^\d+$').hasMatch(raw)
          ? int.tryParse(raw)
          : null;
      if (value == null || value < minimum || value > maximum) {
        throw FormatException('--$key must be between $minimum and $maximum.');
      }
      return value;
    }

    final bool buildArena = flags.contains('build-arena');
    for (final String option in <String>[
      'workload',
      'bounds',
      'goals',
      'completion',
    ]) {
      if (profile != 'stress' && options.containsKey(option)) {
        throw FormatException('--$option requires the stress profile.');
      }
    }
    final String? workload = options['workload'];
    if (workload != null && !workload.toLowerCase().endsWith('.json')) {
      throw const FormatException('--workload must name a .json workload.');
    }
    final GameplaySwarmBounds? bounds = options['bounds'] == null
        ? null
        : GameplaySwarmBounds.parse(options['bounds']!);
    final Map<String, int>? goals = options['goals'] == null
        ? null
        : parseGoals(options['goals']!);
    final String? completion = options['completion'];
    if (completion != null &&
        !const <String>{'duration', 'goals'}.contains(completion)) {
      throw const FormatException('--completion must be duration or goals.');
    }
    if (!profiles.contains(profile) && buildArena) {
      throw const FormatException(
        'Custom plans cannot use --build-arena; prepare the required fixture separately.',
      );
    }
    if ((profile == 'workshop' || profile == 'mixed') && !buildArena) {
      throw FormatException('$profile requires --build-arena.');
    }
    final int? scatter = options.containsKey('scatter')
        ? integer('scatter', 64, 8, 4096)
        : null;
    if (profile == 'stress' && scatter != null) {
      throw const FormatException(
        '--scatter is unavailable for stress; set --bounds to distribute activity.',
      );
    }
    if (buildArena && scatter != null) {
      throw const FormatException(
        '--scatter cannot be combined with --build-arena.',
      );
    }
    final String prefix = options['prefix'] ?? generatedPrefix;
    if (!RegExp(r'^[A-Za-z0-9_]{1,12}$').hasMatch(prefix)) {
      throw const FormatException(
        '--prefix must be 1–12 letters, numbers, or underscores.',
      );
    }
    final String originText = options['origin'] ?? '0,80,0';
    final List<int?> coordinates = originText
        .split(',')
        .map(
          (String part) => RegExp(r'^-?\d+$').hasMatch(part.trim())
              ? int.tryParse(part.trim())
              : null,
        )
        .toList();
    if (coordinates.length != 3 ||
        coordinates.any((int? value) => value == null) ||
        coordinates[0]!.abs() > 29999000 ||
        coordinates[2]!.abs() > 29999000 ||
        coordinates[1]! < -48 ||
        coordinates[1]! > 256) {
      throw const FormatException(
        '--origin must be integer x,y,z; x/z within ±29999000 and y from -48 to 256.',
      );
    }
    if (scatter != null &&
        (coordinates[0]!.abs() + scatter > 29999000 ||
            coordinates[2]!.abs() + scatter > 29999000)) {
      throw const FormatException(
        'The origin and scatter radius exceed the world coordinate bounds.',
      );
    }
    return GameplaySwarmSettings._(
      profile: profile,
      bots: integer('bots', 4, 1, 256),
      durationSeconds: integer('duration', 60, 1, 604800),
      seed: integer('seed', 1, 0, 4294967295),
      joinIntervalMilliseconds: integer('join-interval', 1000, 100, 10000),
      radius: integer('radius', 16, 4, 64),
      prefix: prefix,
      origin: coordinates.map((int? value) => value!).join(','),
      buildArena: buildArena,
      scatter: scatter,
      chat: flags.contains('chat'),
      startupTimeoutSeconds: integer('startup-timeout', 180, 1, 3600),
      connectTimeoutSeconds: integer('connect-timeout', 30, 1, 300),
      actionTimeoutSeconds: integer('action-timeout', 15, 1, 120),
      workload: workload,
      bounds: bounds,
      goals: goals,
      completion: completion,
    );
  }

  final String profile;
  final int bots;
  final int durationSeconds;
  final int seed;
  final int joinIntervalMilliseconds;
  final int radius;
  final String prefix;
  final String origin;
  final bool buildArena;
  final int? scatter;
  final bool chat;
  final int startupTimeoutSeconds;
  final int connectTimeoutSeconds;
  final int actionTimeoutSeconds;
  final String? workload;
  final GameplaySwarmBounds? bounds;
  final Map<String, int>? goals;
  final String? completion;

  static Map<String, int> parseGoals(String text) {
    final Map<String, int> result = <String, int>{};
    for (final String assignment in text.split(',')) {
      final List<String> parts = assignment.trim().split('=');
      final int? count =
          parts.length == 2 && RegExp(r'^\d+$').hasMatch(parts[1])
          ? int.tryParse(parts[1])
          : null;
      if (parts.length != 2 ||
          !stressActivities.contains(parts[0]) ||
          count == null ||
          count < 1 ||
          count > 1000000000 ||
          result.containsKey(parts[0])) {
        throw const FormatException(
          '--goals requires distinct supported activity=count pairs with counts from 1 to 1000000000.',
        );
      }
      result[parts[0]] = count;
    }
    return Map<String, int>.unmodifiable(result);
  }

  String? get goalsArgument => goals?.entries
      .map((MapEntry<String, int> entry) => '${entry.key}=${entry.value}')
      .join(',');

  bool get customPlan => !profiles.contains(profile);
  bool get requiresController =>
      profile == 'stress' || buildArena || scatter != null || customPlan;
  List<String> get workerNames => <String>[
    for (int index = 1; index <= bots; index++)
      '$prefix${index.toString().padLeft(2, '0')}',
  ];
}

class GameplaySwarmBounds {
  const GameplaySwarmBounds._(this.minimum, this.maximum);

  factory GameplaySwarmBounds.parse(String text) {
    final List<String> corners = text.split(':');
    final List<List<int>> parsed = <List<int>>[];
    for (final String corner in corners) {
      final List<int?> values = corner.split(',').map((String value) {
        final String trimmed = value.trim();
        return RegExp(r'^-?\d+$').hasMatch(trimmed)
            ? int.tryParse(trimmed)
            : null;
      }).toList();
      if (values.length != 3 ||
          values.any((int? value) => value == null) ||
          values[0]!.abs() > 29999000 ||
          values[2]!.abs() > 29999000 ||
          values[1]! < -48 ||
          values[1]! > 256) {
        throw const FormatException(
          '--bounds requires minX,minY,minZ:maxX,maxY,maxZ within the world coordinate limits.',
        );
      }
      parsed.add(values.cast<int>());
    }
    if (parsed.length != 2 ||
        List<int>.generate(
          3,
          (int axis) => axis,
        ).any((int axis) => parsed[0][axis] > parsed[1][axis])) {
      throw const FormatException(
        '--bounds minimum coordinates must not exceed maximum coordinates.',
      );
    }
    return GameplaySwarmBounds._(
      List<int>.unmodifiable(parsed[0]),
      List<int>.unmodifiable(parsed[1]),
    );
  }

  final List<int> minimum;
  final List<int> maximum;

  String get argument => '${minimum.join(',')}:${maximum.join(',')}';
}
