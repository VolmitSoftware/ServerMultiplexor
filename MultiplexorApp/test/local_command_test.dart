import 'package:multiplexor/cli/local_command.dart';
import 'package:test/test.dart';

void main() {
  List<String> parse(List<String> args) => LocalCommand.parse(args).arguments;

  test('clone positional, named and mixed forms share one representation', () {
    for (final List<String> args in <List<String>>[
      <String>['source', 'target'],
      <String>['--source', 'source', '--target', 'target'],
      <String>['--target=target', '--source=source'],
      <String>['source', '--target', 'target'],
      <String>['--source', 'source', 'target'],
    ]) {
      expect(parse(<String>['instance', 'clone', ...args]), <String>[
        'instance',
        'clone',
        'source',
        'target',
      ]);
    }
  });

  test('name and runtime instance flags become canonical positionals', () {
    expect(
      parse(<String>['instance', 'create', '--name=demo', '--isolated']),
      <String>['instance', 'create', 'demo', '--isolated'],
    );
    expect(
      parse(<String>[
        'server',
        'create',
        '--name=demo',
        '--jar',
        '/tmp/a b.jar',
      ]),
      <String>['server', 'create', 'demo', '--jar', '/tmp/a b.jar'],
    );
    expect(
      parse(<String>['runtime', 'start', '--instance', 'demo', '--no-console']),
      <String>['runtime', 'start', 'demo', '--no-console'],
    );
    expect(
      () => parse(<String>['runtime', 'start', 'demo', '--instance', 'other']),
      throwsFormatException,
    );
  });

  test(
    'repeated artifacts keep order and flags are idempotently normalized',
    () {
      final List<String> result = parse(<String>[
        'server',
        'create',
        'demo',
        '--type=paper',
        '--isolated=true',
        '--artifact',
        'first.jar',
        '--artifact=second.jar',
        '--auto-build=false',
      ]);
      expect(result, <String>[
        'server',
        'create',
        'demo',
        '--type',
        'paper',
        '--isolated',
        '--artifact',
        'first.jar',
        '--artifact',
        'second.jar',
      ]);
      expect(parse(result), result);
    },
  );

  test('runtime settings retain instance scope and validate each action', () {
    expect(
      parse(<String>[
        'runtime',
        'settings',
        'set-heap',
        '6G',
        '--instance=demo',
      ]),
      <String>['runtime', 'settings', 'set-heap', '6G', '--instance', 'demo'],
    );
    expect(parse(<String>['runtime', 'settings', '--instance=demo']), <String>[
      'runtime',
      'settings',
      'show',
      '--instance',
      'demo',
    ]);
    for (final List<String> args in <List<String>>[
      <String>['presets', '--instance', 'demo'],
      <String>['show', 'extra'],
      <String>['set-heap'],
      <String>['set-heap', '4G', '8G'],
      <String>['set-preset', 'vanilla', '--heap', '4G'],
      <String>['typo'],
    ]) {
      expect(
        () => parse(<String>['runtime', 'settings', ...args]),
        throwsFormatException,
        reason: '$args',
      );
    }
  });

  test('bare commands preserve native default subcommands', () {
    const Map<String, String> defaults = <String, String>{
      'consumer': 'show',
      'instance': 'list',
      'runtime': 'status',
      'build': 'list',
      'repos': 'sync',
      'plugins': 'show-source',
      'mods': 'show-source',
      'config': 'localize',
      'backup': 'list',
      'template': 'list',
      'content': 'list',
      'addons': 'list',
      'gameplay': 'doctor',
    };
    for (final MapEntry<String, String> entry in defaults.entries) {
      expect(parse(<String>[entry.key]), <String>[entry.key, entry.value]);
    }
    expect(parse(<String>['doctor', '--json']), <String>['doctor', '--json']);
  });

  test('intentional native aliases normalize to public names', () {
    expect(parse(<String>['consumer', 'current']), <String>[
      'consumer',
      'show',
    ]);
    expect(parse(<String>['consumer', 'set', 'forge']), <String>[
      'consumer',
      'use',
      'forge',
    ]);
    expect(parse(<String>['consumer', 'root']), <String>['consumer', 'path']);
    expect(parse(<String>['runtime', 'console-all']), <String>[
      'runtime',
      'consoles',
    ]);
    expect(parse(<String>['runtime', 'console-lateral']), <String>[
      'runtime',
      'consoles-lateral',
    ]);
  });

  test('internal daemon commands retain opaque launch arguments', () {
    for (final List<String> args in <List<String>>[
      <String>['runtime', 'host', '--instance', 'demo', '--token', 'owner'],
      <String>['runtime', 'restart-worker', 'demo'],
      <String>['plugins', 'watch-daemon'],
      <String>['mods', 'watch-daemon'],
    ]) {
      expect(parse(args), args);
    }
  });

  test('build version convenience and equals values normalize once', () {
    expect(parse(<String>['build', 'paper', '1.21.4', '--force']), <String>[
      'build',
      'paper',
      '--force',
      '--mc',
      '1.21.4',
    ]);
    expect(
      () => parse(<String>['build', 'paper', '1.21.4', '--mc=1.21.5']),
      throwsFormatException,
    );
    expect(parse(<String>['template', 'init', 'demo', '--mc=1.21.4']), <String>[
      'template',
      'init',
      'demo',
      '--mc',
      '1.21.4',
    ]);
  });

  for (final List<String> malformed in <List<String>>[
    <String>['unknown'],
    <String>['instance', 'typo'],
    <String>['doctor', 'typo'],
    <String>['doctor', '--typo'],
    <String>['runtime', 'start', 'demo', '--no-consol'],
    <String>['runtime', 'start', 'demo', '--no-console=maybe'],
    <String>['server', 'create', 'demo', '--mc'],
    <String>['server', 'create', 'demo', '--mc='],
    <String>['server', 'create', 'demo', '--mc', '--isolated'],
    <String>['server', 'create', 'demo', '--mc', '-x'],
    <String>['server', 'create', 'demo', '--type=paper', '--type=purpur'],
    <String>['instance', 'clone', 'source'],
    <String>['instance', 'clone', 'a', 'b', 'c'],
    <String>['instance', 'clone', 'a', 'b', '--target=c'],
    <String>['instance', 'create', '--name='],
    <String>['instance', 'list', 'ignored'],
    <String>['content', 'list', 'ignored'],
    <String>['addons', 'update', 'demo', '--json'],
    <String>['runtime', 'status', 'demo', '-x'],
    <String>['runtime', 'start', 'demo', '--'],
  ]) {
    test('rejects ${malformed.join(' ')}', () {
      expect(() => parse(malformed), throwsFormatException);
    });
  }
}
