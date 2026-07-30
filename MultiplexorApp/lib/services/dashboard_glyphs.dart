/// The frame-driven state dot for a server row.
///
/// [frame] is a monotonically increasing repaint tick, so a caller that
/// animates gets movement out of it; a caller drawing a single static badge
/// (the wizard's instance-menu header) passes a fixed frame instead.
library;

import 'runtime_state.dart';

const List<String> _spinFrames = <String>['◐', '◓', '◑', '◒'];

/// State dot for a server row. Stable states are (mostly) static; running
/// pulses gently every eighth frame, transitional states spin.
String animatedStateGlyph(RuntimeState state, int frame) {
  return switch (state) {
    RuntimeState.running => frame % 8 == 0 ? '◉' : '●',
    RuntimeState.starting ||
    RuntimeState.stopping ||
    RuntimeState.restarting => _spinFrames[frame % 4],
    RuntimeState.stopped => '○',
  };
}
