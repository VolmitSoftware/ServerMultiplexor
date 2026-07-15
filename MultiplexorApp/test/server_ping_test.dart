import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/server_ping.dart';
import 'package:test/test.dart';

/// Builds a complete status-response packet (length-prefixed) wrapping [json].
List<int> buildStatusPacket(String json) {
  final jsonBytes = utf8.encode(json);
  final body = <int>[
    0x00, // packet id: status response
    ...encodeVarInt(jsonBytes.length),
    ...jsonBytes,
  ];
  return <int>[...encodeVarInt(body.length), ...body];
}

void main() {
  group('encodeVarInt', () {
    test('encodes single-byte values', () {
      expect(encodeVarInt(0), <int>[0x00]);
      expect(encodeVarInt(1), <int>[0x01]);
      expect(encodeVarInt(127), <int>[0x7F]);
    });

    test('encodes multi-byte values', () {
      expect(encodeVarInt(128), <int>[0x80, 0x01]);
      expect(encodeVarInt(255), <int>[0xFF, 0x01]);
      expect(encodeVarInt(300), <int>[0xAC, 0x02]);
      expect(encodeVarInt(25565), <int>[0xDD, 0xC7, 0x01]);
    });

    test('encodes -1 as a 5-byte 32-bit value', () {
      expect(encodeVarInt(-1), <int>[0xFF, 0xFF, 0xFF, 0xFF, 0x0F]);
    });
  });

  group('readVarInt', () {
    test('round-trips positive values', () {
      for (final value in <int>[0, 1, 127, 128, 300, 25565, 2097151]) {
        final encoded = encodeVarInt(value);
        final result = readVarInt(encoded);
        expect(result, isNotNull);
        expect(result!.$1, value);
        expect(result.$2, encoded.length);
      }
    });

    test('honors an offset', () {
      final bytes = <int>[0xFF, ...encodeVarInt(300)];
      final result = readVarInt(bytes, 1);
      expect(result!.$1, 300);
      expect(result.$2, 2);
    });

    test('returns null for an incomplete VarInt', () {
      expect(readVarInt(<int>[0x80]), isNull);
      expect(readVarInt(<int>[]), isNull);
    });
  });

  group('buildHandshakeRequest', () {
    test('frames a handshake followed by a status request', () {
      final bytes = buildHandshakeRequest('localhost', 25565);

      // First a length-prefixed handshake packet.
      final header = readVarInt(bytes)!;
      final handshakeLength = header.$1;
      final prefixSize = header.$2;
      expect(bytes[prefixSize], 0x00); // handshake packet id

      // After the handshake comes the status-request packet: length 1, id 0.
      final afterHandshake = prefixSize + handshakeLength;
      expect(bytes[afterHandshake], 0x01); // status request length
      expect(bytes[afterHandshake + 1], 0x00); // status request id
      expect(bytes.length, afterHandshake + 2);

      // The port is encoded as a big-endian unsigned short before next-state.
      expect(bytes[afterHandshake - 3], (25565 >> 8) & 0xFF);
      expect(bytes[afterHandshake - 2], 25565 & 0xFF);
      expect(bytes[afterHandshake - 1], 0x01); // next state: status
    });
  });

  group('extractPacketBody', () {
    test('returns the body once the full packet has arrived', () {
      final packet = buildStatusPacket('{"a":1}');
      final body = extractPacketBody(packet);
      expect(body, isNotNull);
      expect(body!.first, 0x00); // status-response packet id
    });

    test('returns null while the packet is incomplete', () {
      final packet = buildStatusPacket('{"a":1}');
      final partial = packet.sublist(0, packet.length - 2);
      expect(extractPacketBody(partial), isNull);
    });
  });

  group('parseStatusResponse', () {
    test('decodes the embedded JSON object', () {
      final body = extractPacketBody(buildStatusPacket('{"online":true}'))!;
      final json = parseStatusResponse(body);
      expect(json, <String, dynamic>{'online': true});
    });

    test('returns null on a truncated body', () {
      final body = extractPacketBody(buildStatusPacket('{"x":1}'))!;
      expect(parseStatusResponse(body.sublist(0, body.length - 3)), isNull);
    });
  });

  group('extractMotd', () {
    test('flattens a plain-string description and strips color codes', () {
      expect(extractMotd('Hello §aWorld'), 'Hello World');
    });

    test('flattens a chat-component description with nested extra parts', () {
      final description = <String, dynamic>{
        'text': 'A ',
        'extra': <dynamic>[
          <String, dynamic>{'text': 'B '},
          'C',
        ],
      };
      expect(extractMotd(description), 'A B C');
    });

    test('collapses newlines to spaces', () {
      expect(extractMotd('line1\nline2'), 'line1 line2');
    });
  });

  group('MinecraftPingResult.fromStatusJson', () {
    test('parses counts, version, sample, and motd', () {
      final json = <String, dynamic>{
        'version': <String, dynamic>{'name': 'Purpur 26.1.2'},
        'players': <String, dynamic>{
          'online': 1,
          'max': 20,
          'sample': <dynamic>[
            <String, dynamic>{'name': 'Magic_Psycho', 'id': 'abc'},
          ],
        },
        'description': 'Wormholes §aALPHA',
      };

      final result = MinecraftPingResult.fromStatusJson(
        json,
        const Duration(milliseconds: 12),
      );

      expect(result.online, 1);
      expect(result.max, 20);
      expect(result.versionName, 'Purpur 26.1.2');
      expect(result.sample, <String>['Magic_Psycho']);
      expect(result.motd, 'Wormholes ALPHA');
      expect(result.latency, const Duration(milliseconds: 12));
    });

    test('falls back to safe defaults for missing fields', () {
      final result = MinecraftPingResult.fromStatusJson(
        <String, dynamic>{},
        Duration.zero,
      );
      expect(result.online, 0);
      expect(result.max, 0);
      expect(result.versionName, '?');
      expect(result.sample, isEmpty);
      expect(result.motd, '');
    });
  });

  group('pingMinecraftServer socket behavior (loopback)', () {
    const String statusJson =
        '{"players":{"online":3,"max":20},'
        '"version":{"name":"Loopback 1.0"},"description":"test"}';

    test('closes gracefully (FIN, not RST) even with trailing data', () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<bool> sawCleanEof = Completer<bool>();
      server.listen((Socket client) {
        client.listen(
          (List<int> _) {},
          onError: (Object _) {
            if (!sawCleanEof.isCompleted) {
              sawCleanEof.complete(false);
            }
          },
          onDone: () {
            if (!sawCleanEof.isCompleted) {
              sawCleanEof.complete(true);
            }
            client.destroy();
          },
        );
        client.add(buildStatusPacket(statusJson));
        // Straggler bytes after the response, like a server keeping the
        // connection open for the optional ping/pong exchange. An abortive
        // close with these unread resets the connection (RST) instead of
        // finishing it (FIN).
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          try {
            client.add(<int>[0x00]);
          } catch (_) {}
        });
      });

      final MinecraftPingResult? result = await pingMinecraftServer(
        '127.0.0.1',
        server.port,
        timeout: const Duration(seconds: 2),
      );
      expect(result, isNotNull);
      expect(result!.online, 3);
      expect(result.versionName, 'Loopback 1.0');

      final bool clean = await sawCleanEof.future.timeout(
        const Duration(seconds: 3),
      );
      expect(
        clean,
        isTrue,
        reason: 'server side must observe EOF (FIN), not a reset (RST)',
      );
      await server.close();
    });

    test('closes gracefully when the server never responds', () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<bool> sawCleanEof = Completer<bool>();
      server.listen((Socket client) {
        client.listen(
          (List<int> _) {},
          onError: (Object _) {
            if (!sawCleanEof.isCompleted) {
              sawCleanEof.complete(false);
            }
          },
          onDone: () {
            if (!sawCleanEof.isCompleted) {
              sawCleanEof.complete(true);
            }
            client.destroy();
          },
        );
      });

      final MinecraftPingResult? result = await pingMinecraftServer(
        '127.0.0.1',
        server.port,
        timeout: const Duration(milliseconds: 300),
      );
      expect(result, isNull);

      final bool clean = await sawCleanEof.future.timeout(
        const Duration(seconds: 3),
      );
      expect(clean, isTrue, reason: 'timed-out probes must FIN, not RST');
      await server.close();
    });
  });
}
