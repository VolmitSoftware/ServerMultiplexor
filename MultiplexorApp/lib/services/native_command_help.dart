part of 'native_command_service.dart';

void _printHelp(_NativeIoBuffer io) {
  io.write('Multiplexor');
  io.write('Minecraft server workspace manager');
  io.write('');

  _writeHelpSection(io, 'Usage');
  _writeHelpCommand(io, './start.sh', 'open the interactive wizard');
  _writeHelpCommand(io, './start.sh <command>', 'run a direct command');
  _writeHelpCommand(
    io,
    './start.sh --consumer <profile> <command>',
    'target plugin, forge, fabric, or neoforge',
  );
  io.write('');

  _writeHelpSection(io, 'Common Workflows');
  _writeHelpCommand(
    io,
    './start.sh server create demo --type purpur --auto-build',
    'create a latest-upstream Purpur server',
  );
  _writeHelpCommand(
    io,
    './start.sh runtime start demo',
    'start and attach to a server console',
  );
  _writeHelpCommand(
    io,
    './start.sh plugins sync --all',
    'copy plugin drop-ins to every plugin instance',
  );
  _writeHelpCommand(
    io,
    './start.sh backup create demo --label before-change',
    'create a restore point for an instance',
  );
  _writeHelpCommand(
    io,
    './start.sh doctor',
    'check local tools, workspace state, and instance metadata',
  );
  io.write('');

  _writeHelpSection(io, 'Commands');
  _writeHelpGroup(io, 'consumer', <String>[
    'list',
    'show',
    'use <plugin|forge|fabric|neoforge>',
    'path',
  ]);
  _writeHelpGroup(io, 'instance', <String>[
    'list',
    'create <name>',
    'clone <source> <target>',
    'activate <name>',
    'path [name]',
    'open [name]',
    'update <name> [--mc <version>] [--jar <path>] [--auto-build]',
    'safe-update <name> [--mc <version>] [--auto-build] [--promote]',
    'isolated [name] [true|false]',
    'lock <name> [--pin <digits>]',
    'unlock <name> [--pin <digits>]',
    'locked [name]',
    'port [instance] [port]',
    'reset <name>',
    'delete <name>',
    'delete-all [--everywhere] [--force]',
  ]);
  _writeHelpGroup(io, 'server', <String>[
    'create <name> --type <type> [--mc <version>] [--auto-build] [--isolated]',
    'create <name> --jar <path> [--type label] [--isolated]',
    'create-many --types <a,b,c> [--prefix N] [--mc <v>] [--auto-build] [--isolated]',
  ]);
  _writeHelpGroup(io, 'runtime', <String>[
    'start [instance] [--instance <name>] [--no-console]',
    'console [instance] [--instance <name>]',
    'consoles',
    'consoles-lateral',
    'stop [instance]',
    'restart [instance] [--no-console]',
    'status [instance]',
    'stats [instance]',
    'states',
    'metrics',
    'list',
    'settings <show|presets|set-heap|set-preset|set-wrap|set-log-format|reset>',
  ]);
  _writeHelpGroup(io, 'build', <String>[
    '<paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>]',
    'latest <type>',
    'versions [type]',
    'list',
    'list-all [type]',
    'test-latest [--spigot-mc <version>]',
  ]);
  _writeHelpGroup(io, 'repos', <String>[
    'sync [all|paper|purpur|folia|canvas]',
  ]);
  _writeHelpGroup(io, 'plugins', <String>[
    'show-source',
    'sync [instance|--all] [--clean]',
    'watch-status',
    'watch-start',
    'watch-stop',
    'iris-packs-path',
    'iris-packs-link [instance|--all]',
  ]);
  _writeHelpGroup(io, 'mods', <String>[
    'show-source',
    'sync [instance|--all] [--clean]',
    'watch-status',
    'watch-start',
    'watch-stop',
  ]);
  _writeHelpGroup(io, 'config', <String>[
    'status [instance]',
    'localize [instance|--all]',
  ]);
  _writeHelpGroup(io, 'backup', <String>[
    'create [instance] [--label <label>] [--include-logs]',
    'list [instance|--all]',
    'restore [instance] <backup-id>',
    'verify [instance] <backup-id>',
    'delete [instance] <backup-id>',
    'prune [instance] [--keep <n>]',
  ]);
  _writeHelpGroup(io, 'template', <String>[
    'list',
    'init <name> [--type <type>] [--mc <version>] [--heap <size>] [--preset <name>]',
    'show <name>',
    'apply <template> <instance> [--auto-build] [--sync]',
    'export <instance> <template>',
    'delete <name>',
  ]);
  _writeHelpGroup(io, 'content', <String>[
    'search <query>',
    'install <modrinth-slug|url> [--mc <version>] [--loader <loader>] [--sync]',
    'list',
    'update [name|--all] [--sync]',
    'remove <name>',
    'sync [instance|--all] [--clean]',
  ]);
  _writeHelpGroup(io, 'doctor', <String>['[--fix] [--json]']);
  io.write('');

  _writeHelpSection(io, 'Global Flags');
  _writeHelpCommand(io, '--consumer <profile>', 'temporary profile override');
  _writeHelpCommand(io, '--root <path>', 'use a different workspace root');
  _writeHelpCommand(io, '--verbose', 'print debug argument normalization');
}

void _writeHelpSection(_NativeIoBuffer io, String title) {
  io.write('$title:');
}

void _writeHelpCommand(_NativeIoBuffer io, String command, String detail) {
  const column = 58;
  if (command.length >= column - 2) {
    io.write('  $command');
    io.write('      $detail');
    return;
  }
  io.write('  ${command.padRight(column)}$detail');
}

void _writeHelpGroup(_NativeIoBuffer io, String command, List<String> forms) {
  io.write('  $command');
  for (final form in forms) {
    io.write('      $form');
  }
}
