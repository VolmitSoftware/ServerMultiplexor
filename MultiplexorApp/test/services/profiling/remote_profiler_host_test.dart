import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/profiling/remote_profiler_host.dart';
import 'package:multiplexor/services/profiling/remote_profiler_host_store.dart';
import 'package:multiplexor/services/profiling/remote_profiler_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_process.dart';
import 'package:test/test.dart';

const RemoteProfilerTarget target = RemoteProfilerTarget(
  id: '01234567',
  uuid: '01234567-89ab-cdef-0123-456789abcdef',
  name: 'Test',
  profileId: 'remote',
  nodeId: 2,
);

const String completedLog =
    '2026-01-01T00:00:00Z JProfiler> Saving snapshot /home/container/.multiplexor-profiler/capture01/capture.jps ...\n2026-01-01T00:00:01Z JProfiler> Done.\n';

void main() {
  late Directory temporary;
  late RemoteProfilerHostStore hosts;
  late _Runner runner;
  late SshRemoteProfilerGateway gateway;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('profiler-host-test-');
    hosts = RemoteProfilerHostStore(temporary.path)
      ..save(
        RemoteProfilerHostConfig(
          profileId: 'remote',
          nodeId: 2,
          sshTarget: 'operator@node.example.test',
          sudoDocker: true,
        ),
      );
    runner = _Runner();
    gateway = SshRemoteProfilerGateway(
      pterodactyl: PterodactylService(
        profileStore: PterodactylProfileStore(temporary.path),
        credentialStore: PterodactylCredentialStore(
          temporary.path,
          environment: <String, String>{},
        ),
      ),
      profileId: 'remote',
      hosts: hosts,
      processRunner: runner,
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('SSH mappings remain distinct by profile and node', () {
    hosts.save(
      RemoteProfilerHostConfig(
        profileId: 'other',
        nodeId: 2,
        sshTarget: 'other-node',
      ),
    );
    hosts.save(
      RemoteProfilerHostConfig(
        profileId: 'remote',
        nodeId: 3,
        sshTarget: 'third-node',
      ),
    );
    expect(hosts.load('remote', 2)!.sshTarget, 'operator@node.example.test');
    expect(hosts.load('REMOTE', 2)!.sshTarget, 'operator@node.example.test');
    expect(hosts.load('other', 2)!.sshTarget, 'other-node');
    expect(hosts.load('remote', 3)!.sshTarget, 'third-node');
    expect(hosts.load('missing', 2), isNull);
  });

  test('rejects SSH option injection and relative identity paths', () {
    for (final String value in <String>[
      '-oProxyCommand=evil',
      'host;evil',
      'host\nother',
      'user@host command',
    ]) {
      expect(
        () => RemoteProfilerHostConfig(
          profileId: 'remote',
          nodeId: 2,
          sshTarget: value,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => RemoteProfilerHostConfig(
        profileId: 'remote',
        nodeId: 2,
        sshTarget: 'node',
        identityFile: 'relative/key',
      ),
      throwsFormatException,
    );
  });

  test(
    'transport requires known host verification and noninteractive SSH',
    () async {
      runner.responses.addAll(<String>[
        _container(),
        'capture.jps\t1234\n',
        '',
        completedLog,
      ]);
      final List<RemoteProfilerSnapshot> snapshots = await gateway
          .listSnapshots(
            target,
            '/home/container/.multiplexor-profiler/capture01',
          );
      expect(snapshots.single.size, 1234);
      expect(
        runner.calls.first,
        containsAll(<String>['BatchMode=yes', 'StrictHostKeyChecking=yes']),
      );
      expect(
        runner.calls.first.last,
        contains(
          "sudo -n docker 'inspect' '--type' 'container' '${target.uuid}'",
        ),
      );
      expect(
        runner.calls[1].last,
        contains(
          "'/server data/${target.uuid}/.multiplexor-profiler/capture01'",
        ),
      );
    },
  );

  test(
    'rejects docker inspect alias that does not match the exact UUID',
    () async {
      runner.responses.add(_container(name: '/other-server'));
      await expectLater(
        gateway.listSnapshots(
          target,
          '/home/container/.multiplexor-profiler/capture01',
        ),
        throwsStateError,
      );
      expect(runner.calls, hasLength(1));
    },
  );

  test('rejects snapshot path traversal before SSH', () async {
    await expectLater(
      gateway.download(
        target,
        '/home/container/.multiplexor-profiler/../secret',
        '${temporary.path}/download',
      ),
      throwsArgumentError,
    );
    expect(runner.calls, isEmpty);
  });

  test(
    'tunnel binds loopback and closes owned foreground SSH process',
    () async {
      runner.responses.addAll(<String>[_container(), '']);
      final RemoteProfilerTunnel tunnel = await gateway.openTunnel(
        target,
        8849,
        18849,
      );
      expect(tunnel.localPort, 18849);
      expect(
        runner.started,
        containsAll(<String>[
          '-N',
          '-L',
          '127.0.0.1:18849:172.18.0.2:8849',
          'ExitOnForwardFailure=yes',
        ]),
      );
      await tunnel.close();
      await tunnel.close();
      expect(runner.handle.kills, 1);
      expect(await tunnel.exitCode, 0);
    },
  );

  test('excludes snapshots still open in the JVM', () async {
    runner.responses.addAll(<String>[
      _container(),
      'capture.jps\t1234\n',
      '/home/container/.multiplexor-profiler/capture01/capture.jps\n',
      completedLog,
    ]);
    expect(
      await gateway.listSnapshots(
        target,
        '/home/container/.multiplexor-profiler/capture01',
      ),
      isEmpty,
    );
  });

  test(
    'attaches to exactly one Java process without power or startup writes',
    () async {
      runner.responses.addAll(<String>[
        _container(),
        '42\n',
        '42:\nreturn code: 0\n',
      ]);
      await gateway.attach(
        target,
        const RemoteProfilerStage(
          startupCommand: 'java -jar server.jar',
          remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
          snapshotPath:
              '/home/container/.multiplexor-profiler/capture01/capture.jps',
          agentArgument:
              '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
        ),
        const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
      );
      expect(runner.calls.last.last, contains("exec jcmd 42 JVMTI.agent_load"));
      expect(
        runner.calls.last.last,
        contains("grep -F libjprofilerti.so /proc/42/maps"),
      );
    },
  );

  test('refuses ambiguous running Java processes', () async {
    runner.responses.addAll(<String>[_container(), '42\n43\n']);
    await expectLater(
      gateway.attach(
        target,
        const RemoteProfilerStage(
          startupCommand: 'java -jar server.jar',
          remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
          snapshotPath:
              '/home/container/.multiplexor-profiler/capture01/capture.jps',
          agentArgument:
              '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
        ),
        const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
      ),
      throwsStateError,
    );
    expect(runner.calls, hasLength(2));
  });

  test('refuses a profiler port published by Docker', () async {
    runner.responses.add(_container(published: true));
    await expectLater(
      gateway.openTunnel(target, 8849, 18849),
      throwsStateError,
    );
    expect(runner.started, isEmpty);
  });

  test(
    'stopped probe preserves the container user and exact image digest',
    () async {
      runner.responses.addAll(<String>[
        _container(running: false, user: '1234:1234'),
        'x86_64\n1234\n1234\n',
      ]);
      await expectLater(
        gateway.stage(
          target,
          'capture01',
          RemoteProfilerOptions(agentDirectory: '${temporary.path}/missing'),
        ),
        throwsArgumentError,
      );
      expect(runner.calls.last.last, contains("'--user' '1234:1234'"));
      expect(runner.calls.last.last, contains("'--pull=never'"));
      expect(runner.calls.last.last, contains("'sha256:exact-image'"));
    },
  );

  test(
    'does not open a tunnel when the native agent port is unreachable',
    () async {
      runner.responses.addAll(<String>[_container(), 'Connection refused']);
      runner.exitCodes.addAll(<int>[0, 1]);
      await expectLater(
        gateway.openTunnel(target, 8849, 18849),
        throwsStateError,
      );
      expect(runner.started, isEmpty);
    },
  );

  test('startup confirmation waits for Wings container replacement', () async {
    runner.responses.addAll(<String>[
      '',
      _container(),
      'started',
      '',
      'mapped agent',
    ]);
    runner.errors.addAll(<String>[
      'Error response from daemon: No such container: ${target.uuid}',
      '',
      '',
    ]);
    runner.exitCodes.addAll(<int>[1, 0, 0, 0, 0]);
    expect(
      await gateway.confirmLaunch(
        target,
        const RemoteProfilerStage(
          startupCommand: 'java -jar server.jar',
          remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
          snapshotPath:
              '/home/container/.multiplexor-profiler/capture01/capture.jps',
          agentArgument:
              '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
        ),
        const Duration(seconds: 3),
      ),
      isTrue,
    );
    expect(runner.calls, hasLength(5));
    expect(
      runner.calls[3].last,
      contains('nohup timeout --kill-after=5s 420s'),
    );
  });

  test(
    'startup confirmation does not swallow SSH authentication errors',
    () async {
      runner.responses.add('');
      runner.errors.add('Permission denied (publickey).');
      runner.exitCodes.add(255);
      await expectLater(
        gateway.confirmLaunch(
          target,
          const RemoteProfilerStage(
            startupCommand: 'java -jar server.jar',
            remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
            snapshotPath:
                '/home/container/.multiplexor-profiler/capture01/capture.jps',
            agentArgument:
                '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
          ),
          const Duration(seconds: 3),
        ),
        throwsStateError,
      );
      expect(runner.calls, hasLength(1));
    },
  );

  test(
    'closed snapshots without the matching vendor completion marker stay unavailable',
    () async {
      runner.responses.addAll(<String>[
        _container(),
        'capture.jps\t1234\n',
        '',
        'JProfiler> Saving snapshot /home/container/.multiplexor-profiler/capture01/capture.jps ...\n',
      ]);
      expect(
        await gateway.listSnapshots(
          target,
          '/home/container/.multiplexor-profiler/capture01',
        ),
        isEmpty,
      );
    },
  );

  test(
    'capture logs are fetched only from the requested capture directory',
    () async {
      final List<String> downloads = <String>[];
      gateway = SshRemoteProfilerGateway(
        pterodactyl: gateway.pterodactyl,
        profileId: 'remote',
        hosts: hosts,
        processRunner: runner,
        downloader: (List<String> arguments, String path) async {
          downloads.add(arguments.last);
        },
      );
      runner.responses.add(_container());
      await gateway.downloadLogs(
        target,
        '/home/container/.multiplexor-profiler/capture01',
        '${temporary.path}/startup.log',
      );
      expect(
        downloads.single,
        contains(
          'container-id:/home/container/.multiplexor-profiler/capture01/startup.log',
        ),
      );
      expect(downloads.single, isNot(contains("'logs'")));
    },
  );

  test(
    'an existing collector marker never launches a replacement or truncates its log',
    () async {
      runner.responses.addAll(<String>[_container(), 'existing', 'mapped']);
      expect(
        await gateway.confirmLaunch(
          target,
          const RemoteProfilerStage(
            startupCommand: 'java -jar server.jar',
            remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
            snapshotPath:
                '/home/container/.multiplexor-profiler/capture01/capture.jps',
            agentArgument:
                '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
          ),
          const Duration(seconds: 2),
        ),
        isTrue,
      );
      expect(
        runner.calls.any((List<String> call) => call.last.contains('nohup')),
        isFalse,
      );
      expect(
        runner.calls.any((List<String> call) => call.last.contains('cat >')),
        isFalse,
      );
    },
  );

  test(
    'native agent rejection is not accepted when jcmd exits successfully',
    () async {
      runner.responses.addAll(<String>[
        _container(),
        '42\n',
        '42:\nreturn code: -1\n',
      ]);
      await expectLater(
        gateway.attach(
          target,
          const RemoteProfilerStage(
            startupCommand: 'java -jar server.jar',
            remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
            snapshotPath:
                '/home/container/.multiplexor-profiler/capture01/capture.jps',
            agentArgument:
                '-agentpath:/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so=offline',
          ),
          const RemoteProfilerOptions(agentDirectory: '/agent', attach: true),
        ),
        throwsStateError,
      );
    },
  );

  for (final bool live in <bool>[false, true]) {
    test(
      'jcmd preserves quoted ${live ? 'live' : 'offline'} settings through both shells',
      () async {
        final String settings = live
            ? 'port=8849,address=0.0.0.0,nowait'
            : 'offline,snapshot=/home/container/.multiplexor-profiler/capture01/capture.jps,recording=cpu,duration=10s,callTreeMode=sampling';
        const String library =
            '/home/container/.multiplexor-profiler/capture01/agent/bin/linux-x64/libjprofilerti.so';
        runner.responses.addAll(<String>[
          _container(),
          '42\n',
          '42:\nreturn code: 0\n',
        ]);
        await gateway.attach(
          target,
          RemoteProfilerStage(
            startupCommand: 'java -jar server.jar',
            remoteDirectory: '/home/container/.multiplexor-profiler/capture01',
            snapshotPath:
                '/home/container/.multiplexor-profiler/capture01/capture.jps',
            agentArgument: '-agentpath:$library=$settings',
          ),
          RemoteProfilerOptions(
            agentDirectory: '/agent',
            attach: true,
            live: live,
          ),
        );
        final Directory bin = Directory('${temporary.path}/bin')..createSync();
        final File sudo = File('${bin.path}/sudo')
          ..writeAsStringSync('#!/bin/sh\nshift\nexec "\$@"\n');
        final File docker = File('${bin.path}/docker')
          ..writeAsStringSync(
            '#!/bin/sh\nfor value do last="\$value"; done\nprintf %s "\$last"\n',
          );
        final File jcmd = File('${bin.path}/jcmd')
          ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$@"\n');
        final ProcessResult permissions = await Process.run('chmod', <String>[
          '700',
          sudo.path,
          docker.path,
          jcmd.path,
        ]);
        expect(permissions.exitCode, 0);
        final Map<String, String> environment = <String, String>{
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
        };
        final ProcessResult remoteShell = await Process.run('/bin/sh', <String>[
          '-c',
          runner.calls.last.last,
        ], environment: environment);
        expect(remoteShell.exitCode, 0, reason: remoteShell.stderr.toString());
        final String innerScript = remoteShell.stdout.toString();
        final String invocation = innerScript.substring(
          innerScript.lastIndexOf('exec jcmd '),
        );
        final ProcessResult containerShell = await Process.run(
          '/bin/sh',
          <String>['-c', invocation],
          environment: environment,
        );
        expect(
          containerShell.exitCode,
          0,
          reason: containerShell.stderr.toString(),
        );
        expect(
          const LineSplitter().convert(containerShell.stdout.toString()),
          <String>['42', 'JVMTI.agent_load', library, '"$settings"'],
        );
      },
      skip: Platform.isWindows,
    );
  }

  test('tunnel fails when SSH exits and never returns a live handle', () async {
    runner.responses.addAll(<String>[_container(), '']);
    runner.handle.exited = true;
    await expectLater(
      gateway.openTunnel(target, 8849, 18849),
      throwsStateError,
    );
  });
}

String _container({
  String? name,
  bool published = false,
  bool running = true,
  String user = '1000:1000',
}) => jsonEncode(<Object?>[
  <String, Object?>{
    'Id': 'container-id',
    'Image': 'sha256:exact-image',
    'Name': name ?? '/${target.uuid}',
    'Config': <String, Object?>{'Image': 'java-image', 'User': user},
    'State': <String, Object?>{'Running': running},
    'Mounts': <Object?>[
      <String, Object?>{
        'Destination': '/home/container',
        'Source': '/server data/${target.uuid}',
        'RW': true,
      },
    ],
    'NetworkSettings': <String, Object?>{
      'Ports': <String, Object?>{
        '8849/tcp': published
            ? <Object?>[
                <String, String>{'HostPort': '8849'},
              ]
            : null,
      },
      'Networks': <String, Object?>{
        'pterodactyl': <String, Object?>{'IPAddress': '172.18.0.2'},
      },
    },
  },
]);

final class _Runner implements PterodactylSmbProcessRunner {
  final List<String> responses = <String>[];
  final List<int> exitCodes = <int>[];
  final List<String> errors = <String>[];
  final List<List<String>> calls = <List<String>>[];
  List<String> started = <String>[];
  final _Handle handle = _Handle();
  @override
  Future<PterodactylSmbCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    expect(executable, 'ssh');
    calls.add(arguments);
    return PterodactylSmbCommandResult(
      exitCode: exitCodes.isEmpty ? 0 : exitCodes.removeAt(0),
      stdout: responses.removeAt(0),
      stderr: errors.isEmpty ? '' : errors.removeAt(0),
    );
  }

  @override
  Future<PterodactylSmbProcessHandle> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool detached = false,
  }) async {
    expect(detached, isFalse);
    started = arguments;
    return handle;
  }

  @override
  Future<bool> executableExists(String executable) async => true;
  @override
  Future<String?> describeProcess(int pid) async => null;
  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) =>
      false;
}

final class _Handle implements PterodactylSmbProcessHandle {
  bool exited = false;
  int kills = 0;
  @override
  int get pid => 123;
  @override
  String get diagnostic => 'SSH exited';
  @override
  Future<int?> waitForExit(Duration timeout) async => exited ? 0 : null;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    exited = true;
    return true;
  }
}
