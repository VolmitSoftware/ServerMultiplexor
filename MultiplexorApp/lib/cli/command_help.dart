import 'dart:io';

const String multiplexorVersion = '0.2.0';

class CommandHelpGroup {
  const CommandHelpGroup(this.command, this.forms);

  final String command;
  final List<String> forms;
}

const List<CommandHelpGroup> commandHelpGroups = <CommandHelpGroup>[
  CommandHelpGroup('consumer', <String>[
    'list',
    'show',
    'use <plugin|forge|fabric|neoforge>',
    'path',
  ]),
  CommandHelpGroup('instance', <String>[
    'list',
    'current',
    'create <name>',
    'clone <source> <target>',
    'activate <name>',
    'path [name]',
    'open [name]',
    'update <name> [--mc <version>] [--jar <path>] [--type <type>] [--auto-build]',
    'safe-update <name> [--mc <version>] [--jar <path>] [--type <type>] [--auto-build] [--promote] [--cleanup] [--timeout <seconds>]',
    'isolated [name] [true|false]',
    'lock <name> [--pin <digits>]',
    'unlock <name> [--pin <digits>]',
    'locked [name]',
    'port [instance] [port]',
    'motd-style [name]',
    'reset <name>',
    'delete <name>',
    'delete-all [--everywhere] [--force]',
  ]),
  CommandHelpGroup('server', <String>[
    'create <name> --type <type> [--mc <version>] [--loader <version>] [--installer <version>] [--auto-build] [--isolated]',
    'create <name> --jar <path> [--type label] [--isolated]',
    'create-many --types <a,b,c> [--prefix N] [--mc <v>] [--auto-build] [--isolated]',
  ]),
  CommandHelpGroup('runtime', <String>[
    'start [instance] [--instance <name>] [--no-console]',
    'console [instance] [--instance <name>]',
    'consoles',
    'consoles-lateral',
    'stop [instance] [--graceful]',
    'restart [instance] [--no-console]',
    'status [instance]',
    'stats [instance]',
    'states',
    'metrics',
    'list',
    'settings <show|presets|set-heap|set-preset|set-wrap|set-log-format|reset>',
  ]),
  CommandHelpGroup('build', <String>[
    '<paper|purpur|folia|canvas|leaf|spigot|forge|fabric|neoforge> [--mc <version>] [--loader <version>] [--installer <version>]',
    'latest <type>',
    'versions [type]',
    'cache-info [type] [--mc <version>]',
    'list',
    'list-all [type]',
    'test-latest [--spigot-mc <version>]',
  ]),
  CommandHelpGroup('repos', <String>['sync [all|paper|purpur|folia|canvas|leaf]']),
  CommandHelpGroup('plugins', <String>[
    'show-source',
    'sync [instance|--all] [--clean]',
    'watch-status',
    'watch-start',
    'watch-stop',
    'iris-packs-path',
    'iris-packs-link [instance|--all]',
  ]),
  CommandHelpGroup('mods', <String>[
    'show-source',
    'sync [instance|--all] [--clean]',
    'watch-status',
    'watch-start',
    'watch-stop',
  ]),
  CommandHelpGroup('config', <String>[
    'status [instance]',
    'localize [instance|--all]',
  ]),
  CommandHelpGroup('backup', <String>[
    'create [instance] [--label <label>] [--include-logs]',
    'list [instance|--all]',
    'restore [instance] <backup-id>',
    'verify [instance] <backup-id>',
    'delete [instance] <backup-id>',
    'prune [instance] [--keep <n>]',
  ]),
  CommandHelpGroup('template', <String>[
    'list',
    'init <name> [--type <type>] [--mc <version>] [--heap <size>] [--preset <name>]',
    'show <name>',
    'apply <template> <instance> [--auto-build] [--sync]',
    'export <instance> <template>',
    'delete <name>',
  ]),
  CommandHelpGroup('content', <String>[
    'search <query>',
    'install <modrinth-slug|url> [--mc <version>] [--loader <loader>] [--name <alias>] [--sync]',
    'list',
    'update [name|--all] [--sync]',
    'remove <name>',
    'sync [instance|--all] [--clean]',
  ]),
  CommandHelpGroup('doctor', <String>['[--fix] [--json]']),
];

bool isCliVersionRequest(List<String> args) {
  return args.length == 1 &&
      (args.first == 'version' ||
          args.first == '--version' ||
          args.first == '-V');
}

bool isCliHelpRequest(List<String> args) {
  if (args.isEmpty) {
    return false;
  }
  if (_isHelpToken(args.first)) {
    return true;
  }
  return args.skip(1).any(_isHelpToken);
}

int printCliHelpForArgs(
  List<String> args, {
  void Function(String line)? write,
  void Function(String line)? error,
}) {
  final void Function(String line) out =
      write ?? (String line) => stdout.writeln(line);
  final void Function(String line) err =
      error ?? (String line) => stderr.writeln(line);
  final topic = _helpTopicFromArgs(args);
  if (topic == null) {
    writeGlobalHelp(out);
    return 0;
  }
  final group = _findGroup(topic);
  if (group == null) {
    err('[ERROR] Unknown help topic: $topic');
    writeAvailableHelpTopics(out);
    return 2;
  }
  writeCommandHelp(group, out);
  return 0;
}

void printCliVersion({void Function(String line)? write}) {
  final void Function(String line) out =
      write ?? (String line) => stdout.writeln(line);
  out('Multiplexor CLI v$multiplexorVersion');
  out('Minecraft server profile manager');
}

void writeGlobalHelp(void Function(String line) write) {
  write('Multiplexor');
  write('Minecraft server workspace manager');
  write('');

  _writeHelpSection(write, 'Usage');
  _writeHelpCommand(write, './start.sh', 'open the interactive wizard');
  _writeHelpCommand(write, './start.sh <command>', 'run a direct command');
  _writeHelpCommand(
    write,
    './start.sh --consumer <profile> <command>',
    'target plugin, forge, fabric, or neoforge',
  );
  write('');

  _writeHelpSection(write, 'Common Workflows');
  _writeHelpCommand(
    write,
    './start.sh server create demo --type purpur --auto-build',
    'create a latest-upstream Purpur server',
  );
  _writeHelpCommand(
    write,
    './start.sh runtime start demo',
    'start and attach to a server console',
  );
  _writeHelpCommand(
    write,
    './start.sh plugins sync --all',
    'copy plugin drop-ins to every plugin instance',
  );
  _writeHelpCommand(
    write,
    './start.sh backup create demo --label before-change',
    'create a restore point for an instance',
  );
  _writeHelpCommand(
    write,
    './start.sh doctor',
    'check local tools, workspace state, and instance metadata',
  );
  write('');

  _writeHelpSection(write, 'Commands');
  for (final group in commandHelpGroups) {
    _writeHelpGroup(write, group);
  }
  write('');

  _writeHelpSection(write, 'Global Flags');
  _writeHelpCommand(
    write,
    '--consumer <profile>',
    'temporary profile override',
  );
  _writeHelpCommand(write, '--root <path>', 'use a different workspace root');
  _writeHelpCommand(write, '--verbose', 'print debug argument normalization');
  write('');
  write('Run ./start.sh help <command> for focused command help.');
}

void writeCommandHelp(
  CommandHelpGroup group,
  void Function(String line) write,
) {
  write('Multiplexor ${group.command}');
  write('');
  _writeHelpSection(write, 'Usage');
  for (final form in group.forms) {
    write('  ./start.sh ${group.command} $form');
  }
  write('');
  write('Run ./start.sh help for the full command list.');
}

void writeAvailableHelpTopics(void Function(String line) write) {
  write('Available help topics:');
  write('  ${commandHelpGroups.map((group) => group.command).join(', ')}');
}

bool _isHelpToken(String token) {
  return token == 'help' || token == '--help' || token == '-h';
}

String? _helpTopicFromArgs(List<String> args) {
  if (args.isEmpty) {
    return null;
  }
  if (_isHelpToken(args.first)) {
    if (args.length < 2) {
      return null;
    }
    if (_isHelpToken(args[1])) {
      return null;
    }
    return args[1].trim().toLowerCase();
  }
  if (args.skip(1).any(_isHelpToken)) {
    return args.first.trim().toLowerCase();
  }
  return null;
}

CommandHelpGroup? _findGroup(String command) {
  for (final group in commandHelpGroups) {
    if (group.command == command) {
      return group;
    }
  }
  return null;
}

void _writeHelpSection(void Function(String line) write, String title) {
  write('$title:');
}

void _writeHelpCommand(
  void Function(String line) write,
  String command,
  String detail,
) {
  const column = 58;
  if (command.length >= column - 2) {
    write('  $command');
    write('      $detail');
    return;
  }
  write('  ${command.padRight(column)}$detail');
}

void _writeHelpGroup(void Function(String line) write, CommandHelpGroup group) {
  write('  ${group.command}');
  for (final form in group.forms) {
    write('      $form');
  }
}
