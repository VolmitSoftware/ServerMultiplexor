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
/// RESPONSE_VALUE before the AUTH_RESPONSE.
Future<ServerSocket> _fakeRcon({
  required String password,
  required String response,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((Socket socket) {
    final buffer = <int>[];
    socket.listen((data) {
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
          final ok = body == password;
          socket.add(_packet(id, 0, '')); // empty value precedes auth response
          socket.add(_packet(ok ? id : -1, 2, ''));
        } else if (type == 2) {
          socket.add(_packet(id, 0, response));
        }
      }
    });
  });
  return server;
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

  group('RconClient.command', () {
    test('authenticates and returns the command output', () async {
      final server = await _fakeRcon(
        password: 'secret',
        response: 'TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0',
      );
      addTearDown(() => server.close());

      final out = await RconClient.command(
        '127.0.0.1',
        server.port,
        'secret',
        'tps',
      );
      expect(out, contains('20.0'));
      expect(parseTps(out), 20.0);
    });

    test('returns null on a bad password', () async {
      final server = await _fakeRcon(password: 'secret', response: 'x');
      addTearDown(() => server.close());

      final out = await RconClient.command(
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

      final out = await RconClient.command(
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
