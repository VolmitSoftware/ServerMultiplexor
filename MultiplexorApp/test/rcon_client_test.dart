import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/rcon_client.dart';
import 'package:test/test.dart';

List<int> _int32LE(int v) => <int>[
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

List<int> _packet(int id, int type, String body) {
  final bytes = ascii.encode(body);
  final length = 4 + 4 + bytes.length + 2;
  return <int>[
    ..._int32LE(length),
    ..._int32LE(id),
    ..._int32LE(type),
    ...bytes,
    0,
    0,
  ];
}

int _readInt32LE(List<int> b, int o) {
  final v = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

/// A minimal fake Source RCON server: authenticates against [password] and
/// answers any command with [response]. Mirrors real Paper by sending an empty
/// RESPONSE_VALUE before the AUTH_RESPONSE. Tracks how many client connections
/// it has accepted so tests can assert on connection reuse, and can drop the
/// live client to simulate a server restart.
class _FakeRcon {
  _FakeRcon(this._server, this._password, this._response) {
    _server.listen(_handle);
  }

  final ServerSocket _server;
  final String _password;
  final String _response;
  final List<Socket> _clients = <Socket>[];

  int acceptCount = 0;

  int get port => _server.port;

  void _handle(Socket socket) {
    acceptCount++;
    _clients.add(socket);
    final buffer = <int>[];
    socket.listen(
      (data) {
        buffer.addAll(data);
        while (buffer.length >= 4) {
          final len = _readInt32LE(buffer, 0);
          if (buffer.length - 4 < len) {
            break;
          }
          final id = _readInt32LE(buffer, 4);
          final type = _readInt32LE(buffer, 8);
          final body = ascii.decode(
            buffer.sublist(12, 4 + len - 2),
            allowInvalid: true,
          );
          buffer.removeRange(0, 4 + len);
          if (type == 3) {
            final ok = body == _password;
            socket.add(_packet(id, 0, '')); // empty value precedes auth
            socket.add(_packet(ok ? id : -1, 2, ''));
          } else if (type == 2) {
            socket.add(_packet(id, 0, _response));
          }
        }
      },
      onError: (_) {},
      onDone: () => _clients.remove(socket),
    );
  }

  /// Simulates the server closing its side (e.g. a restart) so the pool has to
  /// re-establish the connection on the next command.
  Future<void> dropClients() async {
    final clients = List<Socket>.from(_clients);
    _clients.clear();
    for (final socket in clients) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    await dropClients();
    await _server.close();
  }
}

Future<_FakeRcon> _startFakeRcon({
  required String password,
  required String response,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  return _FakeRcon(server, password, response);
}

void main() {
  group('parseTps', () {
    test('parses a plain Paper tps line', () {
      expect(
        parseTps('TPS from last 1m, 5m, 15m: 19.98, 20.0, 20.0'),
        closeTo(19.98, 0.001),
      );
    });

    test('ignores section-sign color codes', () {
      expect(
        parseTps('§6TPS from last 1m, 5m, 15m: §a20.0, §a20.0, §a20.0'),
        20.0,
      );
    });

    test('clamps values above 20', () {
      expect(parseTps('TPS: 20.05'), 20.0);
    });

    test('returns null when there is no number to read', () {
      expect(parseTps(null), isNull);
      expect(parseTps(''), isNull);
      expect(parseTps('nothing numeric after the colon:'), isNull);
    });
  });

  group('RconConnectionPool', () {
    test('authenticates and returns the command output', () async {
      final server = await _startFakeRcon(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      expect(out, contains('20.0'));
      expect(parseTps(out), 20.0);
    });

    test('reuses a single connection across sequential commands', () async {
      final server = await _startFakeRcon(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final a = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      final b = await pool.command('127.0.0.1', server.port, 'secret', 'tps');
      final c = await pool.command('127.0.0.1', server.port, 'secret', 'tps');

      expect(parseTps(a), 20.0);
      expect(parseTps(b), 20.0);
      expect(parseTps(c), 20.0);
      expect(
        server.acceptCount,
        1,
        reason: 'the pool must reuse one socket, not reconnect per command',
      );
    });

    test('reconnects after the server drops the connection', () async {
      final server = await _startFakeRcon(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 19.5, 19.5, 19.5',
      );
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final first = await pool.command(
        '127.0.0.1',
        server.port,
        'secret',
        'tps',
      );
      expect(parseTps(first), closeTo(19.5, 0.001));
      expect(server.acceptCount, 1);

      await server.dropClients();
      // Give the pool a chance to observe the FIN before the next command so it
      // reconnects cleanly rather than writing into a dead socket.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final second = await pool.command(
        '127.0.0.1',
        server.port,
        'secret',
        'tps',
      );
      expect(parseTps(second), closeTo(19.5, 0.001));
      expect(
        server.acceptCount,
        2,
        reason: 'a dropped connection must be re-established transparently',
      );
    });

    test('returns null on a bad password', () async {
      final server = await _startFakeRcon(password: 'secret', response: 'x');
      addTearDown(server.close);
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command(
        '127.0.0.1',
        server.port,
        'wrong-password',
        'tps',
      );
      expect(out, isNull);
    });

    test('returns null when the connection is refused', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final pool = RconConnectionPool();
      addTearDown(pool.disposeAll);

      final out = await pool.command(
        '127.0.0.1',
        port,
        'secret',
        'tps',
        timeout: const Duration(milliseconds: 300),
      );
      expect(out, isNull);
    });
  });
}
