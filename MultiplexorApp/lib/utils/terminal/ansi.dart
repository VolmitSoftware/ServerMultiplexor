/// ANSI styling helpers shared by the interactive UI.
class Ansi {
  Ansi._();

  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String inverse = '\x1B[7m';
  static const String red = '\x1B[31m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String magenta = '\x1B[35m';
  static const String cyan = '\x1B[36m';
  static const String gray = '\x1B[90m';
  static const String eraseLine = '\x1B[2K';
  static const String eraseToEnd = '\x1B[0K';

  /// Subtle dark background used for the selected menu row (256-color).
  static const String bgHighlight = '\x1B[48;5;236m';

  static String style(String text, String codes) => '$codes$text$reset';

  /// Length of [text] without ANSI escape sequences.
  static int visibleLength(String text) => strip(text).length;

  static final RegExp _ansiPattern = RegExp(r'\x1B\[[0-9;?]*[A-Za-z]');

  static String strip(String text) => text.replaceAll(_ansiPattern, '');

  /// Pads [text] to [width] visible columns, accounting for ANSI codes.
  static String padVisible(String text, int width) {
    final int visible = visibleLength(text);
    if (visible >= width) {
      return text;
    }
    return text + ' ' * (width - visible);
  }

  /// Clips [text] to at most [width] visible columns, keeping escape
  /// sequences intact. Prevents soft-wrapped rows from corrupting in-place
  /// menu repaints. A reset is appended only when styled text was clipped.
  static String clipVisible(String text, int width) {
    if (visibleLength(text) <= width) {
      return text;
    }
    final StringBuffer out = StringBuffer();
    int visible = 0;
    int i = 0;
    bool sawEscape = false;
    while (i < text.length && visible < width) {
      final Match? escape = _ansiPattern.matchAsPrefix(text, i);
      if (escape != null) {
        out.write(escape.group(0));
        i = escape.end;
        sawEscape = true;
        continue;
      }
      out.write(text[i]);
      visible++;
      i++;
    }
    if (sawEscape) {
      out.write(reset);
    }
    return out.toString();
  }
}
