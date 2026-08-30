/// Session-local command and player completion for consoles that only accept
/// complete command strings (such as Pterodactyl/Wings).
final class MinecraftConsoleCompletion {
  MinecraftConsoleCompletion({Iterable<String> commands = defaultCommands}) {
    for (final String command in commands) {
      _rememberCandidate(_commands, command);
    }
  }

  static const List<String> defaultCommands = <String>[
    'advancement',
    'attribute',
    'ban',
    'ban-ip',
    'banlist',
    'bossbar',
    'clear',
    'clone',
    'damage',
    'data',
    'datapack',
    'debug',
    'defaultgamemode',
    'deop',
    'difficulty',
    'effect',
    'enchant',
    'execute',
    'experience',
    'fill',
    'fillbiome',
    'forceload',
    'function',
    'gamemode',
    'gamerule',
    'give',
    'help',
    'item',
    'jfr',
    'kick',
    'kill',
    'list',
    'locate',
    'loot',
    'me',
    'msg',
    'op',
    'pardon',
    'pardon-ip',
    'particle',
    'perf',
    'place',
    'playsound',
    'plugins',
    'recipe',
    'reload',
    'restart',
    'return',
    'ride',
    'save-all',
    'save-off',
    'save-on',
    'say',
    'schedule',
    'scoreboard',
    'seed',
    'setblock',
    'setidletimeout',
    'setworldspawn',
    'spawnpoint',
    'spectate',
    'spreadplayers',
    'stop',
    'stopsound',
    'summon',
    'tag',
    'team',
    'teammsg',
    'teleport',
    'tell',
    'tellraw',
    'tick',
    'time',
    'title',
    'tm',
    'tp',
    'transfer',
    'trigger',
    'version',
    'whitelist',
    'worldborder',
    'xp',
  ];

  static const List<String> _selectors = <String>[
    '@a',
    '@e',
    '@n',
    '@p',
    '@r',
    '@s',
  ];

  static final RegExp _validCommand = RegExp(r'^[A-Za-z0-9_.:+-]+$');
  static final RegExp _validPlayer = RegExp(r'^[A-Za-z0-9_]{1,16}$');
  static final RegExp _playerList = RegExp(
    r'There are\s+\d+\s+of a max of\s+\d+\s+players online:\s*(.*)$',
    caseSensitive: false,
  );
  static final RegExp _playerJoined = RegExp(
    r'(?:^|\s)([A-Za-z0-9_]{1,16}) joined the game\s*$',
    caseSensitive: false,
  );
  static final RegExp _playerLeft = RegExp(
    r'(?:^|\s)([A-Za-z0-9_]{1,16}) left the game\s*$',
    caseSensitive: false,
  );
  static final RegExp _playerLogin = RegExp(
    r'(?:^|\s)([A-Za-z0-9_]{1,16})\[[^\]]+\] logged in',
    caseSensitive: false,
  );
  static final RegExp _playerUuid = RegExp(
    r'UUID of player ([A-Za-z0-9_]{1,16}) is\b',
    caseSensitive: false,
  );

  final Map<String, String> _commands = <String, String>{};
  final Map<String, String> _players = <String, String>{};

  List<String> get players => _sorted(_players.values);

  /// Learns plugin/mod command roots after the operator successfully uses
  /// them, without persisting command text or arguments.
  void rememberCommand(String input) {
    final String trimmed = input.trimLeft();
    if (trimmed.isEmpty) return;
    String command = trimmed.split(RegExp(r'\s+')).first;
    if (command.startsWith('/')) command = command.substring(1);
    _rememberCandidate(_commands, command);
  }

  /// Updates the current player roster from ordinary Minecraft console lines.
  ///
  /// Wings sends recent log history when a console attaches, so join/leave and
  /// `list` output can seed the roster without injecting hidden commands.
  bool observeOutputLine(String input) {
    final String line = input.trim();
    final RegExpMatch? list = _playerList.firstMatch(line);
    if (list != null) {
      final Map<String, String> replacement = <String, String>{};
      final String names = list.group(1)?.trim() ?? '';
      if (names.isNotEmpty) {
        for (final String value in names.split(',')) {
          final String name = value.trim();
          if (_validPlayer.hasMatch(name)) {
            replacement[name.toLowerCase()] = name;
          }
        }
      }
      if (_sameCandidates(_players, replacement)) return false;
      _players
        ..clear()
        ..addAll(replacement);
      return true;
    }

    final RegExpMatch? left = _playerLeft.firstMatch(line);
    if (left != null) {
      return _players.remove(left.group(1)!.toLowerCase()) != null;
    }

    final RegExpMatch? joined =
        _playerJoined.firstMatch(line) ??
        _playerLogin.firstMatch(line) ??
        _playerUuid.firstMatch(line);
    if (joined == null) return false;
    final String name = joined.group(1)!;
    final String key = name.toLowerCase();
    if (_players[key] == name) return false;
    _players[key] = name;
    return true;
  }

  ConsoleCompletionPlan plan(String input, int cursor) {
    final List<String> characters = input.runes
        .map<String>(String.fromCharCode)
        .toList(growable: false);
    final int safeCursor = cursor.clamp(0, characters.length);
    int start = safeCursor;
    while (start > 0 && !_isWhitespace(characters[start - 1])) {
      start--;
    }
    int end = safeCursor;
    while (end < characters.length && !_isWhitespace(characters[end])) {
      end++;
    }

    final bool commandToken = characters
        .take(start)
        .every((String character) => _isWhitespace(character));
    String prefix = characters.sublist(start, safeCursor).join();
    final bool slash = commandToken && prefix.startsWith('/');
    if (slash) prefix = prefix.substring(1);

    final Iterable<String> candidates = commandToken
        ? _commands.values
        : <String>[..._players.values, ..._selectors];
    final String foldedPrefix = prefix.toLowerCase();
    final List<String> matches = _sorted(
      candidates.where(
        (String candidate) => candidate.toLowerCase().startsWith(foldedPrefix),
      ),
    ).map<String>((String value) => slash ? '/$value' : value).toList();
    final String typedPrefix = slash ? '/$prefix' : prefix;

    return ConsoleCompletionPlan(
      input: input,
      cursor: safeCursor,
      replaceStart: start,
      replaceEnd: end,
      typedPrefix: typedPrefix,
      matches: matches,
      commonPrefix: _commonPrefix(matches),
      commandToken: commandToken,
    );
  }

  static bool _isWhitespace(String character) =>
      RegExp(r'^\s$').hasMatch(character);

  static void _rememberCandidate(
    Map<String, String> destination,
    String candidate,
  ) {
    final String value = candidate.trim();
    if (!_validCommand.hasMatch(value)) return;
    destination[value.toLowerCase()] = value;
  }

  static bool _sameCandidates(
    Map<String, String> left,
    Map<String, String> right,
  ) {
    if (left.length != right.length) return false;
    for (final MapEntry<String, String> entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  static List<String> _sorted(Iterable<String> values) {
    final Map<String, String> unique = <String, String>{};
    for (final String value in values) {
      unique.putIfAbsent(value.toLowerCase(), () => value);
    }
    final List<String> result = unique.values.toList();
    result.sort(
      (String left, String right) =>
          left.toLowerCase().compareTo(right.toLowerCase()),
    );
    return result;
  }

  static String _commonPrefix(List<String> values) {
    if (values.isEmpty) return '';
    final List<String> first = values.first.runes
        .map<String>(String.fromCharCode)
        .toList(growable: false);
    int length = first.length;
    for (final String value in values.skip(1)) {
      final List<String> candidate = value.runes
          .map<String>(String.fromCharCode)
          .toList(growable: false);
      length = length.clamp(0, candidate.length);
      int index = 0;
      while (index < length &&
          first[index].toLowerCase() == candidate[index].toLowerCase()) {
        index++;
      }
      length = index;
      if (length == 0) break;
    }
    return first.take(length).join();
  }
}

final class ConsoleCompletionPlan {
  const ConsoleCompletionPlan({
    required this.input,
    required this.cursor,
    required this.replaceStart,
    required this.replaceEnd,
    required this.typedPrefix,
    required this.matches,
    required this.commonPrefix,
    required this.commandToken,
  });

  final String input;
  final int cursor;
  final int replaceStart;
  final int replaceEnd;
  final String typedPrefix;
  final List<String> matches;
  final String commonPrefix;
  final bool commandToken;

  ConsoleCompletionEdit apply(String candidate, {bool appendSpace = false}) {
    final List<String> characters = input.runes
        .map<String>(String.fromCharCode)
        .toList();
    final List<String> replacement = candidate.runes
        .map<String>(String.fromCharCode)
        .toList();
    if (appendSpace && replaceEnd == characters.length) {
      replacement.add(' ');
    }
    characters.replaceRange(replaceStart, replaceEnd, replacement);
    return ConsoleCompletionEdit(
      input: characters.join(),
      cursor: replaceStart + replacement.length,
    );
  }
}

final class ConsoleCompletionEdit {
  const ConsoleCompletionEdit({required this.input, required this.cursor});

  final String input;
  final int cursor;
}
