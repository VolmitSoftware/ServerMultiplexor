enum PterodactylCredentialRole {
  client('client'),
  application('application');

  const PterodactylCredentialRole(this.key);

  final String key;
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
