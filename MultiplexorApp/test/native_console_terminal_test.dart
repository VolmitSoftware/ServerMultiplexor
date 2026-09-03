import 'dart:async';
import 'dart:collection';

import 'package:multiplexor/services/native_console_terminal.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:multiplexor/utils/terminal/term_io.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

const NativeConsoleTarget _first = NativeConsoleTarget(
  name: 'paper',
  port: 25565,
  logPath: '/test/paper.log',
);
const NativeConsoleTarget _second = NativeConsoleTarget(
  name: 'fabric',
  port: 25566,
  logPath: '/test/fabric.log',
);

void main() {
  test(
    'keeps both consoles visible as asynchronous log reads finish',
    () async {
      final _FakeTerminal io = _FakeTerminal();
      final Completer<List<String>> paperLog = Completer<List<String>>();
      final Completer<List<String>> fabricLog = Completer<List<String>>();
      final Map<String, int> reads = <String, int>{};
      final Future<void> running = NativeConsoleTerminal(
        targets: const <NativeConsoleTarget>[_first, _second],
        sendCommand: (_, _) async => null,
        terminal: io,
        theme: MonitorTheme.plainAscii(),
        yieldInterval: const Duration(milliseconds: 1),
        logReader: (String path, int maximumLines) {
          reads[path] = maximumLines;
          return path == _first.logPath ? paperLog.future : fabricLog.future;
        },
      ).run();

      await _until(() => io.output.contains('Waiting for server output'));
      expect(io.output, contains('paper :25565'));
      expect(io.output, contains('fabric :25566'));
      paperLog.complete(<String>['Paper ready']);
      fabricLog.complete(<String>['Fabric ready']);
      await _until(() => io.output.contains('Fabric ready'));
      expect(io.output, contains('Paper ready'));
      expect(reads, <String, int>{_first.logPath: 400, _second.logPath: 400});
      expect(io.restores, 0);

      io.input.add(const TermEvent(TermEventKind.escape));
      await running;
      expect(io.restores, 1);
    },
  );

  test(
    'routes a command once to the selected pane and keeps its response',
    () async {
      final _FakeTerminal io = _FakeTerminal();
      final List<(String, String)> commands = <(String, String)>[];
      final Completer<String?> response = Completer<String?>();
      final Future<void> running = _console(
        io,
        sendCommand: (NativeConsoleTarget target, String command) {
          commands.add((target.name, command));
          return response.future;
        },
      ).run();
      io.input
        ..add(const TermEvent(TermEventKind.tab))
        ..addAll(_type('list'))
        ..add(const TermEvent(TermEventKind.enter))
        ..add(const TermEvent(TermEventKind.enter));
      await _until(() => commands.isNotEmpty);
      io.input.add(const TermEvent(TermEventKind.arrowLeft));
      response.complete('There are 2 players online.');
      await _until(() => io.output.contains('There are 2 players online.'));
      expect(commands, <(String, String)>[('fabric', 'list')]);
      expect(io.restores, 0);
      io.input.add(const TermEvent(TermEventKind.ctrlC));
      await running;
      expect(io.restores, 1);
    },
  );

  test('command failures stay visible and allow the next command', () async {
    final _FakeTerminal io = _FakeTerminal();
    final List<String> commands = <String>[];
    final Future<void> running = _console(
      io,
      sendCommand: (_, String command) async {
        commands.add(command);
        if (commands.length == 1) throw StateError('RCON is unavailable');
        return 'Sent successfully';
      },
    ).run();
    io.input
      ..addAll(_type('list'))
      ..add(const TermEvent(TermEventKind.enter));
    await _until(() => io.output.contains('Command failed:'));
    expect(io.restores, 0);
    io.input
      ..addAll(_type('say ready'))
      ..add(const TermEvent(TermEventKind.enter));
    await _until(() => io.output.contains('Sent successfully'));
    expect(commands, <String>['list', 'say ready']);
    io.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test('Escape restores immediately while a command is pending', () async {
    final _FakeTerminal io = _FakeTerminal();
    final Completer<String?> response = Completer<String?>();
    bool sent = false;
    final Future<void> running = _console(
      io,
      sendCommand: (_, _) {
        sent = true;
        return response.future;
      },
    ).run();
    io.input
      ..addAll(_type('list'))
      ..add(const TermEvent(TermEventKind.enter));
    await _until(() => sent);
    io.input.add(const TermEvent(TermEventKind.escape));
    await running.timeout(const Duration(seconds: 1));
    expect(io.restores, 1);
    final String before = io.output;
    response.completeError(StateError('late failure'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(io.output, before);
  });

  test('a missing command response is visible and never retried', () async {
    final _FakeTerminal io = _FakeTerminal();
    int attempts = 0;
    final Future<void> running = _console(
      io,
      sendCommand: (_, _) async {
        attempts++;
        return null;
      },
    ).run();
    io.input
      ..addAll(_type('list'))
      ..add(const TermEvent(TermEventKind.enter));
    await _until(() => io.output.contains('No response from server.'));
    expect(io.output, isNot(contains('Command sent.')));
    expect(attempts, 1);
    expect(io.restores, 0);
    io.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test('missing logs remain visible, sanitized, and repaintable', () async {
    final _FakeTerminal io = _FakeTerminal();
    final Future<void> running = NativeConsoleTerminal(
      targets: const <NativeConsoleTarget>[_first, _second],
      sendCommand: (_, _) async => null,
      terminal: io,
      theme: MonitorTheme.plainAscii(),
      yieldInterval: const Duration(milliseconds: 1),
      logReader: (String path, _) async {
        if (path == _first.logPath) throw StateError('missing');
        return <String>['\x1b]0;hijacked\x07\x1b[2JVisible log'];
      },
    ).run();
    await _until(() => io.output.contains('Visible log'));
    expect(io.output, contains('<log unavailable>'));
    expect(io.output, isNot(contains('hijacked')));
    final int fullFrames = '\x1B[2J'.allMatches(io.output).length;
    io.input.add(const TermEvent(TermEventKind.char, char: 'R'));
    await _until(() => '\x1B[2J'.allMatches(io.output).length > fullFrames);
    expect(io.restores, 0);
    io.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test(
    'all panes remain reachable when the fleet requires multiple pages',
    () async {
      final _FakeTerminal io = _FakeTerminal();
      final List<NativeConsoleTarget> targets =
          List<NativeConsoleTarget>.generate(
            20,
            (int index) => NativeConsoleTarget(
              name: 'server-$index',
              port: 25565 + index,
              logPath: '/test/$index.log',
            ),
          );
      final Future<void> running = NativeConsoleTerminal(
        targets: targets,
        sendCommand: (_, _) async => null,
        terminal: io,
        theme: MonitorTheme.plainAscii(),
        logReader: (_, _) async => <String>['Ready'],
        yieldInterval: const Duration(milliseconds: 1),
      ).run();
      io.input.addAll(
        List<TermEvent>.filled(19, const TermEvent(TermEventKind.tab)),
      );
      await _until(() => io.output.contains('CONSOLES  20/20'));
      expect(io.output, contains('server-19 :25584'));
      io.input.add(const TermEvent(TermEventKind.escape));
      await running;
      for (final String patch in io.writes) {
        expect(patch, isNot(matches(RegExp(r'(?<!\r)\n'))));
        if (!patch.contains('\x1B[2J')) continue;
        final String frame = patch.split('\x1B[2J').last.replaceAll('\r', '');
        expect(frame.split('\n').length, lessThanOrEqualTo(io.lines - 1));
        for (final String row in frame.split('\n')) {
          expect(Ansi.visibleLength(row), lessThanOrEqualTo(io.columns - 1));
        }
      }
    },
  );

  test('rejects a noninteractive terminal without entering raw mode', () async {
    final _FakeTerminal io = _FakeTerminal()..hasTerminal = false;
    await expectLater(_console(io).run(), throwsStateError);
    expect(io.activations, 0);
  });

  test(
    'restores the terminal when input disappears or activation fails',
    () async {
      final _FakeTerminal lost = _FakeTerminal()..inputLost = true;
      await _console(lost).run();
      expect(lost.restores, 1);
      final _FakeTerminal broken = _FakeTerminal()..activationFails = true;
      await expectLater(_console(broken).run(), throwsStateError);
      expect(broken.restores, 1);
    },
  );
}

NativeConsoleTerminal _console(
  _FakeTerminal io, {
  Future<String?> Function(NativeConsoleTarget, String)? sendCommand,
}) => NativeConsoleTerminal(
  targets: const <NativeConsoleTarget>[_first, _second],
  sendCommand: sendCommand ?? (_, _) async => null,
  terminal: io,
  theme: MonitorTheme.plainAscii(),
  logReader: (_, _) async => <String>['Server ready'],
  yieldInterval: const Duration(milliseconds: 1),
);

Iterable<TermEvent> _type(String text) => text.runes.map(
  (int rune) => TermEvent(TermEventKind.char, char: String.fromCharCode(rune)),
);

Future<void> _until(bool Function() condition) async {
  for (int attempt = 0; attempt < 500; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('The expected console update did not arrive.');
}

final class _FakeTerminal implements NativeConsoleTerminalIo {
  @override
  bool hasTerminal = true;
  @override
  int columns = 80;
  @override
  int lines = 24;
  final Queue<TermEvent> input = Queue<TermEvent>();
  final List<String> writes = <String>[];
  int activations = 0;
  int restores = 0;
  bool inputLost = false;
  bool activationFails = false;

  String get output => writes.join();

  @override
  void activate() {
    activations++;
    if (activationFails) throw StateError('Activation failed');
  }

  @override
  TermEvent? readEventTimeout(Duration timeout) {
    if (inputLost) throw const TermInputUnavailable();
    return input.isEmpty ? null : input.removeFirst();
  }

  @override
  void write(String text) => writes.add(text);
  @override
  void restore() => restores++;
}
