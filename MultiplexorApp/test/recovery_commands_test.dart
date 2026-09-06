import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:multiplexor/models/backup_summary.dart';
import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/recovery_runtime.dart';
import 'package:multiplexor/services/server_ping.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late ConsumerService consumers;
  late _FakeRuntime runtime;
  late _InstallerRunner installer;
  late String consumerRoot;
  late String instancePath;
  late File originalJar;
  late File candidateJar;

  Future<CapturedResult> command(List<String> args) =>
      service.execute(args, stream: false);
  setUp(() {
    root = Directory.systemTemp.createTempSync('multiplexor-recovery-test-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: true,
    );
    consumers = ConsumerService(context)
      ..ensureConsumerDirs(ConsumerProfile.plugin);
    consumerRoot = consumers.rootFor(ConsumerProfile.plugin);
    instancePath = p.join(consumerRoot, 'instances', 'fixture');
    Directory(instancePath).createSync(recursive: true);
    originalJar =
        File(p.join(consumerRoot, 'builds', 'paper', 'paper-1.21.11-100.jar'))
          ..createSync(recursive: true)
          ..writeAsStringSync('old jar');
    originalJar.setLastModifiedSync(DateTime.utc(2020));
    candidateJar = File(p.join(root.path, 'candidate.jar'))
      ..writeAsStringSync('new jar');
    if (Platform.isWindows) {
      originalJar.copySync(p.join(instancePath, 'server.jar'));
    } else {
      Link(p.join(instancePath, 'server.jar')).createSync(originalJar.path);
    }
    File(p.join(instancePath, '.server-source')).writeAsStringSync(
      'type=paper\nmc=1.21.11\nlaunch=jar\njar=${originalJar.path}\nisolated=true\n',
    );
    File(
      p.join(instancePath, 'server.properties'),
    ).writeAsStringSync('server-port=25565\nserver-ip=0.0.0.0\n');
    File(p.join(instancePath, 'world.dat')).writeAsStringSync('before');
    runtime = _FakeRuntime();
    installer = _InstallerRunner();
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      recoveryRuntime: runtime,
      processRunner: installer,
      javaInspector: (String _) async => 99,
      processExecutor: (String exe, List<String> args) async =>
          ProcessResult(0, exe == 'tmux' ? 1 : 0, '', ''),
    );
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test(
    'backup survives update, prune, verify, and restore with no cache dependency',
    () async {
      final CapturedResult created = await command(<String>[
        'backup',
        'create',
        'fixture',
      ]);
      expect(created.exitCode, 0, reason: created.stderr);
      final BackupSummary backup = service.listBackups('fixture').single;
      final File newer = File(
        p.join(originalJar.parent.path, 'paper-1.21.11-101.jar'),
      )..writeAsStringSync('new jar');
      if (Platform.isWindows) {
        newer.copySync(p.join(instancePath, 'server.jar'));
      } else {
        Link(p.join(instancePath, 'server.jar'))
          ..deleteSync()
          ..createSync(newer.path);
      }
      File(p.join(instancePath, '.server-source')).writeAsStringSync(
        'type=paper\nlaunch=jar\njar=${newer.path}\nisolated=true\n',
      );
      expect((await command(<String>['build', 'prune', 'paper'])).exitCode, 0);
      expect(originalJar.existsSync(), isFalse);
      expect(
        (await command(<String>[
          'backup',
          'verify',
          'fixture',
          backup.id,
        ])).exitCode,
        0,
      );
      final CapturedResult restored = await command(<String>[
        'backup',
        'restore',
        'fixture',
        backup.id,
      ]);
      expect(restored.exitCode, 0, reason: restored.stderr);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'old jar',
      );
      expect(
        File(p.join(instancePath, '.server-source')).readAsStringSync(),
        contains('jar_rel=server.jar'),
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(instancePath, 'server.jar'),
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
    },
  );

  test(
    'live backup is rejected without stopping or publishing a snapshot',
    () async {
      runtime.running.add('fixture');
      final CapturedResult result = await command(<String>[
        'backup',
        'create',
        'fixture',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('stopped instance'));
      expect(runtime.events, isEmpty);
      expect(service.listBackups('fixture'), isEmpty);
    },
  );

  test(
    'corrupt backup is rejected before stopping or replacing original',
    () async {
      expect(
        (await command(<String>['backup', 'create', 'fixture'])).exitCode,
        0,
      );
      final BackupSummary backup = service.listBackups('fixture').single;
      File(
        p.join(
          consumerRoot,
          'backups',
          'fixture',
          backup.id,
          'snapshot',
          'server.jar',
        ),
      ).writeAsStringSync('corrupt');
      runtime.running.add('fixture');
      final CapturedResult result = await command(<String>[
        'backup',
        'restore',
        'fixture',
        backup.id,
      ]);
      expect(result.exitCode, 1);
      expect(runtime.events, isEmpty);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'old jar',
      );
    },
  );

  test(
    'missing linked launch dependency cannot produce a successful backup',
    () async {
      originalJar.deleteSync();
      final CapturedResult result = await command(<String>[
        'backup',
        'create',
        'fixture',
      ]);
      expect(result.exitCode, 1);
      expect(service.listBackups('fixture'), isEmpty);
    },
  );

  test('invalid update path leaves the original running', () async {
    runtime.running.add('fixture');
    final CapturedResult result = await command(<String>[
      'instance',
      'update',
      'fixture',
      '--jar',
      '${root.path}/missing.jar',
    ]);
    expect(result.exitCode, 2);
    expect(runtime.events, isEmpty);
    expect(runtime.running, contains('fixture'));
  });

  test('consistent update refuses to force a stalled shutdown', () async {
    runtime.running.add('fixture');
    runtime.failStop = true;
    final CapturedResult result = await command(<String>[
      'instance',
      'update',
      'fixture',
      '--jar',
      candidateJar.path,
    ]);
    expect(result.exitCode, 1);
    expect(runtime.running, contains('fixture'));
    expect(
      File(p.join(instancePath, 'server.jar')).readAsStringSync(),
      'old jar',
    );
    expect(service.listBackups('fixture'), isEmpty);
  });

  test(
    'ordinary update rolls back after failed readiness and restarts old world',
    () async {
      runtime.running.add('fixture');
      runtime.readiness = (String name) {
        if (File(p.join(instancePath, 'server.jar')).readAsStringSync() ==
            'new jar') {
          File(p.join(instancePath, 'world.dat')).writeAsStringSync('upgraded');
          return null;
        }
        return _ping;
      };
      final CapturedResult result = await command(<String>[
        'instance',
        'update',
        'fixture',
        '--jar',
        candidateJar.path,
      ]);
      expect(result.exitCode, 1);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'old jar',
      );
      expect(
        File(p.join(instancePath, 'world.dat')).readAsStringSync(),
        'before',
      );
      expect(runtime.running, contains('fixture'));
      expect(result.stdout, contains('Restored previous instance state'));
    },
  );

  test(
    'safe promotion uses exact candidate even if source jar changes during staging',
    () async {
      runtime.running.add('fixture');
      runtime.readiness = (String name) {
        if (name != 'fixture') {
          candidateJar.writeAsStringSync('untested replacement');
        }
        return _ping;
      };
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        candidateJar.path,
        '--promote',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'new jar',
      );
      expect(
        runtime.events.where((String event) => event == 'ready:fixture'),
        hasLength(1),
      );
      expect(runtime.running, <String>{'fixture'});
    },
  );

  test(
    'failed promotion restores latest world changes accepted during staging',
    () async {
      runtime.running.add('fixture');
      runtime.readiness = (String name) {
        if (name != 'fixture') {
          File(
            p.join(instancePath, 'world.dat'),
          ).writeAsStringSync('saved during staging');
          return _ping;
        }
        return File(p.join(instancePath, 'server.jar')).readAsStringSync() ==
                'new jar'
            ? null
            : _ping;
      };
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        candidateJar.path,
        '--promote',
      ]);
      expect(result.exitCode, 1);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'old jar',
      );
      expect(
        File(p.join(instancePath, 'world.dat')).readAsStringSync(),
        'saved during staging',
      );
      expect(runtime.running, <String>{'fixture'});
    },
  );

  test(
    'safe promotion returns originally stopped instance to stopped state',
    () async {
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        candidateJar.path,
        '--promote',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(runtime.running, isEmpty);
      expect(runtime.events, contains('ready:fixture'));
    },
  );

  test('failed staging leaves original intact and stops candidate', () async {
    runtime.running.add('fixture');
    runtime.readiness = (String name) => name == 'fixture' ? _ping : null;
    final CapturedResult result = await command(<String>[
      'instance',
      'safe-update',
      'fixture',
      '--jar',
      candidateJar.path,
      '--promote',
    ]);
    expect(result.exitCode, 1);
    expect(
      File(p.join(instancePath, 'server.jar')).readAsStringSync(),
      'old jar',
    );
    expect(runtime.running, <String>{'fixture'});
  });

  test(
    'shared update and restore retain ops and Iris links while staging stays isolated',
    () async {
      final File source = File(p.join(instancePath, '.server-source'));
      source.writeAsStringSync(
        source.readAsStringSync().replaceAll('isolated=true', 'isolated=false'),
      );
      final Directory packs = Directory(
        p.join(consumerRoot, 'shared-plugin-data', 'iris', 'packs'),
      )..createSync(recursive: true);
      File(p.join(packs.path, 'pack.json')).writeAsStringSync('pack');
      Directory(
        p.join(instancePath, 'plugins', 'iris'),
      ).createSync(recursive: true);
      Link(
        p.join(instancePath, 'plugins', 'iris', 'packs'),
      ).createSync(packs.path);
      final File ops =
          File(p.join(consumerRoot, 'shared-plugin-data', 'ops', 'ops.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync('[]');
      Link(p.join(instancePath, 'ops.json')).createSync(ops.path);
      runtime.readiness = (String name) {
        if (name != 'fixture') {
          final String stage = p.join(consumerRoot, 'instances', name);
          expect(
            FileSystemEntity.typeSync(
              p.join(stage, 'plugins', 'iris', 'packs'),
              followLinks: false,
            ),
            FileSystemEntityType.directory,
          );
          expect(
            FileSystemEntity.typeSync(
              p.join(stage, 'ops.json'),
              followLinks: false,
            ),
            FileSystemEntityType.file,
          );
          expect(
            File(p.join(stage, '.server-source')).readAsStringSync(),
            contains('isolated=true'),
          );
          expect(
            File(p.join(stage, 'server.properties')).readAsStringSync(),
            contains('server-ip=127.0.0.1'),
          );
        }
        return _ping;
      };
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        candidateJar.path,
        '--promote',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(Link(p.join(instancePath, 'ops.json')).targetSync(), ops.path);
      expect(
        Link(p.join(instancePath, 'plugins', 'iris', 'packs')).targetSync(),
        packs.path,
      );
      final BackupSummary backup = service.listBackups('fixture').first;
      final CapturedResult restored = await command(<String>[
        'backup',
        'restore',
        'fixture',
        backup.id,
      ]);
      expect(restored.exitCode, 0, reason: restored.stderr);
      expect(Link(p.join(instancePath, 'ops.json')).targetSync(), ops.path);
      expect(
        Link(p.join(instancePath, 'plugins', 'iris', 'packs')).targetSync(),
        packs.path,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'snapshot preparation failure restarts original without modifying its files',
    () async {
      runtime.running.add('fixture');
      Link(
        p.join(instancePath, 'broken-data'),
      ).createSync(p.join(root.path, 'absent'));
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        candidateJar.path,
        '--promote',
      ]);
      expect(result.exitCode, 1);
      expect(runtime.running, <String>{'fixture'});
      expect(runtime.events, <String>['stop:fixture', 'start:fixture']);
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'old jar',
      );
      expect(service.listBackups('fixture'), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test(
    'switching from installer launch to jar removes obsolete launch artifacts',
    () async {
      final File source = File(p.join(instancePath, '.server-source'));
      source.writeAsStringSync(
        'type=custom\nlaunch=argsfile\nargs_file_rel=libraries/old/unix_args.txt\nisolated=true\n',
      );
      File(p.join(instancePath, 'libraries', 'old', 'unix_args.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      File(
        p.join(instancePath, 'installer.jar'),
      ).writeAsStringSync('old installer');
      File(p.join(instancePath, 'run.sh')).writeAsStringSync('old launcher');
      final CapturedResult result = await command(<String>[
        'instance',
        'update',
        'fixture',
        '--jar',
        candidateJar.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        Directory(p.join(instancePath, 'libraries')).existsSync(),
        isFalse,
      );
      expect(File(p.join(instancePath, 'installer.jar')).existsSync(), isFalse);
      expect(File(p.join(instancePath, 'run.sh')).existsSync(), isFalse);
      expect(source.readAsStringSync(), isNot(contains('args_file_rel=')));
      expect(
        File(p.join(instancePath, 'server.jar')).readAsStringSync(),
        'new jar',
      );
    },
  );

  test('installer failure occurs before original shutdown', () async {
    consumers.ensureConsumerDirs(ConsumerProfile.forge);
    service.setConsumerOverride(ConsumerProfile.forge);
    final Directory mod = Directory(
      p.join(consumers.rootFor(ConsumerProfile.forge), 'instances', 'fixture'),
    )..createSync(recursive: true);
    File('${mod.path}/.server-source').writeAsStringSync(
      'type=forge\nlaunch=argsfile\nargs_file_rel=libraries/old/unix_args.txt\nisolated=true\n',
    );
    final File jar = File('${root.path}/forge-installer.jar')
      ..writeAsStringSync('installer');
    runtime.running.add('fixture');
    installer.fail = true;
    final CapturedResult result = await command(<String>[
      'instance',
      'update',
      'fixture',
      '--jar',
      jar.path,
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('installer failed before changing'));
    expect(runtime.events, isEmpty);
    expect(installer.runs, 1);
  });

  test(
    'installer update prepares once and promotes exact installed libraries',
    () async {
      consumers.ensureConsumerDirs(ConsumerProfile.forge);
      service.setConsumerOverride(ConsumerProfile.forge);
      final Directory mod = Directory(
        p.join(
          consumers.rootFor(ConsumerProfile.forge),
          'instances',
          'fixture',
        ),
      )..createSync(recursive: true);
      File('${mod.path}/.server-source').writeAsStringSync(
        'type=forge\nlaunch=argsfile\nargs_file_rel=libraries/old/unix_args.txt\nisolated=true\n',
      );
      File('${mod.path}/libraries/old/unix_args.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('-cp old.jar Main');
      File(
        '${mod.path}/server.properties',
      ).writeAsStringSync('server-port=25565\n');
      final File jar = File('${root.path}/forge-installer.jar')
        ..writeAsStringSync('installer');
      final CapturedResult result = await command(<String>[
        'instance',
        'safe-update',
        'fixture',
        '--jar',
        jar.path,
        '--promote',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(installer.runs, 1);
      expect(
        File('${mod.path}/libraries/new/runtime.jar').readAsStringSync(),
        'prepared library',
      );
      expect(Directory('${mod.path}/libraries/old').existsSync(), isFalse);
      expect(
        File('${mod.path}/.server-source').readAsStringSync(),
        contains('artifact_sha256=${sha256.convert(jar.readAsBytesSync())}'),
      );
    },
  );
}

const MinecraftPingResult _ping = MinecraftPingResult(
  online: 0,
  max: 20,
  versionName: 'fixture',
  motd: '',
  sample: <String>[],
  latency: Duration.zero,
);

class _FakeRuntime implements RecoveryRuntime {
  final Set<String> running = <String>{};
  final List<String> events = <String>[];
  bool failStop = false;
  MinecraftPingResult? Function(String)? readiness;
  @override
  Future<bool> isRunning(ConsumerProfile profile, String instance) async =>
      running.contains(instance);
  @override
  Future<void> start(ConsumerProfile profile, String instance) async {
    events.add('start:$instance');
    running.add(instance);
  }

  @override
  Future<void> stopGracefully(ConsumerProfile profile, String instance) async {
    events.add('stop:$instance');
    if (failStop) throw TimeoutException('stalled shutdown');
    running.remove(instance);
  }

  @override
  Future<MinecraftPingResult?> waitUntilReady(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async {
    events.add('ready:$instance');
    return readiness == null ? _ping : readiness!(instance);
  }
}

class _InstallerRunner extends ProcessRunner {
  bool fail = false;
  int runs = 0;
  @override
  Future<CapturedResult> runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    runs++;
    if (fail) {
      return CapturedResult(
        exitCode: 1,
        stdout: '',
        stderr: 'fixture installer failure',
      );
    }
    File(
        '$workingDirectory/libraries/new/${Platform.isWindows ? 'win_args.txt' : 'unix_args.txt'}',
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('-cp libraries/new/runtime.jar Main');
    File(
      '$workingDirectory/libraries/new/runtime.jar',
    ).writeAsStringSync('prepared library');
    return CapturedResult(exitCode: 0, stdout: '', stderr: '');
  }
}
