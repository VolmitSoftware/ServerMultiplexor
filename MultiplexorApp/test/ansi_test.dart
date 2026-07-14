import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:test/test.dart';

void main() {
  group('Ansi.clipVisible', () {
    test('returns short plain text unchanged', () {
      expect(Ansi.clipVisible('hello', 10), 'hello');
    });

    test('clips plain text to the visible width', () {
      expect(Ansi.clipVisible('hello world', 5), 'hello');
    });

    test('returns styled text unchanged when it fits', () {
      final String styled = Ansi.style('hi', Ansi.cyan);
      expect(Ansi.clipVisible(styled, 10), styled);
    });

    test('clips styled text by visible columns, not raw length', () {
      final String styled = Ansi.style('hello world', Ansi.cyan);
      final String clipped = Ansi.clipVisible(styled, 5);
      expect(Ansi.strip(clipped), 'hello');
    });

    test('preserves escape sequences before the clip point', () {
      final String text = '${Ansi.cyan}ab${Ansi.reset}cdef';
      final String clipped = Ansi.clipVisible(text, 3);
      expect(clipped.contains(Ansi.cyan), isTrue);
      expect(Ansi.strip(clipped), 'abc');
    });

    test('terminates clipped styled text with a reset', () {
      final String styled = Ansi.style('hello world', Ansi.cyan);
      final String clipped = Ansi.clipVisible(styled, 5);
      expect(clipped.endsWith(Ansi.reset), isTrue);
    });

    test('does not append a duplicate reset when nothing was clipped', () {
      expect(Ansi.clipVisible('plain', 10), 'plain');
    });

    test('handles zero width', () {
      expect(Ansi.strip(Ansi.clipVisible('hello', 0)), '');
    });

    test('exact-width text is unchanged', () {
      expect(Ansi.clipVisible('12345', 5), '12345');
    });
  });
}
