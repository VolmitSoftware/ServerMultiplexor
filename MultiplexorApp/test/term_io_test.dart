import 'package:multiplexor/utils/terminal/term_io.dart';
import 'package:test/test.dart';

void main() {
  group('TermIo mouse-reporting sequences', () {
    test('enable sequence turns on click and SGR extended modes', () {
      expect(
        TermIo.enableMouseSequence,
        '\x1B[?1003l\x1B[?1002l\x1B[?1000h\x1B[?1006h',
      );
      expect(TermIo.enableMouseSequence, isNot(contains('?1003h')));
      expect(TermIo.enableMouseSequence, isNot(contains('?1002h')));
    });

    test('disable sequence tears down in reverse order', () {
      expect(
        TermIo.disableMouseSequence,
        '\x1B[?1006l\x1B[?1003l\x1B[?1002l\x1B[?1000l',
      );
      expect(TermIo.disableMouseSequence, isNot(contains('?1003h')));
      expect(TermIo.disableMouseSequence, isNot(contains('?1002h')));
    });
  });
}
