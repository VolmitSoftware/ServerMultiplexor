import 'dart:async';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late String consumerRoot;
  final Set<String> sessions = <String>{};
  final Map<String, Completer<void>> starts = <String, Completer<void>>{};
  final Map<String, Completer<void>> stops = <String, Completer<void>>{};
  final List<Set<int>> assigned = <Set<int>>[];
  int watcherStarts = 0;
  bool holdStarts = false;
  bool holdStops = false;
  bool failStart = false;
  Completer<void>? startObserved;
  Completer<void>? stopObserved;

  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-parallel-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    final ConsumerService consumers = ConsumerService(context);
    consumerRoot = consumers.rootFor(ConsumerProfile.plugin);
    sessions.clear();
    starts.clear();
    stops.clear();
    assigned.clear();
    watcherStarts = 0;
    holdStarts = false;
    holdStops = false;
    failStart = false;
    startObserved = null;
    stopObserved = null;
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      processExecutor: (String executable, List<String> args) async {
        if (executable != 'tmux') return ProcessResult(0, 0, '', '');
        String target(String flag) => args[args.indexOf(flag) + 1];
        if (args.first == 'has-session') {
          return ProcessResult(
            0,
            sessions.contains(target('-t')) ? 0 : 1,
            '',
            '',
          );
        }
        if (args.first == 'list-panes') {
          return ProcessResult(
            0,
            sessions.contains(target('-t')) ? 0 : 1,
            '0\n',
            '',
          );
        }
        if (args.first == 'new-session') {
          final String session = target('-s');
          if (session.startsWith('watch-')) {
            watcherStarts++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          } else {
            final String name = session.substring('mc-plugin-'.length);
            final List<String> properties = File(
              p.join(consumerRoot, 'instances', name, 'server.properties'),
            ).readAsLinesSync();
            assigned.add(<int>{
              for (final String line in properties)
                if (line.startsWith('server-port=') ||
                    line.startsWith('rcon.port='))
                  int.parse(line.split('=').last),
            });
            final Completer<void> gate = Completer<void>();
            starts[session] = gate;
            if (starts.length == 2 && startObserved?.isCompleted == false) {
              startObserved!.complete();
            }
            if (holdStarts) await gate.future;
            if (failStart) {
              return ProcessResult(0, 1, '', 'injected launch failure');
            }
          }
          sessions.add(session);
        }
        if (args.first == 'send-keys' && args.contains('stop')) {
          final String session = target('-t');
          final Completer<void> gate = Completer<void>();
          stops[session] = gate;
          if (stops.length == 2 && stopObserved?.isCompleted == false) {
            stopObserved!.complete();
          }
          if (holdStops) await gate.future;
          sessions.remove(session);
        }
        if (args.first == 'kill-session') sessions.remove(target('-t'));
        return ProcessResult(0, 0, '', '');
      },
    );
  });
  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  Future<void> create(String name, {bool isolated = true}) async {
    final CapturedResult result = await service.execute(<String>[
      'instance',
      'create',
      name,
      if (isolated) '--isolated',
    ], stream: false);
    expect(result.exitCode, 0, reason: result.stderr);
    File(
      p.join(consumerRoot, 'instances', name, 'server.jar'),
    ).writeAsStringSync('mock jar; never executed');
  }

  test(
    'parallel starts reserve distinct ports and start one shared watcher',
    () async {
      for (final String name in <String>['a', 'b', 'c']) {
        await create(name, isolated: false);
      }
      holdStarts = true;
      startObserved = Completer<void>();
      final Future<CapturedResult> result = service.execute(<String>[
        'instance',
        'bulk',
        'start',
        'a',
        'b',
        'c',
        '--concurrency',
        '2',
      ], stream: false);
      await startObserved!.future.timeout(const Duration(seconds: 5));
      expect(starts.length, 2);
      expect(watcherStarts, 1);
      expect(assigned.expand((Set<int> ports) => ports).toSet().length, 4);
      // Release both admitted workers. The queued third must also finish before return.
      holdStarts = false;
      for (final Completer<void> gate in starts.values) {
        gate.complete();
      }
      final CapturedResult output = await result;
      expect(output.exitCode, 0, reason: output.stderr);
      expect(starts.length, 3);
      expect(assigned.expand((Set<int> ports) => ports).toSet().length, 6);
      expect(output.stdout, contains('3 succeeded, 0 skipped, 0 failed'));
    },
    skip: Platform.isWindows ? 'Mocks the tmux backend' : false,
  );

  test(
    'selected deletes overlap shutdown and preserve unselected instance',
    () async {
      for (final String name in <String>['a', 'b', 'kept']) {
        await create(name);
      }
      sessions.addAll(<String>['mc-plugin-a', 'mc-plugin-b']);
      holdStops = true;
      stopObserved = Completer<void>();
      final Future<CapturedResult> result = service.execute(<String>[
        'instance',
        'bulk',
        'delete',
        'a',
        'b',
        '--confirm',
        'DELETE a,b',
      ], stream: false);
      await stopObserved!.future.timeout(const Duration(seconds: 3));
      expect(stops.keys.toSet(), <String>{'mc-plugin-a', 'mc-plugin-b'});
      expect(
        Directory(p.join(consumerRoot, 'instances', 'a')).existsSync(),
        isTrue,
      );
      for (final Completer<void> gate in stops.values) {
        gate.complete();
      }
      final CapturedResult output = await result;
      expect(output.exitCode, 0, reason: output.stderr);
      expect(
        Directory(p.join(consumerRoot, 'instances', 'a')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(consumerRoot, 'instances', 'b')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(consumerRoot, 'instances', 'kept')).existsSync(),
        isTrue,
      );
    },
    skip: Platform.isWindows ? 'Mocks the tmux backend' : false,
  );

  test(
    'failed launches release reservations for a later batch',
    () async {
      await create('a');
      File(
        p.join(consumerRoot, 'instances', 'a', 'server.properties'),
      ).writeAsStringSync(
        'enable-rcon=true\nrcon.port=invalid\n',
        mode: FileMode.append,
      );
      failStart = true;
      final CapturedResult first = await service.execute(<String>[
        'instance',
        'bulk',
        'start',
        'a',
      ], stream: false);
      expect(first.exitCode, 1);
      final Set<int> failedPorts = assigned.single;
      failStart = false;
      final CapturedResult second = await service.execute(<String>[
        'instance',
        'bulk',
        'start',
        'a',
      ], stream: false);
      expect(second.exitCode, 0, reason: second.stderr);
      expect(assigned.last, failedPorts);
    },
    skip: Platform.isWindows ? 'Mocks the tmux backend' : false,
  );

  test(
    'restart waits for each stop while different servers overlap',
    () async {
      for (final String name in <String>['a', 'b']) {
        await create(name);
        File(p.join(consumerRoot, 'state', 'runtime', '$name.log'))
          ..createSync(recursive: true)
          ..writeAsStringSync('[Server thread/INFO]: Done (1.0s)!');
      }
      sessions.addAll(<String>['mc-plugin-a', 'mc-plugin-b']);
      holdStops = true;
      stopObserved = Completer<void>();
      final Future<CapturedResult> result = service.execute(<String>[
        'instance',
        'bulk',
        'restart',
        'a',
        'b',
      ], stream: false);
      await stopObserved!.future.timeout(const Duration(seconds: 3));
      expect(starts, isEmpty);
      for (final Completer<void> gate in stops.values) {
        gate.complete();
      }
      final CapturedResult output = await result;
      expect(output.exitCode, 0, reason: output.stderr);
      expect(starts.keys.toSet(), <String>{'mc-plugin-a', 'mc-plugin-b'});
      expect(output.stdout, contains('2 succeeded, 0 skipped, 0 failed'));
    },
    skip: Platform.isWindows ? 'Mocks the tmux backend' : false,
  );

  test('repo sync refills independent work with four workers', () async {
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    final Completer<void> fourStarted = Completer<void>();
    final Completer<void> release = Completer<void>();
    int active = 0;
    int peak = 0;
    int total = 0;
    final NativeCommandService repos = NativeCommandService(
      context: context,
      consumerService: ConsumerService(context),
      processExecutor: (String executable, List<String> args) async {
        expect(executable, 'git');
        expect(args.first, 'clone');
        total++;
        active++;
        if (active > peak) peak = active;
        if (total == 4) fourStarted.complete();
        await release.future;
        active--;
        return ProcessResult(0, 0, '', '');
      },
    );
    final Future<CapturedResult> result = repos.execute(<String>[
      'repos',
      'sync',
      'all',
    ], stream: false);
    await fourStarted.future.timeout(const Duration(seconds: 3));
    expect(total, 4);
    release.complete();
    expect((await result).exitCode, 0);
    expect(total, 5);
    expect(peak, 4);
    repos.disposeRcon();
  });

  test('invalid concurrency rejects before any mutation', () async {
    await create('a');
    for (final String value in <String>['0', '9', 'many']) {
      final CapturedResult output = await service.execute(<String>[
        'instance',
        'bulk',
        'delete',
        'a',
        '--confirm',
        'DELETE a',
        '--concurrency',
        value,
      ], stream: false);
      expect(output.exitCode, 2);
      expect(
        Directory(p.join(consumerRoot, 'instances', 'a')).existsSync(),
        isTrue,
      );
    }
  });
}
