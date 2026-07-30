import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:test/test.dart';

List<TermEvent> feed(TermEventParser parser, String sequence) {
  final List<TermEvent> events = <TermEvent>[];
  for (final int byte in sequence.codeUnits) {
    events.addAll(parser.add(byte));
  }
  return events;
}

void main() {
  group('TermEventParser keys', () {
    test('parses printable characters', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, 'q');
      expect(events, hasLength(1));
      expect(events.single.kind, TermEventKind.char);
      expect(events.single.char, 'q');
    });

    test('preserves case for uppercase letters', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, 'R');
      expect(events, hasLength(1));
      expect(events.single.kind, TermEventKind.char);
      expect(events.single.char, 'R');
    });

    test('parses enter for both CR and LF', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\r').single.kind, TermEventKind.enter);
      expect(feed(parser, '\n').single.kind, TermEventKind.enter);
    });

    test('parses arrow keys from CSI sequences', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1B[A').single.kind, TermEventKind.arrowUp);
      expect(feed(parser, '\x1B[B').single.kind, TermEventKind.arrowDown);
      expect(feed(parser, '\x1B[C').single.kind, TermEventKind.arrowRight);
      expect(feed(parser, '\x1B[D').single.kind, TermEventKind.arrowLeft);
    });

    test('parses SS3 arrow variants', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1BOA').single.kind, TermEventKind.arrowUp);
    });

    test('parses ctrl-c', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x03').single.kind, TermEventKind.ctrlC);
    });

    test('resolves a lone escape via timeout', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1B'), isEmpty);
      expect(parser.hasPartial, isTrue);
      final TermEvent? resolved = parser.timeout();
      expect(resolved?.kind, TermEventKind.escape);
      expect(parser.hasPartial, isFalse);
    });

    test('timeout returns null when nothing is pending', () {
      final TermEventParser parser = TermEventParser();
      expect(parser.timeout(), isNull);
    });

    test('parses utf8 multi-byte character', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = <TermEvent>[];
      for (final int byte in <int>[0xC3, 0xA9]) {
        events.addAll(parser.add(byte));
      }
      expect(events.single.kind, TermEventKind.char);
      expect(events.single.char, 'é');
    });
  });

  group('TermEventParser mouse', () {
    test('parses SGR left button press with position', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, '\x1B[<0;34;12M');
      expect(events, hasLength(1));
      expect(events.single.kind, TermEventKind.mouseDown);
      expect(events.single.col, 34);
      expect(events.single.row, 12);
      expect(events.single.button, 0);
    });

    test('parses SGR left button release', () {
      final TermEventParser parser = TermEventParser();
      final TermEvent event = feed(parser, '\x1B[<0;5;7m').single;
      expect(event.kind, TermEventKind.mouseUp);
      expect(event.row, 7);
    });

    test('parses wheel up and wheel down', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1B[<64;1;1M').single.kind, TermEventKind.wheelUp);
      expect(
        feed(parser, '\x1B[<65;1;1M').single.kind,
        TermEventKind.wheelDown,
      );
    });

    test('parses SGR motion with no button held as mouseMove', () {
      final TermEventParser parser = TermEventParser();
      final TermEvent event = feed(parser, '\x1B[<35;10;5M').single;
      expect(event.kind, TermEventKind.mouseMove);
      expect(event.col, 10);
      expect(event.row, 5);
    });

    test('parses SGR drag motion (button held) as mouseMove', () {
      final TermEventParser parser = TermEventParser();
      final TermEvent event = feed(parser, '\x1B[<32;3;4M').single;
      expect(event.kind, TermEventKind.mouseMove);
      expect(event.col, 3);
      expect(event.row, 4);
    });

    test(
      'parses SGR motion with release-suffix identically to press-suffix',
      () {
        final TermEventParser parser = TermEventParser();
        final TermEvent event = feed(parser, '\x1B[<35;10;5m').single;
        expect(event.kind, TermEventKind.mouseMove);
        expect(event.col, 10);
        expect(event.row, 5);
      },
    );
  });

  group('TermEventParser legacy X10 mouse', () {
    // X10 encoding: ESC [ M cb cx cy with each value offset by 32. Sent by
    // terminals that ignore the SGR-1006 extension.
    String x10(int cb, int col, int row) {
      return '\x1B[M${String.fromCharCode(cb + 32)}'
          '${String.fromCharCode(col + 32)}${String.fromCharCode(row + 32)}';
    }

    test('parses a left button press with position', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, x10(0, 34, 12));
      expect(events, hasLength(1));
      expect(events.single.kind, TermEventKind.mouseDown);
      expect(events.single.col, 34);
      expect(events.single.row, 12);
      expect(events.single.button, 0);
    });

    test('parses a release (X10 reports button 3 on release)', () {
      final TermEventParser parser = TermEventParser();
      final TermEvent event = feed(parser, x10(3, 5, 7)).single;
      expect(event.kind, TermEventKind.mouseUp);
      expect(event.row, 7);
      expect(event.col, 5);
    });

    test('parses wheel up and wheel down', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, x10(64, 1, 1)).single.kind, TermEventKind.wheelUp);
      expect(feed(parser, x10(65, 1, 1)).single.kind, TermEventKind.wheelDown);
    });

    test('ignores motion events', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, x10(32, 9, 9)).single.kind, TermEventKind.unknown);
    });

    test('press then release then a key parses in sequence', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(
        parser,
        '${x10(0, 10, 6)}${x10(3, 10, 6)}q',
      );
      expect(events, hasLength(3));
      expect(events[0].kind, TermEventKind.mouseDown);
      expect(events[1].kind, TermEventKind.mouseUp);
      expect(events[2].kind, TermEventKind.char);
      expect(events[2].char, 'q');
    });

    test('timeout mid-sequence resolves to unknown and recovers', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1B[M'), isEmpty);
      expect(parser.timeout()!.kind, TermEventKind.unknown);
      expect(feed(parser, 'q').single.kind, TermEventKind.char);
    });
  });

  group('TermEventParser cursor report', () {
    test('parses CPR response', () {
      final TermEventParser parser = TermEventParser();
      final TermEvent event = feed(parser, '\x1B[24;80R').single;
      expect(event.kind, TermEventKind.cursorReport);
      expect(event.row, 24);
      expect(event.col, 80);
    });

    test('recovers cleanly when garbage precedes a CPR response', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, 'ab\x1B[3;1R');
      expect(events, hasLength(3));
      expect(events.last.kind, TermEventKind.cursorReport);
      expect(events.last.row, 3);
    });
  });
}
