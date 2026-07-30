import 'package:multiplexor/services/dashboard_glyphs.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

void main() {
  group('animatedStateGlyph', () {
    test('stopped is a static hollow dot on every frame', () {
      for (int frame = 0; frame < 12; frame++) {
        expect(animatedStateGlyph(RuntimeState.stopped, frame), '○');
      }
    });

    test('running is a solid dot with a pulse every eighth frame', () {
      expect(animatedStateGlyph(RuntimeState.running, 0), '◉');
      expect(animatedStateGlyph(RuntimeState.running, 1), '●');
      expect(animatedStateGlyph(RuntimeState.running, 7), '●');
      expect(animatedStateGlyph(RuntimeState.running, 8), '◉');
    });

    test('transitional states rotate through quarter circles', () {
      const List<String> spin = <String>['◐', '◓', '◑', '◒'];
      for (final RuntimeState state in <RuntimeState>[
        RuntimeState.starting,
        RuntimeState.stopping,
        RuntimeState.restarting,
      ]) {
        for (int frame = 0; frame < 8; frame++) {
          expect(animatedStateGlyph(state, frame), spin[frame % 4]);
        }
      }
    });

    test('frame zero matches the legacy static glyphs for stable states', () {
      expect(animatedStateGlyph(RuntimeState.stopped, 1), '○');
      expect(animatedStateGlyph(RuntimeState.running, 1), '●');
    });
  });
}
