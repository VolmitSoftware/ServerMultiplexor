import 'dart:async';

import 'package:multiplexor/services/pterodactyl/pterodactyl_console_protocol.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_session.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_terminal.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:test/test.dart';

void main() {
  for (final MapEntry<String, List<TermEvent>> scenario
      in <String, List<TermEvent>>{
        'escape': const <TermEvent>[TermEvent(TermEventKind.escape)],
        'ctrl-c': const <TermEvent>[TermEvent(TermEventKind.ctrlC)],
        ':exit': <TermEvent>[
          for (final String character in ':exit'.split(''))
            TermEvent(TermEventKind.char, char: character),
          const TermEvent(TermEventKind.enter),
        ],
      }.entries) {
    test('${scenario.key} detaches and always restores the terminal', () async {
      final _FakeConnection connection = _FakeConnection();
      final _FakeTerminal terminal = _FakeTerminal();
      final PterodactylConsoleTerminal console = PterodactylConsoleTerminal(
        connection: connection,
        terminal: terminal,
      );

      final Future<void> running = console.run();
      await Future<void>.delayed(Duration.zero);
      for (final TermEvent event in scenario.value) {
        terminal.input.add(event);
      }
      await running;

      expect(connection.closed, isTrue);
      expect(terminal.restored, isTrue);
      expect(connection.commands, isEmpty);
    });
  }

  test('sanitizes remote output before writing it to the terminal', () async {
    final _FakeConnection connection = _FakeConnection(
      onConnect: (_FakeConnection value) {
        value.remote.add(
          const PterodactylConsoleOutput(<String>['safe\x1b[2Jbad']),
        );
      },
    );
    final _FakeTerminal terminal = _FakeTerminal();
    final PterodactylConsoleTerminal console = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    );

    final Future<void> running = console.run();
    await Future<void>.delayed(Duration.zero);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    expect(terminal.output.toString(), contains('safebad'));
    expect(terminal.output.toString(), isNot(contains('\x1b[2J')));
  });

  test('restores and closes when connection setup fails', () async {
    final _FakeConnection connection = _FakeConnection(failConnect: true);
    final _FakeTerminal terminal = _FakeTerminal();

    await expectLater(
      PterodactylConsoleTerminal(
        connection: connection,
        terminal: terminal,
      ).run(),
      throwsStateError,
    );

    expect(connection.closed, isTrue);
    expect(terminal.restored, isTrue);
  });

  test('escape can cancel while connection setup is still pending', () async {
    final Completer<void> connectGate = Completer<void>();
    final _FakeConnection connection = _FakeConnection(
      connectGate: connectGate,
    );
    final _FakeTerminal terminal = _FakeTerminal();

    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();
    await Future<void>.delayed(Duration.zero);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    expect(connection.closed, isTrue);
    expect(terminal.restored, isTrue);
  });
}

final class _FakeConnection implements PterodactylConsoleConnection {
  _FakeConnection({this.onConnect, this.failConnect = false, this.connectGate});

  final void Function(_FakeConnection connection)? onConnect;
  final bool failConnect;
  final Completer<void>? connectGate;
  final StreamController<PterodactylConsoleEvent> remote =
      StreamController<PterodactylConsoleEvent>.broadcast(sync: true);
  final Completer<void> completed = Completer<void>();
  final List<String> commands = <String>[];
  bool closed = false;

  @override
  Future<void> get done => completed.future;

  @override
  Stream<PterodactylConsoleEvent> get events => remote.stream;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('fixture failure');
    await connectGate?.future;
    onConnect?.call(this);
  }

  @override
  Future<void> requestLogs() async {}

  @override
  Future<void> requestStats() async {}

  @override
  Future<void> sendCommand(String command) async => commands.add(command);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!completed.isCompleted) completed.complete();
    await remote.close();
  }
}

final class _FakeTerminal implements PterodactylConsoleTerminalIo {
  final StreamController<TermEvent> input =
      StreamController<TermEvent>.broadcast(sync: true);
  final StringBuffer output = StringBuffer();
  bool active = false;
  bool restored = false;

  @override
  Stream<TermEvent> get events => input.stream;

  @override
  bool get hasTerminal => true;

  @override
  Future<void> activate() async => active = true;

  @override
  void write(String value) => output.write(value);

  @override
  Future<void> restore() async {
    restored = true;
    await input.close();
  }
}
