import 'package:multiplexor/utils/terminal/theme.dart';
// Re-exports the menu library and the Ansi helpers alongside the Ui facade.
import 'package:multiplexor/utils/user_prompt.dart';
import 'package:test/test.dart';

List<MenuEntry<String>> menuEntries() => <MenuEntry<String>>[
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

const String menuTitle = 'Multiplexor';
const String menuHint =
    '↑↓ move · enter open · R restart · S stop · X kill · O console · esc back';
const String menuFooter =
    'builds  paper 4d · purpur 4d · folia 4d · canvas 4d · leaf 4d · '
    'spigot 28d  ·  auto-refresh after 24h';

/// A 256-color, unicode-glyph theme: what an interactive terminal resolves to.
MonitorTheme colorTheme() => MonitorTheme.detect(
  env: const <String, String>{'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8'},
  isTty: true,
);

/// A 16-color theme, where the selection bar has no 256-color background to
/// fall back on.
MonitorTheme basicTheme() => MonitorTheme.detect(
  env: const <String, String>{'TERM': 'xterm', 'LANG': 'en_US.UTF-8'},
  isTty: true,
);

/// The content of a framed row: everything between the vertical rules and
/// their padding spaces.
String inner(String row) {
  final String plain = Ansi.strip(row);
  return plain.substring(2, plain.length - 2);
}

void main() {
  group('Ui.theme', () {
    tearDown(() => Ui.themeOverride = null);

    test('is detected once and reused', () {
      Ui.themeOverride = null;
      expect(identical(Ui.theme, Ui.theme), isTrue);
    });

    test('yields to an override and goes back to detection when cleared', () {
      final MonitorTheme detected = Ui.theme;
      Ui.themeOverride = MonitorTheme.plainAscii();
      expect(Ui.theme.glyphs.isAscii, isTrue);
      Ui.themeOverride = null;
      expect(identical(Ui.theme, detected), isTrue);
    });
  });

  group('menuEntryAtRow', () {
    // Frame at row 10: 10 is the top border, 11..14 the four entries, 15 the
    // footer, 16 the bottom border.
    test('maps the row under the top border to the first entry', () {
      expect(menuEntryAtRow(row: 11, frameTop: 10, entryCount: 4), 0);
    });

    test('maps the last entry row', () {
      expect(menuEntryAtRow(row: 14, frameTop: 10, entryCount: 4), 3);
    });

    test('ignores the top border', () {
      expect(menuEntryAtRow(row: 10, frameTop: 10, entryCount: 4), isNull);
    });

    test('ignores the footer and the bottom border below the entries', () {
      expect(menuEntryAtRow(row: 15, frameTop: 10, entryCount: 4), isNull);
      expect(menuEntryAtRow(row: 16, frameTop: 10, entryCount: 4), isNull);
    });

    test('ignores rows above the frame', () {
      expect(menuEntryAtRow(row: 9, frameTop: 10, entryCount: 4), isNull);
      expect(menuEntryAtRow(row: 1, frameTop: 10, entryCount: 4), isNull);
    });
  });

  group('menuClearBand', () {
    test('covers the frame from its top border to its bottom border', () {
      expect(menuClearBand(top: 5, frameHeight: 6), (top: 5, bottom: 10));
    });

    test('is a single row for a one-row frame', () {
      expect(menuClearBand(top: 5, frameHeight: 1), (top: 5, bottom: 5));
    });
  });

  group('menuClearMoves', () {
    test('walks up from the frame\'s last row and back to its first', () {
      final ({int up, int erase, int back}) moves = menuClearMoves(
        frameHeight: 6,
      );
      expect(moves.up, 5);
      expect(moves.erase, 6);
      expect(moves.back, 6);
    });

    test('erases as many rows as the frame is tall', () {
      for (final int height in <int>[3, 8, 34]) {
        final ({int up, int erase, int back}) moves = menuClearMoves(
          frameHeight: height,
        );
        // Up to the top row, erase downward from there, back to the top row.
        expect(moves.up + 1, height);
        expect(moves.erase, height);
        expect(moves.back, moves.erase);
      }
    });
  });

  group('renderPromptResult', () {
    test('reports the prompt and its answer', () {
      final String line = renderPromptResult(
        prompt: 'Server platform',
        value: 'Paper',
        theme: colorTheme(),
      );
      expect(Ansi.strip(line), '✓ Server platform · Paper');
    });

    test('marks the answer with the theme glyph, not a hardcoded check', () {
      final MonitorTheme ascii = MonitorTheme.plainAscii();
      final String line = renderPromptResult(
        prompt: 'Server platform',
        value: 'Paper',
        theme: ascii,
      );
      expect(line, '${ascii.glyphs.check} Server platform · Paper');
      expect(line.startsWith('*'), isTrue);
    });

    test('tones the value with the theme, or with an override', () {
      final MonitorTheme theme = colorTheme();
      expect(
        renderPromptResult(prompt: 'Wipe', value: 'yes', theme: theme),
        contains('${theme.ok}yes'),
      );
      expect(
        renderPromptResult(
          prompt: 'Wipe',
          value: 'no',
          theme: theme,
          valueTone: theme.faint,
        ),
        contains('${theme.faint}no'),
      );
    });

    test('emits no escape bytes with a colorless theme', () {
      final String line = renderPromptResult(
        prompt: 'Instance name',
        value: 'paper-26.2',
        theme: MonitorTheme.plain(),
      );
      expect(line, '✓ Instance name · paper-26.2');
      expect(line, isNot(contains('\x1B')));
    });

    test('stays escape-free with a toned value at depth none', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final String line = renderPromptResult(
        prompt: 'Wipe every instance?',
        value: 'no',
        theme: theme,
        valueTone: theme.faint,
      );
      expect(line, '✓ Wipe every instance? · no');
      expect(line, isNot(contains('\x1B')));
    });
  });

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
    test('boxes the entries between a top and a bottom border', () {
      final List<MenuEntry<String>> entries = menuEntries();
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: null,
        columns: 140,
        theme: colorTheme(),
      );
      expect(rows, hasLength(entries.length + 2));
      expect(Ansi.strip(rows.first), startsWith('┌─ '));
      expect(Ansi.strip(rows.last), startsWith('└─ '));
      for (final String row in rows.sublist(1, rows.length - 1)) {
        expect(Ansi.strip(row), startsWith('│ '));
        expect(Ansi.strip(row), endsWith(' │'));
      }
    });

    test('inlays the uppercased menu title in the top border', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: null,
        columns: 140,
        theme: colorTheme(),
      );
      expect(Ansi.strip(rows.first), contains('MULTIPLEXOR'));
      expect(rows.first, contains(colorTheme().textStrong));
    });

    test('inlays the hint in the bottom border instead of its own row', () {
      final List<MenuEntry<String>> entries = menuEntries();
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: null,
        columns: 140,
        theme: colorTheme(),
      );
      expect(Ansi.strip(rows.last), contains('enter open'));
      // The hint lives in the border, so no entry row repeats it.
      for (final String row in rows.sublist(1, rows.length - 1)) {
        expect(Ansi.strip(row), isNot(contains('enter open')));
      }
    });

    test('keeps the footer as the last content row above the border', () {
      final List<MenuEntry<String>> entries = menuEntries();
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 140,
        theme: colorTheme(),
      );
      expect(rows, hasLength(entries.length + 3));
      expect(Ansi.strip(rows[rows.length - 2]), contains('auto-refresh'));
      expect(Ansi.strip(rows[rows.length - 2]), startsWith('│ '));
      expect(Ansi.strip(rows.last), startsWith('└─ '));
    });

    // A row that reaches the final column soft-wraps into a second terminal
    // line, which pushes every later row down and desynchronises the in-place
    // repaint. Leaving the last column empty is what keeps a frame exactly
    // [rows.length] terminal rows tall.
    test('keeps every row clear of the last column', () {
      for (final int columns in <int>[12, 24, 40, 80, 103, 104, 200]) {
        final List<String> rows = renderMenuRows<String>(
          menuEntries(),
          selected: 1,
          title: menuTitle,
          hint: menuHint,
          footer: menuFooter,
          columns: columns,
          theme: colorTheme(),
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

    test('renders every row at the same width so the box lines up', () {
      for (final int columns in <int>[12, 24, 40, 80, 200]) {
        final List<String> rows = renderMenuRows<String>(
          menuEntries(),
          selected: 1,
          title: menuTitle,
          hint: menuHint,
          footer: menuFooter,
          columns: columns,
          theme: colorTheme(),
        );
        final Set<int> widths = rows.map(Ansi.visibleLength).toSet();
        expect(widths, hasLength(1), reason: 'ragged box at $columns columns');
      }
    });

    test('paints the selected row as a bar inside the frame', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 140,
        theme: colorTheme(),
      );
      expect(rows[2], contains(Ansi.bgHighlight));
      // Re-asserted after every inner reset, or the bar would break up.
      expect(rows[2], contains('${Ansi.reset}${Ansi.bgHighlight}'));
      // Erase-to-EOL would paint over the right-hand border.
      expect(rows[2], isNot(contains(Ansi.eraseToEnd)));
      expect(rows[4], isNot(contains(Ansi.bgHighlight)));
    });

    test('falls back to inverse video for the bar at basic depth', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 140,
        theme: basicTheme(),
      );
      expect(rows[2], contains(Ansi.inverse));
      expect(rows[2], isNot(contains(Ansi.bgHighlight)));
      expect(rows[4], isNot(contains(Ansi.inverse)));
    });

    test('accents the shortcut chip on the selected row only', () {
      final MonitorTheme theme = colorTheme();
      final List<MenuEntry<String>> entries = <MenuEntry<String>>[
        const MenuEntry<String>('first', value: 'a', shortcut: 'f'),
        const MenuEntry<String>('second', value: 'b', shortcut: 's'),
      ];
      final List<String> rows = renderMenuRows<String>(
        entries,
        selected: 0,
        title: menuTitle,
        hint: 'esc back',
        footer: null,
        columns: 80,
        theme: theme,
      );
      expect(rows[1], contains('${theme.accent}f'));
      expect(rows[2], contains('${theme.faint}s'));
      expect(rows[2], isNot(contains('${theme.accent}s')));
    });

    test('renders labelled separators as inlaid rules', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 140,
        theme: colorTheme(),
      );
      expect(inner(rows[1]), startsWith('── SERVERS ──'));
      expect(inner(rows[3]), startsWith('── ACTIONS ──'));
      // The rule fills the frame.
      expect(inner(rows[1]), endsWith('─'));
    });

    test('renders unlabelled separators as a full-width rule', () {
      final List<String> rows = renderMenuRows<String>(
        <MenuEntry<String>>[
          const MenuEntry<String>('first', value: 'a'),
          const MenuEntry<String>.separator(),
          const MenuEntry<String>('second', value: 'b'),
        ],
        selected: 0,
        title: menuTitle,
        hint: 'esc back',
        footer: null,
        columns: 80,
        theme: colorTheme(),
      );
      final String rule = inner(rows[2]);
      expect(rule, matches(RegExp(r'^─+$')));
      expect(rule.length, inner(rows[1]).length);
    });

    test('aligns details past the widest label and badge', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 200,
        theme: colorTheme(),
      );
      final int badgeRowDetail = inner(rows[2]).indexOf(':25565');
      final int plainRowDetail = inner(rows[4]).indexOf('one server');
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
        title: menuTitle,
        hint: 'esc back',
        footer: null,
        columns: 80,
        theme: colorTheme(),
      );
      // Marker column, no hotkey chip column, then the label.
      expect(inner(rows[2]).trimRight(), '   second');
    });

    test('emits no escape bytes at all with a colorless theme', () {
      final List<String> rows = renderMenuRows<String>(
        menuEntries(),
        selected: 1,
        title: menuTitle,
        hint: menuHint,
        footer: menuFooter,
        columns: 140,
        theme: MonitorTheme.plain(),
      );
      for (final String row in rows) {
        expect(row, isNot(contains('\x1B')));
      }
    });

    test('renders a structurally plain box at colour depth none', () {
      final List<String> rows = renderMenuRows<String>(
        <MenuEntry<String>>[
          const MenuEntry<String>.separator('group'),
          const MenuEntry<String>(
            'alpha',
            value: 'a',
            shortcut: 'a',
            detail: 'first',
          ),
          const MenuEntry<String>('beta', value: 'b'),
        ],
        selected: 1,
        title: 'Pick one',
        hint: 'esc back',
        footer: null,
        columns: 41,
        theme: MonitorTheme.plain(),
      );
      expect(rows, <String>[
        '┌─ PICK ONE ──────────┐',
        '│ ── GROUP ────────── │',
        '│ ▸ [a]  alpha  first │',
        '│        beta         │',
        '└─ esc back ──────────┘',
      ]);
    });

    test('draws the box with ascii glyphs when unicode is unavailable', () {
      final List<String> rows = renderMenuRows<String>(
        <MenuEntry<String>>[const MenuEntry<String>('alpha', value: 'a')],
        selected: 0,
        title: 'Pick one',
        hint: 'esc back',
        footer: null,
        columns: 41,
        theme: MonitorTheme.plainAscii(),
      );
      expect(rows, <String>[
        '+- PICK ONE --+',
        '| >  alpha    |',
        '+- esc back --+',
      ]);
    });
  });
}
