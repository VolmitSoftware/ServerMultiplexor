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

    test('ignores drag motion events', () {
      final TermEventParser parser = TermEventParser();
      expect(feed(parser, '\x1B[<32;9;9M').single.kind, TermEventKind.unknown);
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
