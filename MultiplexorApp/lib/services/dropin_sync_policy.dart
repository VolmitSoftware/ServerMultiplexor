enum DropinSyncDecision { copy, unchanged, preserveLocal }

final class DropinSyncPolicy {
  const DropinSyncPolicy._();

  static DropinSyncDecision decide({
    required String sourceHash,
    required String? targetHash,
    required String? synchronizedHash,
  }) {
    if (targetHash == null) {
      return DropinSyncDecision.copy;
    }
    if (targetHash == sourceHash) {
      return DropinSyncDecision.unchanged;
    }
    if (synchronizedHash == null || targetHash != synchronizedHash) {
      return DropinSyncDecision.preserveLocal;
    }
    return DropinSyncDecision.copy;
  }
}
