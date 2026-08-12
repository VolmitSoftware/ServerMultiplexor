import 'package:path/path.dart' as p;

/// Non-secret connection settings for one Pterodactyl Panel.
///
/// API credentials deliberately do not belong to this model. They are resolved
/// separately through credential stores so profile files remain safe to keep
/// under `.multiplexor`.
final class PterodactylProfile {
  PterodactylProfile({
    required String id,
    required String name,
    required Uri panelUri,
    String? trustedCertificatePath,
  }) : id = normalizeId(id),
       name = _normalizeName(name),
       panelUri = _normalizePanelUri(panelUri),
       trustedCertificatePath = _normalizeCertificatePath(
         trustedCertificatePath,
       );

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static final RegExp _controlCharacterPattern = RegExp(r'[\x00-\x1f\x7f]');

  final String id;
  final String name;
  final Uri panelUri;

  /// Optional absolute PEM bundle used in addition to platform trust roots.
  final String? trustedCertificatePath;

  /// The exact HTTPS origin to which credentials may be sent.
  String get origin => panelUri.origin;

  static String normalizeId(String value) {
    final String normalized = value.trim().toLowerCase();
    if (!_idPattern.hasMatch(normalized)) {
      throw const FormatException(
        'Pterodactyl profile IDs must use 1-64 lowercase letters, digits, '
        'underscores, or hyphens, and must start with a letter or digit.',
      );
    }
    return normalized;
  }

  static bool isValidId(String value) {
    try {
      normalizeId(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static String _normalizeName(String value) {
    final String normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 100 ||
        _controlCharacterPattern.hasMatch(normalized)) {
      throw const FormatException(
        'Pterodactyl profile names must contain 1-100 printable characters.',
      );
    }
    return normalized;
  }

  static Uri _normalizePanelUri(Uri value) {
    if (!value.hasScheme ||
        value.scheme.toLowerCase() != 'https' ||
        value.host.isEmpty) {
      throw const FormatException(
        'Pterodactyl Panel URLs must be absolute HTTPS URLs.',
      );
    }
    if (value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw const FormatException(
        'Pterodactyl Panel URLs must contain only an HTTPS origin.',
      );
    }

    return Uri(
      scheme: 'https',
      host: value.host,
      port: value.hasPort && value.port != 443 ? value.port : null,
    );
  }

  static String? _normalizeCertificatePath(String? value) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty ||
        !p.isAbsolute(normalized) ||
        _controlCharacterPattern.hasMatch(normalized)) {
      throw const FormatException(
        'The trusted certificate path must be an absolute local path.',
      );
    }
    return p.normalize(normalized);
  }

  @override
  bool operator ==(Object other) {
    return other is PterodactylProfile &&
        other.id == id &&
        other.name == name &&
        other.panelUri == panelUri &&
        other.trustedCertificatePath == trustedCertificatePath;
  }

  @override
  int get hashCode => Object.hash(id, name, panelUri, trustedCertificatePath);

  @override
  String toString() => 'PterodactylProfile($id, $origin)';
}
