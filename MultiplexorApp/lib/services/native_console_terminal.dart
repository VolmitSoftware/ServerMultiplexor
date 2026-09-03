import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../utils/terminal/ansi.dart';
import '../utils/terminal/frame_patch.dart';
import '../utils/terminal/panel.dart';
import '../utils/terminal/term_events.dart';
import '../utils/terminal/term_io.dart';
import '../utils/terminal/theme.dart';
import 'monitor/log_tail.dart';
import 'pterodactyl/pterodactyl_console_protocol.dart';

final class NativeConsoleTarget {
  const NativeConsoleTarget({
    required this.name,
    required this.port,
    required this.logPath,
  });

  final String name;
  final int port;
  final String logPath;
}

/// Terminal operations are injectable so the same frontend is exercised on
/// every platform without taking ownership of the test runner's stdin.
abstract interface class NativeConsoleTerminalIo {
  bool get hasTerminal;
  int get columns;
  int get lines;
  void activate();
  TermEvent? readEventTimeout(Duration timeout);
  void write(String text);
  void restore();
}

final class DartIoNativeConsoleTerminalIo implements NativeConsoleTerminalIo {
  const DartIoNativeConsoleTerminalIo();

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

/// Live local server consoles for terminals without tmux. Leaving this view
/// only releases the terminal; the server hosts continue running.
final class NativeConsoleTerminal {
  NativeConsoleTerminal({
    required List<NativeConsoleTarget> targets,
    required Future<String?> Function(NativeConsoleTarget, String) sendCommand,
    bool lateral = false,
    NativeConsoleTerminalIo? terminal,
    MonitorTheme? theme,
    Future<List<String>> Function(String, int)? logReader,
    Duration refreshInterval = const Duration(milliseconds: 500),
    Duration yieldInterval = const Duration(milliseconds: 10),
  }) : _targets = List<NativeConsoleTarget>.unmodifiable(targets),
       _sendCommand = sendCommand,
       _lateral = lateral,
       _terminal = terminal ?? const DartIoNativeConsoleTerminalIo(),
       _theme = theme ?? MonitorTheme.cached,
       _logReader = logReader ?? readLogTail,
       _refreshInterval = refreshInterval,
       _yieldInterval = yieldInterval,
       _panes = List<_ConsolePane>.generate(
         targets.length,
         (_) => _ConsolePane(),
       );

  static const int _maximumLogLines = 400;
  final List<NativeConsoleTarget> _targets;
  final Future<String?> Function(NativeConsoleTarget, String) _sendCommand;
  final bool _lateral;
  final NativeConsoleTerminalIo _terminal;
  final MonitorTheme _theme;
  final Future<List<String>> Function(String, int) _logReader;
  final Duration _refreshInterval;
  final Duration _yieldInterval;
  final List<_ConsolePane> _panes;
  final List<String> _buffer = <String>[];
  final List<String> _history = <String>[];
  final List<_ConsolePaneBounds> _bounds = <_ConsolePaneBounds>[];
  int _selected = 0;
  int _cursor = 0;
  int _historyIndex = 0;
  int _lastColumns = 0;
  int _lastLines = 0;
  int _patchCharacters = 0;
  String? _previousFrame;
  DateTime? _lastRead;
  bool _reading = false;
  bool _active = false;

  Future<void> run() async {
    if (!_terminal.hasTerminal) {
      throw StateError('The console view requires an interactive terminal.');
    }
    if (_targets.isEmpty) {
      throw StateError('There are no running servers to display.');
    }
    _active = true;
    try {
      _terminal.activate();
      _refreshLogs();
      _render();
      while (_active) {
        final TermEvent? event = _terminal.readEventTimeout(
          const Duration(milliseconds: 40),
        );
        if (event != null && _handleEvent(event)) break;
        _refreshLogs();
        _render();
        // TermIo retains synchronous ownership of stdin. Yield after every
        // bounded read so log reads and command responses can actually finish.
        await Future<void>.delayed(_yieldInterval);
      }
    } on TermInputUnavailable {
      // Closing the terminal detaches just like Escape.
    } finally {
      _active = false;
      _terminal.restore();
    }
  }

  void _refreshLogs() {
    final DateTime now = DateTime.now();
    if (_reading ||
        (_lastRead != null && now.difference(_lastRead!) < _refreshInterval)) {
      return;
    }
    _reading = true;
    _lastRead = now;
    unawaited(_readLogs());
  }

  Future<void> _readLogs() async {
    try {
      await Future.wait<void>(<Future<void>>[
        for (int index = 0; index < _targets.length; index++) _readPane(index),
      ]);
    } finally {
      _reading = false;
    }
  }

  Future<void> _readPane(int index) async {
    List<String> lines;
    try {
      lines = await _logReader(_targets[index].logPath, _maximumLogLines);
    } catch (_) {
      lines = const <String>['<log unavailable>'];
    }
    if (!_active) return;
    _panes[index].logs = lines
        .skip(math.max(0, lines.length - _maximumLogLines))
        .map(_safeLine)
        .toList(growable: false);
  }

  bool _handleEvent(TermEvent event) {
    switch (event.kind) {
      case TermEventKind.escape:
      case TermEventKind.ctrlC:
        return true;
      case TermEventKind.tab:
        _select(1);
      case TermEventKind.char:
        if (event.char == 'R' && _buffer.isEmpty) {
          _previousFrame = null;
        } else if (event.char.isNotEmpty &&
            _buffer.length < 4096 &&
            !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(event.char)) {
          _buffer.insert(_cursor++, event.char);
          _historyIndex = _history.length;
        }
      case TermEventKind.enter:
        _submit();
      case TermEventKind.backspace:
        if (_cursor > 0) _buffer.removeAt(--_cursor);
      case TermEventKind.delete:
        if (_cursor < _buffer.length) _buffer.removeAt(_cursor);
      case TermEventKind.arrowLeft:
        if (_buffer.isEmpty) {
          _select(-1);
        } else if (_cursor > 0) {
          _cursor--;
        }
      case TermEventKind.arrowRight:
        if (_buffer.isEmpty) {
          _select(1);
        } else if (_cursor < _buffer.length) {
          _cursor++;
        }
      case TermEventKind.home:
        _cursor = 0;
      case TermEventKind.end:
        _cursor = _buffer.length;
        _panes[_selected].scroll = 0;
      case TermEventKind.arrowUp:
        _recall(-1);
      case TermEventKind.arrowDown:
        _recall(1);
      case TermEventKind.pageUp:
        _scroll(10);
      case TermEventKind.pageDown:
        _scroll(-10);
      case TermEventKind.mouseDown:
        if (event.button == 0) _selectAt(event);
      case TermEventKind.wheelUp:
        _selectAt(event);
        _scroll(3);
      case TermEventKind.wheelDown:
        _selectAt(event);
        _scroll(-3);
      default:
        break;
    }
    return false;
  }

  void _select(int delta) => _selected = (_selected + delta) % _targets.length;

  void _selectAt(TermEvent event) {
    for (final _ConsolePaneBounds bounds in _bounds) {
      if (event.row >= bounds.row &&
          event.row < bounds.row + bounds.height &&
          event.col >= bounds.col &&
          event.col < bounds.col + bounds.width) {
        _selected = bounds.index;
        return;
      }
    }
  }

  void _scroll(int delta) {
    final _ConsolePane pane = _panes[_selected];
    pane.scroll = (pane.scroll + delta).clamp(
      0,
      math.max(0, pane.logs.length - 1),
    );
  }

  void _recall(int delta) {
    _historyIndex = (_historyIndex + delta).clamp(0, _history.length);
    _buffer
      ..clear()
      ..addAll(
        _historyIndex == _history.length
            ? const <String>[]
            : _history[_historyIndex].runes.map(String.fromCharCode),
      );
    _cursor = _buffer.length;
  }

  void _submit() {
    final String command = _buffer.join().trim();
    final int index = _selected;
    final _ConsolePane pane = _panes[index];
    if (command.isEmpty || pane.sending) return;
    _buffer.clear();
    _cursor = 0;
    if (_history.isEmpty || _history.last != command) _history.add(command);
    if (_history.length > 100) _history.removeAt(0);
    _historyIndex = _history.length;
    pane
      ..sending = true
      ..notice = <String>['> $command', 'Sending command...'];
    unawaited(_dispatch(index, command));
  }

  Future<void> _dispatch(int index, String command) async {
    final _ConsolePane pane = _panes[index];
    try {
      final String? response = await _sendCommand(_targets[index], command);
      if (!_active) return;
      pane.notice = <String>[
        '> ${_safeLine(command)}',
        if (response == null)
          'No response from server. Check its log.'
        else if (response.trim().isEmpty)
          'Command sent.'
        else
          ...PterodactylConsoleSanitizer.text(response).split('\n').take(8),
      ];
    } catch (error) {
      if (_active) {
        pane.notice = <String>[
          'Command failed: ${_safeLine(error.toString())}',
        ];
      }
    } finally {
      pane.sending = false;
    }
  }

  void _render() {
    final int columns = _terminal.columns.clamp(1, 400);
    final int lines = _terminal.lines.clamp(1, 150);
    final bool resized = columns != _lastColumns || lines != _lastLines;
    _lastColumns = columns;
    _lastLines = lines;
    final String next = _frame(
      math.max(1, columns - 1),
      math.max(1, lines - 1),
    );
    String patch = renderTerminalPatch(
      previous: _previousFrame,
      next: next,
      forceFull: resized,
    );
    final bool checkpoint = terminalFullFrameCheckpointDue(
      charactersSinceFullFrame: _patchCharacters,
      nextPatchCharacters: patch.length,
    );
    if (checkpoint) {
      patch = renderTerminalPatch(previous: null, next: next);
    }
    _patchCharacters = resized || _previousFrame == null || checkpoint
        ? 0
        : _patchCharacters + patch.length;
    _previousFrame = next;
    if (patch.isNotEmpty) {
      _terminal.write(synchronizeTerminalPatch(patch.replaceAll('\n', '\r\n')));
    }
  }

  String _frame(int width, int height) {
    _bounds.clear();
    if (width < 28 || height < 9) {
      return <String>['Resize terminal to at least 29 x 10.', 'Esc: detach']
          .take(height)
          .map((String line) => Ansi.clipVisible(line, width))
          .join('\n');
    }
    final int areaHeight = height - 3;
    final int maxColumns = math.max(1, (width + 1) ~/ 29);
    final int desiredColumns = _lateral
        ? _targets.length
        : math.sqrt(_targets.length).ceil();
    final int gridColumns = desiredColumns.clamp(1, maxColumns);
    final int gridRows = _lateral
        ? 1
        : ((_targets.length + gridColumns - 1) ~/ gridColumns).clamp(
            1,
            math.max(1, areaHeight ~/ 6),
          );
    final int capacity = gridColumns * gridRows;
    final int start = (_selected ~/ capacity) * capacity;
    final int end = math.min(start + capacity, _targets.length);
    final int paneWidth = (width - gridColumns + 1) ~/ gridColumns;
    final int paneHeight = areaHeight ~/ gridRows;
    final List<String> frame = <String>[
      _theme.paint(
        'MULTIPLEXOR  CONSOLES  ${_selected + 1}/${_targets.length}',
        '${_theme.bold}${_theme.textStrong}',
      ),
    ];
    for (int row = 0; row < gridRows; row++) {
      final List<List<String>> blocks = <List<String>>[];
      for (int col = 0; col < gridColumns; col++) {
        final int index = start + row * gridColumns + col;
        if (index >= end) break;
        _bounds.add(
          _ConsolePaneBounds(
            index,
            2 + row * paneHeight,
            1 + col * (paneWidth + 1),
            paneWidth,
            paneHeight,
          ),
        );
        blocks.add(_paneFrame(index, paneWidth, paneHeight));
      }
      frame.addAll(joinBlocks(blocks));
    }
    while (frame.length < height - 2) {
      frame.add('');
    }
    final String prompt = '${_safeLine(_targets[_selected].name)}> ';
    final int available = math.max(1, width - Ansi.visibleLength(prompt));
    final int inputStart = math.max(0, _cursor - available + 1);
    final String before = _buffer
        .skip(inputStart)
        .take(_cursor - inputStart)
        .join();
    final String caret = _cursor < _buffer.length ? _buffer[_cursor] : ' ';
    final String after = _buffer.skip(_cursor + 1).join();
    frame
      ..add('$prompt$before${Ansi.inverse}$caret${Ansi.reset}$after')
      ..add(
        _theme.paint(
          'Tab: pane  Enter: send  PgUp/PgDn: scroll  Shift+R: repaint  Esc: detach',
          _theme.faint,
        ),
      );
    return frame
        .take(height)
        .map((String line) => Ansi.clipVisible(line, width))
        .join('\n');
  }

  List<String> _paneFrame(int index, int width, int height) {
    final NativeConsoleTarget target = _targets[index];
    final _ConsolePane pane = _panes[index];
    final int contentHeight = height - 2;
    final int noticeCount = math.min(pane.notice.length, contentHeight ~/ 2);
    final int logHeight = contentHeight - noticeCount;
    final List<String> logs = pane.logs.isEmpty
        ? const <String>['Waiting for server output...']
        : pane.logs;
    final int end = (logs.length - pane.scroll).clamp(1, logs.length);
    final int start = math.max(0, end - logHeight);
    final List<String> content = <String>[...logs.sublist(start, end)];
    while (content.length < logHeight) {
      content.add('');
    }
    content.addAll(
      pane.notice
          .take(noticeCount)
          .map((String line) => _theme.paint(line, _theme.accent)),
    );
    return renderPanel(
      title: '${_safeLine(target.name)} :${target.port}',
      badge: index == _selected ? 'selected' : null,
      content: content,
      width: width,
      theme: _theme,
      emphasis: index == _selected
          ? PanelEmphasis.active
          : PanelEmphasis.normal,
    );
  }

  static String _safeLine(String value) =>
      PterodactylConsoleSanitizer.text(value).replaceAll('\n', ' ');
}

final class _ConsolePane {
  List<String> logs = const <String>[];
  List<String> notice = const <String>[];
  int scroll = 0;
  bool sending = false;
}

final class _ConsolePaneBounds {
  const _ConsolePaneBounds(
    this.index,
    this.row,
    this.col,
    this.width,
    this.height,
  );
  final int index;
  final int row;
  final int col;
  final int width;
  final int height;
}
