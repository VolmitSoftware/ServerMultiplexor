import 'package:multiplexor/services/dropin_sync_policy.dart';
import 'package:test/test.dart';

void main() {
  group('DropinSyncPolicy', () {
    const String sourceA = 'source-a';
    const String sourceB = 'source-b';
    const String local = 'local';

    test('copies when the target is missing', () {
      expect(
        DropinSyncPolicy.decide(
          sourceHash: sourceA,
          targetHash: null,
          synchronizedHash: null,
        ),
        DropinSyncDecision.copy,
      );
    });

    test('leaves a matching target unchanged', () {
      expect(
        DropinSyncPolicy.decide(
          sourceHash: sourceA,
          targetHash: sourceA,
          synchronizedHash: sourceB,
        ),
        DropinSyncDecision.unchanged,
      );
    });

    test('preserves an unknown differing target', () {
      expect(
        DropinSyncPolicy.decide(
          sourceHash: sourceA,
          targetHash: local,
          synchronizedHash: null,
        ),
        DropinSyncDecision.preserveLocal,
      );
    });

    test('updates an untouched previously synchronized target', () {
      expect(
        DropinSyncPolicy.decide(
          sourceHash: sourceB,
          targetHash: sourceA,
          synchronizedHash: sourceA,
        ),
        DropinSyncDecision.copy,
      );
    });

    test('preserves a target changed since the previous sync', () {
      expect(
        DropinSyncPolicy.decide(
          sourceHash: sourceB,
          targetHash: local,
          synchronizedHash: sourceA,
        ),
        DropinSyncDecision.preserveLocal,
      );
    });
  });
}
