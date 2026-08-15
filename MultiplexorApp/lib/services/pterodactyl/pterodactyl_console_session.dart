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
    Duration reconnectInitialDelay = const Duration(milliseconds: 250),
    Duration reconnectMaximumDelay = const Duration(seconds: 5),
  }) : serverIdentifier = _validateIdentifier(serverIdentifier),
       _loadCredentials = loadCredentials,
       _connector = connector,
       _reconnectInitialDelay = _validateReconnectDelay(
         reconnectInitialDelay,
         'reconnectInitialDelay',
       ),
       _reconnectMaximumDelay = _validateReconnectDelay(
         reconnectMaximumDelay,
         'reconnectMaximumDelay',
       ) {
    if (_reconnectMaximumDelay < _reconnectInitialDelay) {
      throw ArgumentError.value(
        reconnectMaximumDelay,
        'reconnectMaximumDelay',
        'must be at least reconnectInitialDelay',
      );
    }
  }

  final PterodactylProfile profile;
  final String serverIdentifier;
  final PterodactylConsoleCredentialLoader _loadCredentials;
  final PterodactylConsoleSocketConnector _connector;
  final Duration _reconnectInitialDelay;
  final Duration _reconnectMaximumDelay;
  final StreamController<PterodactylConsoleEvent> _events =
      StreamController<PterodactylConsoleEvent>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();

  PterodactylConsoleSocket? _socket;
  Uri? _socketUri;
  Future<void>? _refreshing;
  Future<void>? _reconnecting;
  Timer? _reconnectTimer;
  Completer<void>? _reconnectDelay;
  Completer<void>? _authentication;
  int _generation = 0;
  bool _started = false;
  bool _closed = false;
  bool _hasConnected = false;
  bool _authenticated = false;

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
  Future<void> requestLogs() => _send(
    PterodactylConsoleFrames.requestLogs(),
    requireAuthenticated: true,
    recoverTransportFailure: true,
  );

  @override
  Future<void> requestStats() => _send(
    PterodactylConsoleFrames.requestStats(),
    requireAuthenticated: true,
    recoverTransportFailure: true,
  );

  @override
  Future<void> sendCommand(String command) => _send(
    PterodactylConsoleFrames.sendCommand(command),
    requireAuthenticated: true,
    recoverTransportFailure: true,
  );

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
    _authenticated = false;
    _authentication = Completer<void>();
    _socket = next;
    _socketUri = credentials.socketUri;
    next.messages.listen(
      (Object? message) => _handleMessage(generation, message),
      onError: (Object _) => _handleSocketError(generation, next),
      onDone: () => _handleSocketDone(generation, next),
      cancelOnError: false,
    );
    try {
      await _send(PterodactylConsoleFrames.authenticate(credentials.token));
    } catch (_) {
      if (generation == _generation) {
        _generation++;
        _socket = null;
      }
      unawaited(
        _closeSocket(next, WebSocketStatus.goingAway, 'Authentication failed'),
      );
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
        _hasConnected = true;
        _authenticated = true;
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
        _refreshAuthentication();
      case PterodactylConsoleTokenExpired():
        _refreshAuthentication();
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
        const PterodactylConsoleProtocolWarning(
          'Unable to request remote console history and statistics.',
        ),
      );
    }
  }

  void _refreshAuthentication() {
    // A reconnect already fetched a fresh one-use token. Ignore lifecycle
    // notifications delivered during that authentication handshake so token
    // refresh and transport recovery can never install competing sockets.
    if (_reconnecting != null) return;
    final Future<void>? current = _refreshing;
    if (current != null) {
      return;
    }
    _emit(
      const PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.refreshing,
      ),
    );
    _authenticated = false;
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
            if (_closed || !_hasConnected) {
              await close();
              return;
            }
            _retireActiveSocket('Authentication refresh failed');
            _startReconnect();
          })
          .whenComplete(() {
            if (identical(_refreshing, operation)) _refreshing = null;
            if (!_closed && _hasConnected && _socket == null) {
              _startReconnect();
            }
          }),
    );
  }

  Future<void> _performRefresh() async {
    final PterodactylWebsocketCredentials credentials = await _loadCredentials(
      serverIdentifier,
    );
    final PterodactylConsoleSocket? previous = _socket;
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
        if (previous != null) {
          unawaited(
            _closeSocket(
              previous,
              WebSocketStatus.goingAway,
              'Endpoint refreshed',
            ),
          );
        }
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

  void _handleSocketError(int generation, PterodactylConsoleSocket socket) {
    if (_closed || generation != _generation) return;
    _handleSocketLoss(
      generation,
      socket,
      message: 'The remote console socket reported an error.',
      closeSocket: true,
    );
  }

  void _handleSocketDone(int generation, PterodactylConsoleSocket socket) {
    if (_closed || generation != _generation) return;
    final String? reason = socket.closeReason;
    _handleSocketLoss(
      generation,
      socket,
      message: reason == null || reason.isEmpty
          ? 'Remote console disconnected.'
          : PterodactylConsoleSanitizer.text(reason),
      closeSocket: false,
    );
  }

  void _handleSocketLoss(
    int generation,
    PterodactylConsoleSocket socket, {
    required String message,
    required bool closeSocket,
  }) {
    if (_closed || generation != _generation) return;
    _generation++;
    _socket = null;
    _authenticated = false;
    _emit(
      PterodactylConsoleConnectionEvent(
        PterodactylConsoleConnectionState.disconnected,
        message: message,
      ),
    );
    _failAuthentication();
    if (closeSocket) {
      unawaited(
        _closeSocket(socket, WebSocketStatus.goingAway, 'Transport error'),
      );
    }
    if (_hasConnected && _refreshing == null) {
      _startReconnect();
    } else if (!_hasConnected) {
      _finish();
    }
  }

  void _startReconnect() {
    if (_closed || !_hasConnected || _reconnecting != null) return;
    final Future<void> operation = _reconnect();
    _reconnecting = operation;
    unawaited(_completeReconnect(operation));
  }

  Future<void> _completeReconnect(Future<void> operation) async {
    try {
      await operation;
    } finally {
      if (identical(_reconnecting, operation)) {
        _reconnecting = null;
      }
      // A replacement can authenticate and close again before its reconnect
      // operation has unwound. Re-check after releasing the single-flight
      // guard so that narrow race cannot leave a dead console session behind.
      if (!_closed && _hasConnected && _socket == null) {
        _startReconnect();
      }
    }
  }

  Future<void> _reconnect() async {
    Duration delay = _reconnectInitialDelay;
    while (!_closed && _socket == null) {
      _emit(
        const PterodactylConsoleConnectionEvent(
          PterodactylConsoleConnectionState.reconnecting,
          message: 'Reconnecting remote console.',
        ),
      );
      if (!await _waitForReconnectDelay(delay) || _socket != null) return;
      try {
        final PterodactylWebsocketCredentials credentials =
            await _loadCredentials(serverIdentifier);
        if (_closed || _socket != null) return;
        await _open(credentials);
        await _waitForAuthentication();
        return;
      } catch (_) {
        if (_closed) return;
        _retireActiveSocket('Reconnect attempt failed');
        delay = _nextReconnectDelay(delay);
      }
    }
  }

  Future<bool> _waitForReconnectDelay(Duration delay) async {
    if (_closed) return false;
    final Completer<void> wakeup = Completer<void>();
    _reconnectDelay = wakeup;
    _reconnectTimer = Timer(delay, wakeup.complete);
    await wakeup.future;
    if (identical(_reconnectDelay, wakeup)) {
      _reconnectDelay = null;
      _reconnectTimer = null;
    }
    return !_closed;
  }

  void _cancelReconnectDelay() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final Completer<void>? wakeup = _reconnectDelay;
    _reconnectDelay = null;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
  }

  Duration _nextReconnectDelay(Duration current) {
    final int currentMilliseconds = current.inMilliseconds;
    final int maximumMilliseconds = _reconnectMaximumDelay.inMilliseconds;
    if (currentMilliseconds >= maximumMilliseconds) {
      return _reconnectMaximumDelay;
    }
    final int doubled = currentMilliseconds * 2;
    return Duration(
      milliseconds: doubled > maximumMilliseconds
          ? maximumMilliseconds
          : doubled,
    );
  }

  void _retireActiveSocket(String reason) {
    final PterodactylConsoleSocket? socket = _socket;
    if (socket == null) return;
    _generation++;
    _socket = null;
    _authenticated = false;
    _failAuthentication();
    unawaited(_closeSocket(socket, WebSocketStatus.goingAway, reason));
  }

  Future<void> _closeSocket(
    PterodactylConsoleSocket socket,
    int code,
    String reason,
  ) async {
    try {
      await socket.close(code, reason);
    } catch (_) {
      // The socket is already unusable. Generation checks keep any late
      // callbacks inert, so cleanup failure must not stop reconnect/teardown.
    }
  }

  Future<void> _send(
    String frame, {
    bool requireAuthenticated = false,
    bool recoverTransportFailure = false,
  }) async {
    if (_closed) throw StateError('The console session is closed.');
    final PterodactylConsoleSocket? socket = _socket;
    if (socket == null || (requireAuthenticated && !_authenticated)) {
      throw StateError('The console session is not connected.');
    }
    final int generation = _generation;
    try {
      await socket.sendText(frame);
    } catch (_) {
      if (recoverTransportFailure &&
          !_closed &&
          generation == _generation &&
          identical(socket, _socket)) {
        _handleSocketLoss(
          generation,
          socket,
          message: 'The remote console transport rejected an outbound frame.',
          closeSocket: true,
        );
      }
      rethrow;
    }
  }

  void _emit(PterodactylConsoleEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelReconnectDelay();
    _failAuthentication();
    _generation++;
    _authenticated = false;
    final PterodactylConsoleSocket? socket = _socket;
    _socket = null;
    try {
      // WebSocket.close owns its underlying receive subscription. Cancelling
      // the public stream listener first also cancels dart:io's native socket
      // read, then close() races a second shutdown against that closed secure
      // socket (observed as `_RawSecureSocket.read: Reading from a closed
      // socket`). Let the WebSocket perform the close handshake and finish its
      // receive side itself; [_closed]/generation already make late callbacks
      // inert.
      await socket?.close(WebSocketStatus.normalClosure, 'Detached');
    } finally {
      _finish();
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

  static Duration _validateReconnectDelay(Duration value, String name) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(value, name, 'must be greater than zero');
    }
    return value;
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
