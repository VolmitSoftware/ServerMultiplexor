enum PterodactylCredentialRole {
  client('client'),
  application('application');

  const PterodactylCredentialRole(this.key);

  final String key;
}

/// Infers the standard Pterodactyl role prefix without rejecting keys from
/// older Panels or compatible forks. Unknown prefixes return null so an
/// interactive account flow can ask rather than guess.
PterodactylCredentialRole? inferPterodactylCredentialRole(String value) {
  final String normalized = value.trim().toLowerCase();
  if (normalized.startsWith('ptlc_')) {
    return PterodactylCredentialRole.client;
  }
  if (normalized.startsWith('ptla_')) {
    return PterodactylCredentialRole.application;
  }
  return null;
}

/// An API bearer value whose diagnostics are always redacted.
final class PterodactylCredential {
  PterodactylCredential(String value) : value = _validate(value);

  static final RegExp _unsafe = RegExp(r'[\s\x00-\x1f\x7f]');

  final String value;

  static String _validate(String value) {
    if (value.isEmpty || value.length > 8192 || _unsafe.hasMatch(value)) {
      throw const FormatException('Invalid Pterodactyl API credential.');
    }
    return value;
  }

  @override
  String toString() => 'PterodactylCredential([REDACTED])';
}
