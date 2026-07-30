import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Source RCON packet types.
const int _typeAuth = 3;
const int _typeExec = 2;
const int _typeAuthResponse = 2;

/// A pool of long-lived Source RCON connections, keyed by `host:port`.
///
/// This is the same protocol Minecraft servers expose when `enable-rcon=true`,
/// and the only way to read live data the Server List Ping does not carry
/// (notably `tps` on Paper-family servers).
///
/// Unlike a one-shot client, a pooled connection stays open and is reused for
/// every subsequent command. That matters because Minecraft logs each RCON
/// connect and disconnect at INFO level (`Thread RCON Client ... started` /
/// `... shutting down`); reconnecting on every dashboard tick floods the server
/// log. Holding one connection open means a single pair of log lines for the
/// whole session instead of a pair every second.
///
/// A connection that the server drops (a restart, or an idle timeout) is
/// re-established transparently on the next command. Any failure — refused
/// connection, bad password, timeout, malformed frame — resolves to `null`
/// rather than throwing, so callers treat it as "metric unavailable".
class RconConnectionPool {
  final Map<String, _RconConnection> _connections = <String, _RconConnection>{};

  /// Runs [command] against the server at [host]:[port], reusing an existing
  /// connection when possible. Returns the response body, or `null` on any
  /// failure.
  Future<String?> command(
    String host,
    int port,
    String password,
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) {
    final key = '$host:$port';
    var connection = _connections[key];
    if (connection == null || connection.password != password) {
      // A rotated password invalidates the cached connection.
      connection?.dispose();
      connection = _RconConnection(host, port, password);
      _connections[key] = connection;
    }
    return connection.command(command, timeout: timeout);
  }

  /// Tears down every pooled connection. Not optional on shutdown: a live
  /// socket keeps the Dart event loop alive, so a CLI command that queried
  /// TPS never exits until the pool is closed. Safe to call more than once —
  /// the interactive monitor disposes on its way out and the CLI runner
  /// disposes again at the dispatch boundary.
  void disposeAll() {
    for (final connection in _connections.values) {
      connection.dispose();
    }
    _connections.clear();
  }
}

/// A single persistent RCON connection. Commands are serialized so their
/// response frames never interleave on the shared socket.
class _RconConnection {
  _RconConnection(this.host, this.port, this.password);

  final String host;
  final int port;
  final String password;

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  bool _authenticated = false;

  // Frame reassembly state for the currently-open socket.
  final List<int> _pending = <int>[];
  final List<_RconFrame> _queue = <_RconFrame>[];
  final List<Completer<_RconFrame?>> _waiters = <Completer<_RconFrame?>>[];

  // Request ids are int32 on the wire; keep them positive and wrap before the
  // signed maximum so the id we send always matches the id the server echoes.
  int _nextId = 2; // id 1 is reserved for auth.

  // Serializes commands on this connection.
  Future<void> _lock = Future<void>.value();

  Future<String?> command(String command, {required Duration timeout}) {
    final result = _lock.then((_) => _run(command, timeout));
    // Keep the lock chain alive even if a command throws.
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _run(String command, Duration timeout) async {
    if (!await _ensureConnected(timeout)) {
      return null;
    }
    final socket = _socket;
    if (socket == null) {
      return null;
    }
    if (_nextId >= 0x7FFFFFFE) {
      _nextId = 2;
    }
    final id = _nextId++;
    try {
      socket.add(_buildPacket(id, _typeExec, command));
      await socket.flush();
    } catch (_) {
      _teardown();
      return null;
    }
    // Read frames until our id comes back, skipping any stray frames. A null
    // frame means timeout or a dropped socket — force a reconnect next time.
    for (var i = 0; i < 4; i++) {
      final frame = await _nextFrame(timeout);
      if (frame == null) {
        _teardown();
        return null;
      }
      if (frame.id == id) {
        return frame.body;
      }
    }
    return null;
  }

  Future<bool> _ensureConnected(Duration timeout) async {
    if (_socket != null && _authenticated) {
      return true;
    }
    return _connect(timeout);
  }

  Future<bool> _connect(Duration timeout) async {
    _teardown(); // Clear any half-open state before reconnecting.
    Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
    } catch (_) {
      return false;
    }
    _socket = socket;
    _subscription = socket.listen(
      _onData,
      onError: (_) => _teardown(),
      onDone: _teardown,
      cancelOnError: true,
    );

    try {
      socket.add(_buildPacket(1, _typeAuth, password));
      await socket.flush();
    } catch (_) {
      _teardown();
      return false;
    }

    // The server may send an empty RESPONSE_VALUE before the auth response;
    // read a few frames until the auth verdict arrives.
    _RconFrame? auth;
    for (var i = 0; i < 3; i++) {
      final frame = await _nextFrame(timeout);
      if (frame == null) {
        _teardown();
        return false;
      }
      if (frame.type == _typeAuthResponse) {
        auth = frame;
        break;
      }
    }
    if (auth == null || auth.id == -1) {
      _teardown(); // Auth failed (server signals -1).
      return false;
    }
    _authenticated = true;
    return true;
  }

  void _onData(List<int> data) {
    _pending.addAll(data);
    while (_pending.length >= 4) {
      final length = _readInt32LE(_pending, 0);
      if (length < 0 || _pending.length - 4 < length) {
        break; // Wait for the rest of the frame.
      }
      final id = _readInt32LE(_pending, 4);
      final type = _readInt32LE(_pending, 8);
      // Body sits between the type field and the two trailing null bytes.
      final body = ascii.decode(
        _pending.sublist(12, 4 + length - 2),
        allowInvalid: true,
      );
      _emit(_RconFrame(id, type, body));
      _pending.removeRange(0, 4 + length);
    }
  }

  void _emit(_RconFrame frame) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(frame);
    } else {
      _queue.add(frame);
    }
  }

  Future<_RconFrame?> _nextFrame(Duration timeout) {
    if (_queue.isNotEmpty) {
      return Future<_RconFrame?>.value(_queue.removeAt(0));
    }
    if (_socket == null) {
      return Future<_RconFrame?>.value(null);
    }
    final completer = Completer<_RconFrame?>();
    _waiters.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(completer);
        return null;
      },
    );
  }

  void _teardown() {
    _authenticated = false;
    _pending.clear();
    _queue.clear();
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete(null);
      }
    }
    _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }

  void dispose() => _teardown();

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
