import 'package:multiplexor/utils/prompt/menu.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:test/test.dart';

List<MenuEntry<String>> dashboardEntries() => <MenuEntry<String>>[
  const MenuEntry<String>.separator('servers'),
  const MenuEntry<String>(
    'leaf-26.2',
    value: 'leaf',
    badge: '◐ starting',
    badgeColor: Ansi.yellow,
    detail: ':25565  active',
  ),
  const MenuEntry<String>.separator('actions'),
  const MenuEntry<String>(
    'Create many',
    value: 'many',
    shortcut: 'm',
    detail: 'one server per type, all at once',
  ),
  const MenuEntry<String>(
    'Wipe everything',
    value: 'wipe',
    labelColor: Ansi.red,
    detail: 'delete all instances across all consumers',
  ),
];

const String dashHint =
    '↑↓ move · enter open · R restart · S stop · X kill · O console · esc back';
const String dashFooter =
    'builds  paper 4d · purpur 4d · folia 4d · canvas 4d · leaf 4d · '
    'spigot 28d  ·  auto-refresh after 24h';

void main() {
  group('clampFrameTop', () {
    test('leaves a frame that fits where it is', () {
      expect(
        clampFrameTop(desiredTop: 5, frameHeight: 16, terminalLines: 27),
        5,
      );
    });

    test('lifts a frame that would run past the last row', () {
      expect(
        clampFrameTop(desiredTop: 20, frameHeight: 16, terminalLines: 27),
        12,
      );
    });

    test('pins a frame taller than the screen to the first row', () {
      expect(
        clampFrameTop(desiredTop: 4, frameHeight: 30, terminalLines: 27),
        1,
      );
    });

    test('never returns a row above the screen', () {
      expect(
        clampFrameTop(desiredTop: -3, frameHeight: 4, terminalLines: 27),
        1,
      );
    });

    test('tolerates a terminal that reports no height', () {
      expect(clampFrameTop(desiredTop: 3, frameHeight: 4, terminalLines: 0), 1);
    });
  });

  group('staleBandTop', () {
    test('erases nothing while the frame stays put', () {
      expect(
        staleBandTop(
          top: 12,
          previousTop: 12,
          frameHeight: 16,
          displaced: false,
          cursorAtBottom: true,
        ),
        12,
      );
    });

    test('erases the rows a pushed-down frame vacated', () {
      expect(
        staleBandTop(
          top: 14,
          previousTop: 12,
          frameHeight: 16,
          displaced: true,
          cursorAtBottom: false,
        ),
        12,
      );
    });

    test('erases a frame height above a frame the terminal scrolled', () {
      expect(
        staleBandTop(
          top: 20,
          previousTop: 20,
          frameHeight: 6,
          displaced: true,
          cursorAtBottom: true,
        ),
        14,
      );
    });

    test('never erases above the first row', () {
      expect(
        staleBandTop(
          top: 12,
          previousTop: 12,
          frameHeight: 16,
          displaced: true,
          cursorAtBottom: true,
        ),
        1,
      );
    });

    test('erases nothing before the first repaint', () {
      expect(
        staleBandTop(
          top: 5,
          previousTop: null,
          frameHeight: 16,
          displaced: false,
          cursorAtBottom: false,
        ),
        5,
      );
    });
  });

  group('staleBandBottom', () {
    test('erases nothing below a frame that stayed put', () {
      expect(
        staleBandBottom(
          top: 12,
          previousTop: 12,
          frameHeight: 16,
          terminalLines: 27,
          displaced: true,
        ),
        27,
      );
    });

    test('erases the tail a frame moved up left behind', () {
      expect(
        staleBandBottom(
          top: 4,
          previousTop: 6,
          frameHeight: 8,
          terminalLines: 27,
          displaced: true,
        ),
        13,
      );
    });

    test('never erases past the last row', () {
      expect(
        staleBandBottom(
          top: 4,
          previousTop: 6,
          frameHeight: 8,
          terminalLines: 10,
          displaced: true,
        ),
        10,
      );
    });
  });

  group('renderMenuRows', () {
    test('emits one row per entry, then the hint and the footer', () {
      final List<MenuEntry<String>> entries = dashboardEntries();
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 1,
        hint: dashHint,
        footer: dashFooter,
        columns: 104,
      );
      expect(rows, hasLength(entries.length + 2));
      expect(Ansi.strip(rows[rows.length - 2]), contains('enter open'));
      expect(Ansi.strip(rows.last), contains('auto-refresh'));
    });

    test('drops the footer row when the menu has no footer', () {
      final List<MenuEntry<String>> entries = dashboardEntries();
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 1,
        hint: dashHint,
        footer: null,
        columns: 104,
      );
      expect(rows, hasLength(entries.length + 1));
      expect(Ansi.strip(rows.last), contains('enter open'));
    });

    // A row that reaches the final column soft-wraps into a second terminal
    // line, which pushes every later row down and desynchronises the in-place
    // repaint. Leaving the last column empty is what keeps a frame exactly
    // [rows.length] terminal rows tall.
    test('keeps every row clear of the last column', () {
      for (final int columns in <int>[12, 24, 40, 80, 103, 104, 200]) {
        final List<String> rows = renderMenuRows<String>(
          dashboardEntries(),
          selected: 1,
          hint: dashHint,
          footer: dashFooter,
          columns: columns,
        );
        for (final String row in rows) {
          expect(
            Ansi.visibleLength(row),
            lessThanOrEqualTo(columns - 1),
            reason: 'row "${Ansi.strip(row)}" fills a $columns-column terminal',
          );
        }
      }
    });

    test('paints the selected row as a full-width bar', () {
      final List<String> rows = renderMenuRows<String>(
        dashboardEntries(),
        selected: 1,
        hint: dashHint,
        footer: dashFooter,
        columns: 104,
      );
      expect(rows[1], contains(Ansi.bgHighlight));
      expect(rows[1], contains(Ansi.eraseToEnd));
      expect(rows[3], isNot(contains(Ansi.bgHighlight)));
    });

    test('renders labelled separators as uppercase headings', () {
      final List<String> rows = renderMenuRows<String>(
        dashboardEntries(),
        selected: 1,
        hint: dashHint,
        footer: dashFooter,
        columns: 104,
      );
      expect(Ansi.strip(rows[0]), contains('SERVERS'));
      expect(Ansi.strip(rows[2]), contains('ACTIONS'));
    });

    test('aligns details past the widest label and badge', () {
      final List<String> rows = renderMenuRows<String>(
        dashboardEntries(),
        selected: 1,
        hint: dashHint,
        footer: dashFooter,
        columns: 200,
      );
      final int badgeRowDetail = Ansi.strip(rows[1]).indexOf(':25565');
      final int plainRowDetail = Ansi.strip(rows[3]).indexOf('one server');
      expect(badgeRowDetail, greaterThan(0));
      expect(badgeRowDetail, plainRowDetail);
    });

    test('omits the hotkey column when no entry has a shortcut', () {
      final List<String> rows = renderMenuRows<String>(
        <MenuEntry<String>>[
          const MenuEntry<String>('first', value: 'a'),
          const MenuEntry<String>('second', value: 'b'),
        ],
        selected: 0,
        hint: 'esc back',
        footer: null,
        columns: 80,
      );
      // Marker column, no hotkey chip column, then the label.
      expect(Ansi.strip(rows[1]), '   second');
    });
  });
}
