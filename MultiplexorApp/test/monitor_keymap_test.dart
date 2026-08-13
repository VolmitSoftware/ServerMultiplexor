import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:test/test.dart';

/// A printable-character event for [char], the shape the parser emits for
/// every ordinary keystroke.
TermEvent typed(String char) => TermEvent(TermEventKind.char, char: char);

void main() {
  group('monitorActionForEvent', () {
    test('maps both ways of moving up to the up action', () {
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.arrowUp)),
        MonitorAction.up,
      );
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.wheelUp)),
        MonitorAction.up,
      );
    });

    test('maps both ways of moving down to the down action', () {
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.arrowDown)),
        MonitorAction.down,
      );
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.wheelDown)),
        MonitorAction.down,
      );
    });

    test('maps enter to open and escape to back', () {
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.enter)),
        MonitorAction.open,
      );
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.escape)),
        MonitorAction.back,
      );
    });

    test('maps tab to the Local and Remote view switch', () {
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.tab)),
        MonitorAction.switchView,
      );
    });

    test('maps the uppercase quick actions to their instance commands', () {
      expect(monitorActionForEvent(typed('R')), MonitorAction.restart);
      expect(monitorActionForEvent(typed('S')), MonitorAction.stop);
      expect(monitorActionForEvent(typed('X')), MonitorAction.kill);
      expect(monitorActionForEvent(typed('O')), MonitorAction.console);
    });

    test('maps the lowercase navigation keys to their screen commands', () {
      expect(monitorActionForEvent(typed('d')), MonitorAction.detail);
      expect(monitorActionForEvent(typed('g')), MonitorAction.consolesGrid);
      expect(monitorActionForEvent(typed('n')), MonitorAction.newInstance);
      expect(monitorActionForEvent(typed('b')), MonitorAction.buildMenu);
      expect(monitorActionForEvent(typed('c')), MonitorAction.switchConsumer);
      expect(monitorActionForEvent(typed('r')), MonitorAction.cycleRange);
      expect(monitorActionForEvent(typed('q')), MonitorAction.quit);
    });

    test('maps w to the workspace card, the keyboard twin of [ MORE ]', () {
      expect(monitorActionForEvent(typed('w')), MonitorAction.workspaceCard);
    });

    test('maps ctrl+c to quit so the loop can exit cleanly in raw mode', () {
      expect(
        monitorActionForEvent(const TermEvent(TermEventKind.ctrlC)),
        MonitorAction.quit,
      );
    });

    test('does not confuse the two cases of a bound letter', () {
      expect(monitorActionForEvent(typed('r')), MonitorAction.cycleRange);
      expect(monitorActionForEvent(typed('D')), MonitorAction.none);
      expect(monitorActionForEvent(typed('G')), MonitorAction.none);
      expect(monitorActionForEvent(typed('N')), MonitorAction.none);
      expect(monitorActionForEvent(typed('B')), MonitorAction.none);
      expect(monitorActionForEvent(typed('C')), MonitorAction.none);
      expect(monitorActionForEvent(typed('Q')), MonitorAction.none);
      expect(monitorActionForEvent(typed('W')), MonitorAction.none);
      expect(monitorActionForEvent(typed('s')), MonitorAction.none);
      expect(monitorActionForEvent(typed('x')), MonitorAction.none);
      expect(monitorActionForEvent(typed('o')), MonitorAction.none);
    });

    test('maps unbound characters to none', () {
      expect(monitorActionForEvent(typed('z')), MonitorAction.none);
      expect(monitorActionForEvent(typed('1')), MonitorAction.none);
      expect(monitorActionForEvent(typed(' ')), MonitorAction.none);
      expect(monitorActionForEvent(typed('')), MonitorAction.none);
    });

    test('maps every unbound event kind to none', () {
      // Derived (not hardcoded) from TermEventKind.values minus the kinds
      // bound above, so a future addition to the enum is automatically
      // covered here instead of silently falling through untested.
      const Set<TermEventKind> bound = <TermEventKind>{
        TermEventKind.arrowUp,
        TermEventKind.wheelUp,
        TermEventKind.arrowDown,
        TermEventKind.wheelDown,
        TermEventKind.enter,
        TermEventKind.escape,
        TermEventKind.ctrlC,
        TermEventKind.tab,
        TermEventKind.char,
      };
      final Iterable<TermEventKind> unbound = TermEventKind.values.where(
        (TermEventKind kind) => !bound.contains(kind),
      );
      for (final TermEventKind kind in unbound) {
        expect(
          monitorActionForEvent(TermEvent(kind)),
          MonitorAction.none,
          reason: '${kind.name} must not be bound',
        );
      }
    });
  });

  group('nextRange', () {
    test('cycles the five ranges back around to the first', () {
      expect(nextRange(const Duration(minutes: 15)), const Duration(hours: 1));
      expect(nextRange(const Duration(hours: 1)), const Duration(hours: 6));
      expect(nextRange(const Duration(hours: 6)), const Duration(hours: 24));
      expect(nextRange(const Duration(hours: 24)), const Duration(days: 7));
      expect(nextRange(const Duration(days: 7)), const Duration(minutes: 15));
    });

    test('falls back to the shortest range for an unlisted duration', () {
      expect(
        nextRange(const Duration(minutes: 7)),
        const Duration(minutes: 15),
      );
      expect(nextRange(Duration.zero), const Duration(minutes: 15));
      expect(nextRange(const Duration(days: 30)), const Duration(minutes: 15));
    });

    test('returns to its starting point after a full cycle', () {
      Duration range = const Duration(minutes: 15);
      for (int step = 0; step < monitorRanges.length; step++) {
        range = nextRange(range);
      }
      expect(range, const Duration(minutes: 15));
    });
  });

  group('monitorBackTarget', () {
    test('unwinds exactly one visible layer per Escape press', () {
      expect(
        monitorBackTarget(modalOpen: true, detailOpen: true),
        MonitorBackTarget.modal,
      );
      expect(
        monitorBackTarget(modalOpen: false, detailOpen: true),
        MonitorBackTarget.detail,
      );
      expect(
        monitorBackTarget(modalOpen: false, detailOpen: false),
        MonitorBackTarget.dashboard,
      );
    });
  });

  group('monitorRanges', () {
    test('lists the five cycled windows in ascending order', () {
      expect(monitorRanges, <Duration>[
        Duration(minutes: 15),
        Duration(hours: 1),
        Duration(hours: 6),
        Duration(hours: 24),
        Duration(days: 7),
      ]);
    });
  });
}
