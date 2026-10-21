import 'dart:io';

import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';

abstract interface class ProjectTerminal {
  bool get hasTerminal;
  int get columns;
  int get lines;
  void activate();
  TermEvent? readEventTimeout(Duration timeout);
  void write(String text);
  void restore();
}

class DartProjectTerminal implements ProjectTerminal {
  const DartProjectTerminal();

  TermIo get _io => TermIo.instance;

  @override
  bool get hasTerminal => _io.hasTerminal;
  @override
  int get columns => _io.terminalColumns;
  @override
  int get lines => _io.terminalLines;

  @override
  void activate() {
    _io.installSignalRestore();
    _io.setRawMode(true);
    stdout.write('\x1B[?1049h');
    _io.altScreenActive = true;
    _io.enableMouse();
    _io.drainInput();
    _io.hideCursor();
  }

  @override
  TermEvent? readEventTimeout(Duration timeout) =>
      _io.readEventTimeout(timeout);
  @override
  void write(String text) => stdout.write(text);
  @override
  void restore() => _io.restoreTerminal();
}
