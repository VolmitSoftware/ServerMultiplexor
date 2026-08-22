// Windows console ownership for the interactive UI.
//
// The rest of the terminal layer is written against POSIX semantics: raw
// mode via termios with VMIN=0/VTIME=1, so `stdin.readByteSync()` returns
// -1 after ~100ms of silence, which is the idle tick every read loop in
// [TermIo] is built on. Windows has no equivalent — `readByteSync()` blocks
// until a byte actually arrives — and dart_console's `enableRawMode()` is
// worse than useless here: it ANDs the complements of four flags together,
// producing a mask with every *other* bit set (undefined high bits
// included) that SetConsoleMode rejects outright, leaving the console in
// line mode. Together those two facts deadlock the dashboard inside
// `drainInput()` before it ever draws a frame.
//
// So on Windows the console is driven directly: set the modes we actually
// want, read INPUT_RECORDs with a real timeout, and translate them into the
// same xterm byte stream [TermEventParser] already parses on POSIX. Nothing
// above this file needs to know which platform it is on.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ─── Win32 ────────────────────────────────────────────────────────────────

const int _stdInputHandle = 0xFFFFFFF6; // (DWORD)-10
const int _stdOutputHandle = 0xFFFFFFF5; // (DWORD)-11
const int _invalidHandleValue = -1;

const int _enableProcessedInput = 0x0001;
const int _enableLineInput = 0x0002;
const int _enableEchoInput = 0x0004;
const int _enableWindowInput = 0x0008;
const int _enableMouseInput = 0x0010;
const int _enableQuickEditMode = 0x0040;
const int _enableExtendedFlags = 0x0080;
const int _enableVirtualTerminalInput = 0x0200;

const int _enableProcessedOutput = 0x0001;
const int _enableVirtualTerminalProcessing = 0x0004;

const int _keyEventType = 0x0001;
const int _mouseEventType = 0x0002;

const int _mouseMoved = 0x0001;
const int _mouseWheeled = 0x0004;

const int _waitObject0 = 0x00000000;

/// sizeof(INPUT_RECORD): a WORD event type, padding up to the union's
/// 4-byte alignment, then the 16-byte union itself.
const int _recordSize = 20;
const int _recordCapacity = 32;

class _Kernel32 {
  _Kernel32() : _lib = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _lib;

  late final int Function(int) getStdHandle = _lib
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetStdHandle',
      );

  late final int Function(int, Pointer<Uint32>) getConsoleMode = _lib
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');

  late final int Function(int, int) setConsoleMode = _lib
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'SetConsoleMode',
      );

  late final int Function(int, Pointer<Uint32>) countInputEvents = _lib
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetNumberOfConsoleInputEvents');

  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)
  readConsoleInput = _lib
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)
      >('ReadConsoleInputW');

  late final int Function(int, int) waitForSingleObject = _lib
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject',
      );
}

// ─── Console ──────────────────────────────────────────────────────────────

/// Raw-mode console input for Windows, translated to xterm bytes.
///
/// A process-wide singleton, because the console modes it owns are
/// process-wide: two instances would each restore the other's "original".
class WindowsConsole {
  WindowsConsole._();

  static final WindowsConsole instance = WindowsConsole._();

  _Kernel32? _k32;
  int _inputHandle = _invalidHandleValue;
  int _outputHandle = _invalidHandleValue;
  bool _probed = false;
  bool _usable = false;

  Pointer<Uint32>? _dword;
  Pointer<Uint32>? _readCount;
  Pointer<Uint8>? _records;
  ByteData? _recordView;

  int? _savedInputMode;
  int? _savedOutputMode;
  bool _rawMode = false;

  /// Bytes translated out of input records, waiting to be handed up.
  final Queue<int> _pending = Queue<int>();

  bool _mouseReporting = false;
  int _lastMouseButton = 0;
  int _lastMouseCol = -1;
  int _lastMouseRow = -1;
  int _highSurrogate = 0;

  /// True when this process is attached to a real Windows console this class
  /// can drive. False on every other platform, and when stdin is a pipe.
  bool get isUsable {
    if (!Platform.isWindows) {
      return false;
    }
    if (_probed) {
      return _usable;
    }
    _probed = true;
    try {
      final _Kernel32 k32 = _Kernel32();
      final int input = k32.getStdHandle(_stdInputHandle);
      final int output = k32.getStdHandle(_stdOutputHandle);
      if (input == _invalidHandleValue || input == 0) {
        return _usable = false;
      }
      final Pointer<Uint32> probe = calloc<Uint32>();
      try {
        if (k32.getConsoleMode(input, probe) == 0) {
          return _usable = false; // Redirected to a pipe or a file.
        }
      } finally {
        calloc.free(probe);
      }
      _k32 = k32;
      _inputHandle = input;
      _outputHandle = output;
      _dword = calloc<Uint32>();
      _readCount = calloc<Uint32>();
      _records = calloc<Uint8>(_recordSize * _recordCapacity);
      _recordView = _records!
          .asTypedList(_recordSize * _recordCapacity)
          .buffer
          .asByteData();
      return _usable = true;
    } on Object {
      // A missing kernel32, a blocked FFI load, anything at all: fall back
      // to the portable path rather than taking the whole UI down.
      return _usable = false;
    }
  }

  /// Whether mouse reporting is on. Mirrors the `?1000`/`?1003` sequences
  /// [TermIo] writes: Windows delivers mouse input as records either way, so
  /// this is what decides whether they become bytes or are dropped.
  set mouseReporting(bool enabled) {
    _mouseReporting = enabled;
    if (!enabled) {
      _lastMouseCol = -1;
      _lastMouseRow = -1;
    }
  }

  /// Puts the console into raw mode, remembering the modes to put back.
  void enterRawMode() {
    if (!isUsable || _rawMode) {
      return;
    }
    final _Kernel32 k32 = _k32!;
    final Pointer<Uint32> mode = _dword!;

    if (k32.getConsoleMode(_inputHandle, mode) != 0) {
      _savedInputMode ??= mode.value;
      // Window and mouse input are *enabled* here rather than left alone:
      // resize and mouse records are the only way this layer hears about
      // either. Quick-edit has to go, or a drag selects console text instead
      // of reaching the dashboard, and extended flags is the switch that
      // makes clearing quick-edit take effect at all.
      final int raw =
          (_savedInputMode! &
              ~(_enableProcessedInput |
                  _enableLineInput |
                  _enableEchoInput |
                  _enableQuickEditMode |
                  // Records are translated here, so the console host must
                  // not also translate them on the way out.
                  _enableVirtualTerminalInput)) |
          _enableWindowInput |
          _enableMouseInput |
          _enableExtendedFlags;
      k32.setConsoleMode(_inputHandle, raw);
    }

    if (_outputHandle != _invalidHandleValue &&
        k32.getConsoleMode(_outputHandle, mode) != 0) {
      _savedOutputMode ??= mode.value;
      // Under a ConPTY host this is already on; under plain conhost it is
      // not, and without it every escape sequence the UI writes would be
      // printed literally.
      k32.setConsoleMode(
        _outputHandle,
        _savedOutputMode! |
            _enableProcessedOutput |
            _enableVirtualTerminalProcessing,
      );
    }

    _rawMode = true;
  }

  /// Restores the modes captured by [enterRawMode]. Safe to call repeatedly.
  void exitRawMode() {
    if (!isUsable || !_rawMode) {
      return;
    }
    _rawMode = false;
    final _Kernel32 k32 = _k32!;
    final int? input = _savedInputMode;
    if (input != null) {
      k32.setConsoleMode(_inputHandle, input);
    }
    final int? output = _savedOutputMode;
    if (output != null && _outputHandle != _invalidHandleValue) {
      k32.setConsoleMode(_outputHandle, output);
    }
    _pending.clear();
    _highSurrogate = 0;
  }

  /// True when a byte is already buffered, so callers can skip the wait.
  bool get hasBufferedByte => _pending.isNotEmpty;

  /// The next input byte, or -1 if none arrives within [timeout].
  ///
  /// This is the Windows stand-in for a VMIN=0/VTIME=1 `readByteSync()`:
  /// callers get bytes when there are bytes and an idle tick when there are
  /// not, and never block past the timeout.
  int readByte(Duration timeout) {
    if (!isUsable) {
      return -1;
    }
    if (_pending.isNotEmpty) {
      return _pending.removeFirst();
    }
    final _Kernel32 k32 = _k32!;
    final DateTime deadline = DateTime.now().add(timeout);
    while (true) {
      final int remaining = deadline.difference(DateTime.now()).inMilliseconds;
      if (remaining <= 0) {
        return -1;
      }
      if (k32.waitForSingleObject(_inputHandle, remaining) != _waitObject0) {
        // Timed out, or the handle went away — either way, no byte.
        return -1;
      }
      _pump();
      if (_pending.isNotEmpty) {
        return _pending.removeFirst();
      }
      // Signalled by a record that carries no bytes (a key release, a focus
      // change): it has been consumed, so go back to waiting out the rest of
      // the timeout rather than spinning.
    }
  }

  /// Consumes every record currently queued, translating as it goes.
  void _pump() {
    final _Kernel32 k32 = _k32!;
    final Pointer<Uint32> count = _dword!;
    if (k32.countInputEvents(_inputHandle, count) == 0) {
      return;
    }
    int outstanding = count.value;
    while (outstanding > 0) {
      final int take = outstanding < _recordCapacity
          ? outstanding
          : _recordCapacity;
      if (k32.readConsoleInput(_inputHandle, _records!, take, _readCount!) ==
          0) {
        return;
      }
      final int got = _readCount!.value;
      if (got <= 0) {
        return;
      }
      for (int i = 0; i < got; i++) {
        _translate(i * _recordSize);
      }
      outstanding -= got;
    }
  }

  void _translate(int base) {
    final ByteData view = _recordView!;
    switch (view.getUint16(base, Endian.little)) {
      case _keyEventType:
        _translateKey(view, base);
      case _mouseEventType:
        _translateMouse(view, base);
      default:
        // Resize, focus, and menu records carry nothing a byte stream can
        // express; the screen re-measures the terminal on every frame.
        break;
    }
  }

  void _translateKey(ByteData view, int base) {
    if (view.getUint32(base + 4, Endian.little) == 0) {
      return; // Key release.
    }
    final int repeat = view.getUint16(base + 8, Endian.little);
    final int virtualKey = view.getUint16(base + 10, Endian.little);
    final int char = view.getUint16(base + 14, Endian.little);

    final String? sequence = _sequenceForVirtualKey(virtualKey);
    if (sequence != null) {
      _emitRepeated(sequence.codeUnits, repeat);
      return;
    }

    if (char == 0) {
      return; // A bare modifier: Shift, Ctrl, Alt, Caps Lock, a Windows key.
    }

    // Astral characters (emoji, and anything else outside the BMP) arrive as
    // two records — a high surrogate, then a low one — and mean nothing
    // apart.
    if (char >= 0xD800 && char <= 0xDBFF) {
      _highSurrogate = char;
      return;
    }
    final int high = _highSurrogate;
    _highSurrogate = 0;
    final String text = (high != 0 && char >= 0xDC00 && char <= 0xDFFF)
        ? String.fromCharCodes(<int>[high, char])
        : String.fromCharCode(char);
    _emitRepeated(utf8.encode(text), repeat);
  }

  /// The xterm sequence for keys that produce no character of their own, or
  /// whose character Windows reports differently than a POSIX terminal does.
  String? _sequenceForVirtualKey(int virtualKey) {
    switch (virtualKey) {
      case 0x26:
        return '\x1B[A'; // Up
      case 0x28:
        return '\x1B[B'; // Down
      case 0x27:
        return '\x1B[C'; // Right
      case 0x25:
        return '\x1B[D'; // Left
      case 0x24:
        return '\x1B[H'; // Home
      case 0x23:
        return '\x1B[F'; // End
      case 0x21:
        return '\x1B[5~'; // Page Up
      case 0x22:
        return '\x1B[6~'; // Page Down
      case 0x2D:
        return '\x1B[2~'; // Insert
      case 0x2E:
        return '\x1B[3~'; // Delete
      case 0x08:
        // Windows reports Backspace as 0x08 and terminals send DEL. The
        // parser takes either, so send what the POSIX path sends.
        return '\x7F';
    }
    return null;
  }

  void _emitRepeated(List<int> bytes, int repeat) {
    // A held key can bank a large repeat count while the UI is busy, and
    // replaying all of it would fling the selection somewhere the user never
    // asked for.
    final int times = repeat < 1
        ? 1
        : repeat > 8
        ? 8
        : repeat;
    for (int i = 0; i < times; i++) {
      _pending.addAll(bytes);
    }
  }

  void _translateMouse(ByteData view, int base) {
    if (!_mouseReporting) {
      return;
    }
    final int col = view.getInt16(base + 4, Endian.little) + 1;
    final int row = view.getInt16(base + 6, Endian.little) + 1;
    final int buttons = view.getUint32(base + 8, Endian.little);
    final int flags = view.getUint32(base + 16, Endian.little);

    if ((flags & _mouseWheeled) != 0) {
      // The wheel delta is the signed high word of the button state.
      final int delta = view.getInt16(base + 10, Endian.little);
      _emitMouse(delta > 0 ? 64 : 65, col, row, pressed: true);
      return;
    }
    if ((flags & _mouseMoved) != 0) {
      // The UI only cares about cells, so a report for a move that stayed in
      // one is pure churn.
      if (col == _lastMouseCol && row == _lastMouseRow) {
        return;
      }
      _lastMouseCol = col;
      _lastMouseRow = row;
      final int held = buttons == 0 ? 3 : _buttonCode(buttons);
      _emitMouse(held + 32, col, row, pressed: true);
      return;
    }
    if (buttons != 0) {
      _lastMouseButton = _buttonCode(buttons);
      _emitMouse(_lastMouseButton, col, row, pressed: true);
      return;
    }
    // Every button is up: this is the release of whichever went down last.
    _emitMouse(_lastMouseButton, col, row, pressed: false);
  }

  int _buttonCode(int buttons) {
    if ((buttons & 0x0002) != 0) {
      return 2; // Rightmost.
    }
    if ((buttons & 0x0004) != 0) {
      return 1; // Middle.
    }
    return 0; // Leftmost, and anything more exotic.
  }

  /// Writes an SGR (`?1006`) mouse report, the encoding [TermIo] asks for.
  void _emitMouse(int code, int col, int row, {required bool pressed}) {
    _pending.addAll('\x1B[<$code;$col;$row${pressed ? 'M' : 'm'}'.codeUnits);
  }
}
