import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/profiling/remote_profiler_gateway.dart';
import 'package:multiplexor/services/profiling/remote_profiler_models.dart';
import 'package:multiplexor/services/profiling/remote_profiler_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const List<int> _snapshot = <int>[
  0x28,
  0xb5,
  0x2f,
  0xfd,
  0x20,
  4,
  33,
  0,
  0,
  1,
  2,
  3,
  4,
];

void main() {
  late Directory directory;
  late _Gateway gateway;
  late RemoteProfilerService service;
  const RemoteProfilerOptions options = RemoteProfilerOptions(
    agentDirectory: '/agent',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('remote-profiler-test-');
    gateway = _Gateway();
    service = RemoteProfilerService(
      gateway: gateway,
      stateDirectory: directory.path,
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'fetch retains failed capture diagnosis and permits a new restored capture',
    () async {
      gateway.launchFails = true;
      await expectLater(service.start('test', options), throwsStateError);
      gateway.snapshotBytes = List<int>.of(_snapshot);
      final RemoteProfilerFetch fetched = await service.fetch('test');
      expect(fetched.capture.phase, RemoteProfilerPhase.failed);
      expect(fetched.capture.error, contains('start failed'));
      expect(fetched.capture.files, hasLength(1));
      expect(fetched.capture.blocksCapture, isFalse);
      gateway.launchFails = false;
      expect(
        (await service.start('test', options)).phase,
        RemoteProfilerPhase.recording,
      );
    },
  );

  test(
    'status reports ready only after a completed snapshot exists remotely',
    () async {
      await service.start('test', options);
      expect(
        (await service.status('test')).phase,
        RemoteProfilerPhase.recording,
      );
      gateway.snapshotBytes = List<int>.of(_snapshot);
      expect((await service.status('test')).phase, RemoteProfilerPhase.ready);
      expect((await service.status('test')).files, isEmpty);
      gateway.snapshotBytes.clear();
      expect(
        (await service.status('test')).phase,
        RemoteProfilerPhase.recording,
      );
    },
  );

  test(
    'status preserves failed and recovered phases even when a snapshot exists',
    () async {
      gateway.launchFails = true;
      await expectLater(service.start('test', options), throwsStateError);
      gateway.snapshotBytes = List<int>.of(_snapshot);
      expect((await service.status('test')).phase, RemoteProfilerPhase.failed);
      await service.recover('test');
      expect(
        (await service.status('test')).phase,
        RemoteProfilerPhase.recovered,
      );
    },
  );

  test('state directories and files are private on POSIX', () async {
    if (Platform.isWindows) return;
    final RemoteProfilerCapture capture = await service.start('test', options);
    final Directory targetDirectory = Directory(
      p.join(directory.path, gateway.target.key),
    );
    expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    expect((await targetDirectory.stat()).mode & 0x1ff, 0x1c0);
    for (final String name in <String>[
      'capture.json',
      '${capture.id}.json',
      'capture.lock',
    ]) {
      expect(
        (await File(p.join(targetDirectory.path, name)).stat()).mode & 0x1ff,
        0x180,
      );
    }
  });

  test(
    'attach records durable intent without power or startup mutations',
    () async {
      gateway.running = true;
      gateway.beforeAttach = () async {
        final Map<String, Object?> saved =
            jsonDecode(
                  await File(
                    p.join(directory.path, gateway.target.key, 'capture.json'),
                  ).readAsString(),
                )
                as Map<String, Object?>;
        expect(saved['phase'], 'starting');
        expect(saved['attached'], isTrue);
        expect(saved['startupRestored'], isTrue);
      };
      final RemoteProfilerCapture capture = await service.start(
        'test',
        const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
      );
      expect(capture.attached, isTrue);
      expect(capture.startupRestored, isTrue);
      expect(capture.phase, RemoteProfilerPhase.recording);
      expect(gateway.events, <String>['stage', 'attach', 'prove-agent']);
      expect(gateway.startup, 'java -jar server.jar');
      expect((await service.status('test')).attached, isTrue);
    },
  );

  test('attach requires an existing running JVM and rejects restart', () async {
    await expectLater(
      service.start(
        'test',
        const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
      ),
      throwsStateError,
    );
    await expectLater(
      service.start(
        'test',
        const RemoteProfilerOptions(
          agentDirectory: '/agent',
          attach: true,
          restart: true,
        ),
      ),
      throwsArgumentError,
    );
    expect(gateway.events, isEmpty);
  });

  test('attach failure and recovery never modify startup or power', () async {
    gateway.running = true;
    gateway.attachFails = true;
    await expectLater(
      service.start(
        'test',
        const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
      ),
      throwsStateError,
    );
    expect((await service.status('test')).phase, RemoteProfilerPhase.failed);
    expect(gateway.events, <String>['stage', 'attach']);
    gateway.startup = 'operator command';
    final RemoteProfilerCapture recovered = await service.recover('test');
    expect(recovered.attached, isTrue);
    expect(recovered.phase, RemoteProfilerPhase.recovered);
    expect(gateway.startup, 'operator command');
    expect(gateway.events, <String>['stage', 'attach']);
  });

  test('live attachment supports tunnels after exact agent proof', () async {
    gateway.running = true;
    final RemoteProfilerCapture capture = await service.start(
      'test',
      const RemoteProfilerOptions(
        agentDirectory: '/agent',
        attach: true,
        live: true,
      ),
    );
    expect(capture.live, isTrue);
    final RemoteProfilerTunnel tunnel = await service.openTunnel('test');
    expect(tunnel.localPort, 8849);
    await tunnel.close();
    expect(gateway.events, <String>[
      'stage',
      'attach',
      'prove-agent',
      'prove-agent',
    ]);
  });

  test(
    'records recovery intent before remote mutation and restores startup after agent proof',
    () async {
      gateway.beforeWrite = (String command) async {
        final Map<String, Object?> saved =
            jsonDecode(
                  await File(
                    p.join(directory.path, gateway.target.key, 'capture.json'),
                  ).readAsString(),
                )
                as Map<String, Object?>;
        expect(saved['originalStartup'], 'java -jar server.jar');
        expect(saved['stage'], isNotNull);
        if (command.contains('agentpath')) expect(saved['phase'], 'starting');
      };
      final RemoteProfilerCapture capture = await service.start(
        'test',
        options,
      );
      expect(capture.phase, RemoteProfilerPhase.recording);
      expect(capture.startupRestored, isTrue);
      expect(gateway.startup, 'java -jar server.jar');
      expect(gateway.events, <String>[
        'stage',
        'write-profile',
        'start',
        'prove-agent',
        'write-original',
      ]);
      final RemoteProfilerService reopened = RemoteProfilerService(
        gateway: gateway,
        stateDirectory: directory.path,
      );
      expect((await reopened.status('test')).id, capture.id);
    },
  );

  test('refuses running target without restart authorization', () async {
    gateway.running = true;
    await expectLater(service.start('test', options), throwsStateError);
    expect(gateway.events, isEmpty);
  });

  test(
    'waits for graceful stop and never launches after stop failure',
    () async {
      gateway.running = true;
      gateway.stopFails = true;
      await expectLater(
        service.start(
          'test',
          const RemoteProfilerOptions(agentDirectory: '/agent', restart: true),
        ),
        throwsStateError,
      );
      expect(gateway.events, <String>['stage', 'stop']);
      expect(gateway.startup, 'java -jar server.jar');
      expect((await service.status('test')).startupRestored, isTrue);
    },
  );

  test(
    'failed startup restores launch settings and leaves durable failure',
    () async {
      gateway.launchFails = true;
      await expectLater(service.start('test', options), throwsStateError);
      final RemoteProfilerCapture capture = await service.status('test');
      expect(capture.phase, RemoteProfilerPhase.failed);
      expect(capture.error, contains('start failed'));
      expect(capture.startupRestored, isTrue);
      expect(gateway.startup, 'java -jar server.jar');
    },
  );

  test('operator edits are preserved and block another capture', () async {
    gateway.onConfirm = () => gateway.startup = 'java -Xmx8G -jar server.jar';
    final RemoteProfilerCapture capture = await service.start('test', options);
    expect(capture.phase, RemoteProfilerPhase.operatorChanged);
    expect(capture.startupRestored, isFalse);
    expect(gateway.startup, 'java -Xmx8G -jar server.jar');
    expect(
      (await service.recover('test')).phase,
      RemoteProfilerPhase.operatorChanged,
    );
    await expectLater(service.start('test', options), throwsStateError);
    gateway.startup = capture.originalStartup;
    expect(
      (await service.recover('test')).phase,
      RemoteProfilerPhase.recovered,
    );
  });

  test(
    'recovery restores a persisted interrupted startup before another capture',
    () async {
      gateway.launchFails = true;
      gateway.restoreFails = true;
      await expectLater(service.start('test', options), throwsStateError);
      expect((await service.status('test')).startupRestored, isFalse);
      gateway.restoreFails = false;
      final RemoteProfilerService reopened = RemoteProfilerService(
        gateway: gateway,
        stateDirectory: directory.path,
      );
      final RemoteProfilerCapture recovered = await reopened.recover('test');
      expect(recovered.phase, RemoteProfilerPhase.recovered);
      expect(recovered.startupRestored, isTrue);
      expect(gateway.startup, 'java -jar server.jar');
    },
  );

  test('blocks overlapping operations across service instances', () async {
    final Completer<void> gate = Completer<void>();
    gateway.stageGate = gate.future;
    final Future<RemoteProfilerCapture> pending = service.start(
      'test',
      options,
    );
    await gateway.stageEntered.future;
    final RemoteProfilerService other = RemoteProfilerService(
      gateway: gateway,
      stateDirectory: directory.path,
    );
    await expectLater(other.start('test', options), throwsStateError);
    gate.complete();
    await pending;
  });

  test('same UUID on different accounts has isolated capture state', () async {
    await service.start('test', options);
    gateway.target = const RemoteProfilerTarget(
      id: 'abcd',
      uuid: 'server-uuid',
      name: 'Test',
      profileId: 'another-panel',
      nodeId: 1,
    );
    await expectLater(service.status('test'), throwsStateError);
    expect(
      (await service.start('test', options)).target.profileId,
      'another-panel',
    );
  });

  test('downloads a stable snapshot and logs atomically', () async {
    await service.start('test', options);
    gateway.snapshotBytes = List<int>.of(_snapshot);
    final RemoteProfilerFetch fetched = await service.fetch('test');
    expect(fetched.files, hasLength(1));
    expect(await File(fetched.files.single).readAsBytes(), _snapshot);
    expect(await File(fetched.logsPath).readAsString(), 'server startup');
    expect(fetched.capture.phase, RemoteProfilerPhase.complete);
    expect(
      await Directory(directory.path)
          .list(recursive: true)
          .where((FileSystemEntity entity) => entity.path.endsWith('.partial'))
          .isEmpty,
      isTrue,
    );
  });

  test(
    'incomplete snapshot download does not complete capture or leave partial files',
    () async {
      await service.start('test', options);
      gateway.snapshotBytes = List<int>.of(_snapshot);
      gateway.truncateDownload = true;
      await expectLater(service.fetch('test'), throwsStateError);
      expect((await service.status('test')).phase, RemoteProfilerPhase.ready);
      expect(
        await Directory(directory.path)
            .list(recursive: true)
            .where(
              (FileSystemEntity entity) => entity.path.endsWith('.partial'),
            )
            .isEmpty,
        isTrue,
      );
    },
  );

  test('snapshot changing during download is rejected', () async {
    await service.start('test', options);
    gateway.snapshotBytes = List<int>.of(_snapshot);
    gateway.growDownload = true;
    await expectLater(service.fetch('test'), throwsStateError);
  });

  test(
    'live tunnel requires the recorded live agent to still be present',
    () async {
      await service.start(
        'test',
        const RemoteProfilerOptions(agentDirectory: '/agent', live: true),
      );
      final RemoteProfilerTunnel tunnel = await service.openTunnel(
        'test',
        localPort: 8850,
      );
      expect(tunnel.localPort, 8850);
      await tunnel.close();
      gateway.agentPresent = false;
      await expectLater(service.openTunnel('test'), throwsStateError);
    },
  );
}

final class _Gateway implements RemoteProfilerGateway {
  RemoteProfilerTarget target = const RemoteProfilerTarget(
    id: 'abcd',
    uuid: 'server-uuid',
    name: 'Test',
    profileId: 'panel',
    nodeId: 1,
  );
  String startup = 'java -jar server.jar';
  bool running = false;
  bool stopFails = false;
  bool launchFails = false;
  bool attachFails = false;
  Future<void> Function()? beforeAttach;
  bool restoreFails = false;
  bool agentPresent = true;
  bool truncateDownload = false;
  bool growDownload = false;
  List<int> snapshotBytes = <int>[];
  final List<String> events = <String>[];
  Future<void> Function(String command)? beforeWrite;
  void Function()? onConfirm;
  Future<void>? stageGate;
  final Completer<void> stageEntered = Completer<void>();
  RemoteProfilerStage? staged;

  @override
  Future<RemoteProfilerTarget> resolveTarget(String selector) async => target;

  @override
  Future<RemoteProfilerCheck> inspect(RemoteProfilerTarget target) async =>
      RemoteProfilerCheck(
        target: target,
        javaVersion: '25',
        os: 'linux',
        architecture: 'amd64',
        startupCommand: startup,
        isRunning: running,
      );

  @override
  Future<RemoteProfilerStage> stage(
    RemoteProfilerTarget target,
    String captureId,
    RemoteProfilerOptions options,
  ) async {
    events.add('stage');
    if (!stageEntered.isCompleted) stageEntered.complete();
    await stageGate;
    return staged = RemoteProfilerStage(
      startupCommand: 'JAVA_TOOL_OPTIONS=-agentpath:/agent/lib.so $startup',
      remoteDirectory: '/home/container/profile/$captureId',
      snapshotPath: '/home/container/profile/$captureId/startup.jps',
      agentArgument: '-agentpath:/agent/lib.so',
    );
  }

  @override
  Future<String> readStartup(RemoteProfilerTarget target) async => startup;

  @override
  Future<void> writeStartup(RemoteProfilerTarget target, String command) async {
    await beforeWrite?.call(command);
    if (restoreFails && !command.contains('agentpath')) {
      throw StateError('restore unavailable');
    }
    events.add(
      command.contains('agentpath') ? 'write-profile' : 'write-original',
    );
    startup = command;
  }

  @override
  Future<void> stopGracefully(
    RemoteProfilerTarget target,
    Duration timeout,
  ) async {
    events.add('stop');
    if (stopFails) throw StateError('stop timed out');
    running = false;
  }

  @override
  Future<void> start(RemoteProfilerTarget target) async {
    events.add('start');
    if (launchFails) throw StateError('start failed');
  }

  @override
  Future<void> attach(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    RemoteProfilerOptions options,
  ) async {
    await beforeAttach?.call();
    events.add('attach');
    if (attachFails) throw StateError('JVM attachment disabled');
  }

  @override
  Future<bool> confirmLaunch(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    Duration timeout,
  ) async {
    events.add('prove-agent');
    onConfirm?.call();
    return agentPresent;
  }

  @override
  Future<List<RemoteProfilerSnapshot>> listSnapshots(
    RemoteProfilerTarget target,
    String remoteDirectory,
  ) async => snapshotBytes.isEmpty
      ? <RemoteProfilerSnapshot>[]
      : <RemoteProfilerSnapshot>[
          RemoteProfilerSnapshot(
            path: staged!.snapshotPath,
            size: snapshotBytes.length,
          ),
        ];

  @override
  Future<void> download(
    RemoteProfilerTarget target,
    String remotePath,
    String localPath,
  ) async {
    await File(
      localPath,
    ).writeAsBytes(truncateDownload ? <int>[1] : snapshotBytes);
    if (growDownload) snapshotBytes.add(5);
  }

  @override
  Future<void> downloadLogs(
    RemoteProfilerTarget target,
    String remoteDirectory,
    String localPath,
  ) async {
    expect(remoteDirectory, staged!.remoteDirectory);
    await File(localPath).writeAsString('server startup');
  }

  @override
  Future<RemoteProfilerTunnel> openTunnel(
    RemoteProfilerTarget target,
    int remotePort,
    int localPort,
  ) async => _Tunnel(localPort);
}

final class _Tunnel implements RemoteProfilerTunnel {
  _Tunnel(this.localPort);
  @override
  final int localPort;
  final Completer<int> _exit = Completer<int>();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  Future<void> close() async {
    if (!_exit.isCompleted) _exit.complete(0);
  }
}
