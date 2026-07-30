import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:test/test.dart';

void main() {
  group('Ansi.fg256', () {
    test('renders a 256-color foreground escape sequence', () {
      expect(Ansi.fg256(45), '\x1B[38;5;45m');
    });

    test('renders index 0', () {
      expect(Ansi.fg256(0), '\x1B[38;5;0m');
    });
  });

  group('Ansi.fgRgb', () {
    test('renders a truecolor foreground escape sequence', () {
      expect(Ansi.fgRgb(47, 182, 170), '\x1B[38;2;47;182;170m');
    });

    test('renders black', () {
      expect(Ansi.fgRgb(0, 0, 0), '\x1B[38;2;0;0;0m');
    });
  });

  group('Ansi.strip', () {
    test('removes 256-color foreground codes', () {
      expect(Ansi.strip('${Ansi.fg256(45)}hi${Ansi.reset}'), 'hi');
    });

    test('removes truecolor foreground codes', () {
      expect(Ansi.strip('${Ansi.fgRgb(1, 2, 3)}hi${Ansi.reset}'), 'hi');
    });
  });

  group('Ansi.visibleLength', () {
    test('counts only visible characters around a truecolor code', () {
      expect(Ansi.visibleLength('${Ansi.fgRgb(1, 2, 3)}ab${Ansi.reset}'), 2);
    });

    test('counts only visible characters around a 256-color code', () {
      expect(Ansi.visibleLength('${Ansi.fg256(45)}ab${Ansi.reset}'), 2);
    });
  });

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
