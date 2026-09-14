import 'package:multiplexor/cli/local_command.dart';
import 'package:multiplexor/models/gameplay_swarm.dart';
import 'package:test/test.dart';

GameplaySwarmSettings settings({
  String profile = 'idle',
  Map<String, String> options = const <String, String>{},
  Set<String> flags = const <String>{},
}) => GameplaySwarmSettings.parse(
  profile: profile,
  options: options,
  flags: flags,
  generatedPrefix: 'Sw123abc',
);

void main() {
  test('defaults produce bounded deterministic workers with unique names', () {
    final GameplaySwarmSettings value = settings();
    expect(value.bots, 4);
    expect(value.durationSeconds, 60);
    expect(value.seed, 1);
    expect(value.joinIntervalMilliseconds, 1000);
    expect(value.radius, 16);
    expect(value.origin, '0,80,0');
    expect(value.workerNames, <String>[
      'Sw123abc01',
      'Sw123abc02',
      'Sw123abc03',
      'Sw123abc04',
    ]);
    expect(value.requiresController, isFalse);
  });

  test('largest swarm names remain legal Minecraft usernames', () {
    final GameplaySwarmSettings value = settings(
      options: <String, String>{
        'bots': '256',
        'prefix': 'TwelveChars_',
        'seed': '4294967295',
      },
    );
    expect(value.workerNames.length, 256);
    expect(value.workerNames.toSet().length, 256);
    expect(value.workerNames.last, 'TwelveChars_256');
    expect(value.workerNames.every((String name) => name.length <= 16), isTrue);
  });

  test('stress supports week-long runs with typed bounds and goals', () {
    final GameplaySwarmSettings value = settings(
      profile: 'stress',
      options: <String, String>{
        'bots': '256',
        'duration': '604800',
        'bounds': '-32, 80,-32:32,96,32',
        'goals': 'mine=10000,build=10000',
        'completion': 'goals',
        'workload': '/tmp/stress workload.json',
      },
    );
    expect(value.requiresController, isTrue);
    expect(value.customPlan, isFalse);
    expect(value.durationSeconds, 604800);
    expect(value.bounds!.minimum, <int>[-32, 80, -32]);
    expect(value.bounds!.argument, '-32,80,-32:32,96,32');
    expect(value.goals, <String, int>{'mine': 10000, 'build': 10000});
    expect(value.goalsArgument, 'mine=10000,build=10000');
    expect(value.completion, 'goals');
  });

  test('stress options reject invalid shapes before orchestration', () {
    for (final Map<String, String> options in <Map<String, String>>[
      <String, String>{'bounds': '1,80,0:0,90,10'},
      <String, String>{'bounds': '0,90,0:10,80,10'},
      <String, String>{'bounds': '0,80,0:10,90,10:20,90,20'},
      <String, String>{'bounds': '0,-49,0:10,90,10'},
      <String, String>{'bounds': '0,80,0:29999001,90,10'},
      <String, String>{'bounds': '0,80,0:10,NaN,10'},
      <String, String>{'goals': ''},
      <String, String>{'goals': 'mine=1,mine=2'},
      <String, String>{'goals': 'mine=0'},
      <String, String>{'goals': 'mine=1000000001'},
      <String, String>{'goals': 'mine=1.5'},
      <String, String>{'goals': 'fly=1'},
      <String, String>{'workload': 'plan.mjs'},
      <String, String>{'completion': 'forever'},
      <String, String>{'scatter': '128'},
    ]) {
      expect(
        () => settings(profile: 'stress', options: options),
        throwsFormatException,
        reason: '$options',
      );
    }
    for (final String option in <String>[
      'workload',
      'bounds',
      'goals',
      'completion',
    ]) {
      expect(
        () => settings(options: <String, String>{option: 'value'}),
        throwsFormatException,
      );
    }
  });

  test('CLI accepts stress workload and completion controls', () {
    final List<String> command = <String>[
      'gameplay',
      'swarm',
      'stress',
      'qa',
      '--bots',
      '256',
      '--duration',
      '604800',
      '--workload',
      'long run.json',
      '--bounds',
      '-32,80,-32:32,96,32',
      '--goals',
      'mine=10000,build=10000',
      '--completion',
      'goals',
    ];
    expect(LocalCommand.parse(command).arguments, command);
  });

  test(
    'controller is reserved for explicitly requested setup or custom recipes',
    () {
      expect(settings(profile: 'wander').requiresController, isFalse);
      expect(settings(profile: 'redstone').requiresController, isFalse);
      expect(
        settings(flags: <String>{'build-arena'}).requiresController,
        isTrue,
      );
      expect(
        settings(
          options: <String, String>{'scatter': '128'},
        ).requiresController,
        isTrue,
      );
      expect(
        settings(profile: '/tmp/example plan.json').requiresController,
        isTrue,
      );
      for (final String profile in <String>['workshop', 'mixed']) {
        expect(() => settings(profile: profile), throwsFormatException);
        expect(
          settings(
            profile: profile,
            flags: <String>{'build-arena'},
          ).requiresController,
          isTrue,
        );
      }
      expect(
        () => settings(
          options: <String, String>{'scatter': '128'},
          flags: <String>{'build-arena'},
        ),
        throwsFormatException,
      );
      expect(
        () =>
            settings(profile: '/tmp/plan.json', flags: <String>{'build-arena'}),
        throwsFormatException,
      );
      expect(
        () => settings(
          options: <String, String>{'origin': '29999000,80,0', 'scatter': '8'},
        ),
        throwsFormatException,
      );
    },
  );

  for (final MapEntry<String, List<String>> bound in <String, List<String>>{
    'bots': <String>['0', '257', '0x10', '+4'],
    'duration': <String>['0', '604801'],
    'seed': <String>['-1', '4294967296'],
    'join-interval': <String>['99', '10001'],
    'radius': <String>['3', '65'],
    'scatter': <String>['7', '4097'],
    'prefix': <String>['', 'too_long_name_', 'contains space'],
    'origin': <String>[
      '0x10,80,0',
      '0,0',
      '0,a,0',
      '0,-49,0',
      '0,257,0',
      '29999001,80,0',
    ],
    'startup-timeout': <String>['0', '3601'],
    'connect-timeout': <String>['0', '301'],
    'action-timeout': <String>['0', '121'],
  }.entries) {
    test('invalid ${bound.key} is rejected before orchestration', () {
      for (final String value in bound.value) {
        expect(
          () => settings(options: <String, String>{bound.key: value}),
          throwsFormatException,
        );
      }
    });
  }

  test(
    'CLI accepts swarm controls and rejects privilege or remote overrides',
    () {
      final List<String> command = <String>[
        'gameplay',
        'swarm',
        'wander',
        '--instance',
        'qa',
        '--bots',
        '8',
        '--duration',
        '60',
        '--seed',
        '7',
        '--join-interval',
        '100',
        '--radius',
        '16',
        '--prefix',
        'Test',
        '--origin',
        '-32,80,-32',
        '--scatter',
        '128',
        '--chat',
        '--prepare',
        '--start',
        '--stop-after',
        '--startup-timeout',
        '180',
        '--connect-timeout',
        '30',
        '--action-timeout',
        '15',
        '--version',
        '1.21.11',
        '--viewer-port',
        '3007',
        '--json',
      ];
      expect(LocalCommand.parse(command).arguments, command);
      expect(
        LocalCommand.parse(<String>[
          'gameplay',
          'swarm-profiles',
          '--json',
        ]).arguments,
        <String>['gameplay', 'swarm-profiles', '--json'],
      );
      for (final String flag in <String>[
        'controller',
        'host',
        'auth',
        'username',
        'command',
        'op',
      ]) {
        expect(
          () => LocalCommand.parse(<String>[
            'gameplay',
            'swarm',
            'idle',
            '--$flag',
            'value',
          ]),
          throwsFormatException,
        );
      }
      expect(
        () => LocalCommand.parse(<String>['gameplay', 'swarm']),
        throwsFormatException,
      );
      expect(
        () =>
            LocalCommand.parse(<String>['gameplay', 'swarm-profiles', 'extra']),
        throwsFormatException,
      );
    },
  );
}
