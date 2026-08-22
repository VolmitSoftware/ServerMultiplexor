// Interactive check of the terminal input stack. Run it in the terminal you
// actually use the wizard from:
//
//   dart run tool/tty_probe.dart
//
// It reports what the app sees, then echoes decoded input events for 20
// seconds. Press q to stop early.
import 'dart:io';

import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:multiplexor/utils/terminal/term_io.dart';
import 'package:multiplexor/utils/terminal/windows_console.dart';

void main() {
  final TermIo io = TermIo.instance;
  stdout.writeln('platform           : ${Platform.operatingSystem}');
  stdout.writeln('stdin.hasTerminal  : ${stdin.hasTerminal}');
  stdout.writeln('stdout.hasTerminal : ${stdout.hasTerminal}');
  stdout.writeln('TermIo.hasTerminal : ${io.hasTerminal}');
  stdout.writeln('WindowsConsole     : ${WindowsConsole.instance.isUsable}');
  stdout.writeln(
    'terminal size      : ${io.terminalColumns}x${io.terminalLines}',
  );

  if (!io.hasTerminal) {
    stdout.writeln(
      '\nNo TTY here, so there is nothing to test. Run this '
      'directly in your terminal.',
    );
    return;
  }

  io.setRawMode(true);
  io.enableMouse();
  try {
    final Stopwatch drain = Stopwatch()..start();
    io.drainInput();
    drain.stop();
    stdout.write(
      '\r\ndrainInput() returned in ${drain.elapsedMilliseconds}ms '
      '(must be well under a second, not "never")\r\n',
    );

    final Stopwatch idle = Stopwatch()..start();
    final TermEvent? none = io.readEventTimeout(
      const Duration(milliseconds: 300),
    );
    idle.stop();
    stdout.write(
      'idle read returned ${none?.kind.name ?? 'null'} after '
      '${idle.elapsedMilliseconds}ms (should be ~300ms and null, if you '
      'did not touch anything)\r\n\r\n',
    );

    stdout.write(
      'Now press keys — arrows, Enter, Escape, letters — and move '
      'or click the mouse.\r\nPress q to finish.\r\n\r\n',
    );

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final TermEvent? event = io.readEventTimeout(
        const Duration(milliseconds: 250),
      );
      if (event == null) {
        continue;
      }
      stdout.write('  $event\r\n');
      if (event.kind == TermEventKind.ctrlC ||
          (event.kind == TermEventKind.char && event.char == 'q')) {
        break;
      }
    }
  } finally {
    io.restoreTerminal();
  }
  stdout.writeln('\nDone. Terminal restored.');
}
