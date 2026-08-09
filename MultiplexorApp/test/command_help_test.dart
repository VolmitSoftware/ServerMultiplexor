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
  });
}
