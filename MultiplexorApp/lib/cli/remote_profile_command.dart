enum RemoteProfileAction { hostSet, check, start, status, fetch, recover, live }

final class RemoteProfileCommand {
  RemoteProfileCommand._(this.action, this.server, this.options, this.flags);

  final RemoteProfileAction action;
  final String server;
  final Map<String, String> options;
  final Set<String> flags;

  String? option(String key) => options[key];
  bool flag(String key) => flags.contains(key);

  Duration get duration => parseDuration(option('duration') ?? '120s');

  static Duration parseDuration(String value) {
    final RegExpMatch? match = RegExp(r'^(\d+)(s|m|h)$').firstMatch(value);
    if (match == null) {
      throw ArgumentError(
        'Duration must include s, m, or h, for example 120s.',
      );
    }
    final int multiplier = switch (match[2]) {
      'm' => 60,
      'h' => 3600,
      _ => 1,
    };
    final int seconds = int.parse(match[1]!) * multiplier;
    if (seconds < 1 || seconds > 86400) {
      throw ArgumentError('Duration must be between 1s and 24h.');
    }
    return Duration(seconds: seconds);
  }

  factory RemoteProfileCommand.parse(List<String> args) {
    if (args.isEmpty) {
      throw ArgumentError(
        'Usage: remote profile <host-set|check|start|status|fetch|recover|live> <server>',
      );
    }
    final RemoteProfileAction action = switch (args.first) {
      'host-set' => RemoteProfileAction.hostSet,
      'check' => RemoteProfileAction.check,
      'start' => RemoteProfileAction.start,
      'status' => RemoteProfileAction.status,
      'fetch' => RemoteProfileAction.fetch,
      'recover' => RemoteProfileAction.recover,
      'live' => RemoteProfileAction.live,
      _ => throw ArgumentError('Unknown remote profile action: ${args.first}'),
    };
    final Set<String> valueOptions = <String>{
      'profile',
      ...switch (action) {
        RemoteProfileAction.hostSet => <String>{
          'ssh-target',
          'ssh-port',
          'identity-file',
          'known-hosts-file',
        },
        RemoteProfileAction.start => <String>{
          'agent-dir',
          'agent-version',
          'duration',
          'config',
          'session-id',
          'port',
        },
        RemoteProfileAction.fetch => <String>{'output'},
        RemoteProfileAction.live => <String>{'local-port'},
        _ => <String>{},
      },
    };
    final Set<String> booleanOptions = switch (action) {
      RemoteProfileAction.hostSet => <String>{'sudo-docker'},
      RemoteProfileAction.start => <String>{
        'startup',
        'attach',
        'restart',
        'live',
      },
      RemoteProfileAction.fetch => <String>{'open'},
      _ => <String>{},
    };
    final Map<String, String> options = <String, String>{};
    final Set<String> flags = <String>{};
    final List<String> positionals = <String>[];
    for (int index = 1; index < args.length; index++) {
      final String token = args[index];
      if (!token.startsWith('-')) {
        positionals.add(token);
        continue;
      }
      final String name = token.startsWith('--') ? token.substring(2) : token;
      if (options.containsKey(name) || flags.contains(name)) {
        throw ArgumentError('Duplicate option: $token');
      }
      if (booleanOptions.contains(name)) {
        flags.add(name);
      } else if (valueOptions.contains(name)) {
        if (index + 1 == args.length ||
            args[index + 1].startsWith('-') ||
            args[index + 1].trim().isEmpty) {
          throw ArgumentError('$token requires a value.');
        }
        options[name] = args[++index];
      } else {
        throw ArgumentError(
          'Unknown option for remote profile ${args.first}: $token',
        );
      }
    }
    if (positionals.length != 1 || positionals.single.trim().isEmpty) {
      throw ArgumentError('Specify exactly one remote server.');
    }
    if (action == RemoteProfileAction.hostSet &&
        !options.containsKey('ssh-target')) {
      throw ArgumentError(
        'host-set requires --ssh-target <SSH alias|user@host>.',
      );
    }
    if (action == RemoteProfileAction.start &&
        flags.contains('startup') == flags.contains('attach')) {
      throw ArgumentError(
        'start requires exactly one of --startup or --attach.',
      );
    }
    if (flags.contains('attach') && flags.contains('restart')) {
      throw ArgumentError('--restart cannot be used with --attach.');
    }
    if (flags.contains('live') && options.containsKey('duration')) {
      throw ArgumentError(
        '--duration applies to offline recording. Control live recording in JProfiler.',
      );
    }
    if (options.containsKey('agent-dir') &&
        options.containsKey('agent-version')) {
      throw ArgumentError('Use either --agent-dir or --agent-version.');
    }
    if (options.containsKey('session-id') && !options.containsKey('config')) {
      throw ArgumentError('--session-id requires --config.');
    }
    if (options.containsKey('port') && !flags.contains('live')) {
      throw ArgumentError('--port requires --live.');
    }
    for (final String key in <String>[
      'ssh-port',
      'local-port',
      'port',
      'session-id',
    ]) {
      if (!options.containsKey(key)) continue;
      final int? number = int.tryParse(options[key]!);
      if (number == null ||
          number < 1 ||
          (key != 'session-id' && number > 65535)) {
        throw ArgumentError(
          '--$key requires ${key == 'session-id' ? 'a positive integer' : 'an integer from 1 to 65535'}.',
        );
      }
    }
    final RemoteProfileCommand command = RemoteProfileCommand._(
      action,
      positionals.single,
      Map<String, String>.unmodifiable(options),
      Set<String>.unmodifiable(flags),
    );
    if (action == RemoteProfileAction.start) command.duration;
    return command;
  }
}
