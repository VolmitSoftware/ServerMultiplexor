import 'dart:async';
import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const Map<ConsumerProfile, String> _installerNames = <ConsumerProfile, String>{
  ConsumerProfile.forge: 'forge-1.21.1-52.0.0-installer.jar',
  ConsumerProfile.neoforge: 'neoforge-21.1.234-installer.jar',
};

void main() {
  for (final bool failFirst in <bool>[false, true]) {
    test(
      'create-many overlaps installers, reserves ports, and '
      '${failFirst ? 'retains partial success' : 'deduplicates types'}',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'multiplexor-create-many-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final ManagerContext context = ManagerContext(
          rootDir: root.path,
          verbose: false,
        );
        final ConsumerService consumers = ConsumerService(context);
        final _ConcurrentInstallerRunner runner = _ConcurrentInstallerRunner(
          failFirst: failFirst,
        );
        final NativeCommandService service = NativeCommandService(
          context: context,
          consumerService: consumers,
          javaInspector: (String _) async => 25,
          processRunner: runner,
        );
        for (final ConsumerProfile profile in <ConsumerProfile>[
          ConsumerProfile.forge,
          ConsumerProfile.neoforge,
        ]) {
          consumers.ensureConsumerDirs(profile);
          File(
              p.join(
                consumers.rootFor(profile),
                'builds',
                profile.shortName,
                _installerNames[profile]!,
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('fixture installer ${profile.shortName}');
        }
        final CapturedResult existing = await service.execute(<String>[
          'instance',
          'create',
          'existing',
          '--isolated',
        ], stream: false);
        expect(existing.exitCode, 0, reason: existing.stderr);

        final Future<CapturedResult> creation = HttpOverrides.runZoned(
          () => service.execute(<String>[
            'server',
            'create-many',
            '--types',
            'forge,neoforge,FORGE',
            '--mc',
            '1.21.1',
            '--isolated',
          ], stream: false),
          createHttpClient: (_) => throw StateError(
            'Cached server creation must not request upstream builds',
          ),
        );
        addTearDown(() async {
          runner.releaseInstallers();
          await creation;
        });

        await Future.any<void>(<Future<void>>[runner.bothStarted, creation]);
        try {
          expect(runner.maximumActive, 2);
        } finally {
          runner.releaseInstallers();
        }
        final CapturedResult result = await creation;

        expect(result.exitCode, 0, reason: result.stderr);
        expect(runner.started, <String>['forge', 'neoforge']);
        expect(runner.ports.toSet(), hasLength(2));
        expect(runner.ports, everyElement(greaterThan(25565)));
        expect(
          result.stdout,
          contains(failFirst ? '1 created, 2 skipped' : '2 created, 1 skipped'),
        );
        expect(result.stdout, contains('already included in this batch'));
        if (failFirst) {
          expect(result.stderr, contains('fixture install failure'));
        }
        final File installed = File(
          p.join(
            consumers.rootFor(ConsumerProfile.neoforge),
            'instances',
            'neoforge',
            '.server-source',
          ),
        );
        expect(installed.readAsStringSync(), contains('launch=argsfile'));
        expect(
          installed.readAsStringSync(),
          contains(_installerNames[ConsumerProfile.neoforge]!),
        );
      },
    );
  }
}

final class _ConcurrentInstallerRunner extends ProcessRunner {
  _ConcurrentInstallerRunner({required this.failFirst});

  final bool failFirst;
  final Completer<void> _bothStarted = Completer<void>();
  final Completer<void> _releaseInstallers = Completer<void>();
  final List<String> started = <String>[];
  final List<int> ports = <int>[];
  int _active = 0;
  int maximumActive = 0;

  Future<void> get bothStarted => _bothStarted.future;

  void releaseInstallers() {
    if (!_releaseInstallers.isCompleted) _releaseInstallers.complete();
  }

  @override
  Future<CapturedResult> runCaptured(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    expect(executable, 'java');
    expect(arguments, contains('--installServer'));
    final String directory = workingDirectory!;
    final String name = p.basename(directory);
    final ConsumerProfile profile = name == 'forge'
        ? ConsumerProfile.forge
        : ConsumerProfile.neoforge;
    final String installer = arguments[arguments.indexOf('-jar') + 1];
    expect(
      File(installer).readAsStringSync(),
      'fixture installer ${profile.shortName}',
    );
    started.add(name);
    final String properties = File(
      p.join(directory, 'server.properties'),
    ).readAsStringSync();
    ports.add(
      int.parse(
        RegExp(
          r'^server-port=(\d+)',
          multiLine: true,
        ).firstMatch(properties)!.group(1)!,
      ),
    );
    _active++;
    if (_active > maximumActive) maximumActive = _active;
    if (started.length == 2) _bothStarted.complete();
    try {
      await _releaseInstallers.future;
      if (failFirst && name == 'forge') {
        return CapturedResult(
          exitCode: 1,
          stdout: '',
          stderr: 'fixture install failure',
        );
      }
      final String argsName = Platform.isWindows
          ? 'win_args.txt'
          : 'unix_args.txt';
      File(p.join(directory, 'libraries', 'fixture', argsName))
        ..createSync(recursive: true)
        ..writeAsStringSync('fixture args');
      return CapturedResult(exitCode: 0, stdout: '', stderr: '');
    } finally {
      _active--;
    }
  }
}
