import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal Source RCON client — the same protocol Minecraft servers expose
/// when `enable-rcon=true`. It is the only way to read live data the Server
/// List Ping does not carry (notably `tps` on Paper-family servers).
///
/// One-shot by design: connect, authenticate, run a single command, return the
/// response text, and tear the socket down. Any failure (refused connection,
/// bad password, timeout, malformed frame) resolves to `null` rather than
/// throwing, so callers can treat it as "metric unavailable".
class RconClient {
  RconClient._();

  // Packet types.
  static const int _typeAuth = 3;
  static const int _typeExec = 2;
  static const int _typeAuthResponse = 2;

  static Future<String?> command(
    String host,
    int port,
    String password,
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    Socket? socket;
    final queue = <_RconFrame>[];
    final waiters = <Completer<_RconFrame?>>[];
    var closed = false;

    void emit(_RconFrame frame) {
      if (waiters.isNotEmpty) {
        waiters.removeAt(0).complete(frame);
      } else {
        queue.add(frame);
      }
    }

    void closeAll() {
      closed = true;
      while (waiters.isNotEmpty) {
        waiters.removeAt(0).complete(null);
      }
    }

    Future<_RconFrame?> nextFrame() {
      if (queue.isNotEmpty) {
        return Future<_RconFrame?>.value(queue.removeAt(0));
      }
      if (closed) {
        return Future<_RconFrame?>.value(null);
      }
      final completer = Completer<_RconFrame?>();
      waiters.add(completer);
      return completer.future.timeout(timeout, onTimeout: () => null);
    }

    final pending = <int>[];
    void onData(List<int> data) {
      pending.addAll(data);
      while (pending.length >= 4) {
        final length = _readInt32LE(pending, 0);
        if (length < 0 || pending.length - 4 < length) {
          break; // Wait for the rest of the frame.
        }
        final id = _readInt32LE(pending, 4);
        final type = _readInt32LE(pending, 8);
        // Body sits between the type field and the two trailing null bytes.
        final body = ascii.decode(
          pending.sublist(12, 4 + length - 2),
          allowInvalid: true,
        );
        emit(_RconFrame(id, type, body));
        pending.removeRange(0, 4 + length);
      }
    }

    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.listen(
        onData,
        onError: (_) => closeAll(),
        onDone: closeAll,
        cancelOnError: true,
      );

      socket.add(_buildPacket(1, _typeAuth, password));
      await socket.flush();

      // The server may send an empty RESPONSE_VALUE before the auth response;
      // read a few frames until the auth verdict arrives.
      _RconFrame? auth;
      for (var i = 0; i < 3; i++) {
        final frame = await nextFrame();
        if (frame == null) {
          return null;
        }
        if (frame.type == _typeAuthResponse) {
          auth = frame;
          break;
        }
      }
      if (auth == null || auth.id == -1) {
        return null; // Auth failed.
      }

      socket.add(_buildPacket(2, _typeExec, command));
      await socket.flush();

      final response = await nextFrame();
      return response?.body;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  static List<int> _buildPacket(int id, int type, String body) {
    final bodyBytes = ascii.encode(body);
    final length = 4 + 4 + bodyBytes.length + 2;
    return <int>[
      ..._int32LE(length),
      ..._int32LE(id),
      ..._int32LE(type),
      ...bodyBytes,
      0,
      0,
    ];
  }

  static List<int> _int32LE(int value) {
    return <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
  }

  static int _readInt32LE(List<int> bytes, int offset) {
    final value =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    // Restore sign: RCON uses -1 to signal auth failure.
    return value >= 0x80000000 ? value - 0x100000000 : value;
  }
}

class _RconFrame {
  _RconFrame(this.id, this.type, this.body);

  final int id;
  final int type;
  final String body;
}

/// Parses the first TPS number out of a Paper-family `/tps` response, ignoring
/// color codes and the "1m, 5m, 15m" label digits. Returns null when no number
/// is present. Clamps to 20.0 since servers can report a hair above.
double? parseTps(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final clean = raw.replaceAll(RegExp('§.'), '');
  final colon = clean.lastIndexOf(':');
  final tail = colon >= 0 ? clean.substring(colon + 1) : clean;
  final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(tail);
  if (match == null) {
    return null;
  }
  final value = double.tryParse(match.group(1)!);
  if (value == null) {
    return null;
  }
  return value > 20.0 ? 20.0 : value;
}
