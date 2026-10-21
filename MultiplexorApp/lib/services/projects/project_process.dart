import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

class ProjectProcessResult {
  const ProjectProcessResult(this.exitCode, this.lines);
  final int exitCode;
  final List<String> lines;
}

Future<void> stopRecordedProjectProcess(File log) async {
  File state = File('${log.path}.process.json');
  if (!state.existsSync()) {
    return;
  }
  Map<String, Object?> data = (jsonDecode(state.readAsStringSync()) as Map)
      .cast<String, Object?>();
  if (data['schema'] != 1 ||
      data['token'] is! String ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(data['token'] as String)) {
    throw StateError('Invalid project process ownership: ${state.path}');
  }
  _ProjectProcessOwner owner = _ProjectProcessOwner(
    state,
    data['token'] as String,
  );
  owner.rootPid = data['pid'] as int?;
  owner.rootStarted = data['started'] as String?;
  owner.group = data['group'] as int?;
  for (MapEntry<String, Object?> entry
      in ((data['identities'] as Map?)?.cast<String, Object?>() ??
              <String, Object?>{})
          .entries) {
    owner.known[int.parse(entry.key)] = entry.value as String;
  }
  await owner.stop();
  owner.removeState();
}

Future<void> stopProjectProcess(Process process) async {
  _ProjectProcessOwner? owner = _activeProcesses[process.pid];
  if (owner == null) {
    throw StateError('Process ${process.pid} is not an owned project command');
  }
  await owner.stop();
}

final Map<int, _ProjectProcessOwner> _activeProcesses =
    <int, _ProjectProcessOwner>{};

class _ProjectProcessIdentity {
  const _ProjectProcessIdentity(
    this.pid,
    this.parent,
    this.started, [
    this.group,
  ]);
  final int pid;
  final int parent;
  final String started;
  final int? group;
}

class _ProjectProcessOwner {
  _ProjectProcessOwner(this.state, this.token);

  final File state;
  final String token;
  int? rootPid;
  String? rootStarted;
  Future<void>? _termination;
  int? group;
  bool launching = false;
  final Map<int, String> known = <int, String>{};
  File get groupFile => File('${state.path}.group');

  void removeState() {
    if (state.existsSync()) state.deleteSync();
    if (groupFile.existsSync()) groupFile.deleteSync();
  }

  void save() {
    File temporary = File('${state.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'token': token,
        'pid': rootPid,
        'started': rootStarted,
        'group': group,
        'identities': <String, String>{
          for (MapEntry<int, String> entry in known.entries)
            '${entry.key}': entry.value,
        },
      }),
      flush: true,
    );
    temporary.renameSync(state.path);
  }

  Future<Map<int, _ProjectProcessIdentity>> owned() async {
    if (Platform.isWindows) {
      return _windowsOwned();
    }
    String output = await _processOutput('ps', <String>[
      'eww',
      '-x',
      '-o',
      'pid=,ppid=,pgid=,lstart=,command=',
    ]);
    RegExp marker = RegExp(
      '(?:^|\\s)MULTIPLEXOR_PROCESS_TOKEN=$token(?:\\s|\$)',
    );
    RegExp row = RegExp(
      r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.*)$',
    );
    Map<int, _ProjectProcessIdentity> all = <int, _ProjectProcessIdentity>{};
    Set<int> tagged = <int>{};
    for (String line in const LineSplitter().convert(output)) {
      RegExpMatch? match = row.firstMatch(line);
      if (match == null) continue;
      int id = int.parse(match.group(1)!);
      all[id] = _ProjectProcessIdentity(
        id,
        int.parse(match.group(2)!),
        match.group(4)!,
        int.parse(match.group(3)!),
      );
      if (marker.hasMatch(line)) tagged.add(id);
    }
    if (group == null && groupFile.existsSync()) {
      group = int.tryParse(groupFile.readAsStringSync().trim());
    }
    Set<int> selected = <int>{...tagged};
    for (MapEntry<int, String> entry in known.entries) {
      if (all.containsKey(entry.key) &&
          _processBirth(entry.key) == entry.value) {
        selected.add(entry.key);
      }
    }
    if (launching && rootPid != null && all.containsKey(rootPid)) {
      selected.add(rootPid!);
    }
    bool ownGroup =
        group != null &&
        (launching || selected.any((int id) => all[id]?.group == group));
    if (ownGroup) {
      selected.addAll(
        all.values
            .where((_ProjectProcessIdentity entry) => entry.group == group)
            .map((_ProjectProcessIdentity entry) => entry.pid),
      );
    }
    bool added = true;
    while (added) {
      added = false;
      for (_ProjectProcessIdentity entry in all.values) {
        if (selected.contains(entry.parent) && selected.add(entry.pid)) {
          added = true;
        }
      }
    }
    Map<int, _ProjectProcessIdentity> result = <int, _ProjectProcessIdentity>{};
    for (int id in selected) {
      if (id == pid) continue;
      String? birth = _processBirth(id);
      if (birth == null) continue;
      _ProjectProcessIdentity entry = all[id]!;
      result[id] = _ProjectProcessIdentity(
        id,
        entry.parent,
        birth,
        entry.group,
      );
      known[id] = birth;
    }
    save();
    return result;
  }

  Future<Map<int, _ProjectProcessIdentity>> _windowsOwned() async {
    String output = await _processOutput('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'@(Get-CimInstance Win32_Process | Where-Object {$_.ProcessId -gt 0 -and $null -ne $_.CreationDate} | Select-Object ProcessId,ParentProcessId,@{Name="Started";Expression={$_.CreationDate.ToUniversalTime().ToString("o")}}) | ConvertTo-Json -Compress',
    ]);
    Object? decoded = jsonDecode(output);
    List<Object?> entries = decoded is List<Object?>
        ? decoded
        : <Object?>[decoded];
    Map<int, _ProjectProcessIdentity> all = <int, _ProjectProcessIdentity>{};
    for (Object? entry in entries) {
      Map<String, Object?> row = (entry as Map).cast<String, Object?>();
      int id = row['ProcessId'] as int;
      all[id] = _ProjectProcessIdentity(
        id,
        row['ParentProcessId'] as int,
        row['Started'] as String,
      );
    }
    _ProjectProcessIdentity? root = all[rootPid];
    if (launching && root != null && rootStarted == null) {
      rootStarted = root.started;
      save();
    }
    Set<int> selected = <int>{
      for (MapEntry<int, String> entry in known.entries)
        if (all[entry.key]?.started == entry.value) entry.key,
      if (root != null && root.started == rootStarted) root.pid,
    };
    bool added = true;
    while (added) {
      added = false;
      for (_ProjectProcessIdentity identity in all.values) {
        if (selected.contains(identity.parent) &&
            identity.started.compareTo(all[identity.parent]!.started) >= 0 &&
            selected.add(identity.pid)) {
          added = true;
        }
      }
    }
    selected.remove(pid);
    for (int id in selected) {
      known[id] = all[id]!.started;
    }
    save();
    return <int, _ProjectProcessIdentity>{
      for (int id in selected) id: all[id]!,
    };
  }

  Future<void> stop() => _termination ??= _stop();

  Future<void> _stop() async {
    Map<int, _ProjectProcessIdentity> remaining = await owned();
    if (remaining.isEmpty) {
      return;
    }
    Stopwatch elapsed = Stopwatch()..start();
    Set<String> signalled = <String>{};
    while (remaining.isNotEmpty) {
      bool force = elapsed.elapsed >= const Duration(seconds: 2);
      for (_ProjectProcessIdentity identity in remaining.values) {
        String key = '${identity.pid}:${identity.started}:$force';
        if (!signalled.add(key)) {
          continue;
        }
        if (Platform.isWindows) {
          await _processOutput('taskkill.exe', <String>[
            '/PID',
            '${identity.pid}',
            '/T',
            '/F',
          ], allowFailure: true);
        } else if (_processBirth(identity.pid) == identity.started) {
          Process.killPid(
            identity.pid,
            force ? ProcessSignal.sigkill : ProcessSignal.sigterm,
          );
        }
      }
      if (elapsed.elapsed >= const Duration(seconds: 8)) {
        throw StateError(
          'Project command processes did not stop: ${remaining.keys.join(', ')}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      remaining = await owned();
    }
  }
}

String? _processBirth(int id) {
  if (Platform.isLinux) {
    try {
      String stat = File('/proc/$id/stat').readAsStringSync();
      List<String> fields = stat
          .substring(stat.lastIndexOf(')') + 2)
          .split(' ');
      return fields[0] == 'Z' ? null : fields[19];
    } on FileSystemException {
      return null;
    }
  }
  if (Platform.isMacOS) {
    Pointer<Uint8> buffer = calloc<Uint8>(136);
    try {
      int count = _darwinProcessInfo(id, 3, 0, buffer.cast<Void>(), 136);
      if (count != 136 || buffer.cast<Uint32>()[1] == 5) return null;
      return '${buffer.cast<Uint64>()[15]}:${buffer.cast<Uint64>()[16]}';
    } finally {
      calloc.free(buffer);
    }
  }
  throw UnsupportedError(
    'Project process ownership requires macOS, Linux, or Windows',
  );
}

final int Function(int, int, int, Pointer<Void>, int) _darwinProcessInfo =
    DynamicLibrary.process().lookupFunction<
      Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
      int Function(int, int, int, Pointer<Void>, int)
    >('proc_pidinfo');

Future<String> _processOutput(
  String executable,
  List<String> arguments, {
  bool allowFailure = false,
}) async {
  Process process = await Process.start(
    executable,
    arguments,
    environment: <String, String>{'LC_ALL': 'C'},
  );
  Future<String> output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  Future<String> errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    int code = await process.exitCode.timeout(const Duration(seconds: 10));
    String text = await output;
    String diagnostic = await errors;
    if (code != 0 && !allowFailure) {
      throw ProcessException(executable, arguments, diagnostic, code);
    }
    return text;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait<String>(<Future<String>>[output, errors]);
    rethrow;
  }
}

Future<ProjectProcessResult> runProjectProcess({
  required String executable,
  required List<String> arguments,
  required String directory,
  required File log,
  Map<String, String> environment = const <String, String>{},
  Set<String> removeEnvironment = const <String>{},
  bool Function()? cancelled,
  void Function(String)? onLine,
  Duration timeout = const Duration(hours: 2),
}) async {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
  }
  if (cancelled?.call() == true) {
    return const ProjectProcessResult(130, <String>[]);
  }
  log.parent.createSync(recursive: true);
  File state = File('${log.path}.process.json');
  if (state.existsSync()) {
    throw StateError(
      'Project command still has process ownership: ${state.path}',
    );
  }
  Random random = Random.secure();
  String token = List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  _ProjectProcessOwner owner = _ProjectProcessOwner(state, token)..save();
  IOSink sink = log.openWrite(mode: FileMode.append);
  Completer<void> failure = Completer<void>();
  void fail(Object error, StackTrace trace) {
    if (!failure.isCompleted) {
      failure.completeError(error, trace);
    }
  }

  Future<void> sinkCompletion = sink.done.then<void>(
    (_) {},
    onError: (Object error, StackTrace trace) => fail(error, trace),
  );
  List<String> tail = <String>[];
  void record(String line) {
    sink.writeln(line);
    tail.add(line);
    if (tail.length > 300) {
      tail.removeAt(0);
    }
    onLine?.call(line);
  }

  Map<String, String> variables = <String, String>{
    for (MapEntry<String, String> entry in Platform.environment.entries)
      if (!removeEnvironment.contains(entry.key)) entry.key: entry.value,
    ...environment,
    'MULTIPLEXOR_PROCESS_TOKEN': token,
  }..remove('GIT_CONFIG_COUNT');
  Process? process;
  Timer? timer;
  List<StreamSubscription<String>> streams = <StreamSubscription<String>>[];
  bool stopping = false;
  bool timedOut = false;
  bool cleaned = false;
  Future<void>? termination;
  Stopwatch elapsed = Stopwatch()..start();
  Future<void> shutdown() => termination ??= owner.stop();
  Future<int> failed = failure.future.then<int>((_) => -1);
  unawaited(failed.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  try {
    record('Command: ${jsonEncode(<String>[executable, ...arguments])}');
    record('Working directory: $directory');
    process = await Process.start(
      Platform.isWindows ? executable : '/bin/bash',
      Platform.isWindows
          ? arguments
          : <String>[
              '-c',
              r'set -m; ownership="$1"; shift; "$@" & child=$!; printf "%s\n" "$child" > "$ownership"; wait "$child"',
              'multiplexor-command',
              owner.groupFile.path,
              executable,
              ...arguments,
            ],
      workingDirectory: directory,
      environment: variables,
      includeParentEnvironment: false,
      runInShell: Platform.isWindows && executable.endsWith('.bat'),
    );
    Process active = process;
    owner.rootPid = active.pid;
    _activeProcesses[active.pid] = owner;
    owner.save();
    owner.launching = true;
    if (!Platform.isWindows) {
      Stopwatch handshake = Stopwatch()..start();
      while (!owner.groupFile.existsSync() &&
          handshake.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!owner.groupFile.existsSync()) {
        throw StateError('Project process group did not initialize');
      }
    }
    await owner.owned();
    owner.launching = false;
    List<Completer<void>> drained = <Completer<void>>[];
    for (Stream<List<int>> stream in <Stream<List<int>>>[
      active.stdout,
      active.stderr,
    ]) {
      Completer<void> done = Completer<void>();
      drained.add(done);
      streams.add(
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(
              (String line) {
                try {
                  record(line);
                } catch (error, trace) {
                  fail(error, trace);
                }
              },
              onError: (Object error, StackTrace trace) => fail(error, trace),
              onDone: done.complete,
            ),
      );
    }
    timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (stopping) {
        return;
      }
      try {
        bool wasCancelled = cancelled?.call() == true;
        if (wasCancelled || elapsed.elapsed >= timeout) {
          stopping = true;
          timedOut = !wasCancelled;
          unawaited(shutdown().catchError(fail));
        }
      } catch (error, trace) {
        fail(error, trace);
      }
    });
    int code = await Future.any<int>(<Future<int>>[active.exitCode, failed]);
    await shutdown();
    cleaned = true;
    await Future.any<void>(<Future<void>>[
      Future.wait<void>(
        drained.map((Completer<void> done) => done.future),
      ).timeout(const Duration(seconds: 5)),
      failure.future,
    ]);
    timer.cancel();
    if (timedOut) {
      record('Build exceeded ${timeout.inMilliseconds} milliseconds');
    }
    record('Exit code: $code');
    await sink.flush();
    if (failure.isCompleted) {
      await failure.future;
    }
    return ProjectProcessResult(timedOut ? 124 : (stopping ? 130 : code), tail);
  } finally {
    timer?.cancel();
    try {
      if (!cleaned) {
        await shutdown();
        cleaned = true;
      }
      if (process != null) {
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    } finally {
      for (StreamSubscription<String> stream in streams) {
        await stream.cancel();
      }
      if (process != null) {
        _activeProcesses.remove(process.pid);
      }
      await sink.close();
      await sinkCompletion;
      if (cleaned && state.existsSync()) {
        owner.removeState();
      }
    }
  }
}
