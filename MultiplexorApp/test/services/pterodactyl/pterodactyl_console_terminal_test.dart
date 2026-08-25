import 'dart:async';
import 'dart:collection';

import 'package:multiplexor/services/pterodactyl/pterodactyl_console_protocol.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_session.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_terminal.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:test/test.dart';

void main() {
  group('PterodactylConsoleLogFormatter', () {
    test('matches Local minimal console prefixes across server formats', () {
      expect(
        PterodactylConsoleLogFormatter.line('[12:34:56 INFO]: Done (1.2s)!'),
        'Done (1.2s)!',
      );
      expect(
        PterodactylConsoleLogFormatter.line(
          '[12:34:56] [Server thread/WARN]: Can\'t keep up!',
        ),
        'Can\'t keep up!',
      );
      expect(
        PterodactylConsoleLogFormatter.line(
          '[12Aug2026 12:34:56.123] [Server thread/INFO] '
          '[minecraft/MinecraftServer]: Player joined',
        ),
        'Player joined',
      );
      expect(
        PterodactylConsoleLogFormatter.line('12:34:56 [ERROR] Crash detail'),
        'Crash detail',
      );
      expect(
        PterodactylConsoleLogFormatter.line('container@pterodactyl~ started'),
        'container@pterodactyl~ started',
      );
    });

    test('suppresses the same RCON lifecycle noise as Local', () {
      expect(
        PterodactylConsoleLogFormatter.line(
          '[12:34:56 INFO]: Thread RCON Client /127.0.0.1 started',
        ),
        isNull,
      );
      expect(
        PterodactylConsoleLogFormatter.line(
          '[12:34:57 INFO]: Thread RCON Client /127.0.0.1 shutting down',
        ),
        isNull,
      );
      expect(
        PterodactylConsoleLogFormatter.line(
          '[12:34:58 WARN]: RCON Client authentication failed',
        ),
        'RCON Client authentication failed',
      );
    });

    test(
      'suppresses routine Wings lifecycle chatter but preserves commands',
      () {
        for (final String noise in <String>[
          'container@pterodactyl~ Server marked as starting...',
          'container@pterodactyl~ Server marked as running.',
          '[Pterodactyl Daemon]: Checking server disk space usage, this could '
              'take a few seconds...',
          '[Pterodactyl Daemon]: Ensuring file permissions are set correctly...',
        ]) {
          expect(PterodactylConsoleLogFormatter.line(noise), isNull);
        }
        expect(
          PterodactylConsoleLogFormatter.line(
            'container@pterodactyl~ java -version',
          ),
          'container@pterodactyl~ java -version',
        );
      },
    );

    test('preserves severity and safely translates Minecraft colors', () {
      final String warning = PterodactylConsoleLogFormatter.renderedLine(
        '[12:34:56 WARN]: §6Disk §lis almost full§r',
      )!;
      final String error = PterodactylConsoleLogFormatter.renderedLine(
        '12:34:56 [ERROR] Crash detail',
      )!;
      final String success = PterodactylConsoleLogFormatter.renderedLine(
        '[12:34:56 INFO]: Done (1.2s)!',
      )!;

      expect(warning, contains('${Ansi.yellow}[WARN]'));
      expect(warning, contains(Ansi.bold));
      expect(warning, isNot(contains('§')));
      expect(error, contains('${Ansi.red}[ERROR]'));
      expect(success, contains(Ansi.green));
      expect(warning, isNot(contains('12:34:56')));
    });

    test(
      'never preserves hostile remote ANSI and supports colorless output',
      () {
        final String rendered = PterodactylConsoleLogFormatter.renderedLine(
          '[12:34:56 INFO]: safe\x1b[35mhostile\x1b[0m §aMinecraft',
        )!;
        final String colorless = PterodactylConsoleLogFormatter.renderedLine(
          '[12:34:56 WARN]: §6Caution',
          colors: false,
        )!;

        expect(rendered, contains('safehostile'));
        expect(rendered, isNot(contains(Ansi.magenta)));
        expect(rendered, isNot(contains('§')));
        expect(colorless, '[WARN] Caution');
        expect(colorless, isNot(contains('\x1b')));
      },
    );
  });

  test(
    'terminal adapter pumps shared bounded reads and releases ownership',
    () async {
      final _FakeBackend backend = _FakeBackend();
      final DartIoPterodactylConsoleTerminalIo terminal =
          DartIoPterodactylConsoleTerminalIo(
            backend: backend,
            readTimeout: Duration.zero,
            writer: (_) {},
          );
      final List<TermEvent> events = <TermEvent>[];
      final Completer<void> escaped = Completer<void>();
      final Completer<void> resized = Completer<void>();
      final StreamSubscription<TermEvent> subscription = terminal.events.listen(
        (TermEvent event) {
          events.add(event);
          if (event.kind == TermEventKind.escape && !escaped.isCompleted) {
            escaped.complete();
          }
          if (event.kind == TermEventKind.unknown && !resized.isCompleted) {
            resized.complete();
          }
        },
      );

      await terminal.activate();
      backend.pending.add(const TermEvent(TermEventKind.escape));
      await escaped.future.timeout(const Duration(milliseconds: 250));
      backend.columns = 80;
      await resized.future.timeout(const Duration(milliseconds: 250));
      await terminal.restore().timeout(const Duration(milliseconds: 250));
      await subscription.cancel();

      expect(backend.activated, isTrue);
      expect(backend.restored, isTrue);
      expect(backend.reads, greaterThan(0));
      expect(
        events.map((TermEvent event) => event.kind),
        containsAll(<TermEventKind>[
          TermEventKind.escape,
          TermEventKind.unknown,
        ]),
      );
    },
  );

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

  test(
    'escape restores and returns when WebSocket close never completes',
    () async {
      final Completer<void> closeGate = Completer<void>();
      final _FakeConnection connection = _FakeConnection(closeGate: closeGate);
      final _FakeTerminal terminal = _FakeTerminal();
      final Future<void> running = PterodactylConsoleTerminal(
        connection: connection,
        terminal: terminal,
        closeTimeout: const Duration(milliseconds: 10),
      ).run();
      await Future<void>.delayed(Duration.zero);

      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running.timeout(const Duration(milliseconds: 250));

      expect(connection.closeStarted, isTrue);
      expect(terminal.restored, isTrue);
      closeGate.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('escape buffered during terminal activation still detaches', () async {
    final _FakeConnection connection = _FakeConnection();
    final _FakeTerminal terminal = _FakeTerminal(
      onActivate: (_FakeTerminal value) {
        value.input.add(const TermEvent(TermEventKind.escape));
      },
    );

    await PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();

    expect(connection.closed, isTrue);
    expect(terminal.restored, isTrue);
  });

  test('formats remote Minecraft logs before rendering them', () async {
    final _FakeConnection connection = _FakeConnection(
      onConnect: (_FakeConnection value) {
        value.remote.add(
          const PterodactylConsoleOutput(<String>[
            '[09:10:11 INFO]: Server ready',
            '[09:10:12 INFO]: Thread RCON Client /127.0.0.1 started',
          ]),
        );
      },
    );
    final _FakeTerminal terminal = _FakeTerminal();

    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();
    await Future<void>.delayed(Duration.zero);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    final String output = terminal.output.toString();
    expect(output, contains('Server ready'));
    expect(output, isNot(contains('09:10:11')));
    expect(output, isNot(contains('RCON Client')));
  });

  test('batches history flood into one prompt redraw', () async {
    final _FakeConnection connection = _FakeConnection(
      onConnect: (_FakeConnection value) {
        value.remote.add(
          PterodactylConsoleOutput(<String>[
            for (int index = 0; index < 100; index++)
              '[09:10:11 INFO]: history-$index',
          ]),
        );
      },
    );
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
      outputBatchDelay: const Duration(milliseconds: 5),
    ).run();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    final String output = terminal.output.toString();
    expect(output, contains('history-99'));
    expect(
      output,
      anyOf(contains('history-0'), contains('older console lines skipped')),
    );
    // Header, transport connection, server state, and one batched history
    // flush. The 100 history rows must not trigger 100 prompt redraws.
    expect(RegExp(r'> ').allMatches(output).length, 4);
  });

  test('typed command reaches the remote console on Enter', () async {
    final _FakeConnection connection = _FakeConnection();
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();
    await _pump();

    for (final String character in 'say hello'.split('')) {
      terminal.input.add(TermEvent(TermEventKind.char, char: character));
    }
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();

    expect(connection.commands, <String>['say hello']);
    expect(Ansi.strip(terminal.output.toString()), contains('> say hello\r\n'));

    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test('failed command remains editable and can be retried', () async {
    final _FakeConnection connection = _FakeConnection(sendFailures: 1);
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
      outputBatchDelay: Duration.zero,
    ).run();
    await _pump();

    for (final String character in 'list'.split('')) {
      terminal.input.add(TermEvent(TermEventKind.char, char: character));
    }
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();
    expect(connection.commands, isEmpty);
    expect(terminal.output.toString(), contains('Command retained'));

    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();
    expect(connection.commands, <String>['list']);

    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test('command waits through disconnect and sends after reconnect', () async {
    final _FakeConnection connection = _FakeConnection();
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
      outputBatchDelay: Duration.zero,
    ).run();
    await _pump();

    connection.remote.add(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.disconnected,
      ),
    );
    for (final String character in 'list'.split('')) {
      terminal.input.add(TermEvent(TermEventKind.char, char: character));
    }
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();
    expect(connection.commands, isEmpty);
    expect(terminal.output.toString(), contains('Command retained'));

    connection.remote.add(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.connected,
      ),
    );
    connection.remote.add(const PterodactylConsoleStatus('running'));
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();
    expect(connection.commands, <String>['list']);

    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test('command waits through restart states and sends once running', () async {
    final _FakeConnection connection = _FakeConnection();
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
      outputBatchDelay: Duration.zero,
    ).run();
    await _pump();

    for (final String character in 'list'.split('')) {
      terminal.input.add(TermEvent(TermEventKind.char, char: character));
    }
    for (final String state in <String>['offline', 'stopping', 'starting']) {
      connection.remote.add(PterodactylConsoleStatus(state));
      terminal.input.add(const TermEvent(TermEventKind.enter));
      await _pump();
      expect(connection.commands, isEmpty);
    }
    expect(terminal.output.toString(), contains('remote server is'));

    connection.remote.add(const PterodactylConsoleStatus('running'));
    terminal.input.add(const TermEvent(TermEventKind.enter));
    await _pump();
    expect(connection.commands, <String>['list']);

    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;
  });

  test(
    'restart output flood stays bounded and leaves input responsive',
    () async {
      final _FakeConnection connection = _FakeConnection(
        onConnect: (_FakeConnection value) {
          value.remote.add(
            PterodactylConsoleOutput(<String>[
              for (int index = 0; index < 5000; index++)
                '[09:10:11 INFO]: restart-$index',
            ]),
          );
        },
      );
      final _FakeTerminal terminal = _FakeTerminal();
      final Future<void> running = PterodactylConsoleTerminal(
        connection: connection,
        terminal: terminal,
        outputBatchDelay: const Duration(milliseconds: 1),
      ).run();
      await _pump();

      for (final String character in 'list'.split('')) {
        terminal.input.add(TermEvent(TermEventKind.char, char: character));
      }
      terminal.input.add(const TermEvent(TermEventKind.enter));
      await _pump();
      expect(connection.commands, <String>['list']);

      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running.timeout(const Duration(milliseconds: 500));
      expect(
        terminal.output.toString(),
        contains('older console lines skipped'),
      );
    },
  );

  test('status text cannot add rows to the two-line editor chrome', () async {
    final _FakeConnection connection = _FakeConnection(
      onConnect: (_FakeConnection value) {
        value.remote.add(const PterodactylConsoleStatus('running\nbroken'));
      },
    );
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();
    await _pump();
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    expect(terminal.output.toString(), contains('RUNNING BROKEN'));
    expect(terminal.output.toString(), isNot(contains('RUNNING\nBROKEN')));
  });

  test(
    'writer failure still restores terminal and closes connection',
    () async {
      final _FakeConnection connection = _FakeConnection();
      final _FakeTerminal terminal = _FakeTerminal(failWriteAt: 0);

      await expectLater(
        PterodactylConsoleTerminal(
          connection: connection,
          terminal: terminal,
        ).run(),
        throwsStateError,
      );

      expect(terminal.restored, isTrue);
      expect(connection.closed, isTrue);
    },
  );

  test(
    'asynchronous output failure restores terminal and closes connection',
    () async {
      final _FakeConnection connection = _FakeConnection(
        onConnect: (_FakeConnection value) {
          value.remote.add(
            const PterodactylConsoleOutput(<String>['timer output']),
          );
        },
      );
      final _FakeTerminal terminal = _FakeTerminal(failWriteAt: 6);

      await expectLater(
        PterodactylConsoleTerminal(
          connection: connection,
          terminal: terminal,
          outputBatchDelay: Duration.zero,
        ).run().timeout(const Duration(milliseconds: 500)),
        throwsStateError,
      );

      expect(terminal.restored, isTrue);
      expect(connection.closed, isTrue);
    },
  );

  test('restores terminal before a failing event cancellation', () async {
    late final _FakeTerminal terminal;
    bool cancelObservedAfterRestore = false;
    final _FakeConnection connection = _FakeConnection(
      failEventCancel: true,
      onEventCancel: () {
        cancelObservedAfterRestore = terminal.restored;
      },
    );
    terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
      closeTimeout: const Duration(milliseconds: 10),
    ).run();
    await _pump();

    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running.timeout(const Duration(milliseconds: 500));

    expect(terminal.restored, isTrue);
    expect(cancelObservedAfterRestore, isTrue);
    expect(connection.closed, isTrue);
  });

  test('renders stable branded status and help chrome', () async {
    final _FakeConnection connection = _FakeConnection(
      onConnect: (_FakeConnection value) {
        value.remote.add(
          const PterodactylConsoleStats(
            state: 'running',
            cpuAbsolute: 12.5,
            memoryBytes: 1024 * 1024 * 512,
            memoryLimitBytes: 1024 * 1024 * 1024,
          ),
        );
      },
    );
    final _FakeTerminal terminal = _FakeTerminal();
    final Future<void> running = PterodactylConsoleTerminal(
      connection: connection,
      terminal: terminal,
    ).run();
    await Future<void>.delayed(Duration.zero);
    terminal.input.add(const TermEvent(TermEventKind.escape));
    await running;

    final String output = terminal.output.toString();
    expect(output, contains('MULTIPLEXOR'));
    expect(output, contains('REMOTE CONSOLE'));
    expect(output, contains('RUNNING'));
    expect(output, contains('CPU 12.5%'));
    expect(output, contains('MEM 512 MiB / 1.0 GiB'));
    expect(output, contains('[Esc] back'));
  });

  test(
    'honors a colorless terminal while retaining console controls',
    () async {
      final _FakeConnection connection = _FakeConnection(
        onConnect: (_FakeConnection value) {
          value.remote.add(
            const PterodactylConsoleOutput(<String>[
              '[09:10:11 WARN]: §6Caution',
            ]),
          );
        },
      );
      final _FakeTerminal terminal = _FakeTerminal(color: false);
      final Future<void> running = PterodactylConsoleTerminal(
        connection: connection,
        terminal: terminal,
        outputBatchDelay: Duration.zero,
      ).run();
      await Future<void>.delayed(Duration.zero);
      terminal.input.add(const TermEvent(TermEventKind.escape));
      await running;

      final String output = terminal.output.toString();
      expect(output, contains('[WARN] Caution'));
      expect(output, isNot(contains(Ansi.yellow)));
      expect(output, isNot(contains(Ansi.cyan)));
      expect(output, contains(Ansi.eraseLine));
    },
  );
}

final class _FakeConnection implements PterodactylConsoleConnection {
  _FakeConnection({
    this.onConnect,
    this.onEventCancel,
    this.failEventCancel = false,
    this.failConnect = false,
    this.connectGate,
    this.closeGate,
    int sendFailures = 0,
  }) : _sendFailures = sendFailures;

  final void Function(_FakeConnection connection)? onConnect;
  final void Function()? onEventCancel;
  final bool failEventCancel;
  final bool failConnect;
  final Completer<void>? connectGate;
  final Completer<void>? closeGate;
  final StreamController<PterodactylConsoleEvent> remote =
      StreamController<PterodactylConsoleEvent>.broadcast(sync: true);
  final Completer<void> completed = Completer<void>();
  final List<String> commands = <String>[];
  bool closed = false;
  bool closeStarted = false;
  int _sendFailures;

  @override
  Future<void> get done => completed.future;

  @override
  Stream<PterodactylConsoleEvent> get events => failEventCancel
      ? _CancelFailingStream<PterodactylConsoleEvent>(
          remote.stream,
          onEventCancel ?? () {},
        )
      : remote.stream;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('fixture failure');
    await connectGate?.future;
    remote.add(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.connected,
      ),
    );
    remote.add(const PterodactylConsoleStatus('running'));
    onConnect?.call(this);
  }

  @override
  Future<void> requestLogs() async {}

  @override
  Future<void> requestStats() async {}

  @override
  Future<void> sendCommand(String command) async {
    if (_sendFailures > 0) {
      _sendFailures--;
      throw StateError('fixture send failure');
    }
    commands.add(command);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeStarted = true;
    await closeGate?.future;
    if (!completed.isCompleted) completed.complete();
    await remote.close();
  }
}

final class _CancelFailingStream<T> extends StreamView<T> {
  _CancelFailingStream(super.stream, this._onCancel);

  final void Function() _onCancel;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelFailingSubscription<T>(
    super.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    _onCancel,
  );
}

final class _CancelFailingSubscription<T> implements StreamSubscription<T> {
  const _CancelFailingSubscription(this._delegate, this._onCancel);

  final StreamSubscription<T> _delegate;
  final void Function() _onCancel;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);

  @override
  Future<void> cancel() async {
    _onCancel();
    await _delegate.cancel();
    throw StateError('fixture cancellation failure');
  }

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();
}

Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeTerminal implements PterodactylConsoleTerminalIo {
  _FakeTerminal({this.onActivate, this.color = true, this.failWriteAt});

  final void Function(_FakeTerminal terminal)? onActivate;
  final bool color;
  final int? failWriteAt;
  final StreamController<TermEvent> input = StreamController<TermEvent>(
    sync: true,
  );
  final StringBuffer output = StringBuffer();
  bool active = false;
  bool restored = false;
  int writes = 0;

  @override
  int get columns => 120;

  @override
  bool get supportsColor => color;

  @override
  Stream<TermEvent> get events => input.stream;

  @override
  bool get hasTerminal => true;

  @override
  Future<void> activate() async {
    active = true;
    onActivate?.call(this);
  }

  @override
  void write(String value) {
    final int currentWrite = writes++;
    if (failWriteAt case final int threshold when currentWrite >= threshold) {
      throw StateError('fixture writer failure');
    }
    output.write(value);
  }

  @override
  Future<void> restore() async {
    restored = true;
    if (!input.isClosed) unawaited(input.close());
  }
}

final class _FakeBackend implements PterodactylConsoleTerminalBackend {
  final Queue<TermEvent> pending = Queue<TermEvent>();
  bool activated = false;
  bool restored = false;
  int reads = 0;

  @override
  int columns = 120;

  @override
  bool get hasTerminal => true;

  @override
  void activate() => activated = true;

  @override
  TermEvent? readEventTimeout(Duration timeout) {
    reads++;
    return pending.isEmpty ? null : pending.removeFirst();
  }

  @override
  void restore() => restored = true;
}
