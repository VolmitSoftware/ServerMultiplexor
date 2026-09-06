import 'command_help.dart';

/// Validated arguments shared by the executable and native wizard commands.
class LocalCommand {
  LocalCommand._(this.arguments);

  final List<String> arguments;

  static LocalCommand parse(List<String> input) {
    if (input.isEmpty ||
        isCliHelpRequest(input) ||
        isCliVersionRequest(input)) {
      return LocalCommand._(List<String>.unmodifiable(input));
    }
    final String command = input.first;
    final bool explicitSub =
        command != 'doctor' && input.length > 1 && !input[1].startsWith('-');
    final String requestedSub = explicitSub
        ? input[1]
        : _defaults[command] ?? '';
    final String sub =
        _commandAliases['$command $requestedSub'] ?? requestedSub;
    final bool settings = command == 'runtime' && sub == 'settings';
    final bool explicitAction =
        settings && input.length > 2 && !input[2].startsWith('-');
    final String? action = settings
        ? (explicitAction ? input[2] : 'show')
        : null;
    final String keyPath = '$command $sub${action == null ? '' : ' $action'}';
    if (_internal.contains('$command $sub')) {
      return LocalCommand._(List<String>.unmodifiable(input));
    }
    final CommandHelpGroup? group = commandHelpGroups
        .where((CommandHelpGroup group) => group.command == command)
        .firstOrNull;
    if (group == null) {
      throw FormatException('Unknown command: $command');
    }
    final List<String> forms = group.forms.where((String form) {
      final String first = form.split(' ').first;
      if (settings) {
        return form.startsWith('settings $action ') ||
            form == 'settings $action';
      }
      return command == 'doctor' ||
          first == sub ||
          first.replaceAll(RegExp(r'[<>\[\]]'), '').split('|').contains(sub);
    }).toList();
    if (forms.isEmpty) {
      throw FormatException(
        'Unknown $command command: $sub${action == null ? '' : ' $action'}',
      );
    }
    final Set<String> allowed = <String>{
      for (final String form in forms)
        for (final RegExpMatch match in RegExp(
          r'--([a-z][a-z0-9-]*)',
        ).allMatches(form))
          match.group(1)!,
    };
    final List<String> aliases =
        _positionalOptions['$command $sub'] ?? const <String>[];
    allowed.addAll(aliases);
    final int prefix = 1 + (explicitSub ? 1 : 0) + (explicitAction ? 1 : 0);
    final List<String> positional = <String>[];
    final Map<String, String> named = <String, String>{};
    final List<String> options = <String>[];
    final Set<String> seen = <String>{};
    for (int i = prefix; i < input.length; i++) {
      final String token = input[i];
      if (!token.startsWith('-')) {
        positional.add(token);
        continue;
      }
      if (!token.startsWith('--')) {
        throw FormatException('Unknown option: $token');
      }
      final int equals = token.indexOf('=');
      final String key = token.substring(2, equals < 0 ? null : equals);
      if (!allowed.contains(key)) {
        throw FormatException('Unknown option for $command $sub: --$key');
      }
      if (!seen.add(key) && key != 'artifact') {
        throw FormatException('Option specified more than once: --$key');
      }
      String? value = equals < 0 ? null : token.substring(equals + 1);
      if (_booleanOptions.contains(key)) {
        if (value != null && value != 'true' && value != 'false') {
          throw FormatException('--$key expects true or false');
        }
        if (value != 'false') options.add('--$key');
        continue;
      }
      if (value == null) {
        if (i + 1 >= input.length ||
            (input[i + 1].startsWith('-') &&
                !RegExp(r'^-\d').hasMatch(input[i + 1]))) {
          throw FormatException('Missing value for --$key');
        }
        value = input[++i];
      }
      if (value.trim().isEmpty) {
        throw FormatException('Missing value for --$key');
      }
      if (aliases.contains(key)) {
        named[key] = value;
      } else {
        options.addAll(<String>['--$key', value]);
      }
    }
    if (named.isNotEmpty) {
      if (positional.length + named.length > aliases.length) {
        throw const FormatException(
          'Specify each argument once, as a positional value or a named option',
        );
      }
      final List<String> merged = <String>[];
      int position = 0;
      for (final String alias in aliases) {
        final String? explicit = named[alias];
        if (explicit != null) {
          merged.add(explicit);
        } else if (position < positional.length) {
          merged.add(positional[position++]);
        } else if (named.keys.any(
          (String key) => aliases.indexOf(key) > aliases.indexOf(alias),
        )) {
          throw FormatException('Missing $alias');
        }
      }
      positional
        ..clear()
        ..addAll(merged);
    }
    final int? maximum = _maximumPositionals[keyPath];
    if (maximum != null && positional.length > maximum) {
      throw FormatException(
        'Unexpected arguments for $keyPath: ${positional.skip(maximum).join(' ')}',
      );
    }
    final int minimum = _minimumPositionals[keyPath] ?? 0;
    if (positional.length < minimum) {
      throw FormatException('Missing argument. Usage: $command ${forms.first}');
    }
    // Build's positional Minecraft convenience becomes the canonical option.
    if (command == 'build' &&
        _serverTypes.contains(sub) &&
        positional.isNotEmpty) {
      if (seen.contains('mc') || positional.length != 1) {
        throw const FormatException('Specify one Minecraft version');
      }
      options.addAll(<String>['--mc', positional.removeAt(0)]);
    }
    return LocalCommand._(
      List<String>.unmodifiable(<String>[
        command,
        if (command != 'doctor') sub,
        ?action,
        ...positional,
        ...options,
      ]),
    );
  }
}

const Map<String, String> _defaults = <String, String>{
  'consumer': 'show',
  'instance': 'list',
  'runtime': 'status',
  'build': 'list',
  'repos': 'sync',
  'plugins': 'show-source',
  'mods': 'show-source',
  'config': 'localize',
  'backup': 'list',
  'template': 'list',
  'content': 'list',
  'addons': 'list',
  'gameplay': 'doctor',
};

const Set<String> _internal = <String>{
  'runtime host',
  'runtime restart-worker',
  'plugins watch-daemon',
  'mods watch-daemon',
};

const Set<String> _serverTypes = <String>{
  'paper',
  'purpur',
  'folia',
  'canvas',
  'leaf',
  'spigot',
  'forge',
  'mohist',
  'fabric',
  'neoforge',
};

const Set<String> _booleanOptions = <String>{
  'all',
  'auto-build',
  'clean',
  'everywhere',
  'force',
  'graceful',
  'isolated',
  'no-console',
  'once',
  'promote',
  'cleanup',
  'keep-staging',
  'mod-dropins',
  'plugin-dropins',
  'fix',
  'json',
  'include-logs',
  'sync',
  'none',
  'start',
  'stop-after',
  'prepare',
  'no-viewer',
  'no-op',
};

const Map<String, List<String>> _positionalOptions = <String, List<String>>{
  'server create': <String>['name'],
  'instance create': <String>['name'],
  'instance clone': <String>['source', 'target'],
  'instance delete': <String>['name'],
  'instance reset': <String>['name'],
  'instance activate': <String>['name'],
  'instance path': <String>['name'],
  'instance open': <String>['name'],
  'instance update': <String>['name'],
  'instance safe-update': <String>['name'],
  'instance lock': <String>['name'],
  'instance unlock': <String>['name'],
  'instance locked': <String>['name'],
  'instance isolated': <String>['name', 'value'],
  'instance port': <String>['instance', 'port'],
  'instance motd-style': <String>['target'],
  'runtime start': <String>['instance'],
  'runtime stop': <String>['instance'],
  'runtime restart': <String>['instance'],
  'runtime console': <String>['instance'],
  'runtime status': <String>['instance'],
  'runtime stats': <String>['instance'],
  'build latest': <String>['type'],
  'build versions': <String>['type'],
  'build list-all': <String>['type'],
  'build prune': <String>['type'],
  'build cache-info': <String>['type'],
  'repos sync': <String>['target'],
  'plugins sync': <String>['target'],
  'mods sync': <String>['target'],
  'plugins iris-packs-link': <String>['target'],
  'config status': <String>['target'],
  'config localize': <String>['target'],
};

const Map<String, int> _maximumPositionals = <String, int>{
  'instance list': 0,
  'instance current': 0,
  'instance create': 1,
  'instance clone': 2,
  'instance delete': 1,
  'instance reset': 1,
  'instance activate': 1,
  'instance path': 1,
  'instance open': 1,
  'instance update': 1,
  'instance safe-update': 1,
  'instance delete-all': 0,
  'runtime states': 0,
  'runtime metrics': 0,
  'runtime list': 0,
  'runtime watch': 0,
  'runtime consoles': 0,
  'runtime consoles-lateral': 0,
  'runtime status': 1,
  'runtime start': 1,
  'runtime stop': 1,
  'runtime restart': 1,
  'runtime console': 1,
  'runtime stats': 1,
  'build list': 0,
  'build latest': 1,
  'build versions': 1,
  'build list-all': 1,
  'build cache-info': 1,
  'build prune': 1,
  'consumer list': 0,
  'consumer show': 0,
  'consumer path': 0,
  'consumer use': 1,
  'plugins show-source': 0,
  'mods show-source': 0,
  'doctor ': 0,
  'server create': 1,
  'server create-many': 0,
  'instance locked': 1,
  'instance lock': 1,
  'instance unlock': 1,
  'instance isolated': 2,
  'instance port': 2,
  'instance motd-style': 1,
  'runtime settings show': 0,
  'runtime settings check': 0,
  'runtime settings presets': 0,
  'runtime settings reset': 0,
  'runtime settings set-java': 1,
  'runtime settings set-heap': 1,
  'runtime settings set-preset': 1,
  'runtime settings set-wrap': 1,
  'runtime settings set-log-format': 1,
  'repos sync': 1,
  'plugins sync': 1,
  'plugins copy': 1,
  'plugins watch-start': 0,
  'plugins watch-stop': 0,
  'plugins watch-status': 0,
  'plugins iris-packs-path': 0,
  'plugins iris-packs-link': 1,
  'mods sync': 1,
  'mods copy': 1,
  'mods watch-start': 0,
  'mods watch-stop': 0,
  'mods watch-status': 0,
  'config localize': 1,
  'config status': 1,
  'backup create': 1,
  'backup list': 1,
  'backup restore': 2,
  'backup verify': 2,
  'backup delete': 2,
  'backup prune': 1,
  'template list': 0,
  'template init': 1,
  'template show': 1,
  'template apply': 2,
  'template export': 2,
  'template delete': 1,
  'addons catalog': 0,
  'addons list': 1,
  'addons set': 1,
  'addons update': 1,
  'content install': 1,
  'content list': 0,
  'content update': 1,
  'content remove': 1,
  'content sync': 1,
  'gameplay setup': 0,
  'gameplay doctor': 0,
  'gameplay list': 0,
  'gameplay prepare': 1,
  'gameplay run': 2,
  'build test-latest': 0,
};

const Map<String, String> _commandAliases = <String, String>{
  'consumer current': 'show',
  'consumer set': 'use',
  'consumer root': 'path',
  'runtime console-all': 'consoles',
  'runtime console-lateral': 'consoles-lateral',
};

const Map<String, int> _minimumPositionals = <String, int>{
  'consumer use': 1,
  'server create': 1,
  'instance create': 1,
  'instance clone': 2,
  'instance delete': 1,
  'instance reset': 1,
  'instance activate': 1,
  'instance update': 1,
  'instance safe-update': 1,
  'instance lock': 1,
  'instance unlock': 1,
  'instance bulk': 2,
  'runtime settings set-java': 1,
  'runtime settings set-heap': 1,
  'runtime settings set-preset': 1,
  'runtime settings set-wrap': 1,
  'runtime settings set-log-format': 1,
  'build latest': 1,
  'plugins copy': 1,
  'mods copy': 1,
  'backup restore': 1,
  'backup verify': 1,
  'backup delete': 1,
  'template init': 1,
  'template show': 1,
  'template apply': 2,
  'template export': 2,
  'template delete': 1,
  'content search': 1,
  'content install': 1,
  'content remove': 1,
};
