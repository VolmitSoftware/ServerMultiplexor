/// Frame-driven glyphs for the live dashboard: animated server-state dots
/// and the breathing status blob. The dashboard repaints ~4x/second and
/// passes a monotonically increasing frame counter.
library;

import '../utils/terminal/ansi.dart';
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

/// Breathing blob glyph: contracts to a point once per cycle.
String blobGlyph(int frame) {
  return frame % 4 == 0 ? '∙' : '●';
}

/// Breathing blob style: cyan, peaking bold mid-cycle.
String blobStyle(int frame) {
  return frame % 4 == 2 ? '${Ansi.bold}${Ansi.cyan}' : Ansi.cyan;
}
