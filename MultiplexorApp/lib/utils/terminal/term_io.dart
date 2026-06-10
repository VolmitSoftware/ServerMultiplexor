import 'dart:async';
import 'dart:io';

import 'package:dart_console/dart_console.dart';

import 'term_events.dart';

/// Owns the terminal for interactive UI: raw-mode reads, mouse reporting,
/// stale-input draining, and guaranteed cleanup.
///
/// dart_console raw mode uses VMIN=0/VTIME=1, so [stdin.readByteSync]
/// returns -1 after ~100ms of silence. That property powers both bare-ESC
/// disambiguation and [drainInput].
class TermIo {
  TermIo._();

  static final TermIo instance = TermIo._();

  final Console _console = Console();
  final TermEventParser _parser = TermEventParser();
  final List<TermEvent> _queue = <TermEvent>[];
  bool _rawMode = false;
  bool _mouseEnabled = false;
  StreamSubscription<ProcessSignal>? _sigintSub;

  bool get hasTerminal => stdin.hasTerminal && stdout.hasTerminal;

  void setRawMode(bool enabled) {
    if (_rawMode == enabled || !hasTerminal) {
      return;
    }
    _rawMode = enabled;
    _console.rawMode = enabled;
  }

  void enableMouse() {
    if (_mouseEnabled || !hasTerminal) {
      return;
    }
    _mouseEnabled = true;
    stdout.write('\x1B[?1000h\x1B[?1006h');
  }

  void disableMouse() {
    if (!_mouseEnabled) {
      return;
    }
    _mouseEnabled = false;
    if (stdout.hasTerminal) {
      stdout.write('\x1B[?1000l\x1B[?1006l');
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
        byte = stdin.readByteSync();
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
          byte = stdin.readByteSync();
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

  /// Reports the 1-based cursor row, or null if the terminal does not
  /// answer. Stale input received while waiting is discarded. Requires raw
  /// mode.
  int? cursorRow() {
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
        byte = stdin.readByteSync();
      } catch (_) {
        return null;
      }
      if (byte < 0) {
        _parser.timeout();
        continue;
      }
      for (final TermEvent event in _parser.add(byte)) {
        if (event.kind == TermEventKind.cursorReport) {
          return event.row;
        }
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

  int get terminalColumns =>
      stdout.hasTerminal ? stdout.terminalColumns : 100;
}

class TermInputUnavailable implements Exception {
  const TermInputUnavailable();

  @override
  String toString() => 'Terminal input is no longer readable';
}
