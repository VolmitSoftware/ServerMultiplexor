import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Authenticated local stdin transport for a proxy owned by the Windows host.
final class ProxyRuntimeControl {
  ProxyRuntimeControl._(this._server);

  final ServerSocket _server;
  final Set<Socket> _clients = <Socket>{};
  int get port => _server.port;

  static Future<ProxyRuntimeControl> start({
    required String token,
    required Future<void> Function(String) onCommand,
  }) async {
    if (!RegExp(r'^[0-9a-f]{32,128}$').hasMatch(token)) {
      throw ArgumentError('Invalid runtime owner token');
    }
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final ProxyRuntimeControl control = ProxyRuntimeControl._(server);
    server.listen((Socket client) {
      control._clients.add(client);
      unawaited(control._handle(client, token, onCommand));
    });
    return control;
  }

  Future<void> _handle(
    Socket client,
    String token,
    Future<void> Function(String) onCommand,
  ) async {
    try {
      final String request = await _readLine(client);
      final Object? decoded = jsonDecode(request);
      if (decoded is! Map<String, Object?> || decoded['token'] != token) return;
      final Object? command = decoded['command'];
      if (command is! String || !validCommand(command)) return;
      await onCommand(command);
      client.write('ok\n');
      await client.flush();
    } catch (_) {
      // A failed or unauthenticated request has no effect on the host.
    } finally {
      _clients.remove(client);
      client.destroy();
    }
  }

  static bool validCommand(String command) =>
      command.trim().isNotEmpty &&
      command.length <= 4096 &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(command);

  static Future<bool> send({
    required int port,
    required String token,
    required String command,
  }) async {
    if (!validCommand(command)) throw ArgumentError('Invalid proxy command');
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.write(
        '${jsonEncode(<String, String>{'token': token, 'command': command})}\n',
      );
      await socket.flush();
      return await _readLine(socket) == 'ok';
    } on IOException {
      return false;
    } on TimeoutException {
      return false;
    } on FormatException {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<String> _readLine(Socket socket) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in socket.timeout(
      const Duration(seconds: 2),
    )) {
      for (final int byte in chunk) {
        if (byte == 10) return utf8.decode(bytes);
        bytes.add(byte);
        if (bytes.length > 32768) {
          throw const FormatException('Command too long');
        }
      }
    }
    throw const FormatException('Incomplete command');
  }

  Future<void> close() async {
    await _server.close();
    for (final Socket client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
  }
}
