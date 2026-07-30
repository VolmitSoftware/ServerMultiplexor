/// Computes a differential ANSI patch that turns a previously rendered
/// terminal frame into [next], writing only the lines that actually
/// changed. This keeps full-screen dashboard repaints flicker-free by
/// avoiding a clear-and-redraw on every frame.
///
/// When [previous] is `null` or [forceFull] is `true`, the whole screen is
/// cleared and [next] is written in full. When [previous] and [next] are
/// identical, nothing needs to be written and an empty string is returned.
/// Otherwise the two frames are split on `\n` and compared line by line;
/// each differing line is rewritten in place via a cursor-addressed escape
/// sequence, including trailing lines that were removed (cleared) or added
/// (written) when the line counts differ.
String renderTerminalPatch({
  required String? previous,
  required String next,
  bool forceFull = false,
}) {
  if (forceFull || previous == null) {
    return '\x1B[H\x1B[2J$next\x1B[0m';
  }
  if (previous == next) {
    return '';
  }

  final List<String> previousLines = previous.split('\n');
  final List<String> nextLines = next.split('\n');
  final int lineCount = previousLines.length > nextLines.length
      ? previousLines.length
      : nextLines.length;

  final StringBuffer patch = StringBuffer();
  for (int index = 0; index < lineCount; index += 1) {
    final String? previousLine = index < previousLines.length
        ? previousLines[index]
        : null;
    final String? nextLine = index < nextLines.length ? nextLines[index] : null;
    if (previousLine == nextLine) {
      continue;
    }
    final String line = nextLine ?? '';
    patch.write('\x1B[${index + 1};1H$line\x1B[K');
  }

  if (patch.isEmpty) {
    return '';
  }
  patch.write('\x1B[0m');
  return patch.toString();
}
