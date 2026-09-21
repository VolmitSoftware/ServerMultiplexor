import 'dart:io';

import 'package:path/path.dart' as p;

import 'self_update_installer.dart';
import 'self_update_release.dart';
import 'self_update_settings.dart';

typedef SelfUpdateInstall =
    Future<bool> Function({
      required File archive,
      required String version,
      required String currentVersion,
      required String executableName,
      required String targetPath,
      required List<String> restartArguments,
      required String workingDirectory,
    });

class SelfUpdateService {
  SelfUpdateService({
    required this.currentVersion,
    required this.executablePath,
    required this.releaseBuild,
    required this.platform,
    required this.store,
    required this.client,
    SelfUpdateInstall install = installSelfUpdate,
    Future<int> Function(String, List<String>)? restart,
    DateTime Function()? now,
    void Function(String)? write,
    void Function(String)? error,
  }) : _install = install,
       _restart = restart ?? _restartExecutable,
       _now = now ?? DateTime.now,
       _write = write ?? stdout.writeln,
       _error = error ?? stderr.writeln;

  final UpdateVersion currentVersion;
  final String executablePath;
  final bool releaseBuild;
  final UpdatePlatform? platform;
  final SelfUpdateStore store;
  final GithubUpdateClient client;
  final SelfUpdateInstall _install;
  final Future<int> Function(String, List<String>) _restart;
  final DateTime Function() _now;
  final void Function(String) _write;
  final void Function(String) _error;
  bool _exitRequired = false;

  bool get exitRequired => _exitRequired;

  Future<SelfUpdateRelease?> check() =>
      client.latest(currentVersion, _requirePlatform());

  Future<int?> updateAndRestart(List<String> restartArguments) async {
    _requireReleaseBuild();
    final bool? helperStarted = await store.locked(
      () => _apply(restartArguments),
    );
    if (helperStarted == null) return null;
    if (helperStarted) return 0;
    client.close();
    return _restart(executablePath, restartArguments);
  }

  Future<int> command(List<String> args) async {
    if (args.isEmpty || (args.length == 1 && args.single == 'install')) {
      _requireReleaseBuild();
      await store.locked(() => _apply(const <String>['version']));
      return 0;
    }
    if (args.length == 1 && args.single == 'check') {
      final SelfUpdateRelease? release = await check();
      _write(
        release == null
            ? 'Multiplexor v${currentVersion.text} is up to date.'
            : 'Multiplexor v${release.version.text} is available '
                  '(current: v${currentVersion.text}).',
      );
      return 0;
    }
    if (args.length == 1 && args.single == 'status') {
      _write('Multiplexor v${currentVersion.text}');
      _write('Executable: $executablePath');
      if (!releaseBuild) {
        _write('Source build: automatic updates are disabled.');
        return 0;
      }
      _requirePlatform();
      final SelfUpdateSettings settings = store.read();
      _write('Automatic updates: ${settings.automatic ? 'on' : 'off'}');
      _write(
        'Last check: ${settings.lastAttempt?.toIso8601String() ?? 'never'}',
      );
      return 0;
    }
    if (args.isNotEmpty && args.first == 'auto' && args.length <= 2) {
      if (args.length == 2 && args[1] != 'on' && args[1] != 'off') {
        throw const FormatException('Use update auto on or update auto off.');
      }
      _requireReleaseBuild();
      await store.locked(() async {
        SelfUpdateSettings settings = store.read();
        if (args.length == 2) {
          settings = settings.withAutomatic(args[1] == 'on');
          store.write(settings);
        }
        _write('Automatic updates: ${settings.automatic ? 'on' : 'off'}');
      });
      return 0;
    }
    throw const FormatException(
      'Use update [install], update check, update status, or update auto [on|off].',
    );
  }

  Future<int?> automatic(List<String> restartArguments) async {
    if (!releaseBuild || platform == null) return null;
    try {
      final bool? helperStarted = await store.locked(() async {
        final SelfUpdateSettings settings = store.read();
        if (!settings.automatic ||
            !settings.isDue(_now(), currentVersion.text)) {
          return null;
        }
        return _apply(restartArguments, automatic: true);
      });
      if (helperStarted == null) return null;
      if (helperStarted) return 0;
      client.close();
      return await _restart(executablePath, restartArguments);
    } on UpdateBusyException {
      return null;
    } catch (error) {
      _error('[update] Update skipped: $error');
      return null;
    }
  }

  Future<bool?> _apply(
    List<String> restartArguments, {
    bool automatic = false,
  }) async {
    final SelfUpdateSettings settings = store.read();
    store.write(settings.attempted(_now(), currentVersion.text, false));
    final SelfUpdateRelease? release = await client.latest(
      currentVersion,
      _requirePlatform(),
    );
    if (release == null) {
      store.write(settings.attempted(_now(), currentVersion.text, true));
      if (!automatic) {
        _write('Multiplexor v${currentVersion.text} is up to date.');
      }
      return null;
    }
    _error('[update] Downloading Multiplexor v${release.version.text}');
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-download-',
    );
    try {
      final File archive = File(p.join(temporary.path, release.assetName));
      await client.download(release, archive);
      final bool helperStarted = await _install(
        archive: archive,
        version: release.version.text,
        currentVersion: currentVersion.text,
        executableName: _requirePlatform().executableName,
        targetPath: executablePath,
        restartArguments: restartArguments,
        workingDirectory: Directory.current.path,
      );
      _exitRequired = helperStarted;
      try {
        if (!helperStarted) {
          store.write(settings.attempted(_now(), release.version.text, true));
        }
      } on FileSystemException catch (error) {
        _error('[update] Could not save the update check time: $error');
      }
      _error(
        helperStarted
            ? '[update] Update prepared; finishing after this process exits.'
            : '[update] Installed Multiplexor v${release.version.text}',
      );
      return helperStarted;
    } finally {
      try {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      } on FileSystemException catch (error) {
        _error('[update] Could not remove ${temporary.path}: $error');
      }
    }
  }

  void _requireReleaseBuild() {
    if (!releaseBuild) {
      throw const FormatException(
        'Self-update requires a compiled release. Source builds use ./start.sh.',
      );
    }
    _requirePlatform();
  }

  UpdatePlatform _requirePlatform() =>
      platform ??
      (throw const FormatException(
        'No compiled update is available for this operating system/architecture.',
      ));

  static Future<int> _restartExecutable(String path, List<String> args) async {
    final Process child = await Process.start(
      path,
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    return child.exitCode;
  }
}

bool opensUpdateDashboard(List<String> args) =>
    args.isEmpty ||
    (args.length == 1 && args.single == 'wizard') ||
    (args.length == 2 && args[0] == 'runtime' && args[1] == 'watch');

bool isRunningCompiledExecutable() {
  if (Platform.script.scheme != 'file') return false;
  try {
    return p.equals(
      File.fromUri(Platform.script).resolveSymbolicLinksSync(),
      File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
    );
  } on FileSystemException {
    return false;
  }
}
