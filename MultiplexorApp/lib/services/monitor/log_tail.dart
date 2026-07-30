/// Reading the tail of a server's runtime log for the monitor's detail view.
///
/// The parsing half ([tailLines]) is pure and tested; the IO half
/// ([readLogTail]) is a thin, bounded read on top of it. Deliberately
/// standalone rather than reaching into the native command service: the
/// monitor is given an absolute `logPath` by the metrics row and needs
/// nothing else the service knows.
library;

import 'dart:convert';
import 'dart:io';

/// How much of a log file's tail is ever read. Server logs grow without
/// bound; the detail view shows a dozen lines, so anything past this window
/// is IO nobody looks at.
const int _maxTailBytes = 64 * 1024;

/// What the detail view is shown when the log cannot be read at all.
const String _unavailable = '<log unavailable>';

/// The last [maxLines] lines of [text], oldest first.
///
/// A single trailing line terminator is dropped (a log ending in `\n` has no
/// empty last line) but interior and doubled blank lines are preserved.
/// Carriage returns are stripped so CRLF text yields clean lines. Returns an
/// empty list for empty text or a non-positive [maxLines].
List<String> tailLines(String text, int maxLines) {
  if (maxLines <= 0 || text.isEmpty) {
    return <String>[];
  }
  String body = text;
  if (body.endsWith('\n')) {
    body = body.substring(0, body.length - 1);
  }
  if (body.isEmpty) {
    return <String>[];
  }
  final List<String> lines = <String>[
    for (final String line in body.split('\n')) line.replaceAll('\r', ''),
  ];
  if (lines.length <= maxLines) {
    return lines;
  }
  return lines.sublist(lines.length - maxLines);
}

/// The last [maxLines] lines of the file at [logPath], reading at most the
/// trailing [_maxTailBytes] of it.
///
/// Never throws: a missing, rotated, unreadable, or non-file path yields
/// `['<log unavailable>']` so the detail view always has something honest to
/// show. Malformed bytes at the window's leading edge are tolerated (the
/// window can start mid-codepoint).
Future<List<String>> readLogTail(String logPath, int maxLines) async {
  RandomAccessFile? handle;
  try {
    handle = await File(logPath).open();
    final int length = await handle.length();
    final int start = length > _maxTailBytes ? length - _maxTailBytes : 0;
    await handle.setPosition(start);
    final List<int> bytes = await handle.read(length - start);
    return tailLines(utf8.decode(bytes, allowMalformed: true), maxLines);
  } catch (_) {
    return const <String>[_unavailable];
  } finally {
    try {
      await handle?.close();
    } catch (_) {
      // Closing a handle we already failed on adds nothing.
    }
  }
}
