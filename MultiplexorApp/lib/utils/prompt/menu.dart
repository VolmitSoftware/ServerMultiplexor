import 'dart:io';

import '../terminal/ansi.dart';
import '../terminal/term_events.dart';
import '../terminal/term_io.dart';

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
  final bool isSeparator;

  bool get selectable => !isSeparator;
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
  Future<List<MenuEntry<T>>> Function()? onTick,
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

  // Mutable so a live refresh (onTick) can recompute alignment when badge
  // contents grow or shrink between ticks.
  int labelWidth = entries
      .where((MenuEntry<T> e) => e.selectable)
      .fold(
        0,
        (int w, MenuEntry<T> e) => e.label.length > w ? e.label.length : w,
      );
  int badgeWidth = entries.fold(
    0,
    (int w, MenuEntry<T> e) => (e.badge?.length ?? 0) > w ? e.badge!.length : w,
  );

  String renderEntry(int index) {
    final MenuEntry<T> entry = entries[index];
    if (entry.isSeparator) {
      if (entry.label.isEmpty) {
        return '  ${Ansi.style('─' * (labelWidth + badgeWidth + 8), Ansi.gray)}';
      }
      return '  ${Ansi.style(entry.label.toUpperCase(), '${Ansi.gray}${Ansi.bold}')}';
    }
    final bool isSelected = index == selected;
    final String marker = isSelected
        ? Ansi.style('▸', '${Ansi.cyan}${Ansi.bold}')
        : ' ';
    final String key = entry.shortcut == null
        ? ' '
        : Ansi.style(entry.shortcut!, Ansi.gray);
    final String label = isSelected
        ? Ansi.style(
            Ansi.padVisible(entry.label, labelWidth),
            '${Ansi.cyan}${Ansi.bold}',
          )
        : Ansi.padVisible(entry.label, labelWidth);
    final StringBuffer line = StringBuffer('$marker $key  $label');
    if (entry.badge != null) {
      line.write('  ');
      line.write(
        Ansi.style(
          Ansi.padVisible(entry.badge!, badgeWidth),
          entry.badgeColor ?? Ansi.gray,
        ),
      );
    } else if (badgeWidth > 0) {
      line.write('  ${' ' * badgeWidth}');
    }
    if (entry.detail != null && entry.detail!.isNotEmpty) {
      line.write('  ${Ansi.style(entry.detail!, Ansi.gray)}');
    }
    return line.toString();
  }

  final String footer =
      '  ${Ansi.style(hint ?? '↑↓ move · enter select · esc back · click', Ansi.gray)}';
  final int redrawLines = entries.length + 1;

  void draw({required bool repaint}) {
    if (repaint) {
      stdout.write('\x1B[${redrawLines}A');
    }
    for (int i = 0; i < entries.length; i++) {
      stdout.write('\r${Ansi.eraseLine}');
      stdout.writeln(renderEntry(i));
    }
    stdout.write('\r${Ansi.eraseLine}');
    stdout.writeln(footer);
  }

  void clear() {
    stdout.write('\x1B[${redrawLines + 1}A');
    for (int i = 0; i < redrawLines + 1; i++) {
      stdout.write('\r${Ansi.eraseLine}\x1B[1B');
    }
    stdout.write('\x1B[${redrawLines + 1}A');
  }

  void moveSelection(int delta) {
    final int position = selectable.indexOf(selected);
    final int next = (position + delta + selectable.length) % selectable.length;
    selected = selectable[next];
  }

  stdout.writeln(
    '${Ansi.style('?', Ansi.yellow)} ${Ansi.style(title, Ansi.bold)}',
  );

  io.setRawMode(true);
  io.hideCursor();
  io.enableMouse();
  int? firstEntryRow;
  try {
    draw(repaint: false);
    final int? rowAfter = io.cursorRow();
    if (rowAfter != null) {
      firstEntryRow = rowAfter - 1 - entries.length;
    }

    int? entryAtRow(int row) {
      if (firstEntryRow == null) {
        return null;
      }
      final int index = row - firstEntryRow;
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
        // Timed out with no input: refresh the entries and redraw in place.
        // The refresh must preserve the row count so the repaint cursor math
        // stays correct; a structural change is picked up on the next full
        // reload instead.
        List<MenuEntry<T>>? refreshed;
        try {
          refreshed = await onTick!();
        } catch (_) {
          refreshed = null;
        }
        if (refreshed != null && refreshed.length == entries.length) {
          entries = refreshed;
          labelWidth = entries
              .where((MenuEntry<T> e) => e.selectable)
              .fold(
                0,
                (int w, MenuEntry<T> e) =>
                    e.label.length > w ? e.label.length : w,
              );
          badgeWidth = entries.fold(
            0,
            (int w, MenuEntry<T> e) =>
                (e.badge?.length ?? 0) > w ? e.badge!.length : w,
          );
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
