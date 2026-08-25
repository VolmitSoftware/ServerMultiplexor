import 'dart:async';
import 'dart:io';

import 'package:dart_console/dart_console.dart';

import 'term_events.dart';
import 'windows_console.dart';

/// Owns the terminal for interactive UI: raw-mode reads, mouse reporting,
/// stale-input draining, and guaranteed cleanup.
///
/// dart_console raw mode uses VMIN=0/VTIME=1, so [stdin.readByteSync]
/// returns -1 after ~100ms of silence. That property powers both bare-ESC
/// disambiguation and [drainInput]. Windows has no VMIN/VTIME and its
/// dart_console raw mode does not even apply, so there [_readByte] goes
/// through [WindowsConsole], which reproduces the same idle tick from
/// console input records. Everything below that one method is shared.
class TermIo {
  TermIo._();

  static final TermIo instance = TermIo._();

  /// Clears drag/any-motion modes left by an interrupted older session, then
  /// enables click reporting (`?1000`) and SGR coordinates (`?1006`). Passive
  /// pointer motion is intentionally not tracked, so moving the mouse cannot
  /// churn dashboard redraws.
  static const String enableMouseSequence =
      '\x1B[?1003l\x1B[?1002l\x1B[?1000h\x1B[?1006h';

  /// Tears the modes back down in reverse of [enableMouseSequence].
  static const String disableMouseSequence =
      '\x1B[?1006l\x1B[?1003l\x1B[?1002l\x1B[?1000l';

  final Console _console = Console();
  final TermEventParser _parser = TermEventParser();
  final List<TermEvent> _queue = <TermEvent>[];
  bool _rawMode = false;
  bool _mouseEnabled = false;
  StreamSubscription<ProcessSignal>? _sigintSub;

  /// True while the app is drawing on the alternate screen buffer. Set by
  /// whoever wrote `\x1B[?1049h` so [restoreTerminal] — and therefore the
  /// Ctrl+C handler installed by [installSignalRestore] — hands the primary
  /// screen back instead of leaving the user staring at a dead dashboard.
  bool altScreenActive = false;

  bool get hasTerminal => stdin.hasTerminal && stdout.hasTerminal;

  /// The silence after which [_readByte] reports an idle tick, matching the
  /// VTIME=1 deciseconds the POSIX path gets from termios.
  static const Duration _idleTick = Duration(milliseconds: 100);

  /// True when the console has to be driven through Win32 rather than
  /// dart_console and termios.
  bool get _viaWindows => WindowsConsole.instance.isUsable;

  void setRawMode(bool enabled) {
    if (_rawMode == enabled || !hasTerminal) {
      return;
    }
    _rawMode = enabled;
    if (_viaWindows) {
      if (enabled) {
        WindowsConsole.instance.enterRawMode();
      } else {
        WindowsConsole.instance.exitRawMode();
      }
      return;
    }
    _console.rawMode = enabled;
  }

  /// One input byte, or -1 once [_idleTick] passes with none.
  ///
  /// Raw mode has to be on: on POSIX that is what makes the read time out
  /// rather than block, and on Windows it is what stops the console host
  /// from swallowing keys into a line buffer first.
  int _readByte() {
    if (_viaWindows) {
      return WindowsConsole.instance.readByte(_idleTick);
    }
    return stdin.readByteSync();
  }

  void enableMouse() {
    if (!hasTerminal) {
      return;
    }
    // Always re-write the enable sequence, even when the flag says mouse is
    // already on: external programs that share the tty (tmux console
    // attach/detach, subprocess cleanup) can reset tracking modes behind
    // our back, and the sequence is idempotent.
    _mouseEnabled = true;
    WindowsConsole.instance.mouseReporting = true;
    stdout.write(enableMouseSequence);
  }

  void disableMouse() {
    if (!_mouseEnabled) {
      return;
    }
    _mouseEnabled = false;
    WindowsConsole.instance.mouseReporting = false;
    if (stdout.hasTerminal) {
      stdout.write(disableMouseSequence);
    }
  }

  void hideCursor() {
    if (stdout.hasTerminal) {
      _console.hideCursor();
    }
  }

  void showCursor() {
    if (stdout.hasTerminal) {
      _console.showCursor();
    }
  }

  /// Blocking read of the next input event. Requires raw mode.
  TermEvent readEvent() {
    while (true) {
      if (_queue.isNotEmpty) {
        return _queue.removeAt(0);
      }
      int byte;
      try {
        byte = _readByte();
      } on StdinException {
        throw const TermInputUnavailable();
      } on OSError {
        throw const TermInputUnavailable();
      }
      if (byte < 0) {
        final TermEvent? resolved = _parser.timeout();
        if (resolved != null) {
          _queue.add(resolved);
        }
        continue;
      }
      _queue.addAll(_parser.add(byte));
    }
  }

  /// Like [readEvent], but returns null if no event arrives within [timeout]
  /// instead of blocking forever. Powers periodic refresh loops (e.g. the live
  /// dashboard) that must redraw on a timer while still handling keystrokes.
  /// Requires raw mode.
  TermEvent? readEventTimeout(Duration timeout) {
    if (_queue.isNotEmpty) {
      return _queue.removeAt(0);
    }
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      int byte;
      try {
        byte = _readByte();
      } on StdinException {
        throw const TermInputUnavailable();
      } on OSError {
        throw const TermInputUnavailable();
      }
      if (byte < 0) {
        // VTIME=1 silence tick: resolve a pending bare-ESC, else keep waiting.
        final TermEvent? resolved = _parser.timeout();
        if (resolved != null) {
          return resolved;
        }
        continue;
      }
      _queue.addAll(_parser.add(byte));
      if (_queue.isNotEmpty) {
        return _queue.removeAt(0);
      }
    }
    return null;
  }

  /// Discards all pending input. Call after background work so keystrokes
  /// typed while the app was busy cannot trigger menu actions.
  void drainInput() {
    if (!hasTerminal) {
      return;
    }
    final bool wasRaw = _rawMode;
    setRawMode(true);
    try {
      while (true) {
        int byte;
        try {
          byte = _readByte();
        } catch (_) {
          break;
        }
        if (byte < 0) {
          break;
        }
        _parser.add(byte);
      }
      _parser.timeout();
      _queue.clear();
    } finally {
      if (!wasRaw) {
        setRawMode(false);
      }
    }
  }

  /// Reports the 1-based cursor position, or null if the terminal does not
  /// answer. Other events received while waiting (clicks, keys) are queued
  /// for the next [readEvent] rather than discarded. Requires raw mode.
  TermCursor? cursorPosition() {
    if (!hasTerminal) {
      return null;
    }
    stdout.write('\x1B[6n');
    final DateTime deadline = DateTime.now().add(
      const Duration(milliseconds: 600),
    );
    while (DateTime.now().isBefore(deadline)) {
      int byte;
      try {
        byte = _readByte();
      } catch (_) {
        return null;
      }
      if (byte < 0) {
        _parser.timeout();
        continue;
      }
      for (final TermEvent event in _parser.add(byte)) {
        if (event.kind == TermEventKind.cursorReport) {
          return TermCursor(event.row, event.col);
        }
        _queue.add(event);
      }
    }
    return null;
  }

  /// Runs [operation] with keyboard echo suppressed, then discards anything
  /// typed while it ran. This is what keeps stray keypresses during builds,
  /// startups, and syncs from corrupting the UI or queueing menu actions.
  Future<T> shielded<T>(Future<T> Function() operation) async {
    if (!hasTerminal) {
      return operation();
    }
    try {
      stdin.echoMode = false;
    } catch (_) {}
    try {
      return await operation();
    } finally {
      drainInput();
      try {
        stdin.echoMode = true;
      } catch (_) {}
    }
  }

  /// Restores the terminal to a sane state and releases the signal watch
  /// so the VM can exit. Safe to call repeatedly.
  void restoreTerminal() {
    _sigintSub?.cancel();
    _sigintSub = null;
    disableMouse();
    if (altScreenActive) {
      // Leave the alternate screen before anything else so the restored
      // primary screen keeps the scrollback the dashboard never touched.
      // Clearing the flag first keeps repeat calls from re-emitting it.
      altScreenActive = false;
      if (stdout.hasTerminal) {
        stdout.write('\x1B[?1049l');
      }
    }
    if (stdout.hasTerminal) {
      stdout.write('\x1B[0m');
      _console.showCursor();
    }
    setRawMode(false);
    try {
      stdin.echoMode = true;
    } catch (_) {}
    try {
      stdin.lineMode = true;
    } catch (_) {}
  }

  /// Restores the terminal before dying on Ctrl+C delivered while the app
  /// is in cooked mode (during raw-mode menus Ctrl+C arrives as a byte and
  /// is handled by the UI instead).
  void installSignalRestore() {
    _sigintSub ??= ProcessSignal.sigint.watch().listen((ProcessSignal _) {
      restoreTerminal();
      stdout.writeln();
      exit(130);
    });
  }

  int get terminalColumns => stdout.hasTerminal ? stdout.terminalColumns : 100;

  int get terminalLines => stdout.hasTerminal ? stdout.terminalLines : 24;
}

/// A 1-based cursor position as reported by the terminal.
class TermCursor {
  const TermCursor(this.row, this.col);

  final int row;
  final int col;
}

class TermInputUnavailable implements Exception {
  const TermInputUnavailable();

  @override
  String toString() => 'Terminal input is no longer readable';
}
