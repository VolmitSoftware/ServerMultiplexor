import 'package:multiplexor/cli/handlers/remote_profile_handler.dart';
import 'package:multiplexor/cli/remote_profile_command.dart';
import 'package:multiplexor/services/profiling/remote_profiler_models.dart';
import 'package:test/test.dart';

void main() {
  test('startup recording preserves explicit restart authorization', () {
    final RemoteProfileCommand command = RemoteProfileCommand.parse(<String>[
      'start',
      'test-server',
      '--startup',
      '--duration',
      '5m',
      '--restart',
      '--profile',
      'development',
    ]);
    expect(command.action, RemoteProfileAction.start);
    expect(command.server, 'test-server');
    expect(command.duration, const Duration(minutes: 5));
    expect(command.flag('restart'), isTrue);
    expect(command.option('profile'), 'development');
    expect(command.option('agent-dir'), isNull);
    expect(
      RemoteProfileCommand.parse(<String>[
        'start',
        'test-server',
        '--startup',
      ]).flag('restart'),
      isFalse,
    );
  });

  test('rejects unknown, misplaced, missing, and repeated options', () {
    final List<List<String>> invalid = <List<String>>[
      <String>[],
      <String>['unknown', 'test-server'],
      <String>['check'],
      <String>['check', 'one', 'two'],
      <String>['check', 'test-server', '--restart'],
      <String>['check', 'test-server', '--profile'],
      <String>['check', 'test-server', '--profile', '--open'],
      <String>['check', 'test-server', '--profile', ''],
      <String>['check', 'test-server', '--profile', 'one', '--profile', 'two'],
      <String>['start', 'test-server', '--startup', '--startup'],
      <String>['start', 'test-server'],
      <String>['start', 'test-server', '--startup', '--port', '8849'],
      <String>['start', 'test-server', '--startup', '--session-id', '1'],
      <String>[
        'start',
        'test-server',
        '--startup',
        '--agent-dir',
        '/tmp/agent',
        '--agent-version',
        '16.2',
      ],
      <String>['host-set', 'test-server'],
      <String>[
        'host-set',
        'test-server',
        '--ssh-target',
        'node',
        '--ssh-port',
        '0',
      ],
      <String>['live', 'test-server', '--local-port', '65536'],
      <String>['live', 'test-server', '--local-port', '1.5'],
      <String>['check', 'test-server', '--api-key', 'secret'],
    ];
    for (final List<String> args in invalid) {
      expect(
        () => RemoteProfileCommand.parse(args),
        throwsArgumentError,
        reason: args.toString(),
      );
    }
  });

  test('duration has explicit units and a bounded capture window', () {
    expect(
      RemoteProfileCommand.parseDuration('1s'),
      const Duration(seconds: 1),
    );
    expect(
      RemoteProfileCommand.parseDuration('24h'),
      const Duration(hours: 24),
    );
    for (final String value in <String>[
      '0s',
      '25h',
      '-1s',
      '120',
      '1.5m',
      '86401s',
    ]) {
      expect(
        () => RemoteProfileCommand.parseDuration(value),
        throwsArgumentError,
      );
    }
  });

  test('running attachment cannot restart or request startup capture', () {
    final RemoteProfileCommand command = RemoteProfileCommand.parse(<String>[
      'start',
      'test-server',
      '--attach',
    ]);
    expect(command.flag('attach'), isTrue);
    expect(command.flag('startup'), isFalse);
    expect(
      () => RemoteProfileCommand.parse(<String>[
        'start',
        'test-server',
        '--attach',
        '--startup',
      ]),
      throwsArgumentError,
    );
    expect(
      () => RemoteProfileCommand.parse(<String>[
        'start',
        'test-server',
        '--attach',
        '--restart',
      ]),
      throwsArgumentError,
    );
  });

  test('live recording cannot silently ignore an offline duration', () {
    expect(
      () => RemoteProfileCommand.parse(<String>[
        'start',
        'test-server',
        '--startup',
        '--live',
        '--duration',
        '120s',
      ]),
      throwsArgumentError,
    );
  });

  test('live startup and advanced session options parse independently', () {
    final RemoteProfileCommand command = RemoteProfileCommand.parse(<String>[
      'start',
      'test-server',
      '--startup',
      '--live',
      '--port',
      '9000',
      '--config',
      '/tmp/session.xml',
      '--session-id',
      '7',
    ]);
    expect(command.flag('live'), isTrue);
    expect(command.option('port'), '9000');
    expect(command.option('session-id'), '7');
    expect(command.duration, const Duration(seconds: 120));
  });

  test('capture output distinguishes restoration from JVM unloading', () {
    final RemoteProfilerCapture capture = RemoteProfilerCapture(
      id: 'capture-1',
      target: const RemoteProfilerTarget(
        id: 'id',
        uuid: 'uuid',
        name: 'Test\nServer',
        profileId: 'dev',
        nodeId: 1,
      ),
      createdAt: DateTime.utc(2026),
      originalStartup: 'java -jar server.jar',
      durationSeconds: 120,
      live: false,
      port: 8849,
      phase: RemoteProfilerPhase.recording,
      startupRestored: true,
    );
    final List<String> lines = remoteProfilerCaptureLines(capture);
    expect(lines, contains('startup restored: true'));
    expect(lines, contains('phase: recording'));
    expect(lines.last, contains('until a normal restart'));
    expect(lines.any((String line) => line.contains('\n')), isFalse);
  });
}
