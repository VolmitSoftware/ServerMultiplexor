/// The monitor dashboard's key bindings and range cycle, kept pure and
/// separate from the event loop so both can be reasoned about (and the
/// bindings tested) without a terminal.
library;

import '../../utils/terminal/term_events.dart';

/// Everything the monitor screen can be asked to do by one input event.
///
/// [MonitorAction.up] and [MonitorAction.down] describe intent, not a
/// keystroke: the screen decides contextually whether a wheel event moves
/// the selection or cycles the chart range, based on where the pointer was.
/// [MonitorAction.refresh] has no binding — an out-of-band refresh is
/// available to callers, but the dashboard already sweeps on its own timer.
enum MonitorAction {
  up,
  down,
  open,
  detail,
  restart,
  stop,
  kill,
  console,
  consolesGrid,
  newInstance,
  buildMenu,
  switchConsumer,
  cycleRange,
  refresh,
  quit,
  back,
  none,
}

/// The chart/history windows `r` cycles through, shortest first.
const List<Duration> monitorRanges = <Duration>[
  Duration(minutes: 15),
  Duration(hours: 1),
  Duration(hours: 6),
  Duration(hours: 24),
];

/// The window after [current] in [monitorRanges], wrapping at the end. A
/// duration that is not one of the cycled windows restarts the cycle at the
/// shortest one rather than being silently kept.
Duration nextRange(Duration current) {
  final int index = monitorRanges.indexOf(current);
  if (index < 0) {
    return monitorRanges.first;
  }
  return monitorRanges[(index + 1) % monitorRanges.length];
}

/// The action [event] is bound to, or [MonitorAction.none] when it is bound
/// to nothing.
///
/// Character bindings are case-sensitive and deliberately so: the uppercase
/// keys (`R`, `S`, `X`, `O`) are the destructive-ish per-instance quick
/// actions carried over from the legacy dashboard, and their lowercase
/// counterparts must never trigger them by a slipped shift key.
MonitorAction monitorActionForEvent(TermEvent event) {
  switch (event.kind) {
    case TermEventKind.arrowUp:
    case TermEventKind.wheelUp:
      return MonitorAction.up;
    case TermEventKind.arrowDown:
    case TermEventKind.wheelDown:
      return MonitorAction.down;
    case TermEventKind.enter:
      return MonitorAction.open;
    case TermEventKind.escape:
      return MonitorAction.back;
    case TermEventKind.ctrlC:
      return MonitorAction.quit;
    case TermEventKind.char:
      return _charAction(event.char);
    case TermEventKind.backspace:
    case TermEventKind.tab:
    case TermEventKind.arrowLeft:
    case TermEventKind.arrowRight:
    case TermEventKind.home:
    case TermEventKind.end:
    case TermEventKind.pageUp:
    case TermEventKind.pageDown:
    case TermEventKind.delete:
    case TermEventKind.mouseDown:
    case TermEventKind.mouseUp:
    case TermEventKind.cursorReport:
    case TermEventKind.unknown:
      return MonitorAction.none;
  }
}

MonitorAction _charAction(String char) => switch (char) {
  'd' => MonitorAction.detail,
  'R' => MonitorAction.restart,
  'S' => MonitorAction.stop,
  'X' => MonitorAction.kill,
  'O' => MonitorAction.console,
  'g' => MonitorAction.consolesGrid,
  'n' => MonitorAction.newInstance,
  'b' => MonitorAction.buildMenu,
  'c' => MonitorAction.switchConsumer,
  'r' => MonitorAction.cycleRange,
  'q' => MonitorAction.quit,
  _ => MonitorAction.none,
};
