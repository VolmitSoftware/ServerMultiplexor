import 'package:multiplexor/cli/command_help.dart';
import 'package:test/test.dart';

void main() {
  group('command help', () {
    test('recognizes focused help forms', () {
      expect(isCliHelpRequest(<String>['help', 'runtime']), isTrue);
      expect(isCliHelpRequest(<String>['runtime', '--help']), isTrue);
      expect(isCliHelpRequest(<String>['server', 'create', '-h']), isTrue);
      expect(isCliHelpRequest(<String>['runtime', 'status']), isFalse);
    });

    test('prints focused command help', () {
      final lines = <String>[];
      final code = printCliHelpForArgs(
        <String>['server', 'create', '--help'],
        write: lines.add,
        error: lines.add,
      );

      expect(code, 0);
      expect(lines.first, 'Multiplexor server');
      expect(lines.join('\n'), contains('./start.sh server create <name>'));
      expect(lines.join('\n'), isNot(contains('Multiplexor runtime')));
    });

    test('prints global help for help --help', () {
      final lines = <String>[];
      final code = printCliHelpForArgs(
        <String>['help', '--help'],
        write: lines.add,
        error: lines.add,
      );

      expect(code, 0);
      expect(lines.first, 'Multiplexor');
      expect(lines.join('\n'), contains('Commands:'));
    });

    test('reports unknown help topics', () {
      final lines = <String>[];
      final code = printCliHelpForArgs(
        <String>['help', 'missing'],
        write: lines.add,
        error: lines.add,
      );

      expect(code, 2);
      expect(lines.join('\n'), contains('Unknown help topic: missing'));
      expect(lines.join('\n'), contains('Available help topics:'));
    });

    test('documents Mineflayer gameplay commands', () {
      final lines = <String>[];
      final code = printCliHelpForArgs(
        <String>['help', 'gameplay'],
        write: lines.add,
        error: lines.add,
      );

      expect(code, 0);
      expect(lines.first, 'Multiplexor gameplay');
      expect(lines.join('\n'), contains('gameplay prepare [instance]'));
      expect(lines.join('\n'), contains('gameplay run <scenario> [instance]'));
      expect(lines.join('\n'), contains('--viewer-port <port>'));
      expect(lines.join('\n'), contains('--no-viewer'));
    });

    test('documents complete remote administration and history', () {
      final List<String> lines = <String>[];
      final int code = printCliHelpForArgs(
        <String>['help', 'remote'],
        write: lines.add,
        error: lines.add,
      );

      expect(code, 0);
      final String output = lines.join('\n');
      expect(output, contains('remote account add'));
      expect(output, contains('remote history <server>'));
      expect(output, contains('remote drive install'));
      expect(output, contains('remote drive trust'));
      expect(output, contains('remote drive start'));
      expect(output, contains('remote drive open [server]'));
      expect(output, contains('remote files <...> (compatibility alias'));
      expect(output, contains('remote smb <...> (compatibility alias'));
      expect(output, isNot(contains('files authorize')));
      expect(output, contains('remote reinstall <server>'));
      expect(output, contains('remote delete <server>'));
      expect(
        output,
        contains('remote bulk <start|stop|restart|kill|reinstall|delete>'),
      );
      expect(output, contains('remote create-many --template <server>'));
      expect(output, contains('--state <running|offline>'));
      expect(output, contains('--concurrency <1-8>'));
      expect(output, contains('remote variable <server>'));
      expect(output, contains('remote limits <server>'));
    });
  });
}
