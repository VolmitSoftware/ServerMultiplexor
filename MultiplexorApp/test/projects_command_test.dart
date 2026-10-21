import 'package:multiplexor/cli/command_help.dart';
import 'package:multiplexor/cli/local_command.dart';
import 'package:test/test.dart';

void main() {
  test('projects builds preserve selection and execution limits', () {
    expect(
      LocalCommand.parse(<String>[
        'projects',
        'build',
        'iris',
        '--target=fabric-26.1',
        '--jobs=3',
        '--memory=12',
        '--workers=2',
        '--wait=true',
        '--json',
      ]).arguments,
      <String>[
        'projects',
        'build',
        'iris',
        '--target',
        'fabric-26.1',
        '--jobs',
        '3',
        '--memory',
        '12',
        '--workers',
        '2',
        '--wait',
        '--json',
      ],
    );
  });

  test('projects defaults to the cached catalog', () {
    expect(LocalCommand.parse(<String>['projects']).arguments, <String>[
      'projects',
      'list',
    ]);
  });

  test('projects public actions and internal worker are accepted', () {
    for (List<String> arguments in <List<String>>[
      <String>['scan', '/source path', '--json'],
      <String>['list', '--json'],
      <String>['plan', '--all', '--all-targets', '--json'],
      <String>['plan', 'iris', '--target', 'bukkit,fabric-26.3', '--json'],
      <String>['plan', '--targets', 'iris:bukkit,gloss:api', '--json'],
      <String>['build', 'iris', '--target', 'bukkit,fabric-26.3'],
      <String>['build', '--targets', 'iris:bukkit,gloss:api'],
      <String>['build', '--all', '--all-targets'],
      <String>['build', '--all', '--all-targets', '--changed'],
      <String>['build', '--targets', 'iris:bukkit', '--packaging', 'local'],
      <String>['limits', '--json'],
      <String>['limits', '--jobs', '3', '--memory', '12288', '--workers', '6'],
      <String>['status', 'run-1', '--json'],
      <String>['logs', 'run-1', '--target', 'iris:bukkit', '--follow'],
      <String>['cancel', 'run-1'],
      <String>['retry', 'run-1', '--wait', '--json'],
      <String>['retry', 'run-1', '--packaging', 'compact'],
      <String>['destinations', '--json'],
      <String>['destination', 'exports', '--remove', '--json'],
      <String>['deploy', 'run-1', '--to', 'exports', '--preview', '--json'],
      <String>[
        'destination',
        'exports',
        '--path',
        '/exports',
        '--platform',
        'fabric',
        '--mc',
        '26.1',
      ],
      <String>['dashboard'],
      <String>['worker', 'run-1'],
    ]) {
      List<String> command = <String>['projects', ...arguments];
      expect(LocalCommand.parse(command).arguments, command);
    }
  });

  test('projects reject missing values and unexpected arguments', () {
    for (List<String> arguments in <List<String>>[
      <String>['scan'],
      <String>['list', 'iris'],
      <String>['build', 'iris', 'gloss'],
      <String>['build', 'iris', '--jobs'],
      <String>['build', 'iris', '--sandbox'],
      <String>['build', '--targets'],
      <String>['build', '--targets', ''],
      <String>['build', '--targets', 'iris:bukkit', '--targets', 'gloss:api'],
      <String>['limits', 'iris'],
      <String>['limits', '--jobs'],
      <String>['limits', '--all'],
      <String>['logs'],
      <String>['cancel'],
      <String>['retry'],
      <String>['deploy'],
      <String>['destination'],
      <String>['destinations', 'exports'],
      <String>['build', '--packaging'],
      <String>['dashboard', '--json'],
      <String>['dashboard', 'iris'],
    ]) {
      expect(
        () => LocalCommand.parse(<String>['projects', ...arguments]),
        throwsFormatException,
        reason: arguments.join(' '),
      );
    }
  });

  test('projects help includes build isolation controls and delivery', () {
    List<String> lines = <String>[];
    expect(
      printCliHelpForArgs(
        <String>['help', 'projects'],
        write: lines.add,
        error: lines.add,
      ),
      0,
    );
    String help = lines.join('\n');
    expect(help, contains('projects scan <path>'));
    expect(help, contains('--all-targets'));
    expect(help, contains('--target <id,...>'));
    expect(help, contains('projects plan --targets <project:target,...>'));
    expect(help, contains('projects build --targets <project:target,...>'));
    expect(help, contains('projects limits [--jobs <count>]'));
    expect(help, contains('--workers <total-count>'));
    expect(help, contains('projects deploy <run> --to <name>'));
    expect(help, contains('projects dashboard'));
    expect(help, contains('--packaging <local|compact>'));
    expect(help, contains('projects destinations [--json]'));
    expect(help, contains('destination <name> --remove'));
    expect(help, isNot(contains('projects worker')));
  });
}
