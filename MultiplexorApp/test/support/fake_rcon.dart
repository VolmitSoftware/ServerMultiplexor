import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FakeRcon {
  FakeRcon._(this._server, this._password, this._response, this._onCommand) {
    _server.listen(_handle);
  }

  static Future<FakeRcon> start({
    required String password,
    String response = '',
    String? Function(String command)? onCommand,
  }) async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return FakeRcon._(server, password, response, onCommand);
  }

  final ServerSocket _server;
  final String _password;
  final String _response;
  final String? Function(String command)? _onCommand;
  final List<Socket> _clients = <Socket>[];

  int acceptCount = 0;

  int get port => _server.port;

  int get liveClientCount => _clients.length;

  void _handle(Socket socket) {
    acceptCount++;
    _clients.add(socket);
    final List<int> buffer = <int>[];
    socket.listen(
      (Uint8List data) {
        buffer.addAll(data);
        while (buffer.length >= 4) {
          final int length = _readInt32LE(buffer, 0);
          if (buffer.length - 4 < length) {
            break;
          }
          final int id = _readInt32LE(buffer, 4);
          final int type = _readInt32LE(buffer, 8);
          final String body = ascii.decode(
            buffer.sublist(12, 4 + length - 2),
            allowInvalid: true,
          );
          buffer.removeRange(0, 4 + length);
          if (type == 3) {
            final bool authenticated = body == _password;
            // Paper sends an empty value before the authentication response.
            socket.add(_packet(id, 0, ''));
            socket.add(_packet(authenticated ? id : -1, 2, ''));
          } else if (type == 2) {
            final String? Function(String command)? handler = _onCommand;
            final String? response = handler == null
                ? _response
                : handler(body);
            if (response == null) {
              _clients.remove(socket);
              socket.destroy();
              return;
            }
            socket.add(_packet(id, 0, response));
          }
        }
      },
      onError: (Object _) {},
      onDone: () => _clients.remove(socket),
    );
  }

  Future<void> dropClients() async {
    final List<Socket> clients = List<Socket>.from(_clients);
    _clients.clear();
    for (final Socket socket in clients) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    await dropClients();
    await _server.close();
  }
}

List<int> _int32LE(int value) => <int>[
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

List<int> _packet(int id, int type, String body) {
  final List<int> bytes = ascii.encode(body);
  final int length = 4 + 4 + bytes.length + 2;
  return <int>[
    ..._int32LE(length),
    ..._int32LE(id),
    ..._int32LE(type),
    ...bytes,
    0,
    0,
  ];
}

int _readInt32LE(List<int> bytes, int offset) {
  final int value =
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  return value >= 0x80000000 ? value - 0x100000000 : value;
}
