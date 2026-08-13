import 'dart:io';

/// Base exception for failures while communicating with a Pterodactyl panel.
sealed class PterodactylException implements Exception {
  const PterodactylException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The client was configured with an invalid or unsafe endpoint.
final class PterodactylConfigurationException extends PterodactylException {
  const PterodactylConfigurationException(super.message);
}

/// The panel could not be reached before the request completed.
final class PterodactylConnectionException extends PterodactylException {
  const PterodactylConnectionException(super.message, {this.cause});

  final Object? cause;
}

/// The panel returned a non-successful HTTP response.
///
/// Only Pterodactyl's structured error summaries are retained. Raw response
/// bodies are intentionally discarded because they can contain sensitive
/// configuration values or third-party proxy output.
final class PterodactylApiException extends PterodactylException {
  const PterodactylApiException({
    required this.statusCode,
    required this.method,
    required this.uri,
    required String message,
    this.errorCode,
  }) : super(message);

  final int statusCode;
  final String method;
  final Uri uri;
  final String? errorCode;

  bool get isUnauthorized =>
      statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden;

  bool get isRateLimited => statusCode == HttpStatus.tooManyRequests;
}

/// A successful response did not match Pterodactyl's documented JSON shape.
final class PterodactylProtocolException extends PterodactylException {
  const PterodactylProtocolException(super.message);
}

/// An Application key cannot read one resource required to build the
/// zero-server creation catalog.
final class PterodactylCreationCatalogPermissionException
    extends PterodactylException {
  const PterodactylCreationCatalogPermissionException({
    required this.permission,
  }) : super(
         'Creation catalog requires Application API $permission permission.',
       );

  final String permission;
}
