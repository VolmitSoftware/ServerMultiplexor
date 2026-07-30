import 'dart:io';

import '../terminal/ansi.dart';
import '../terminal/term_events.dart';
import '../terminal/term_io.dart';
import '../terminal/theme.dart';
// Only for the shared, lazily detected prompt theme; `show` keeps this back
// edge to the Ui facade from shadowing the imports above it.
import '../user_prompt.dart' show Ui;

part 'menu_layout.dart';

/// Thrown when the user backs out of a prompt with Escape.
class PromptBackNavigation implements Exception {
  const PromptBackNavigation();

  @override
  String toString() => 'Prompt cancelled with Escape';
}

/// Thrown when stdin stops being readable mid-prompt.
class PromptInputUnavailable implements Exception {
  PromptInputUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One row in an interactive menu.
class MenuEntry<T> {
  const MenuEntry(
    this.label, {
    this.value,
    this.detail,
    this.badge,
    this.badgeColor,
    this.shortcut,
    this.labelColor,
    this.isSeparator = false,
  });

  /// A non-selectable divider line. With a [label], renders as a dim
  /// section heading; without, as a horizontal rule.
  const MenuEntry.separator([String label = ''])
    : this(label, isSeparator: true);

  final String label;
  final T? value;

  /// Dim supplemental text rendered after the label.
  final String? detail;

  /// Short colored state chip rendered between label and detail.
  final String? badge;
  final String? badgeColor;

  /// Single-character hotkey that activates this entry directly.
  final String? shortcut;

  /// ANSI code applied to the label (e.g. red for destructive actions).
  /// Also used, bolded, when the entry is selected.
  final String? labelColor;
  final bool isSeparator;

  bool get selectable => !isSeparator;
}

/// One live-refresh update from a menu's onTick callback.
class MenuTick<T> {
  const MenuTick(this.entries, {this.footer});

  /// Replacement entries; applied only when the entry count is unchanged
  /// (a structural change is picked up on the next full reload).
  final List<MenuEntry<T>> entries;

  /// Replacement footer; applied only when the menu was created with a
  /// footer, so the repaint row count stays stable. Null keeps the
  /// current footer.
  final String? footer;
}

/// Interactive menu with keyboard and mouse support.
///
/// Keys: arrows/wheel move, Enter activates, Escape goes back, digits jump,
/// shortcut letters activate their entry directly. Mouse: click selects,
/// click on the selected entry activates.
Future<T> menuSelect<T>(
  String title,
  List<MenuEntry<T>> entries, {
  int initialIndex = 0,
  String? hint,
  String? footer,
  Future<MenuTick<T>> Function()? onTick,
  Duration tickInterval = const Duration(seconds: 1),
  T? Function(String rawChar, MenuEntry<T> highlighted)? onActionKey,
}) async {
  final List<int> selectable = <int>[
    for (int i = 0; i < entries.length; i++)
      if (entries[i].selectable) i,
  ];
  if (selectable.isEmpty) {
    throw StateError('Menu "$title" requires at least one selectable entry.');
  }

  final TermIo io = TermIo.instance;
  if (!io.hasTerminal) {
    return _menuLineFallback(title, entries, selectable);
  }

  int selected = selectable.contains(initialIndex)
      ? initialIndex
      : selectable.first;

  final String hintText = hint ?? '↑↓ move · enter select · esc back · click';
  String? currentFooter = footer;
  // Two border rows carry the title and the hint; a footer, when the menu has
  // one, is a content row just above the bottom border.
  final int tailLines = footer == null ? 2 : 3;
  final int frameHeight = entries.length + tailLines;

  /// Screen row the frame's first line currently occupies. Null while the
  /// terminal has not answered a cursor-position query, in which case repaints
  /// fall back to relative cursor moves.
  int? frameTop;

  /// Where the last draw parked the cursor: column 1 of the frame's last row.
  /// Any other position means something else wrote to the terminal since, so
  /// the frame is no longer where it was drawn.
  int? restingRow;
  bool cursorReportsWork = true;

  // Terminal geometry the current frame was drawn for. A resize reflows every
  // row the terminal is holding, so nothing on screen can be trusted and the
  // frame is redrawn on a cleared screen.
  int lastColumns = io.terminalColumns;
  int lastLines = io.terminalLines;

  /// Writes [rows] downward from the cursor's current row and leaves the cursor
  /// on the last one. There is deliberately no trailing newline: a newline on
  /// the bottom screen row scrolls the terminal, which would move the frame out
  /// from under the next repaint.
  void writeRowsFromCursor(List<String> rows) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < rows.length; i++) {
      if (i > 0) {
        out.write('\n');
      }
      out.write('\r${Ansi.eraseLine}${rows[i]}');
    }
    stdout.write(out.toString());
  }

  /// Cursor position, or null once the terminal has proven it does not report
  /// one (queries are not retried after that).
  TermCursor? queryCursor() {
    if (!cursorReportsWork) {
      return null;
    }
    final TermCursor? at = io.cursorPosition();
    if (at == null) {
      cursorReportsWork = false;
    }
    return at;
  }

  void draw({required bool repaint}) {
    final int columns = io.terminalColumns;
    final List<String> rows = renderMenuRows<T>(
      entries,
      selected: selected,
      title: title,
      hint: hintText,
      footer: currentFooter,
      columns: columns,
      theme: Ui.theme,
    );

    // Parking the cursor at column 1 of the last row makes the resting position
    // exact: it does not depend on how wide the terminal renders the glyphs in
    // that row, so a position that differs on the next query really does mean
    // foreign output landed in the frame.
    void park(int top) {
      final int lastRow = top + rows.length - 1;
      frameTop = top;
      restingRow = lastRow;
      stdout.write('\x1B[$lastRow;1H');
    }

    if (!repaint) {
      writeRowsFromCursor(rows);
      final TermCursor? at = queryCursor();
      if (at == null) {
        frameTop = null;
        restingRow = null;
        return;
      }
      park(at.row - rows.length + 1);
      return;
    }

    // Re-measure on every repaint. The cursor is the only record of where the
    // frame actually sits, so anything that wrote to the terminal in between —
    // subprocess output, an error trace, a scroll, a resize — is absorbed here
    // instead of smearing stale copies of the frame down the screen.
    final TermCursor? at = queryCursor();
    if (at == null) {
      if (rows.length > 1) {
        stdout.write('\x1B[${rows.length - 1}A');
      }
      writeRowsFromCursor(rows);
      return;
    }
    final int lines = io.terminalLines;
    final bool resized = columns != lastColumns || lines != lastLines;
    lastColumns = columns;
    lastLines = lines;
    final bool displaced = resized || at.row != restingRow || at.col != 1;
    final int top = clampFrameTop(
      desiredTop: at.row - rows.length + 1,
      frameHeight: rows.length,
      terminalLines: lines,
    );
    final StringBuffer out = StringBuffer();
    if (resized) {
      out.write(Ansi.eraseScreen);
    } else {
      final int bandTop = staleBandTop(
        top: top,
        previousTop: frameTop,
        frameHeight: rows.length,
        displaced: displaced,
        cursorAtBottom: at.row >= lines,
      );
      final int bandBottom = staleBandBottom(
        top: top,
        previousTop: frameTop,
        frameHeight: rows.length,
        terminalLines: lines,
        displaced: displaced,
      );
      for (int row = bandTop; row < top; row++) {
        out.write('\x1B[$row;1H${Ansi.eraseLine}');
      }
      for (int row = top + rows.length; row <= bandBottom; row++) {
        out.write('\x1B[$row;1H${Ansi.eraseLine}');
      }
    }
    for (int i = 0; i < rows.length; i++) {
      out.write('\x1B[${top + i};1H${Ansi.eraseLine}${rows[i]}');
    }
    stdout.write(out.toString());
    park(top);
  }

  /// Erases the frame, leaving the cursor on the row its top border occupied
  /// so the caller can print its own line in the menu's place.
  void clear() {
    final int? top = frameTop;
    if (top == null) {
      // Cursor rests on the frame's last row; the top border sits
      // frameHeight - 1 rows above it.
      if (frameHeight > 1) {
        stdout.write('\r\x1B[${frameHeight - 1}A');
      }
      for (int i = 0; i < frameHeight; i++) {
        stdout.write('\r${Ansi.eraseLine}\x1B[1B');
      }
      stdout.write('\x1B[${frameHeight}A');
      return;
    }
    final StringBuffer out = StringBuffer();
    for (int row = top; row < top + frameHeight; row++) {
      out.write('\x1B[$row;1H${Ansi.eraseLine}');
    }
    out.write('\x1B[$top;1H');
    stdout.write(out.toString());
  }

  void moveSelection(int delta) {
    final int position = selectable.indexOf(selected);
    final int next = (position + delta + selectable.length) % selectable.length;
    selected = selectable[next];
  }

  // No prompt line above the frame: the title is inlaid in the box's top
  // border, which — unlike a line printed once — is redrawn with every
  // repaint and so survives interleaved subprocess output.
  io.setRawMode(true);
  io.hideCursor();
  io.enableMouse();
  try {
    draw(repaint: false);

    /// Entry under a mouse click, using the row the last draw measured. Null
    /// when the terminal does not report the cursor, or when the click missed
    /// the entries — the borders and the footer are not clickable.
    int? entryAtRow(int row) {
      final int? first = frameTop;
      if (first == null) {
        return null;
      }
      // The frame's first row is the top border, so entries start one below.
      final int index = row - first - 1;
      if (index < 0 || index >= entries.length) {
        return null;
      }
      return entries[index].selectable ? index : null;
    }

    T finishWith(T value, String label) {
      clear();
      io.disableMouse();
      io.showCursor();
      // Leave raw mode before printing: with OPOST off, "\n" does not
      // return the carriage and the next line starts mid-column.
      io.setRawMode(false);
      stdout.writeln(
        '${Ansi.style('✔', Ansi.green)} ${Ansi.style(title, Ansi.bold)} '
        '${Ansi.style('·', Ansi.gray)} ${Ansi.style(label, Ansi.green)}',
      );
      return value;
    }

    T finish(int index) =>
        finishWith(entries[index].value as T, entries[index].label);

    while (true) {
      TermEvent? event;
      try {
        event = onTick == null
            ? io.readEvent()
            : io.readEventTimeout(tickInterval);
      } on TermInputUnavailable {
        throw PromptInputUnavailable(
          'stdin is not readable while waiting for "$title"',
        );
      }

      if (event == null) {
        // Timed out with no input: refresh entries/footer and redraw in
        // place. The refresh must preserve the row count so the repaint
        // cursor math stays correct; a structural change is picked up on
        // the next full reload instead.
        MenuTick<T>? update;
        try {
          update = await onTick!();
        } catch (_) {
          update = null;
        }
        if (update == null) {
          continue;
        }
        bool changed = false;
        if (update.entries.length == entries.length) {
          // Column alignment is recomputed per draw, so badges that grow or
          // shrink between ticks stay aligned.
          entries = update.entries;
          changed = true;
        }
        if (footer != null && update.footer != null) {
          currentFooter = update.footer;
          changed = true;
        }
        if (changed) {
          // Re-assert mouse tracking with the repaint: programs sharing the
          // tty (tmux console attach/detach) can reset it behind our back,
          // and the enable sequence is idempotent. Self-heals within one
          // tick instead of leaving the menu click-dead.
          io.enableMouse();
          draw(repaint: true);
        }
        continue;
      }

      switch (event.kind) {
        case TermEventKind.arrowUp:
        case TermEventKind.wheelUp:
          moveSelection(-1);
          draw(repaint: true);
          break;
        case TermEventKind.arrowDown:
        case TermEventKind.wheelDown:
          moveSelection(1);
          draw(repaint: true);
          break;
        case TermEventKind.home:
          selected = selectable.first;
          draw(repaint: true);
          break;
        case TermEventKind.end:
          selected = selectable.last;
          draw(repaint: true);
          break;
        case TermEventKind.enter:
          return finish(selected);
        case TermEventKind.escape:
          clear();
          io.disableMouse();
          io.showCursor();
          io.setRawMode(false);
          throw const PromptBackNavigation();
        case TermEventKind.ctrlC:
          TermIo.instance.restoreTerminal();
          stdout.writeln();
          exit(130);
        case TermEventKind.mouseDown:
          final int? index = entryAtRow(event.row);
          if (index != null && index != selected) {
            selected = index;
            draw(repaint: true);
          }
          break;
        case TermEventKind.mouseUp:
          final int? index = entryAtRow(event.row);
          if (index != null && index == selected) {
            return finish(index);
          }
          break;
        case TermEventKind.char:
          if (onActionKey != null) {
            final T? actionValue = onActionKey(event.char, entries[selected]);
            if (actionValue != null) {
              return finishWith(actionValue, entries[selected].label);
            }
          }
          final String char = event.char.toLowerCase();
          final int digit = int.tryParse(char) ?? -1;
          if (digit >= 1 && digit <= selectable.length) {
            selected = selectable[digit - 1];
            draw(repaint: true);
            break;
          }
          for (final int i in selectable) {
            if (entries[i].shortcut?.toLowerCase() == char) {
              return finish(i);
            }
          }
          break;
        default:
          break;
      }
    }
  } finally {
    io.disableMouse();
    io.showCursor();
    io.setRawMode(false);
  }
}

Future<T> _menuLineFallback<T>(
  String title,
  List<MenuEntry<T>> entries,
  List<int> selectable,
) async {
  stdout.writeln('? $title');
  for (int position = 0; position < selectable.length; position++) {
    final MenuEntry<T> entry = entries[selectable[position]];
    final String detail = entry.detail == null ? '' : '  (${entry.detail})';
    final String badge = entry.badge == null ? '' : ' [${entry.badge}]';
    stdout.writeln('  ${position + 1}) ${entry.label}$badge$detail');
  }
  stdout.write('Select [1]: ');
  String? raw;
  try {
    raw = stdin.readLineSync();
  } catch (_) {
    raw = null;
  }
  if (raw == null) {
    throw PromptInputUnavailable(
      'stdin is not readable while waiting for "$title"',
    );
  }
  final String trimmed = raw.trim().toLowerCase();
  if (trimmed == 'esc' || trimmed == 'escape' || trimmed == 'b') {
    throw const PromptBackNavigation();
  }
  final int numeric = int.tryParse(trimmed) ?? 1;
  final int position = numeric >= 1 && numeric <= selectable.length
      ? numeric - 1
      : 0;
  return entries[selectable[position]].value as T;
}
