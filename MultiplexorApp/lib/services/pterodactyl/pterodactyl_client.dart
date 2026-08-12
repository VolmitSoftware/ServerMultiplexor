import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pterodactyl_errors.dart';
import 'pterodactyl_models.dart';

final class PterodactylTransportRequest {
  const PterodactylTransportRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

final class PterodactylTransportResponse {
  const PterodactylTransportResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

abstract interface class PterodactylTransport {
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  );

  void close();
}

/// A strict-TLS transport. Redirects are never followed and certificate
/// verification is never disabled.
final class DartIoPterodactylTransport implements PterodactylTransport {
  DartIoPterodactylTransport({
    String? trustedCertificatePath,
    this.timeout = const Duration(seconds: 15),
    this.maximumResponseBytes = 8 * 1024 * 1024,
    HttpClient Function(SecurityContext context)? clientFactory,
  }) : _client = _createClient(trustedCertificatePath, clientFactory);

  final HttpClient _client;
  final Duration timeout;
  final int maximumResponseBytes;

  static HttpClient _createClient(
    String? trustedCertificatePath,
    HttpClient Function(SecurityContext context)? clientFactory,
  ) {
    final SecurityContext context = SecurityContext(withTrustedRoots: true);
    if (trustedCertificatePath != null) {
      context.setTrustedCertificates(trustedCertificatePath);
    }
    return clientFactory?.call(context) ?? HttpClient(context: context);
  }

  @override
  Future<PterodactylTransportResponse> send(
    PterodactylTransportRequest request,
  ) async {
    try {
      final HttpClientRequest outgoing = await _client
          .openUrl(request.method, request.uri)
          .timeout(timeout);
      outgoing.followRedirects = false;
      outgoing.maxRedirects = 0;
      request.headers.forEach(outgoing.headers.set);
      final String? body = request.body;
      if (body != null) {
        outgoing.add(utf8.encode(body));
      }
      final HttpClientResponse incoming = await outgoing.close().timeout(
        timeout,
      );
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in incoming.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > maximumResponseBytes) {
          throw const PterodactylProtocolException(
            'Panel response exceeded the permitted size.',
          );
        }
      }
      return PterodactylTransportResponse(
        statusCode: incoming.statusCode,
        body: utf8.decode(bytes.takeBytes(), allowMalformed: true),
      );
    } on PterodactylException {
      rethrow;
    } on TimeoutException catch (error) {
      throw PterodactylConnectionException(
        'The panel request timed out.',
        cause: error,
      );
    } on IOException catch (error) {
      throw PterodactylConnectionException(
        'The panel connection failed.',
        cause: error,
      );
    }
  }

  @override
  void close() => _client.close(force: true);
}

enum PterodactylClientServerScope {
  accessible,
  adminAll;

  String? get queryValue => this == adminAll ? 'admin-all' : null;
}

final class PterodactylClient {
  PterodactylClient({
    required Uri baseUri,
    String? clientKey,
    String? applicationKey,
    String? trustedCertificatePath,
    PterodactylTransport? transport,
    Duration timeout = const Duration(seconds: 15),
  }) : baseUri = _validateBaseUri(baseUri),
       _clientKey = _cleanKey(clientKey),
       _applicationKey = _cleanKey(applicationKey),
       _transport =
           transport ??
           DartIoPterodactylTransport(
             trustedCertificatePath: trustedCertificatePath,
             timeout: timeout,
           ),
       _ownsTransport = transport == null {
    if (_clientKey == null && _applicationKey == null) {
      throw const PterodactylConfigurationException(
        'At least one Pterodactyl API key is required.',
      );
    }
  }

  final Uri baseUri;
  final String? _clientKey;
  final String? _applicationKey;
  final PterodactylTransport _transport;
  final bool _ownsTransport;

  Future<PterodactylPage<PterodactylClientServer>> listClientServers({
    int page = 1,
    int perPage = 100,
    PterodactylClientServerScope scope =
        PterodactylClientServerScope.accessible,
  }) async {
    final Map<String, String> query = _pageQuery(page, perPage);
    final String? type = scope.queryValue;
    if (type != null) query['type'] = type;
    return _getPage<PterodactylClientServer>(
      'api/client',
      key: _requireClientKey(),
      query: query,
      parser: PterodactylClientServer.fromJson,
    );
  }

  Future<List<PterodactylClientServer>> listAllClientServers({
    PterodactylClientServerScope scope =
        PterodactylClientServerScope.accessible,
  }) => _collectPages<PterodactylClientServer>(
    (int page) => listClientServers(page: page, scope: scope),
  );

  Future<PterodactylClientServer> getClientServer(String identifier) =>
      _getItem<PterodactylClientServer>(
        'api/client/servers/${_segment(identifier, 'identifier')}',
        key: _requireClientKey(),
        parser: PterodactylClientServer.fromJson,
      );

  Future<PterodactylResourceUsage> getServerResources(String identifier) =>
      _getItem<PterodactylResourceUsage>(
        'api/client/servers/${_segment(identifier, 'identifier')}/resources',
        key: _requireClientKey(),
        parser: PterodactylResourceUsage.fromJson,
      );

  Future<PterodactylWebsocketCredentials> getServerWebsocketCredentials(
    String identifier,
  ) async {
    final String path =
        'api/client/servers/${_segment(identifier, 'identifier')}/websocket';
    final PterodactylTransportResponse response = await _request(
      'GET',
      path,
      key: _requireClientKey(),
    );
    try {
      final Object? data = _decodeObject(response.body)['data'];
      if (data is! Map<Object?, Object?>) {
        throw const FormatException();
      }
      return PterodactylWebsocketCredentials.fromJson(_asJsonObject(data));
    } on FormatException {
      throw PterodactylProtocolException(
        'Unexpected response shape for GET /$path.',
      );
    }
  }

  Future<List<PterodactylAllocation>> listServerAllocations(
    String identifier,
  ) async => (await _getPage<PterodactylAllocation>(
    'api/client/servers/${_segment(identifier, 'identifier')}/network/allocations',
    key: _requireClientKey(),
    query: const <String, String>{},
    parser: PterodactylAllocation.fromClientJson,
    paginationOptional: true,
  )).items;

  Future<void> sendPowerSignal(
    String identifier,
    PterodactylPowerSignal signal,
  ) => _sendNoContent(
    'POST',
    'api/client/servers/${_segment(identifier, 'identifier')}/power',
    key: _requireClientKey(),
    body: <String, Object?>{'signal': signal.wireValue},
  );

  Future<void> sendConsoleCommand(String identifier, String command) {
    if (command.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    return _sendNoContent(
      'POST',
      'api/client/servers/${_segment(identifier, 'identifier')}/command',
      key: _requireClientKey(),
      body: <String, Object?>{'command': command},
    );
  }

  Future<PterodactylPage<PterodactylApplicationServer>> listApplicationServers({
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylApplicationServer>(
    'api/application/servers',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylApplicationServer.fromJson,
  );

  Future<List<PterodactylApplicationServer>> listAllApplicationServers() =>
      _collectPages<PterodactylApplicationServer>(
        (int page) => listApplicationServers(page: page),
      );

  Future<PterodactylApplicationServer> getApplicationServer(int id) =>
      _getItem<PterodactylApplicationServer>(
        'api/application/servers/${_positiveId(id)}',
        key: _requireApplicationKey(),
        parser: PterodactylApplicationServer.fromJson,
      );

  Future<PterodactylApplicationServer> createApplicationServer(
    PterodactylCreateServerRequest request,
  ) => _sendItem<PterodactylApplicationServer>(
    'POST',
    'api/application/servers',
    key: _requireApplicationKey(),
    body: request.toJson(),
    parser: PterodactylApplicationServer.fromJson,
  );

  Future<PterodactylPage<PterodactylNode>> listApplicationNodes({
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylNode>(
    'api/application/nodes',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylNode.fromJson,
  );

  Future<List<PterodactylNode>> listAllApplicationNodes() =>
      _collectPages<PterodactylNode>(
        (int page) => listApplicationNodes(page: page),
      );

  Future<PterodactylPage<PterodactylAllocation>> listNodeAllocations(
    int nodeId, {
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylAllocation>(
    'api/application/nodes/${_positiveId(nodeId)}/allocations',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylAllocation.fromApplicationJson,
  );

  Future<List<PterodactylAllocation>> listAllNodeAllocations(int nodeId) =>
      _collectPages<PterodactylAllocation>(
        (int page) => listNodeAllocations(nodeId, page: page),
      );

  Future<PterodactylPage<PterodactylUser>> listApplicationUsers({
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylUser>(
    'api/application/users',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylUser.fromJson,
  );

  Future<List<PterodactylUser>> listAllApplicationUsers() =>
      _collectPages<PterodactylUser>(
        (int page) => listApplicationUsers(page: page),
      );

  Future<PterodactylPage<PterodactylNest>> listApplicationNests({
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylNest>(
    'api/application/nests',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylNest.fromJson,
  );

  Future<List<PterodactylNest>> listAllApplicationNests() =>
      _collectPages<PterodactylNest>(
        (int page) => listApplicationNests(page: page),
      );

  Future<PterodactylPage<PterodactylEgg>> listNestEggs(
    int nestId, {
    int page = 1,
    int perPage = 100,
  }) => _getPage<PterodactylEgg>(
    'api/application/nests/${_positiveId(nestId)}/eggs',
    key: _requireApplicationKey(),
    query: _pageQuery(page, perPage),
    parser: PterodactylEgg.fromJson,
  );

  void close() {
    if (_ownsTransport) _transport.close();
  }

  Future<PterodactylPage<T>> _getPage<T>(
    String path, {
    required String key,
    required Map<String, String> query,
    required T Function(JsonObject) parser,
    bool paginationOptional = false,
  }) async {
    final PterodactylTransportResponse response = await _request(
      'GET',
      path,
      key: key,
      query: query,
    );
    return _parsePage<T>(response.body, parser, paginationOptional);
  }

  Future<T> _getItem<T>(
    String path, {
    required String key,
    required T Function(JsonObject) parser,
  }) => _sendItem<T>('GET', path, key: key, parser: parser);

  Future<T> _sendItem<T>(
    String method,
    String path, {
    required String key,
    required T Function(JsonObject) parser,
    JsonObject? body,
  }) async {
    final PterodactylTransportResponse response = await _request(
      method,
      path,
      key: key,
      body: body,
    );
    try {
      return parser(_resourceAttributes(_decodeObject(response.body)));
    } on FormatException {
      throw PterodactylProtocolException(
        'Unexpected response shape for $method /$path.',
      );
    }
  }

  Future<void> _sendNoContent(
    String method,
    String path, {
    required String key,
    required JsonObject body,
  }) async {
    await _request(method, path, key: key, body: body);
  }

  Future<PterodactylTransportResponse> _request(
    String method,
    String path, {
    required String key,
    Map<String, String> query = const <String, String>{},
    JsonObject? body,
  }) async {
    final Uri uri = baseUri
        .resolve(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final PterodactylTransportResponse response = await _transport.send(
      PterodactylTransportRequest(
        method: method,
        uri: uri,
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $key',
          HttpHeaders.acceptHeader: 'application/json',
          if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PterodactylApiException(
        statusCode: response.statusCode,
        method: method,
        uri: uri,
        message: 'Pterodactyl request failed with HTTP ${response.statusCode}.',
        errorCode: _safeErrorCode(response.body),
      );
    }
    return response;
  }

  PterodactylPage<T> _parsePage<T>(
    String body,
    T Function(JsonObject) parser,
    bool paginationOptional,
  ) {
    try {
      final JsonObject root = _decodeObject(body);
      final Object? data = root['data'];
      if (data is! List<Object?>) throw const FormatException();
      final List<T> items = data
          .map<T>((Object? value) {
            if (value is! Map<Object?, Object?>) throw const FormatException();
            return parser(_resourceAttributes(_asJsonObject(value)));
          })
          .toList(growable: false);
      final Object? pagination = _objectAt(root, 'meta', 'pagination');
      if (pagination == null && paginationOptional) {
        return PterodactylPage<T>(
          items: items,
          pagination: PterodactylPagination(
            total: items.length,
            count: items.length,
            perPage: items.length,
            currentPage: 1,
            totalPages: 1,
          ),
        );
      }
      if (pagination is! Map<Object?, Object?>) throw const FormatException();
      final JsonObject page = _asJsonObject(pagination);
      return PterodactylPage<T>(
        items: items,
        pagination: PterodactylPagination(
          total: _number(page, 'total'),
          count: _number(page, 'count'),
          perPage: _number(page, 'per_page'),
          currentPage: _number(page, 'current_page'),
          totalPages: _number(page, 'total_pages'),
        ),
      );
    } on FormatException {
      throw const PterodactylProtocolException(
        'Unexpected collection response shape from the panel.',
      );
    }
  }

  Future<List<T>> _collectPages<T>(
    Future<PterodactylPage<T>> Function(int page) loader,
  ) async {
    final List<T> result = <T>[];
    int pageNumber = 1;
    while (true) {
      final PterodactylPage<T> page = await loader(pageNumber);
      if (page.pagination.currentPage != pageNumber) {
        throw const PterodactylProtocolException(
          'Panel pagination did not advance as requested.',
        );
      }
      result.addAll(page.items);
      if (!page.pagination.hasNextPage) return List<T>.unmodifiable(result);
      pageNumber++;
    }
  }

  String _requireClientKey() =>
      _clientKey ??
      (throw const PterodactylConfigurationException(
        'A Client API key is required for this operation.',
      ));

  String _requireApplicationKey() =>
      _applicationKey ??
      (throw const PterodactylConfigurationException(
        'An Application API key is required for this operation.',
      ));

  static Uri _validateBaseUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const PterodactylConfigurationException(
        'Panel URL must be an HTTPS origin without credentials, query, or fragment.',
      );
    }
    final String path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }

  static String? _cleanKey(String? value) {
    final String? key = value?.trim();
    return key == null || key.isEmpty ? null : key;
  }
}

Map<String, String> _pageQuery(int page, int perPage) {
  if (page < 1) throw RangeError.range(page, 1, null, 'page');
  if (perPage < 1 || perPage > 100) {
    throw RangeError.range(perPage, 1, 100, 'perPage');
  }
  return <String, String>{'page': '$page', 'per_page': '$perPage'};
}

int _positiveId(int id) {
  if (id < 1) throw RangeError.range(id, 1, null, 'id');
  return id;
}

String _segment(String value, String name) {
  final String cleaned = value.trim();
  if (cleaned.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return Uri.encodeComponent(cleaned);
}

JsonObject _decodeObject(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const FormatException();
  }
  if (decoded is! Map<Object?, Object?>) {
    throw const FormatException();
  }
  return _asJsonObject(decoded);
}

JsonObject _asJsonObject(Map<Object?, Object?> value) =>
    value.map<String, Object?>(
      (Object? key, Object? item) =>
          MapEntry<String, Object?>(key is String ? key : key.toString(), item),
    );

JsonObject _resourceAttributes(JsonObject resource) {
  final Object? attributes = resource['attributes'];
  if (attributes is! Map<Object?, Object?>) throw const FormatException();
  final JsonObject result = _asJsonObject(attributes);
  final Object? relationships = resource['relationships'];
  if (relationships != null) result['relationships'] = relationships;
  return result;
}

Object? _objectAt(JsonObject root, String first, String second) {
  final Object? value = root[first];
  return value is Map<Object?, Object?> ? value[second] : null;
}

int _number(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is! num) throw const FormatException();
  return value.toInt();
}

String? _safeErrorCode(String body) {
  try {
    final JsonObject root = _decodeObject(body);
    final Object? errors = root['errors'];
    if (errors is! List<Object?> || errors.isEmpty) return null;
    final Object? first = errors.first;
    if (first is! Map<Object?, Object?>) return null;
    final Object? code = first['code'];
    if (code is! String || code.length > 80) return null;
    return RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(code) ? code : null;
  } on FormatException {
    return null;
  }
}
