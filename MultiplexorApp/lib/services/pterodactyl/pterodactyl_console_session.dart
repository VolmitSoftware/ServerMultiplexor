import 'dart:async';
import 'dart:io';

import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_models.dart';
import 'pterodactyl_profile.dart';

typedef PterodactylConsoleCredentialLoader =
    Future<PterodactylWebsocketCredentials> Function(String identifier);

abstract interface class PterodactylConsoleSocket {
  Stream<Object?> get messages;
  int? get closeCode;
  String? get closeReason;

  Future<void> sendText(String text);
  Future<void> close([int? code, String? reason]);
}

abstract interface class PterodactylConsoleSocketConnector {
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  });
}

final class DartIoPterodactylConsoleSocketConnector
    implements PterodactylConsoleSocketConnector {
  const DartIoPterodactylConsoleSocketConnector({
    this.pingInterval = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 15),
  });

  final Duration pingInterval;
  final Duration connectTimeout;

  @override
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  }) async {
    _requireSecureSocketUri(socketUri);
    _requirePanelOrigin(origin);
    final WebSocket socket = await WebSocket.connect(
      socketUri.toString(),
      headers: <String, String>{'Origin': origin},
      compression: CompressionOptions.compressionOff,
    ).timeout(connectTimeout);
    socket.pingInterval = pingInterval;
    return _DartIoPterodactylConsoleSocket(socket);
  }

  static void _requirePanelOrigin(String origin) {
    final Uri? uri = Uri.tryParse(origin);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.origin != origin) {
      throw const FormatException('Invalid Pterodactyl WebSocket Origin.');
    }
  }
}

final class _DartIoPterodactylConsoleSocket
    implements PterodactylConsoleSocket {
  const _DartIoPterodactylConsoleSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get messages => _socket;

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  Future<void> sendText(String text) async {
    _socket.add(text);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    await _socket.close(code, reason);
  }
}

/// Shared engine boundary used by both interactive and future headless console
/// frontends. It owns authentication, token refresh, and socket lifecycle.
abstract interface class PterodactylConsoleConnection {
  Stream<PterodactylConsoleEvent> get events;
  Future<void> get done;

  Future<void> connect();
  Future<void> requestLogs();
  Future<void> requestStats();
  Future<void> sendCommand(String command);
  Future<void> close();
}

final class PterodactylConsoleSession implements PterodactylConsoleConnection {
  PterodactylConsoleSession({
    required this.profile,
    required String serverIdentifier,
    required PterodactylConsoleCredentialLoader loadCredentials,
    PterodactylConsoleSocketConnector connector =
        const DartIoPterodactylConsoleSocketConnector(),
  }) : serverIdentifier = _validateIdentifier(serverIdentifier),
       _loadCredentials = loadCredentials,
       _connector = connector;

  final PterodactylProfile profile;
  final String serverIdentifier;
  final PterodactylConsoleCredentialLoader _loadCredentials;
  final PterodactylConsoleSocketConnector _connector;
  final StreamController<PterodactylConsoleEvent> _events =
      StreamController<PterodactylConsoleEvent>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();

  PterodactylConsoleSocket? _socket;
  StreamSubscription<Object?>? _messages;
  Uri? _socketUri;
  Future<void>? _refreshing;
  Completer<void>? _authentication;
  int _generation = 0;
  bool _started = false;
  bool _closed = false;

  @override
  Stream<PterodactylConsoleEvent> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> connect() async {
    if (_started) throw StateError('The console session has already started.');
    if (_closed) throw StateError('The console session is closed.');
    _started = true;
    _emit(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.connecting,
      ),
    );
    try {
      final PterodactylWebsocketCredentials credentials =
          await _loadCredentials(serverIdentifier);
      await _open(credentials);
      await _waitForAuthentication();
    } catch (_) {
      _emit(
        const PterodactylConsoleConnectionEvent(
          PterodactylConsoleConnectionState.error,
          message: 'Unable to establish the secure remote console.',
        ),
      );
      await close();
      rethrow;
    }
  }

  @override
  Future<void> requestLogs() => _send(PterodactylConsoleFrames.requestLogs());

  @override
  Future<void> requestStats() => _send(PterodactylConsoleFrames.requestStats());

  @override
  Future<void> sendCommand(String command) =>
      _send(PterodactylConsoleFrames.sendCommand(command));

  Future<void> _open(PterodactylWebsocketCredentials credentials) async {
    _requireSecureSocketUri(credentials.socketUri);
    final PterodactylConsoleSocket next = await _connector.connect(
      credentials.socketUri,
      origin: profile.origin,
    );
    if (_closed) {
      await next.close(WebSocketStatus.normalClosure, 'Session closed');
      return;
    }

    final int generation = ++_generation;
    _authentication = Completer<void>();
    _socket = next;
    _socketUri = credentials.socketUri;
    _messages = next.messages.listen(
      (Object? message) => _handleMessage(generation, message),
      onError: (Object _) => _handleSocketError(generation),
      onDone: () => _handleSocketDone(generation, next),
      cancelOnError: false,
    );
    try {
      await _send(PterodactylConsoleFrames.authenticate(credentials.token));
    } catch (_) {
      await _messages?.cancel();
      _messages = null;
      _socket = null;
      await next.close(WebSocketStatus.goingAway, 'Authentication failed');
      // The send failure itself is propagated to the caller. Clearing this
      // completer avoids creating a second, unobserved asynchronous error
      // before connect() has begun waiting for the authentication response.
      _authentication = null;
      rethrow;
    }
  }

  void _handleMessage(int generation, Object? message) {
    if (_closed || generation != _generation) return;
    if (message is! String) {
      _emit(
        const PterodactylConsoleProtocolWarning(
          'Ignored a non-text console event.',
        ),
      );
      return;
    }
    final PterodactylConsoleEvent event = PterodactylConsoleEventParser.parse(
      message,
    );
    _emit(event);
    switch (event) {
      case PterodactylConsoleAuthenticated():
        final Completer<void>? authentication = _authentication;
        if (authentication != null && !authentication.isCompleted) {
          authentication.complete();
          _emit(
            const PterodactylConsoleConnectionEvent(
              PterodactylConsoleConnectionState.connected,
            ),
          );
        }
        unawaited(_requestInitialData());
      case PterodactylConsoleTokenExpiring():
        _refreshAuthentication(expired: false);
      case PterodactylConsoleTokenExpired():
        _refreshAuthentication(expired: true);
      default:
        break;
    }
  }

  Future<void> _requestInitialData() async {
    try {
      await requestLogs();
      await requestStats();
    } catch (_) {
      _emit(
        const PterodactylConsoleConnectionEvent(
          PterodactylConsoleConnectionState.error,
          message: 'Unable to request remote console history and statistics.',
        ),
      );
    }
  }

  void _refreshAuthentication({required bool expired}) {
    final Future<void>? current = _refreshing;
    if (current != null) {
      if (expired) {
        unawaited(current.catchError((Object _) => close()));
      }
      return;
    }
    _emit(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.refreshing,
      ),
    );
    final Future<void> operation = _performRefresh();
    _refreshing = operation;
    unawaited(
      operation
          .catchError((Object _) async {
            _emit(
              const PterodactylConsoleConnectionEvent(
                PterodactylConsoleConnectionState.error,
                message: 'Unable to refresh remote console authentication.',
              ),
            );
            await close();
          })
          .whenComplete(() {
            if (identical(_refreshing, operation)) _refreshing = null;
          }),
    );
  }

  Future<void> _performRefresh() async {
    final PterodactylWebsocketCredentials credentials = await _loadCredentials(
      serverIdentifier,
    );
    final PterodactylConsoleSocket? previous = _socket;
    final StreamSubscription<Object?>? previousMessages = _messages;
    if (credentials.socketUri == _socketUri) {
      _authentication = Completer<void>();
      await _send(PterodactylConsoleFrames.authenticate(credentials.token));
      await _waitForAuthentication();
    } else {
      try {
        await _open(credentials);
        await _waitForAuthentication();
      } finally {
        // _open() installs the replacement as the active generation. The
        // previous listener and socket must therefore be retired whether the
        // replacement authenticates or fails; otherwise they are unreachable
        // from close() and remain alive until the peer happens to disconnect.
        await previousMessages?.cancel();
        await previous?.close(WebSocketStatus.goingAway, 'Endpoint refreshed');
      }
    }
  }

  Future<void> _waitForAuthentication() async {
    final Completer<void>? authentication = _authentication;
    if (authentication == null) {
      throw StateError('Remote console authentication was not started.');
    }
    try {
      await authentication.future.timeout(const Duration(seconds: 15));
    } finally {
      if (identical(_authentication, authentication)) {
        _authentication = null;
      }
    }
  }

  void _handleSocketError(int generation) {
    if (_closed || generation != _generation) return;
    _emit(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.error,
        message: 'The remote console socket reported an error.',
      ),
    );
    _failAuthentication();
  }

  void _handleSocketDone(int generation, PterodactylConsoleSocket socket) {
    if (_closed || generation != _generation) return;
    _socket = null;
    _messages = null;
    final String? reason = socket.closeReason;
    _emit(
      PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.disconnected,
        message: reason == null || reason.isEmpty
            ? 'Remote console disconnected.'
            : PterodactylConsoleSanitizer.text(reason),
      ),
    );
    _failAuthentication();
    _finish();
  }

  Future<void> _send(String frame) async {
    if (_closed) throw StateError('The console session is closed.');
    final PterodactylConsoleSocket? socket = _socket;
    if (socket == null) {
      throw StateError('The console session is not connected.');
    }
    await socket.sendText(frame);
  }

  void _emit(PterodactylConsoleEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAuthentication();
    _generation++;
    final StreamSubscription<Object?>? messages = _messages;
    final PterodactylConsoleSocket? socket = _socket;
    _messages = null;
    _socket = null;
    try {
      await messages?.cancel();
    } finally {
      try {
        await socket?.close(WebSocketStatus.normalClosure, 'Detached');
      } finally {
        _finish();
      }
    }
  }

  void _failAuthentication() {
    final Completer<void>? authentication = _authentication;
    if (authentication != null && !authentication.isCompleted) {
      authentication.completeError(
        StateError('Remote console authentication did not complete.'),
      );
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
    if (!_events.isClosed) unawaited(_events.close());
  }

  static String _validateIdentifier(String value) {
    final String result = value.trim();
    if (result.isEmpty ||
        result.length > 128 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(result)) {
      throw const FormatException('Invalid Pterodactyl server identifier.');
    }
    return result;
  }
}

void _requireSecureSocketUri(Uri socketUri) {
  if (socketUri.scheme != 'wss' ||
      socketUri.host.isEmpty ||
      socketUri.userInfo.isNotEmpty ||
      socketUri.hasQuery ||
      socketUri.hasFragment ||
      (socketUri.hasPort && (socketUri.port < 1 || socketUri.port > 65535))) {
    throw const FormatException(
      'Pterodactyl console sockets must use a clean wss URL.',
    );
  }
}
