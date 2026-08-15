import 'dart:async';
import 'dart:convert';

import 'package:multiplexor/services/pterodactyl/pterodactyl_console_protocol.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_session.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:test/test.dart';

void main() {
  test(
    'uses exact Origin, authenticates, requests data, and refreshes auth',
    () async {
      final _FakeConnector connector = _FakeConnector();
      int credentialLoads = 0;
      final PterodactylConsoleSession session = PterodactylConsoleSession(
        profile: _profile,
        serverIdentifier: 'abc123',
        connector: connector,
        loadCredentials: (String identifier) async {
          expect(identifier, 'abc123');
          credentialLoads++;
          return _credentials('token-$credentialLoads');
        },
      );
      final List<PterodactylConsoleEvent> events = <PterodactylConsoleEvent>[];
      final StreamSubscription<PterodactylConsoleEvent> subscription = session
          .events
          .listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        await session.close();
      });

      final Future<void> connected = session.connect();
      await _pump();

      expect(connector.origin, _profile.origin);
      expect(connector.uri, _credentials('ignored').socketUri);
      expect(_eventNames(connector.socket.sent), <String>['auth']);

      connector.socket.add(<String, Object?>{'event': 'auth success'});
      await connected;
      await _pump();
      expect(_eventNames(connector.socket.sent), <String>[
        'auth',
        'send logs',
        'send stats',
      ]);

      connector.socket.add(<String, Object?>{'event': 'token expiring'});
      await _pump();
      expect(credentialLoads, 2);
      expect(_eventNames(connector.socket.sent), <String>[
        'auth',
        'send logs',
        'send stats',
        'auth',
      ]);
      expect(connector.socket.sent.last, contains('token-2'));
      expect(events, contains(isA<PterodactylConsoleTokenExpiring>()));
    },
  );

  test('sends commands as JSON and closes the socket', () async {
    final _FakeConnector connector = _FakeConnector();
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      loadCredentials: (String _) async => _credentials('token'),
    );

    final Future<void> connected = session.connect();
    await _pump();
    connector.socket.add(<String, Object?>{'event': 'auth success'});
    await connected;
    await session.sendCommand('say hello');
    await session.close();

    final List<Object?> decoded = connector.socket.sent
        .map<Object?>(jsonDecode)
        .toList(growable: false);
    expect(
      decoded.any(
        (Object? frame) =>
            frame is Map<String, Object?> &&
            frame['event'] == 'send command' &&
            frame['args'] is List<Object?> &&
            (frame['args']! as List<Object?>).single == 'say hello',
      ),
      isTrue,
    );
    expect(connector.socket.closed, isTrue);
    expect(connector.socket.listenerCanceledBeforeClose, isFalse);
    expect(connector.socket.listenerCompleted, isTrue);
    await session.close();
    expect(connector.socket.closeCalls, 1);
  });

  test('close and socket completion race remains idempotent', () async {
    final _FakeConnector connector = _FakeConnector();
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      loadCredentials: (String _) async => _credentials('token'),
    );
    int doneCount = 0;
    session.done.then((_) => doneCount++);

    final Future<void> connected = session.connect();
    await _pump();
    connector.socket.add(<String, Object?>{'event': 'auth success'});
    await connected;
    await Future.wait<void>(<Future<void>>[session.close(), session.close()]);
    await session.done;
    await _pump();

    expect(doneCount, 1);
    expect(connector.socket.closeCalls, 1);
  });

  test(
    'reconnects after an authenticated socket drops and keeps commands live',
    () async {
      final _FakeConnector connector = _FakeConnector();
      int credentialLoads = 0;
      final PterodactylConsoleSession session = PterodactylConsoleSession(
        profile: _profile,
        serverIdentifier: 'abc123',
        connector: connector,
        reconnectInitialDelay: const Duration(milliseconds: 10),
        reconnectMaximumDelay: const Duration(milliseconds: 20),
        loadCredentials: (String _) async {
          credentialLoads++;
          return _credentials('token-$credentialLoads');
        },
      );
      final List<PterodactylConsoleConnectionState> states =
          <PterodactylConsoleConnectionState>[];
      final StreamSubscription<PterodactylConsoleEvent> subscription = session
          .events
          .listen((PterodactylConsoleEvent event) {
            if (event is PterodactylConsoleConnectionEvent) {
              states.add(event.state);
            }
          });
      bool done = false;
      session.done.then((_) => done = true);
      addTearDown(() async {
        await subscription.cancel();
        await session.close();
      });

      final Future<void> connected = session.connect();
      await _pump();
      final _FakeSocket original = connector.socket;
      original.add(<String, Object?>{'event': 'auth success'});
      await connected;
      await _pump();

      connector.failuresRemaining = 1;
      await original.close();
      await expectLater(session.sendCommand('list'), throwsStateError);
      await _waitUntil(() => connector.sockets.length == 2);
      expect(done, isFalse);
      expect(states, contains(PterodactylConsoleConnectionState.disconnected));
      expect(states, contains(PterodactylConsoleConnectionState.reconnecting));
      expect(credentialLoads, 3);
      expect(connector.attempts, 3);

      final _FakeSocket replacement = connector.socket;
      expect(_eventNames(replacement.sent), <String>['auth']);
      replacement.add(<String, Object?>{'event': 'auth success'});
      await _waitUntil(
        () =>
            states
                .where(
                  (PterodactylConsoleConnectionState state) =>
                      state == PterodactylConsoleConnectionState.connected,
                )
                .length ==
            2,
      );
      await session.sendCommand('say after restart');

      expect(
        replacement.sent.any(
          (String frame) =>
              (jsonDecode(frame) as Map<String, Object?>)['event'] ==
              'send command',
        ),
        isTrue,
      );
      expect(original.listenerCanceledBeforeClose, isFalse);
    },
  );

  test('recovers when a socket errors without first completing', () async {
    final _FakeConnector connector = _FakeConnector();
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      reconnectInitialDelay: const Duration(milliseconds: 1),
      reconnectMaximumDelay: const Duration(milliseconds: 2),
      loadCredentials: (String _) async => _credentials('token'),
    );
    addTearDown(session.close);

    final Future<void> connected = session.connect();
    await _pump();
    final _FakeSocket original = connector.socket;
    original.add(<String, Object?>{'event': 'auth success'});
    await connected;

    original.addError(StateError('fixture transport failure'));
    await _waitUntil(() => connector.sockets.length == 2);
    final _FakeSocket replacement = connector.socket;
    replacement.add(<String, Object?>{'event': 'auth success'});
    await _pump();
    await session.sendCommand('say recovered');

    expect(original.closed, isTrue);
    expect(_eventNames(replacement.sent), contains('send command'));
  });

  test('recovers when an outbound command exposes a dead transport', () async {
    final _FakeConnector connector = _FakeConnector();
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      reconnectInitialDelay: const Duration(milliseconds: 1),
      reconnectMaximumDelay: const Duration(milliseconds: 2),
      loadCredentials: (String _) async => _credentials('token'),
    );
    addTearDown(session.close);

    final Future<void> connected = session.connect();
    await _pump();
    final _FakeSocket original = connector.socket;
    original.add(<String, Object?>{'event': 'auth success'});
    await connected;
    await _pump();

    original.sendFailures = 1;
    await expectLater(session.sendCommand('list'), throwsStateError);
    await _waitUntil(() => connector.sockets.length == 2);
    final _FakeSocket replacement = connector.socket;
    replacement.add(<String, Object?>{'event': 'auth success'});
    await _pump();
    await session.sendCommand('list');

    expect(original.closed, isTrue);
    expect(_eventNames(replacement.sent), contains('send command'));
  });

  test('close cancels a pending reconnect backoff immediately', () async {
    final _FakeConnector connector = _FakeConnector();
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      reconnectInitialDelay: const Duration(days: 1),
      reconnectMaximumDelay: const Duration(days: 1),
      loadCredentials: (String _) async => _credentials('token'),
    );
    final Completer<void> reconnecting = Completer<void>();
    final StreamSubscription<PterodactylConsoleEvent> subscription = session
        .events
        .listen((PterodactylConsoleEvent event) {
          if (event case PterodactylConsoleConnectionEvent(
            state: PterodactylConsoleConnectionState.reconnecting,
          )) {
            if (!reconnecting.isCompleted) reconnecting.complete();
          }
        });
    addTearDown(subscription.cancel);

    final Future<void> connected = session.connect();
    await _pump();
    final _FakeSocket original = connector.socket;
    original.add(<String, Object?>{'event': 'auth success'});
    await connected;
    await original.close();
    await reconnecting.future.timeout(const Duration(milliseconds: 250));

    await session.close().timeout(const Duration(milliseconds: 250));
    await session.done.timeout(const Duration(milliseconds: 250));
    await _pump();

    expect(connector.sockets, hasLength(1));
  });

  test('serializes token refresh with a simultaneous socket loss', () async {
    final _FakeConnector connector = _FakeConnector();
    final Completer<void> refreshStarted = Completer<void>();
    final Completer<PterodactylWebsocketCredentials> refreshCredentials =
        Completer<PterodactylWebsocketCredentials>();
    int credentialLoads = 0;
    final PterodactylConsoleSession session = PterodactylConsoleSession(
      profile: _profile,
      serverIdentifier: 'abc123',
      connector: connector,
      reconnectInitialDelay: const Duration(milliseconds: 1),
      reconnectMaximumDelay: const Duration(milliseconds: 2),
      loadCredentials: (String _) {
        credentialLoads++;
        if (credentialLoads == 2) {
          refreshStarted.complete();
          return refreshCredentials.future;
        }
        return Future<PterodactylWebsocketCredentials>.value(
          _credentials('token-$credentialLoads'),
        );
      },
    );
    addTearDown(session.close);

    final Future<void> connected = session.connect();
    await _pump();
    final _FakeSocket original = connector.socket;
    original.add(<String, Object?>{'event': 'auth success'});
    await connected;

    original.add(<String, Object?>{'event': 'token expiring'});
    await refreshStarted.future.timeout(const Duration(milliseconds: 250));
    await original.close();
    refreshCredentials.complete(_credentials('token-2'));
    await _waitUntil(() => connector.sockets.length == 2);

    final _FakeSocket replacement = connector.socket;
    replacement.add(<String, Object?>{'event': 'auth success'});
    await _pump();
    await session.sendCommand('say serialized');

    expect(credentialLoads, 3);
    expect(connector.attempts, 2);
    expect(original.closed, isTrue);
    expect(_eventNames(replacement.sent), contains('send command'));
  });

  test(
    'reconnects when auth succeeds immediately before transport loss',
    () async {
      final _FakeConnector connector = _FakeConnector();
      final PterodactylConsoleSession session = PterodactylConsoleSession(
        profile: _profile,
        serverIdentifier: 'abc123',
        connector: connector,
        reconnectInitialDelay: const Duration(milliseconds: 1),
        reconnectMaximumDelay: const Duration(milliseconds: 2),
        loadCredentials: (String _) async => _credentials('token'),
      );
      addTearDown(session.close);

      final Future<void> connected = session.connect();
      await _pump();
      final _FakeSocket original = connector.socket;
      original.add(<String, Object?>{'event': 'auth success'});
      final Future<void> originalClosed = original.close();
      await connected;
      await originalClosed;
      await _waitUntil(() => connector.sockets.length == 2);

      final _FakeSocket replacement = connector.socket;
      replacement.add(<String, Object?>{'event': 'auth success'});
      await _pump();
      await session.sendCommand('say still attached');

      expect(_eventNames(replacement.sent), contains('send command'));
    },
  );

  test(
    'retires the previous socket when endpoint refresh auth fails',
    () async {
      final _FakeConnector connector = _FakeConnector();
      int credentialLoads = 0;
      final PterodactylConsoleSession session = PterodactylConsoleSession(
        profile: _profile,
        serverIdentifier: 'abc123',
        connector: connector,
        loadCredentials: (String _) async {
          credentialLoads++;
          return _credentialsAt(
            'token-$credentialLoads',
            credentialLoads == 1
                ? 'node-one.example.test'
                : 'node-two.example.test',
          );
        },
      );

      final Future<void> connected = session.connect();
      await _pump();
      final _FakeSocket original = connector.socket;
      original.add(<String, Object?>{'event': 'auth success'});
      await connected;
      await _pump();

      original.add(<String, Object?>{'event': 'token expiring'});
      await _pump();
      final _FakeSocket replacement = connector.socket;
      expect(replacement, isNot(same(original)));
      await replacement.close();
      await session.close();
      await session.done;

      expect(original.closed, isTrue);
      expect(original.listenerCanceledBeforeClose, isFalse);
      expect(replacement.closed, isTrue);
    },
  );
}

final PterodactylProfile _profile = PterodactylProfile(
  id: 'dev',
  name: 'Development',
  panelUri: Uri.parse('https://dev.volmitsoftware.com'),
);

PterodactylWebsocketCredentials _credentials(String token) =>
    _credentialsAt(token, 'node.example.test');

PterodactylWebsocketCredentials _credentialsAt(String token, String host) =>
    PterodactylWebsocketCredentials.fromJson(<String, Object?>{
      'token': token,
      'socket': 'wss://$host/api/servers/server/ws',
    });

List<String> _eventNames(List<String> frames) => frames
    .map(
      (String frame) =>
          (jsonDecode(frame) as Map<String, Object?>)['event']! as String,
    )
    .toList(growable: false);

Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for console test state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _FakeConnector implements PterodactylConsoleSocketConnector {
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  int attempts = 0;
  int failuresRemaining = 0;
  Uri? uri;
  String? origin;

  _FakeSocket get socket => sockets.last;

  @override
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  }) async {
    attempts++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('fixture connect failure');
    }
    uri = socketUri;
    this.origin = origin;
    final _FakeSocket socket = _FakeSocket();
    sockets.add(socket);
    return socket;
  }
}

final class _FakeSocket implements PterodactylConsoleSocket {
  late final StreamController<Object?> controller = StreamController<Object?>(
    sync: true,
    onCancel: () {
      if (!closeEntered) listenerCanceledBeforeClose = true;
    },
  );
  final List<String> sent = <String>[];
  bool closed = false;
  bool listenerCanceledBeforeClose = false;
  bool listenerCompleted = false;
  bool closeEntered = false;
  int closeCalls = 0;
  int sendFailures = 0;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => controller.stream;

  void add(Map<String, Object?> event) => controller.add(jsonEncode(event));

  void addError(Object error) => controller.addError(error);

  @override
  Future<void> sendText(String text) async {
    if (sendFailures > 0) {
      sendFailures--;
      throw StateError('fixture send failure');
    }
    sent.add(text);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalls++;
    closed = true;
    closeEntered = true;
    if (!controller.isClosed) {
      await controller.close();
      listenerCompleted = true;
    }
  }
}
