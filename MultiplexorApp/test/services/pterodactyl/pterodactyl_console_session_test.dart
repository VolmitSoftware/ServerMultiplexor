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
      await session.done;

      expect(original.closed, isTrue);
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

final class _FakeConnector implements PterodactylConsoleSocketConnector {
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  Uri? uri;
  String? origin;

  _FakeSocket get socket => sockets.last;

  @override
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  }) async {
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

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => controller.stream;

  void add(Map<String, Object?> event) => controller.add(jsonEncode(event));

  @override
  Future<void> sendText(String text) async => sent.add(text);

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
