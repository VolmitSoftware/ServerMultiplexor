/// Terminal input event model and incremental escape-sequence parser.
///
/// The parser is pure: feed it bytes with [TermEventParser.add] and it emits
/// [TermEvent]s. When a read times out while a partial sequence is pending,
/// call [TermEventParser.timeout] to resolve ambiguity (a lone ESC byte is a
/// real Escape key press only once no continuation arrived).
library;

enum TermEventKind {
  char,
  enter,
  escape,
  backspace,
  tab,
  ctrlC,
  arrowUp,
  arrowDown,
  arrowLeft,
  arrowRight,
  home,
  end,
  pageUp,
  pageDown,
  delete,
  mouseDown,
  mouseUp,
  mouseMove,
  wheelUp,
  wheelDown,
  cursorReport,
  unknown,
}

class TermEvent {
  const TermEvent(
    this.kind, {
    this.char = '',
    this.row = 0,
    this.col = 0,
    this.button = 0,
  });

  final TermEventKind kind;

  /// Printable character for [TermEventKind.char].
  final String char;

  /// 1-based terminal row for mouse events and cursor reports.
  final int row;

  /// 1-based terminal column for mouse events and cursor reports.
  final int col;

  /// Raw button code for mouse events (0 left, 1 middle, 2 right).
  final int button;

  @override
  String toString() =>
      'TermEvent(${kind.name}'
      '${char.isEmpty ? '' : ', char=$char'}'
      '${row == 0 && col == 0 ? '' : ', row=$row, col=$col'})';
}

enum _ParseState { ground, escape, csi, ss3, utf8, x10Mouse }

class TermEventParser {
  _ParseState _state = _ParseState.ground;
  final List<int> _csiBytes = <int>[];
  final List<int> _utf8Bytes = <int>[];
  final List<int> _x10Bytes = <int>[];
  int _utf8Expected = 0;

  bool get hasPartial => _state != _ParseState.ground;

  /// Feeds one byte; returns zero or more completed events.
  List<TermEvent> add(int byte) {
    switch (_state) {
      case _ParseState.ground:
        return _ground(byte);
      case _ParseState.escape:
        return _afterEscape(byte);
      case _ParseState.csi:
        return _inCsi(byte);
      case _ParseState.ss3:
        _state = _ParseState.ground;
        return <TermEvent>[_ss3Key(byte)];
      case _ParseState.utf8:
        return _inUtf8(byte);
      case _ParseState.x10Mouse:
        return _inX10(byte);
    }
  }

  /// Resolves a pending partial sequence after a read timeout.
  TermEvent? timeout() {
    final _ParseState state = _state;
    _state = _ParseState.ground;
    _csiBytes.clear();
    _utf8Bytes.clear();
    _x10Bytes.clear();
    _utf8Expected = 0;
    if (state == _ParseState.escape) {
      return const TermEvent(TermEventKind.escape);
    }
    if (state == _ParseState.ground) {
      return null;
    }
    return const TermEvent(TermEventKind.unknown);
  }

  List<TermEvent> _ground(int byte) {
    if (byte == 0x1B) {
      _state = _ParseState.escape;
      return const <TermEvent>[];
    }
    if (byte == 0x0D || byte == 0x0A) {
      return const <TermEvent>[TermEvent(TermEventKind.enter)];
    }
    if (byte == 0x09) {
      return const <TermEvent>[TermEvent(TermEventKind.tab)];
    }
    if (byte == 0x7F || byte == 0x08) {
      return const <TermEvent>[TermEvent(TermEventKind.backspace)];
    }
    if (byte == 0x03) {
      return const <TermEvent>[TermEvent(TermEventKind.ctrlC)];
    }
    if (byte >= 0x20 && byte < 0x7F) {
      return <TermEvent>[
        TermEvent(TermEventKind.char, char: String.fromCharCode(byte)),
      ];
    }
    if (byte >= 0xC0) {
      _utf8Bytes
        ..clear()
        ..add(byte);
      _utf8Expected = byte >= 0xF0
          ? 4
          : byte >= 0xE0
          ? 3
          : 2;
      _state = _ParseState.utf8;
      return const <TermEvent>[];
    }
    return const <TermEvent>[TermEvent(TermEventKind.unknown)];
  }

  List<TermEvent> _afterEscape(int byte) {
    if (byte == 0x5B) {
      _state = _ParseState.csi;
      _csiBytes.clear();
      return const <TermEvent>[];
    }
    if (byte == 0x4F) {
      _state = _ParseState.ss3;
      return const <TermEvent>[];
    }
    if (byte == 0x1B) {
      // ESC ESC: report one escape, stay armed for the second.
      return const <TermEvent>[TermEvent(TermEventKind.escape)];
    }
    // Alt+key chords are not used; treat as a bare escape followed by the key.
    _state = _ParseState.ground;
    return <TermEvent>[const TermEvent(TermEventKind.escape), ..._ground(byte)];
  }

  List<TermEvent> _inCsi(int byte) {
    if (byte == 0x4D && _csiBytes.isEmpty) {
      // ESC [ M with no parameters: legacy X10 mouse report; three
      // offset-encoded payload bytes (button, column, row) follow.
      _state = _ParseState.x10Mouse;
      _x10Bytes.clear();
      return const <TermEvent>[];
    }
    if (byte >= 0x40 && byte <= 0x7E) {
      _state = _ParseState.ground;
      final String params = String.fromCharCodes(_csiBytes);
      _csiBytes.clear();
      return <TermEvent>[_csiEvent(params, byte)];
    }
    _csiBytes.add(byte);
    if (_csiBytes.length > 32) {
      _state = _ParseState.ground;
      _csiBytes.clear();
      return const <TermEvent>[TermEvent(TermEventKind.unknown)];
    }
    return const <TermEvent>[];
  }

  List<TermEvent> _inUtf8(int byte) {
    if (byte < 0x80 || byte >= 0xC0) {
      // Malformed continuation; reprocess this byte from ground state.
      _state = _ParseState.ground;
      _utf8Bytes.clear();
      _utf8Expected = 0;
      return _ground(byte);
    }
    _utf8Bytes.add(byte);
    if (_utf8Bytes.length < _utf8Expected) {
      return const <TermEvent>[];
    }
    _state = _ParseState.ground;
    final List<int> bytes = List<int>.from(_utf8Bytes);
    _utf8Bytes.clear();
    _utf8Expected = 0;
    try {
      final String decoded = String.fromCharCodes(_decodeUtf8(bytes));
      return <TermEvent>[TermEvent(TermEventKind.char, char: decoded)];
    } catch (_) {
      return const <TermEvent>[TermEvent(TermEventKind.unknown)];
    }
  }

  List<int> _decodeUtf8(List<int> bytes) {
    int value = bytes.first;
    value &= bytes.length == 2
        ? 0x1F
        : bytes.length == 3
        ? 0x0F
        : 0x07;
    for (int i = 1; i < bytes.length; i++) {
      value = (value << 6) | (bytes[i] & 0x3F);
    }
    return <int>[value];
  }

  TermEvent _ss3Key(int byte) {
    switch (String.fromCharCode(byte)) {
      case 'A':
        return const TermEvent(TermEventKind.arrowUp);
      case 'B':
        return const TermEvent(TermEventKind.arrowDown);
      case 'C':
        return const TermEvent(TermEventKind.arrowRight);
      case 'D':
        return const TermEvent(TermEventKind.arrowLeft);
      case 'H':
        return const TermEvent(TermEventKind.home);
      case 'F':
        return const TermEvent(TermEventKind.end);
    }
    return const TermEvent(TermEventKind.unknown);
  }

  TermEvent _csiEvent(String params, int finalByte) {
    final String terminator = String.fromCharCode(finalByte);

    if (params.startsWith('<') && (terminator == 'M' || terminator == 'm')) {
      return _sgrMouse(params.substring(1), pressed: terminator == 'M');
    }

    if (terminator == 'R') {
      final List<int> values = _intParams(params);
      if (values.length >= 2) {
        return TermEvent(
          TermEventKind.cursorReport,
          row: values[0],
          col: values[1],
        );
      }
      return const TermEvent(TermEventKind.unknown);
    }

    switch (terminator) {
      case 'A':
        return const TermEvent(TermEventKind.arrowUp);
      case 'B':
        return const TermEvent(TermEventKind.arrowDown);
      case 'C':
        return const TermEvent(TermEventKind.arrowRight);
      case 'D':
        return const TermEvent(TermEventKind.arrowLeft);
      case 'H':
        return const TermEvent(TermEventKind.home);
      case 'F':
        return const TermEvent(TermEventKind.end);
      case '~':
        final List<int> values = _intParams(params);
        final int code = values.isEmpty ? -1 : values.first;
        switch (code) {
          case 1:
          case 7:
            return const TermEvent(TermEventKind.home);
          case 3:
            return const TermEvent(TermEventKind.delete);
          case 4:
          case 8:
            return const TermEvent(TermEventKind.end);
          case 5:
            return const TermEvent(TermEventKind.pageUp);
          case 6:
            return const TermEvent(TermEventKind.pageDown);
        }
        return const TermEvent(TermEventKind.unknown);
    }
    return const TermEvent(TermEventKind.unknown);
  }

  List<TermEvent> _inX10(int byte) {
    _x10Bytes.add(byte);
    if (_x10Bytes.length < 3) {
      return const <TermEvent>[];
    }
    _state = _ParseState.ground;
    final int cb = _x10Bytes[0] - 32;
    final int col = _x10Bytes[1] - 32;
    final int row = _x10Bytes[2] - 32;
    _x10Bytes.clear();
    return <TermEvent>[_x10Event(cb, col, row)];
  }

  TermEvent _x10Event(int cb, int col, int row) {
    if (cb >= 64 && cb < 96) {
      return TermEvent(
        cb == 64 ? TermEventKind.wheelUp : TermEventKind.wheelDown,
        row: row,
        col: col,
      );
    }
    if ((cb & 32) != 0) {
      // Motion/drag tracking; menus do not use it.
      return const TermEvent(TermEventKind.unknown);
    }
    // X10 reports button 3 for any release.
    if ((cb & 0x03) == 3) {
      return TermEvent(TermEventKind.mouseUp, row: row, col: col);
    }
    return TermEvent(
      TermEventKind.mouseDown,
      row: row,
      col: col,
      button: cb & 0x03,
    );
  }

  TermEvent _sgrMouse(String params, {required bool pressed}) {
    final List<int> values = _intParams(params);
    if (values.length < 3) {
      return const TermEvent(TermEventKind.unknown);
    }
    final int code = values[0];
    final int col = values[1];
    final int row = values[2];

    if (code >= 64 && code < 96) {
      if (!pressed) {
        return const TermEvent(TermEventKind.unknown);
      }
      return TermEvent(
        code == 64 ? TermEventKind.wheelUp : TermEventKind.wheelDown,
        row: row,
        col: col,
      );
    }
    if ((code & 32) != 0) {
      // Any-motion tracking (?1003): plain motion or a drag (button held).
      // The screen distinguishes drag from hover via its own tracked
      // pressed state, not from this packet, so both map to mouseMove.
      return TermEvent(TermEventKind.mouseMove, row: row, col: col);
    }
    return TermEvent(
      pressed ? TermEventKind.mouseDown : TermEventKind.mouseUp,
      row: row,
      col: col,
      button: code & 0x03,
    );
  }

  List<int> _intParams(String params) {
    return params
        .split(';')
        .map((String part) => int.tryParse(part.trim()) ?? -1)
        .toList(growable: false);
  }
}
