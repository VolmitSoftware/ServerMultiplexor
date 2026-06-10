import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

void main() {
  group('classifyRuntimeLogTail', () {
    test('returns starting when no markers are present', () {
      const String log = '''
[12:00:01 INFO]: Environment: Environment[sessionHost=https://...]
[12:00:02 INFO]: Loaded 1290 recipes
[12:00:03 INFO]: Preparing level "world"
''';
      expect(classifyRuntimeLogTail(log), RuntimeState.starting);
    });

    test('returns starting for an empty log', () {
      expect(classifyRuntimeLogTail(''), RuntimeState.starting);
    });

    test('returns running when Done marker is the latest marker', () {
      const String log = '''
[12:00:03 INFO]: Preparing level "world"
[12:00:09 INFO]: Done (6.221s)! For help, type "help"
[12:01:00 INFO]: Player joined the game
''';
      expect(classifyRuntimeLogTail(log), RuntimeState.running);
    });

    test('matches vanilla-style thread-prefixed Done marker', () {
      const String log =
          '[Server thread/INFO]: Done (8.110s)! For help, type "help"';
      expect(classifyRuntimeLogTail(log), RuntimeState.running);
    });

    test('returns stopping when Stopping server follows Done', () {
      const String log = '''
[12:00:09 INFO]: Done (6.221s)! For help, type "help"
[12:30:00 INFO]: Stopping server
''';
      expect(classifyRuntimeLogTail(log), RuntimeState.stopping);
    });

    test('returns stopping when restart shutdown follows Done', () {
      const String log = '''
[12:00:09 INFO]: Done (6.221s)! For help, type "help"
[12:30:00 INFO]: Attempting to restart with ./multiplexor-restart.sh
''';
      expect(classifyRuntimeLogTail(log), RuntimeState.stopping);
    });

    test('returns running again after a restart completes in same tail', () {
      const String log = '''
[12:30:00 INFO]: Stopping server
[12:31:09 INFO]: Done (5.004s)! For help, type "help"
''';
      expect(classifyRuntimeLogTail(log), RuntimeState.running);
    });

    test('does not treat chat text containing done as the ready marker', () {
      const String log = '[12:00:05 INFO]: <player> are we done (yet)?';
      expect(classifyRuntimeLogTail(log), RuntimeState.starting);
    });
  });

  group('runtimeRestartMarkerFresh', () {
    final DateTime now = DateTime(2026, 6, 9, 12, 0, 0);

    test('returns true when marker is recent', () {
      expect(
        runtimeRestartMarkerFresh(
          now.subtract(const Duration(seconds: 30)),
          now,
        ),
        isTrue,
      );
    });

    test('returns true at exactly the ttl boundary', () {
      expect(
        runtimeRestartMarkerFresh(now.subtract(runtimeRestartMarkerTtl), now),
        isTrue,
      );
    });

    test('returns false when marker is older than the ttl', () {
      expect(
        runtimeRestartMarkerFresh(
          now.subtract(runtimeRestartMarkerTtl + const Duration(seconds: 1)),
          now,
        ),
        isFalse,
      );
    });

    test('tolerates small clock skew into the future', () {
      expect(
        runtimeRestartMarkerFresh(now.add(const Duration(seconds: 5)), now),
        isTrue,
      );
    });

    test('rejects large clock skew into the future', () {
      expect(
        runtimeRestartMarkerFresh(now.add(const Duration(minutes: 5)), now),
        isFalse,
      );
    });
  });
}
