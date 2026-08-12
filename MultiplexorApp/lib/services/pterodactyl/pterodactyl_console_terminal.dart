import 'dart:async';
import 'dart:io';

import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_console_session.dart';

abstract interface class PterodactylConsoleTerminalIo {
  bool get hasTerminal;
  Stream<TermEvent> get events;

  Future<void> activate();
  void write(String value);
  Future<void> restore();
}

/// Asynchronous raw-terminal input that leaves WebSocket events free to run on
/// the isolate event loop while a command is being edited.
final class DartIoPterodactylConsoleTerminalIo
    implements PterodactylConsoleTerminalIo {
  DartIoPterodactylConsoleTerminalIo({
    Duration escapeTimeout = const Duration(milliseconds: 120),
  }) : _escapeTimeout = escapeTimeout;

  final Duration _escapeTimeout;
  final StreamController<TermEvent> _events =
      StreamController<TermEvent>.broadcast(sync: true);
  final TermEventParser _parser = TermEventParser();
  StreamSubscription<List<int>>? _input;
  Timer? _partialTimer;
  bool _active = false;

  @override
  bool get hasTerminal => TermIo.instance.hasTerminal;

  @override
  Stream<TermEvent> get events => _events.stream;

  @override
  Future<void> activate() async {
    if (_active) throw StateError('The console terminal is already active.');
    if (!hasTerminal) {
      throw StateError('The remote console requires an interactive terminal.');
    }
    _active = true;
    final TermIo io = TermIo.instance;
    io.disableMouse();
    io.drainInput();
    io.setRawMode(true);
    io.showCursor();
    _input = stdin.listen(
      _addBytes,
      onError: (Object _) => _closeInput(),
      onDone: _closeInput,
      cancelOnError: true,
    );
  }

  void _addBytes(List<int> bytes) {
    if (!_active) return;
    for (final int byte in bytes) {
      _partialTimer?.cancel();
      for (final TermEvent event in _parser.add(byte)) {
        _events.add(event);
      }
      if (_parser.hasPartial) {
        _partialTimer = Timer(_escapeTimeout, () {
          final TermEvent? event = _parser.timeout();
          if (event != null && !_events.isClosed) _events.add(event);
        });
      }
    }
  }

  void _closeInput() {
    _partialTimer?.cancel();
    final TermEvent? pending = _parser.timeout();
    if (pending != null && !_events.isClosed) _events.add(pending);
    if (!_events.isClosed) unawaited(_events.close());
  }

  @override
  void write(String value) => stdout.write(value);

  @override
  Future<void> restore() async {
    if (!_active) return;
    _active = false;
    _partialTimer?.cancel();
    _partialTimer = null;
    try {
      await _input?.cancel();
    } finally {
      _input = null;
      if (!_events.isClosed) await _events.close();
      TermIo.instance.restoreTerminal();
    }
  }
}

/// Minimal live-console frontend: sanitized output above a raw-mode line
/// editor. Escape, Ctrl+C, and `:exit` detach without stopping the server.
final class PterodactylConsoleTerminal {
  PterodactylConsoleTerminal({
    required PterodactylConsoleConnection connection,
    PterodactylConsoleTerminalIo? terminal,
    String prompt = '> ',
  }) : _connection = connection,
       _terminal = terminal ?? DartIoPterodactylConsoleTerminalIo(),
       _prompt = PterodactylConsoleSanitizer.text(prompt);

  final PterodactylConsoleConnection _connection;
  final PterodactylConsoleTerminalIo _terminal;
  final String _prompt;
  final List<String> _buffer = <String>[];
  final List<String> _history = <String>[];
  int _cursor = 0;
  int _historyIndex = 0;
  String _stats = '';
  bool _connected = false;

  Future<void> run() async {
    StreamSubscription<PterodactylConsoleEvent>? remoteEvents;
    try {
      await _terminal.activate();
      remoteEvents = _connection.events.listen(_renderEvent);
      final Future<void> input = _inputLoop();
      final Future<void> connecting = _connection.connect();
      // If input detaches first, the lifecycle `finally` closes the
      // connection. Still consume a late connect failure so it cannot escape
      // as an unhandled asynchronous error after the terminal is restored.
      unawaited(connecting.catchError((Object _) {}));
      final Object first = await Future.any<Object>(<Future<Object>>[
        connecting.then<Object>((_) => const _ConsoleConnected()),
        input.then<Object>((_) => const _ConsoleDetached()),
        _connection.done.then<Object>((_) => const _ConsoleDetached()),
      ]);
      if (first is _ConsoleDetached) return;
      _connected = true;
      _redraw();
      await Future.any<void>(<Future<void>>[input, _connection.done]);
    } finally {
      await remoteEvents?.cancel();
      try {
        await _connection.close();
      } finally {
        _terminal.write('\r\x1b[2K\n');
        await _terminal.restore();
      }
    }
  }

  Future<void> _inputLoop() async {
    try {
      await for (final TermEvent event in _terminal.events) {
        if (await _handleInput(event)) return;
      }
    } catch (_) {
      // A lost terminal detaches through run()'s lifecycle finally block.
    }
  }

  Future<bool> _handleInput(TermEvent event) async {
    switch (event.kind) {
      case TermEventKind.escape:
      case TermEventKind.ctrlC:
        return true;
      case TermEventKind.enter:
        if (!_connected) return false;
        return _submit();
      case TermEventKind.char:
        if (_buffer.length < 4096 &&
            event.char.isNotEmpty &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(event.char)) {
          _buffer.insert(_cursor, event.char);
          _cursor++;
          _historyIndex = _history.length;
          _redraw();
        }
      case TermEventKind.backspace:
        if (_cursor > 0) {
          _buffer.removeAt(--_cursor);
          _redraw();
        }
      case TermEventKind.delete:
        if (_cursor < _buffer.length) {
          _buffer.removeAt(_cursor);
          _redraw();
        }
      case TermEventKind.arrowLeft:
        if (_cursor > 0) {
          _cursor--;
          _redraw();
        }
      case TermEventKind.arrowRight:
        if (_cursor < _buffer.length) {
          _cursor++;
          _redraw();
        }
      case TermEventKind.home:
        _cursor = 0;
        _redraw();
      case TermEventKind.end:
        _cursor = _buffer.length;
        _redraw();
      case TermEventKind.arrowUp:
        _recall(-1);
      case TermEventKind.arrowDown:
        _recall(1);
      default:
        break;
    }
    return false;
  }

  Future<bool> _submit() async {
    final String command = _buffer.join();
    _terminal.write('\r\x1b[2K${_safe(_prompt)}${_safe(command)}\n');
    _buffer.clear();
    _cursor = 0;
    if (command.trim() == ':exit') return true;
    if (command.isEmpty) {
      _redraw();
      return false;
    }
    if (_history.isEmpty || _history.last != command) _history.add(command);
    if (_history.length > 100) _history.removeAt(0);
    _historyIndex = _history.length;
    try {
      await _connection.sendCommand(command);
    } catch (_) {
      _printLine('[error] Unable to send the console command.');
    }
    _redraw();
    return false;
  }

  void _recall(int delta) {
    if (_history.isEmpty) return;
    _historyIndex = (_historyIndex + delta).clamp(0, _history.length);
    _buffer
      ..clear()
      ..addAll(
        _historyIndex == _history.length
            ? const <String>[]
            : _history[_historyIndex].runes.map(String.fromCharCode),
      );
    _cursor = _buffer.length;
    _redraw();
  }

  void _renderEvent(PterodactylConsoleEvent event) {
    switch (event) {
      case PterodactylConsoleOutput(:final lines):
        _printLines(lines);
      case PterodactylConsoleInstallOutput(:final lines):
        _printLines(lines.map((String line) => '[install] $line'));
      case PterodactylConsoleStatus(:final status):
        _printLine('[status] $status');
      case PterodactylConsoleStats():
        _stats = _statsLabel(event);
        _redraw();
      case PterodactylConsoleAuthenticated():
        _printLine('[connected] Console authenticated.');
      case PterodactylConsoleTokenExpiring():
        _printLine('[auth] Refreshing expiring console credentials.');
      case PterodactylConsoleTokenExpired():
        _printLine('[auth] Refreshing expired console credentials.');
      case PterodactylConsoleDaemonMessage(:final message, :final isError):
        _printLine('${isError ? '[daemon error]' : '[daemon]'} $message');
      case PterodactylConsoleUnknownEvent(:final name):
        _printLine('[event] $name');
      case PterodactylConsoleProtocolWarning(:final message):
        _printLine('[warning] $message');
      case PterodactylConsoleConnectionEvent(:final state, :final message):
        if (message != null) {
          _printLine('[${state.name}] $message');
        }
    }
  }

  String _statsLabel(PterodactylConsoleStats stats) {
    final List<String> fields = <String>[];
    if (stats.state case final String state) fields.add(state);
    if (stats.cpuAbsolute case final double cpu) {
      fields.add('CPU ${cpu.toStringAsFixed(1)}%');
    }
    if (stats.memoryBytes case final int memory) {
      fields.add('MEM ${_bytes(memory)}');
    }
    return fields.isEmpty ? '' : '[${fields.join(' · ')}] ';
  }

  static String _bytes(int value) {
    const int gibibyte = 1024 * 1024 * 1024;
    const int mebibyte = 1024 * 1024;
    if (value >= gibibyte) {
      return '${(value / gibibyte).toStringAsFixed(1)} GiB';
    }
    return '${(value / mebibyte).toStringAsFixed(0)} MiB';
  }

  void _printLines(Iterable<String> lines) {
    for (final String line in lines) {
      _printLine(line);
    }
  }

  void _printLine(String value) {
    final List<String> lines = _safe(value).split('\n');
    _terminal.write('\r\x1b[2K${lines.join('\n')}\n');
    _redraw();
  }

  void _redraw() {
    final String line = _buffer.join();
    _terminal.write('\r\x1b[2K$_stats$_prompt${_safe(line)}');
    final int moveLeft = _buffer.length - _cursor;
    if (moveLeft > 0) _terminal.write('\x1b[${moveLeft}D');
  }

  static String _safe(String value) => PterodactylConsoleSanitizer.text(value);
}

final class _ConsoleConnected {
  const _ConsoleConnected();
}

final class _ConsoleDetached {
  const _ConsoleDetached();
}
