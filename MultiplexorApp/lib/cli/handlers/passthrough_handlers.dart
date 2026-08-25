import 'dart:io';

import '../../services/app_context.dart';

Future<void> handleNativePassthrough(List<String> args) async =>
    _runAndExit(args);

Future<void> handleReposSync(
  Map<String, dynamic> args,
  Map<String, dynamic> flags,
) async {
  final target = _arg(args, 'target') ?? 'all';
  await _runAndExit(<String>['repos', 'sync', target]);
}

Future<void> handleBuildList() async {
  await _runAndExit(<String>['build', 'list']);
}

Future<void> handleBuildListAll(Map<String, dynamic> args) async {
  final type = _arg(args, 'type');
  final cmd = <String>['build', 'list-all'];
  if (type != null) {
    cmd.add(type);
  }
  await _runAndExit(cmd);
}

Future<void> handleBuildLatest(Map<String, dynamic> args) async {
  final type = _arg(args, 'type');
  if (type == null) {
    stderr.writeln('Usage: build latest <type>');
    exit(2);
  }
  await _runAndExit(<String>['build', 'latest', type]);
}

Future<void> handleBuildVersions(Map<String, dynamic> args) async {
  final type = _arg(args, 'type') ?? 'all';
  await _runAndExit(<String>['build', 'versions', type]);
}

Future<void> handleBuildCacheInfo(Map<String, dynamic> args) async {
  final type = _arg(args, 'type') ?? 'all';
  final mc = _arg(args, 'mc');
  final cmd = <String>['build', 'cache-info', type];
  if (mc != null) {
    cmd.addAll(<String>['--mc', mc]);
  }
  await _runAndExit(cmd);
}

Future<void> handleBuildTestLatest(Map<String, dynamic> args) async {
  final spigotMc = _arg(args, 'spigot-mc');
  final cmd = <String>['build', 'test-latest'];
  if (spigotMc != null) {
    cmd.addAll(<String>['--spigot-mc', spigotMc]);
  }
  await _runAndExit(cmd);
}

Future<void> handleBuildPrune(Map<String, dynamic> args) async {
  final type = _arg(args, 'type') ?? 'all';
  await _runAndExit(<String>['build', 'prune', type]);
}

Future<void> handleBuildTarget(String type, Map<String, dynamic> args) async {
  final mc = _arg(args, 'mc');
  final loader = _arg(args, 'loader');
  final installer = _arg(args, 'installer');

  final cmd = <String>['build', type];
  if (mc != null) {
    cmd.addAll(<String>['--mc', mc]);
  }
  if (loader != null) {
    cmd.addAll(<String>['--loader', loader]);
  }
  if (installer != null) {
    cmd.addAll(<String>['--installer', installer]);
  }
  if (args['force'] == true) {
    cmd.add('--force');
  }

  await _runAndExit(cmd);
}

Future<void> handleInstanceList() async =>
    _runAndExit(<String>['instance', 'list']);
Future<void> handleInstanceCurrent() async =>
    _runAndExit(<String>['instance', 'current']);

Future<void> handleInstanceDeleteAll([Map<String, dynamic>? args]) async {
  final cmd = <String>['instance', 'delete-all'];
  if (args != null && _flag(args, 'everywhere')) {
    cmd.add('--everywhere');
  }
  if (args != null && _flag(args, 'force')) {
    cmd.add('--force');
  }
  await _runAndExit(cmd);
}

Future<void> handleServerCreateMany(
  Map<String, dynamic> args,
  Map<String, dynamic> flags,
) async {
  final types = _arg(args, 'types');
  if (types == null) {
    stderr.writeln(
      'Usage: server create-many --types <a,b,c> [--prefix N] [--mc v] [--auto-build] [--isolated]',
    );
    exit(2);
  }
  final cmd = <String>['server', 'create-many', '--types', types];
  final prefix = _arg(args, 'prefix');
  final mc = _arg(args, 'mc');
  if (prefix != null) {
    cmd.addAll(<String>['--prefix', prefix]);
  }
  if (mc != null) {
    cmd.addAll(<String>['--mc', mc]);
  }
  if (_flag(flags, 'auto-build')) {
    cmd.add('--auto-build');
  }
  if (_flag(flags, 'isolated')) {
    cmd.add('--isolated');
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceDelete(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  if (name == null) {
    stderr.writeln('Usage: instance delete <name>');
    exit(2);
  }
  await _runAndExit(<String>['instance', 'delete', name]);
}

Future<void> handleInstanceReset(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  if (name == null) {
    stderr.writeln('Usage: instance reset <name>');
    exit(2);
  }
  await _runAndExit(<String>['instance', 'reset', name]);
}

Future<void> handleInstanceCreate(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  if (name == null) {
    stderr.writeln('Usage: instance create <name> [--isolated]');
    exit(2);
  }
  await _runAndExit(<String>[
    'instance',
    'create',
    name,
    if (args['isolated'] == true) '--isolated',
  ]);
}

Future<void> handleInstanceClone(Map<String, dynamic> args) async {
  final source = _arg(args, 'source');
  final target = _arg(args, 'target');
  if (source == null || target == null) {
    stderr.writeln('Usage: instance clone <source> <target>');
    exit(2);
  }
  await _runAndExit(<String>['instance', 'clone', source, target]);
}

Future<void> handleInstanceActivate(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  if (name == null) {
    stderr.writeln('Usage: instance activate <name>');
    exit(2);
  }
  await _runAndExit(<String>['instance', 'activate', name]);
}

Future<void> handleInstancePath(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final cmd = <String>['instance', 'path'];
  if (name != null) {
    cmd.add(name);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceOpen(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final cmd = <String>['instance', 'open'];
  if (name != null) {
    cmd.add(name);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceUpdate(
  Map<String, dynamic> args,
  Map<String, dynamic> flags,
) async {
  final name = _arg(args, 'name');
  if (name == null) {
    stderr.writeln(
      'Usage: instance update <name> [--mc <version>] [--jar <path>] [--auto-build]',
    );
    exit(2);
  }
  final type = _arg(args, 'type');
  final mc = _arg(args, 'mc');
  final jar = _arg(args, 'jar');
  final loader = _arg(args, 'loader');
  final autoBuild = _flag(flags, 'auto-build');

  final cmd = <String>['instance', 'update', name];
  if (type != null) {
    cmd.addAll(<String>['--type', type]);
  }
  if (mc != null) {
    cmd.addAll(<String>['--mc', mc]);
  }
  if (jar != null) {
    cmd.addAll(<String>['--jar', jar]);
  }
  if (loader != null) {
    cmd.addAll(<String>['--loader', loader]);
  }
  if (autoBuild) {
    cmd.add('--auto-build');
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceIsolated(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final value = _arg(args, 'value');
  final cmd = <String>['instance', 'isolated'];
  if (name != null) {
    cmd.add(name);
  }
  if (value != null) {
    cmd.add(value);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceLock(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final pin = _arg(args, 'pin');
  final cmd = <String>['instance', 'lock'];
  if (name != null) {
    cmd.add(name);
  }
  if (pin != null) {
    cmd.addAll(<String>['--pin', pin]);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceUnlock(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final pin = _arg(args, 'pin');
  final cmd = <String>['instance', 'unlock'];
  if (name != null) {
    cmd.add(name);
  }
  if (pin != null) {
    cmd.addAll(<String>['--pin', pin]);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceLocked(Map<String, dynamic> args) async {
  final name = _arg(args, 'name');
  final cmd = <String>['instance', 'locked'];
  if (name != null) {
    cmd.add(name);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstancePort(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final port = _arg(args, 'port');

  final cmd = <String>['instance', 'port'];
  if (instance != null) {
    cmd.add(instance);
  }
  if (port != null) {
    cmd.add(port);
  }
  await _runAndExit(cmd);
}

Future<void> handleInstanceMotdStyle(Map<String, dynamic> args) async {
  final target = _arg(args, 'target');
  final cmd = <String>['instance', 'motd-style'];
  if (target != null) {
    cmd.add(target);
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeConsole(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final cmd = <String>['runtime', 'console'];
  if (instance != null) {
    cmd.add(instance);
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeConsoles() async =>
    _runAndExit(<String>['runtime', 'consoles']);

Future<void> handleRuntimeConsolesLateral() async =>
    _runAndExit(<String>['runtime', 'consoles-lateral']);

Future<void> handleRuntimeStart(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final noConsole = _flag(args, 'no-console');
  final cmd = <String>['runtime', 'start'];
  if (instance != null) {
    cmd.add(instance);
  }
  if (noConsole) {
    cmd.add('--no-console');
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeStop(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final cmd = <String>['runtime', 'stop'];
  if (instance != null) {
    cmd.add(instance);
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeRestart(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final noConsole = _flag(args, 'no-console');
  final cmd = <String>['runtime', 'restart'];
  if (instance != null) {
    cmd.add(instance);
  }
  if (noConsole) {
    cmd.add('--no-console');
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeStatus(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final cmd = <String>['runtime', 'status'];
  if (instance != null) {
    cmd.add(instance);
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeStats(Map<String, dynamic> args) async {
  final instance = _arg(args, 'instance');
  final cmd = <String>['runtime', 'stats'];
  if (instance != null) {
    cmd.add(instance);
  }
  await _runAndExit(cmd);
}

Future<void> handleRuntimeList() async =>
    _runAndExit(<String>['runtime', 'list']);

Future<void> handleRuntimeStates() async =>
    _runAndExit(<String>['runtime', 'states']);

Future<void> handleRuntimeMetrics() async =>
    _runAndExit(<String>['runtime', 'metrics']);

// `set-wrap` and `set-log-format` follow the same shape as `set-heap` and
// `set-preset` — they take an optional value passed via --value or as a
// positional arg by the runner.
Future<void> handleRuntimeSettings(String action, {String? value}) async {
  final cmd = <String>['runtime', 'settings', action];
  if (value != null && value.trim().isNotEmpty) {
    cmd.add(value.trim());
  }
  await _runAndExit(cmd);
}

Future<void> handlePluginsShowSource({bool mods = false}) async {
  await _runAndExit(<String>[mods ? 'mods' : 'plugins', 'show-source']);
}

Future<void> handlePluginsSync(
  Map<String, dynamic> args,
  Map<String, dynamic> flags, {
  bool mods = false,
}) async {
  final target = _arg(args, 'target');
  final clean = _flag(flags, 'clean');
  final all = _flag(flags, 'all');

  final cmd = <String>[mods ? 'mods' : 'plugins', 'sync'];
  if (all) {
    cmd.add('--all');
  } else if (target != null) {
    cmd.add(target);
  }
  if (clean) {
    cmd.add('--clean');
  }

  await _runAndExit(cmd);
}

Future<void> handlePluginsIrisPath() async =>
    _runAndExit(<String>['plugins', 'iris-packs-path']);

Future<void> handlePluginsIrisLink(
  Map<String, dynamic> args,
  Map<String, dynamic> flags,
) async {
  final all = _flag(flags, 'all');
  final target = _arg(args, 'target');

  final cmd = <String>['plugins', 'iris-packs-link'];
  if (all) {
    cmd.add('--all');
  } else if (target != null) {
    cmd.add(target);
  }

  await _runAndExit(cmd);
}

Future<void> handlePluginsWatchStatus({bool mods = false}) async =>
    _runAndExit(<String>[mods ? 'mods' : 'plugins', 'watch-status']);
Future<void> handlePluginsWatchStart({bool mods = false}) async =>
    _runAndExit(<String>[mods ? 'mods' : 'plugins', 'watch-start']);
Future<void> handlePluginsWatchStop({bool mods = false}) async =>
    _runAndExit(<String>[mods ? 'mods' : 'plugins', 'watch-stop']);
Future<void> handlePluginsWatchDaemon({bool mods = false}) async =>
    _runAndExit(<String>[mods ? 'mods' : 'plugins', 'watch-daemon']);

Future<void> handleConfigLink(
  Map<String, dynamic> args,
  Map<String, dynamic> flags,
) async {
  final all = _flag(flags, 'all');
  final target = _arg(args, 'target');

  final cmd = <String>['config', 'localize'];
  if (all) {
    cmd.add('--all');
  } else if (target != null) {
    cmd.add(target);
  }

  await _runAndExit(cmd);
}

Future<void> handleConfigStatus(Map<String, dynamic> args) async {
  final target = _arg(args, 'target');
  final cmd = <String>['config', 'status'];
  if (target != null) {
    cmd.add(target);
  }
  await _runAndExit(cmd);
}

Future<void> handleHelp() async => _runAndExit(<String>['help']);

String? _arg(Map<String, dynamic> args, String name) {
  final value = args[name];
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return null;
  }
  return text;
}

bool _flag(Map<String, dynamic> flags, String name) {
  final value = flags[name];
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

Future<void> _runAndExit(List<String> args) async {
  final code = await passthroughService.run(args);
  if (code != 0) {
    exit(code);
  }
}
