import 'dart:async';
import 'dart:io';

import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_console_session.dart';

abstract interface class PterodactylConsoleTerminalIo {
  bool get hasTerminal;
  bool get supportsColor;
  int get columns;
  Stream<TermEvent> get events;

  Future<void> activate();
  void write(String value);
  Future<void> restore();
}

/// The synchronous terminal primitives behind the asynchronous console input
/// pump. Keeping this boundary injectable makes it possible to prove that the
/// pump releases stdin without turning the process-wide [stdin] into a Stream.
abstract interface class PterodactylConsoleTerminalBackend {
  bool get hasTerminal;
  int get columns;

  void activate();
  TermEvent? readEventTimeout(Duration timeout);
  void restore();
}

final class TermIoPterodactylConsoleTerminalBackend
    implements PterodactylConsoleTerminalBackend {
  const TermIoPterodactylConsoleTerminalBackend();

  TermIo get _io => TermIo.instance;

  @override
  bool get hasTerminal => _io.hasTerminal;

  @override
  int get columns => _io.terminalColumns;

  @override
  void activate() {
    _io.disableMouse();
    _io.drainInput();
    _io.setRawMode(true);
    _io.showCursor();
  }

  @override
  TermEvent? readEventTimeout(Duration timeout) =>
      _io.readEventTimeout(timeout);

  @override
  void restore() => _io.restoreTerminal();
}

/// Asynchronous raw-terminal input that leaves WebSocket events free to run on
/// the isolate event loop while a command is being edited.
final class DartIoPterodactylConsoleTerminalIo
    implements PterodactylConsoleTerminalIo {
  DartIoPterodactylConsoleTerminalIo({
    PterodactylConsoleTerminalBackend backend =
        const TermIoPterodactylConsoleTerminalBackend(),
    Duration readTimeout = const Duration(milliseconds: 40),
    void Function(String value)? writer,
  }) : _backend = backend,
       _readTimeout = readTimeout,
       _writer = writer ?? stdout.write;

  final PterodactylConsoleTerminalBackend _backend;
  final Duration _readTimeout;
  final void Function(String value) _writer;
  final StreamController<TermEvent> _events = StreamController<TermEvent>(
    sync: true,
  );
  Future<void>? _pump;
  bool _active = false;
  bool _activatedBackend = false;
  int _lastColumns = 0;

  @override
  bool get hasTerminal => _backend.hasTerminal;

  @override
  bool get supportsColor {
    final Map<String, String> environment = Platform.environment;
    return !environment.containsKey('NO_COLOR') &&
        (environment['TERM'] ?? '').toLowerCase() != 'dumb';
  }

  @override
  int get columns => _backend.columns;

  @override
  Stream<TermEvent> get events => _events.stream;

  @override
  Future<void> activate() async {
    if (_active) throw StateError('The console terminal is already active.');
    if (!hasTerminal) {
      throw StateError('The remote console requires an interactive terminal.');
    }
    _active = true;
    try {
      _backend.activate();
      _activatedBackend = true;
      _lastColumns = columns;
      _pump = _pumpEvents();
    } catch (_) {
      _active = false;
      if (_activatedBackend) _backend.restore();
      _activatedBackend = false;
      rethrow;
    }
  }

  Future<void> _pumpEvents() async {
    try {
      while (_active) {
        final TermEvent? event = _backend.readEventTimeout(_readTimeout);
        if (!_active) break;
        if (event != null && !_events.isClosed) _events.add(event);
        final int currentColumns = columns;
        if (currentColumns != _lastColumns) {
          _lastColumns = currentColumns;
          if (!_events.isClosed) {
            _events.add(const TermEvent(TermEventKind.unknown));
          }
        }
        // The read itself is synchronous so stdin remains owned by TermIo.
        // Yield after every bounded read to let WebSocket frames render.
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      // A lost tty closes the event stream; the console lifecycle detaches.
    } finally {
      if (!_events.isClosed) await _events.close();
    }
  }

  @override
  void write(String value) => _writer(value);

  @override
  Future<void> restore() async {
    if (!_active && !_activatedBackend) return;
    _active = false;
    try {
      await _pump;
    } finally {
      _pump = null;
      if (!_events.isClosed) await _events.close();
      if (_activatedBackend) _backend.restore();
      _activatedBackend = false;
    }
  }
}

/// Minimal live-console frontend: sanitized output above a raw-mode line
/// editor. Escape, Ctrl+C, and `:exit` detach without stopping the server.
final class PterodactylConsoleTerminal {
  static const int _maximumPendingOutputLines = 4096;
  static const int _maximumLinesPerFlush = 128;
  static const int _pendingOutputTrimChunk = 256;
  static const int _maximumDetachOutputLines = 16;

  PterodactylConsoleTerminal({
    required PterodactylConsoleConnection connection,
    PterodactylConsoleTerminalIo? terminal,
    String prompt = '> ',
    Duration closeTimeout = const Duration(seconds: 2),
    Duration outputBatchDelay = const Duration(milliseconds: 12),
  }) : _connection = connection,
       _terminal = terminal ?? DartIoPterodactylConsoleTerminalIo(),
       _prompt = PterodactylConsoleSanitizer.text(prompt),
       _closeTimeout = closeTimeout,
       _outputBatchDelay = outputBatchDelay;

  final PterodactylConsoleConnection _connection;
  final PterodactylConsoleTerminalIo _terminal;
  final String _prompt;
  final Duration _closeTimeout;
  final Duration _outputBatchDelay;
  final List<String> _buffer = <String>[];
  final List<String> _history = <String>[];
  final List<String> _pendingOutput = <String>[];
  int _cursor = 0;
  int _historyIndex = 0;
  String _state = 'connecting';
  double? _cpu;
  int? _memory;
  int? _memoryLimit;
  bool _transportConnected = false;
  bool _serverAcceptsCommands = false;
  bool _chromeVisible = false;
  bool _acceptOutput = true;
  int _droppedOutputLines = 0;
  Timer? _outputTimer;
  final Completer<_ConsoleTerminalFailure> _terminalFailure =
      Completer<_ConsoleTerminalFailure>.sync();

  Future<void> run() async {
    StreamSubscription<PterodactylConsoleEvent>? remoteEvents;
    try {
      await _terminal.activate();
      _printHeader();
      remoteEvents = _connection.events.listen((PterodactylConsoleEvent event) {
        try {
          _renderEvent(event);
        } catch (error, stackTrace) {
          _failTerminal(error, stackTrace);
        }
      });
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
        _terminalFailure.future.then<Object>(
          (_ConsoleTerminalFailure value) => value,
        ),
      ]);
      if (first case final _ConsoleTerminalFailure failure) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
      if (first is _ConsoleDetached) return;
      final Object finished = await Future.any<Object>(<Future<Object>>[
        input.then<Object>((_) => const _ConsoleDetached()),
        _connection.done.then<Object>((_) => const _ConsoleDetached()),
        _terminalFailure.future.then<Object>(
          (_ConsoleTerminalFailure value) => value,
        ),
      ]);
      if (finished case final _ConsoleTerminalFailure failure) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
    } finally {
      _acceptOutput = false;
      _outputTimer?.cancel();
      _outputTimer = null;
      try {
        try {
          _trimPendingOutputForDetach();
          _flushOutput(drainAll: true);
          _finishDisplay();
        } finally {
          // Restore before awaiting socket/subscription cleanup. A stalled
          // WebSocket listener must never leave the caller in raw/no-echo
          // mode or make Escape appear to hang during a restart flood.
          await _terminal.restore();
        }
      } finally {
        try {
          await remoteEvents?.cancel().timeout(_closeTimeout);
        } catch (_) {
          // Rendering is disabled and the tty is already restored. A stalled
          // listener is safe to abandon with the socket.
        } finally {
          try {
            await _connection.close().timeout(_closeTimeout);
          } catch (_) {
            // A stuck or failed socket close must not keep the CLI alive or
            // replace the error that originally ended the session.
          }
        }
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
      case TermEventKind.unknown:
        // The concrete terminal adapter emits this when the tty width changes.
        _redraw();
      default:
        break;
    }
    return false;
  }

  Future<bool> _submit() async {
    final String command = _buffer.join();
    if (command.trim() == ':exit') {
      _echoSubmittedCommand(command);
      return true;
    }
    if (command.isEmpty) {
      _redraw();
      return false;
    }
    if (!_transportConnected || !_serverAcceptsCommands) {
      final String reason = !_transportConnected
          ? 'The remote console is reconnecting.'
          : 'The remote server is ${_state.toUpperCase()}.';
      _printNotice(
        'WAITING',
        '$reason Command retained; press Enter to retry.',
        _style(Ansi.yellow),
      );
      return false;
    }
    try {
      await _connection.sendCommand(command);
    } catch (_) {
      _printNotice(
        'ERROR',
        'Unable to send the console command. Command retained; press Enter '
            'to retry.',
        _style(Ansi.red),
      );
      return false;
    }
    _echoSubmittedCommand(command);
    if (_history.isEmpty || _history.last != command) _history.add(command);
    if (_history.length > 100) _history.removeAt(0);
    _historyIndex = _history.length;
    _redraw();
    return false;
  }

  void _echoSubmittedCommand(String command) {
    _clearChrome();
    _terminal.write(
      '${_style(Ansi.gray)}${_safe(_prompt)}${_style(Ansi.reset)}'
      '${_safe(command)}\r\n',
    );
    _buffer.clear();
    _cursor = 0;
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
    if (!_acceptOutput) return;
    switch (event) {
      case PterodactylConsoleOutput(:final lines):
        _queueLines(
          PterodactylConsoleLogFormatter.renderedLines(
            lines,
            colors: _terminal.supportsColor,
          ),
        );
      case PterodactylConsoleInstallOutput(:final lines):
        _queueLines(
          lines.map(
            (String line) =>
                '${_style(Ansi.magenta)}[INSTALL]${_style(Ansi.reset)} '
                '${_safe(line)}',
          ),
        );
      case PterodactylConsoleStatus(:final status):
        _state = _singleLine(status).toLowerCase();
        _serverAcceptsCommands = _isRunningState(_state);
        _redraw();
      case PterodactylConsoleStats():
        if (event.state case final String state) {
          _state = _singleLine(state).toLowerCase();
          _serverAcceptsCommands = _isRunningState(_state);
        }
        _cpu = event.cpuAbsolute;
        _memory = event.memoryBytes;
        _memoryLimit = event.memoryLimitBytes;
        _redraw();
      case PterodactylConsoleAuthenticated():
        _transportConnected = true;
        if (_state == 'connecting') _state = 'connected';
        _redraw();
      case PterodactylConsoleTokenExpiring():
        _state = 'refreshing auth';
        _redraw();
      case PterodactylConsoleTokenExpired():
        _state = 'refreshing auth';
        _redraw();
      case PterodactylConsoleDaemonMessage(:final message, :final isError):
        _printNotice(
          isError ? 'DAEMON ERROR' : 'DAEMON',
          message,
          _style(isError ? Ansi.red : Ansi.magenta),
        );
      case PterodactylConsoleUnknownEvent():
        // Wings adds protocol events over time. Unknown names are safe to
        // ignore here and remain available to protocol-level diagnostics.
        break;
      case PterodactylConsoleProtocolWarning(:final message):
        _printNotice('WARNING', message, _style(Ansi.yellow));
      case PterodactylConsoleConnectionEvent(:final state, :final message):
        _transportConnected = switch (state) {
          PterodactylConsoleConnectionState.connected => true,
          PterodactylConsoleConnectionState.refreshing => _transportConnected,
          PterodactylConsoleConnectionState.connecting ||
          PterodactylConsoleConnectionState.reconnecting ||
          PterodactylConsoleConnectionState.disconnected ||
          PterodactylConsoleConnectionState.error => false,
        };
        if (state != PterodactylConsoleConnectionState.connected &&
            state != PterodactylConsoleConnectionState.refreshing) {
          _serverAcceptsCommands = false;
        }
        _state = switch (state) {
          PterodactylConsoleConnectionState.connecting => 'connecting',
          PterodactylConsoleConnectionState.connected => 'connected',
          PterodactylConsoleConnectionState.reconnecting => 'reconnecting',
          PterodactylConsoleConnectionState.refreshing => 'refreshing auth',
          PterodactylConsoleConnectionState.disconnected => 'disconnected',
          PterodactylConsoleConnectionState.error => 'connection error',
        };
        if (message != null &&
            (state == PterodactylConsoleConnectionState.error ||
                state == PterodactylConsoleConnectionState.disconnected)) {
          _printNotice(
            state == PterodactylConsoleConnectionState.error
                ? 'CONNECTION ERROR'
                : 'DISCONNECTED',
            message,
            _style(
              state == PterodactylConsoleConnectionState.error
                  ? Ansi.red
                  : Ansi.yellow,
            ),
          );
        } else {
          _redraw();
        }
    }
  }

  static String _bytes(int value) {
    const int gibibyte = 1024 * 1024 * 1024;
    const int mebibyte = 1024 * 1024;
    if (value >= gibibyte) {
      return '${(value / gibibyte).toStringAsFixed(1)} GiB';
    }
    return '${(value / mebibyte).toStringAsFixed(0)} MiB';
  }

  void _printHeader() {
    final int width = _usableWidth;
    final String rule = '─' * width;
    final String title =
        '${_style(Ansi.cyan)}${_style(Ansi.bold)}MULTIPLEXOR'
        '${_style(Ansi.reset)}  ${_style(Ansi.bold)}REMOTE CONSOLE'
        '${_style(Ansi.reset)}';
    _terminal.write(
      '${Ansi.clipVisible(title, width)}\r\n'
      '${_style(Ansi.gray)}${Ansi.clipVisible(rule, width)}'
      '${_style(Ansi.reset)}\r\n',
    );
    _redraw();
  }

  int get _usableWidth {
    final int columns = _terminal.columns;
    if (columns < 1) return 1;
    return columns > 240 ? 240 : columns;
  }

  void _queueLines(Iterable<String> lines) {
    bool added = false;
    for (final String line in lines) {
      if (_pendingOutput.length >= _maximumPendingOutputLines) {
        final int discard = _pendingOutput.length.clamp(
          0,
          _pendingOutputTrimChunk,
        );
        _pendingOutput.removeRange(0, discard);
        _droppedOutputLines += discard;
      }
      _pendingOutput.add(line);
      added = true;
    }
    if (!added) return;
    _scheduleOutputFlush(_outputBatchDelay);
  }

  void _trimPendingOutputForDetach() {
    final int overflow = _pendingOutput.length - _maximumDetachOutputLines;
    if (overflow <= 0) return;
    _pendingOutput.removeRange(0, overflow);
    _droppedOutputLines += overflow;
  }

  void _scheduleOutputFlush(Duration delay) {
    if (_outputTimer != null) return;
    _outputTimer = Timer(delay, () {
      _outputTimer = null;
      try {
        _flushOutput();
      } catch (error, stackTrace) {
        _failTerminal(error, stackTrace);
      }
    });
  }

  void _failTerminal(Object error, StackTrace stackTrace) {
    _acceptOutput = false;
    _outputTimer?.cancel();
    _outputTimer = null;
    if (!_terminalFailure.isCompleted) {
      _terminalFailure.complete(_ConsoleTerminalFailure(error, stackTrace));
    }
  }

  void _flushOutput({bool drainAll = false}) {
    if (_pendingOutput.isEmpty && _droppedOutputLines == 0) return;
    final int count = drainAll
        ? _pendingOutput.length
        : _pendingOutput.length.clamp(0, _maximumLinesPerFlush);
    final List<String> lines = _pendingOutput.sublist(0, count);
    _pendingOutput.removeRange(0, count);
    final int dropped = _droppedOutputLines;
    _droppedOutputLines = 0;
    _clearChrome();
    if (dropped > 0) {
      _terminal.write(
        '${_style(Ansi.yellow)}[OUTPUT]${_style(Ansi.reset)} '
        '$dropped older console lines skipped to keep input responsive.'
        '${_style(Ansi.reset)}\r\n',
      );
    }
    for (final String line in lines) {
      _terminal.write('${_clipRendered(line)}${_style(Ansi.reset)}\r\n');
    }
    _redraw();
    if (_pendingOutput.isNotEmpty) {
      _scheduleOutputFlush(Duration.zero);
    }
  }

  String _clipRendered(String line) => Ansi.clipVisible(line, _usableWidth);

  void _printNotice(String label, String message, String tone) {
    final List<String> lines = _safe(message).split('\n');
    _queueLines(<String>[
      for (final String line in lines)
        '$tone[$label]${_style(Ansi.reset)} ${line.trim()}',
    ]);
  }

  void _clearChrome() {
    if (!_chromeVisible) return;
    _terminal.write('\r${Ansi.eraseLine}\x1b[1A\r${Ansi.eraseLine}');
    _chromeVisible = false;
  }

  void _redraw() {
    if (!_transportConnected && !_acceptOutput) return;
    _clearChrome();
    final String status = _statusLine();
    final String line = _buffer.join();
    final String fullPrompt =
        '${_style(Ansi.cyan)}${_safe(_prompt)}${_style(Ansi.reset)}';
    final String prompt = Ansi.clipVisible(fullPrompt, _usableWidth);
    final int promptWidth = Ansi.visibleLength(prompt);
    final int available = (_usableWidth - promptWidth).clamp(0, 4096);
    final String visibleInput = _safe(line).length <= available
        ? _safe(line)
        : _safe(line).substring(_safe(line).length - available);
    _terminal.write(
      '\r${Ansi.eraseLine}${_clipRendered(status)}\r\n'
      '${Ansi.eraseLine}$prompt$visibleInput',
    );
    _chromeVisible = true;
    final int hiddenCharacters = line.length - visibleInput.length;
    final int visibleCursor = (_cursor - hiddenCharacters).clamp(
      0,
      visibleInput.length,
    );
    final int moveLeft = visibleInput.length - visibleCursor;
    if (moveLeft > 0) _terminal.write('\x1b[${moveLeft}D');
  }

  String _statusLine() {
    final List<String> metrics = <String>[
      '${_style(_stateTone(_state))}${_state.toUpperCase()}'
          '${_style(Ansi.reset)}',
      if (_cpu case final double cpu) 'CPU ${cpu.toStringAsFixed(1)}%',
      if (_memory case final int memory) _memoryLabel(memory),
    ];
    return '${metrics.join('${_style(Ansi.gray)} · ${_style(Ansi.reset)}')}  '
        '${_style(Ansi.gray)}[Esc] back · [Enter] send · [:exit] back'
        '${_style(Ansi.reset)}';
  }

  String _memoryLabel(int memory) {
    final int? limit = _memoryLimit;
    return limit != null && limit > 0
        ? 'MEM ${_bytes(memory)} / ${_bytes(limit)}'
        : 'MEM ${_bytes(memory)}';
  }

  static String _stateTone(String state) {
    final String normalized = state.toLowerCase();
    if (normalized.contains('error') || normalized.contains('offline')) {
      return Ansi.red;
    }
    if (normalized.contains('stop') ||
        normalized.contains('disconnect') ||
        normalized.contains('refresh')) {
      return Ansi.yellow;
    }
    if (normalized.contains('running') || normalized.contains('connect')) {
      return Ansi.green;
    }
    return Ansi.gray;
  }

  void _finishDisplay() {
    _clearChrome();
    _terminal.write('${_style(Ansi.reset)}\r\n');
  }

  String _style(String ansi) => _terminal.supportsColor ? ansi : '';

  static String _safe(String value) => PterodactylConsoleSanitizer.text(value);

  static String _singleLine(String value) {
    final String output = _safe(value)
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .join(' ');
    return output.isEmpty ? 'unknown' : output;
  }

  static bool _isRunningState(String state) =>
      state.trim().toLowerCase() == 'running';
}

/// Makes Wings console output resemble Multiplexor's Local minimal console.
///
/// The remote protocol supplies already-rendered log text, so it cannot use
/// the Local runtime's Log4j pattern directly. It can still remove the common
/// timestamp/thread/level prefixes and suppress the manager-generated RCON
/// client lifecycle noise that the Local Log4j filter removes. Unknown output
/// is preserved verbatim after terminal sanitization.
final class PterodactylConsoleLogFormatter {
  PterodactylConsoleLogFormatter._();

  static const Set<String> _levels = <String>{
    'TRACE',
    'DEBUG',
    'INFO',
    'WARN',
    'ERROR',
    'FATAL',
  };

  static final RegExp _compactMinecraftPrefix = RegExp(
    r'^\[\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+'
    r'(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\](?::\s*|\s+)',
    caseSensitive: false,
  );
  static final RegExp _threadedMinecraftPrefix = RegExp(
    r'^\[[^\]\r\n]*\d{2}:\d{2}:\d{2}(?:\.\d+)?\]\s*'
    r'\[[^\]\r\n]+/(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\]\s*'
    r'(?:\[[^\]\r\n]+\]\s*)?:?\s*',
    caseSensitive: false,
  );
  static final RegExp _classicMinecraftPrefix = RegExp(
    r'^(?:\d{4}-\d{2}-\d{2}[ T])?\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+'
    r'\[(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\]\s*:?[ \t]*',
    caseSensitive: false,
  );
  static final RegExp _rconLifecycleNoise = RegExp(
    r'^\s*Thread\s+RCON Client\b.*\b(?:started|shutting down)\s*$',
    caseSensitive: false,
  );
  static final RegExp _wingsLifecycleNoise = RegExp(
    r'^\s*container@pterodactyl~\s+Server marked as '
    r'(?:starting|running|stopping|offline)\.*\s*$',
    caseSensitive: false,
  );
  static final RegExp _routineDaemonNoise = RegExp(
    r'^\s*\[Pterodactyl Daemon\]:\s*(?:'
    r'Checking server disk space usage.*|'
    r'Updating process configuration files.*|'
    r'Ensuring file permissions are set correctly.*|'
    r'Pulling Docker container image.*|'
    r'Finished pulling Docker container image.*)\s*$',
    caseSensitive: false,
  );
  static final List<RegExp> _severityPrefixes = <RegExp>[
    RegExp(
      r'^\[\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+'
      r'(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\]',
      caseSensitive: false,
    ),
    RegExp(
      r'^\[[^\]\r\n]*\d{2}:\d{2}:\d{2}(?:\.\d+)?\]\s*'
      r'\[[^\]\r\n]+/(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\]',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:\d{4}-\d{2}-\d{2}[ T])?\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+'
      r'\[(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\]',
      caseSensitive: false,
    ),
  ];
  static final RegExp _successMessage = RegExp(
    r'^(?:Done \(|.+ (?:joined|logged in|connected)|Started .+|'
    r'Server ready\b)',
    caseSensitive: false,
  );

  static const Map<String, String> _legacyCodes = <String, String>{
    '0': '\x1b[30m',
    '1': '\x1b[34m',
    '2': '\x1b[32m',
    '3': '\x1b[36m',
    '4': '\x1b[31m',
    '5': '\x1b[35m',
    '6': '\x1b[33m',
    '7': '\x1b[37m',
    '8': '\x1b[90m',
    '9': '\x1b[94m',
    'a': '\x1b[92m',
    'b': '\x1b[96m',
    'c': '\x1b[91m',
    'd': '\x1b[95m',
    'e': '\x1b[93m',
    'f': '\x1b[97m',
    'l': Ansi.bold,
    'm': '\x1b[9m',
    'n': '\x1b[4m',
    'o': '\x1b[3m',
    'r': Ansi.reset,
  };

  /// Formats [input] for display, or returns null for a line intentionally
  /// hidden by the same RCON-noise policy as the Local console.
  static String? line(String input) {
    String output = PterodactylConsoleSanitizer.text(input);
    if (_wingsLifecycleNoise.hasMatch(output) ||
        _routineDaemonNoise.hasMatch(output)) {
      return null;
    }
    output = output.replaceFirst(_threadedMinecraftPrefix, '');
    output = output.replaceFirst(_compactMinecraftPrefix, '');
    output = output.replaceFirst(_classicMinecraftPrefix, '');
    if (output.trim().isEmpty || _rconLifecycleNoise.hasMatch(output)) {
      return null;
    }
    return output;
  }

  /// A terminal-safe, severity-preserving representation of [input]. Remote
  /// ANSI was removed by [line]; every escape emitted here is a fixed local
  /// style, including translated Minecraft `§` formatting codes.
  static String? renderedLine(String input, {bool colors = true}) {
    final String sanitized = PterodactylConsoleSanitizer.text(input);
    final String? message = line(sanitized);
    if (message == null) return null;
    final String? level = _severity(sanitized);
    final bool success = _successMessage.hasMatch(message);
    final String tone = !colors
        ? ''
        : success
        ? Ansi.green
        : switch (level) {
            'TRACE' || 'DEBUG' => Ansi.gray,
            'WARN' => Ansi.yellow,
            'ERROR' || 'FATAL' => Ansi.red,
            _ => '',
          };
    final String label = level == null
        ? ''
        : '${colors ? _levelTone(level) : ''}[$level]'
              '${colors ? Ansi.reset : ''} ';
    final String body = _minecraftStyles(message, colors: colors);
    return '$label$tone$body${tone.isEmpty ? '' : Ansi.reset}';
  }

  static String? _severity(String input) {
    for (final RegExp pattern in _severityPrefixes) {
      final RegExpMatch? match = pattern.firstMatch(input);
      if (match != null) {
        final String level = match.group(1)!.toUpperCase();
        if (_levels.contains(level)) return level;
      }
    }
    return null;
  }

  static String _levelTone(String level) => switch (level) {
    'WARN' => Ansi.yellow,
    'ERROR' || 'FATAL' => Ansi.red,
    'TRACE' || 'DEBUG' => Ansi.gray,
    _ => Ansi.gray,
  };

  static String _minecraftStyles(String input, {required bool colors}) {
    final StringBuffer output = StringBuffer();
    int index = 0;
    while (index < input.length) {
      if (input.codeUnitAt(index) == 0x00a7 && index + 1 < input.length) {
        final String code = input[index + 1].toLowerCase();
        final String? ansi = _legacyCodes[code];
        if (ansi != null) {
          if (colors && RegExp(r'^[0-9a-f]$').hasMatch(code)) {
            output.write(Ansi.reset);
          }
          if (colors) output.write(ansi);
          index += 2;
          continue;
        }
        // Unknown Minecraft formatting codes are controls, not content.
        index += 2;
        continue;
      }
      output.write(input[index]);
      index++;
    }
    return output.toString();
  }

  static Iterable<String> lines(Iterable<String> input) sync* {
    for (final String raw in input) {
      final String? formatted = line(raw);
      if (formatted != null) {
        yield formatted;
      }
    }
  }

  static Iterable<String> renderedLines(
    Iterable<String> input, {
    bool colors = true,
  }) sync* {
    for (final String raw in input) {
      final String? formatted = renderedLine(raw, colors: colors);
      if (formatted != null) yield formatted;
    }
  }
}

final class _ConsoleConnected {
  const _ConsoleConnected();
}

final class _ConsoleDetached {
  const _ConsoleDetached();
}

final class _ConsoleTerminalFailure {
  const _ConsoleTerminalFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
