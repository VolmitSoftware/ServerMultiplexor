import 'package:multiplexor/cli/command_help.dart';
import 'package:multiplexor/cli/local_command.dart';
import 'package:test/test.dart';

void main() {
  List<String> parse(List<String> args) => LocalCommand.parse(args).arguments;

  test('network default and JSON catalogs normalize for automation', () {
    expect(parse(<String>['network']), <String>['network', 'list']);
    expect(parse(<String>['network', 'recover']), <String>[
      'network',
      'recover',
    ]);
    for (final String action in <String>['list', 'candidates']) {
      expect(parse(<String>['network', action, '--json=true']), <String>[
        'network',
        action,
        '--json',
      ]);
    }
  });

  test('creation keeps explicit forwarding and download arguments', () {
    final List<String> command = parse(<String>[
      'network',
      'create',
      'dev',
      '--members=lobby,survival',
      '--default=lobby',
      '--proxy=velocity',
      '--port=25565',
      '--bind=127.0.0.1',
      '--fallback=lobby,survival',
      '--jar=/tmp/Velocity Proxy.jar',
      '--proxy-version=3.4.0',
      '--offline=true',
    ]);
    expect(command, <String>[
      'network',
      'create',
      'dev',
      '--members',
      'lobby,survival',
      '--default',
      'lobby',
      '--proxy',
      'velocity',
      '--port',
      '25565',
      '--bind',
      '127.0.0.1',
      '--fallback',
      'lobby,survival',
      '--jar',
      '/tmp/Velocity Proxy.jar',
      '--proxy-version',
      '3.4.0',
      '--offline',
    ]);
    expect(parse(command), command);
    expect(
      parse(<String>['network', 'create', 'dev', '--offline=false']),
      <String>['network', 'create', 'dev'],
    );
  });

  test('every network operation is validated and available in help', () {
    final List<String> output = <String>[];
    expect(
      printCliHelpForArgs(<String>['help', 'network'], write: output.add),
      0,
    );
    for (final List<String> args in <List<String>>[
      <String>['add', 'dev', 'survival', '--alias', 'game', '--port', '25570'],
      <String>['remove', 'dev', 'game'],
      <String>[
        'configure',
        'dev',
        '--default',
        'lobby',
        '--fallback',
        'lobby',
        '--port',
        '25565',
        '--bind',
        '0.0.0.0',
      ],
      <String>['delete', 'dev', '--confirm', 'dev'],
      <String>['start', 'dev', '--timeout', '120'],
      <String>['stop', 'dev'],
      <String>['restart', 'dev', '--timeout', '120'],
      <String>['status', 'dev', '--json'],
      <String>['check', 'dev', '--json'],
      <String>['repair', 'dev'],
      <String>['console', 'dev'],
      <String>['plugins-sync', 'dev'],
    ]) {
      expect(parse(<String>['network', ...args]), <String>['network', ...args]);
      expect(output.join('\n'), contains(args.first));
    }
  });

  for (final List<String> args in <List<String>>[
    <String>['create'],
    <String>['add', 'dev'],
    <String>['remove', 'dev'],
    <String>['list', 'dev'],
    <String>['candidates', 'dev'],
    <String>['recover', 'dev'],
    <String>['status'],
    <String>['repair'],
    <String>['repair', 'dev', 'extra'],
    <String>['status', 'dev', 'extra'],
    <String>['configure', 'dev', '--port'],
    <String>['create', 'dev', '--offline=maybe'],
    <String>['create', 'dev', '--members=a', '--members=b'],
    <String>['stop', 'dev', '--timeout', '10'],
    <String>['configure', 'dev', '--offline'],
    <String>['plugins-sync', 'dev', '--clean'],
    <String>['delete', 'dev', '--confirm'],
  ]) {
    test('rejects network ${args.join(' ')} before native execution', () {
      expect(() => parse(<String>['network', ...args]), throwsFormatException);
    });
  }
}
