part of 'menu.dart';

/// First screen row a frame of [frameHeight] rows may start on so that the
/// whole frame stays on screen. Repaints address rows absolutely, so a frame
/// that hangs off the bottom would otherwise scroll the terminal and move
/// itself out from under the next repaint.
///
/// A frame taller than the screen cannot fit at all; it is pinned to the top
/// and its tail is cut off rather than corrupting the rows above it.
int clampFrameTop({
  required int desiredTop,
  required int frameHeight,
  required int terminalLines,
}) {
  final int lastPossible = terminalLines - frameHeight + 1;
  final int top = desiredTop > lastPossible ? lastPossible : desiredTop;
  return top < 1 ? 1 : top;
}

/// First row to erase above a frame about to be redrawn at [top], so stale
/// copies of the frame's head do not pile up.
///
/// While nothing else writes to the terminal ([displaced] false) there is
/// nothing above the frame to clean. Foreign output either pushes the frame
/// down — the rows it vacated, `[previousTop, top)`, are stale — or, when the
/// cursor is already on the last screen row, scrolls the terminal, which slides
/// a partial copy of the frame above [top]. That copy can be up to
/// [frameHeight] rows tall, and the rows it scrolled over are gone regardless.
int staleBandTop({
  required int top,
  required int? previousTop,
  required int frameHeight,
  required bool displaced,
  required bool cursorAtBottom,
}) {
  if (displaced && cursorAtBottom) {
    final int band = top - frameHeight;
    return band < 1 ? 1 : band;
  }
  final int previous = previousTop ?? top;
  return previous < top ? previous : top;
}

/// Last row to erase below a frame about to be redrawn at [top]: when foreign
/// output moved the frame up, its previous copy left a tail below the new
/// position. Returns a row before `top + frameHeight` when there is nothing to
/// erase.
int staleBandBottom({
  required int top,
  required int? previousTop,
  required int frameHeight,
  required int terminalLines,
  required bool displaced,
}) {
  if (!displaced || previousTop == null || previousTop <= top) {
    return top + frameHeight - 1;
  }
  final int tail = previousTop + frameHeight - 1;
  return tail > terminalLines ? terminalLines : tail;
}

/// The terminal rows of one menu frame, in draw order: one row per entry, then
/// the hint row, then the footer row when [footer] is set.
///
/// Every row is clipped to one column short of [columns]. A row that reaches
/// the last column soft-wraps into a second terminal line, which makes the
/// frame taller than the repaint arithmetic expects and leaves stale copies of
/// its top rows behind on every refresh.
List<String> renderMenuRows<T>(
  List<MenuEntry<T>> entries, {
  required int selected,
  required String hint,
  required String? footer,
  required int columns,
}) {
  final int width = columns > 1 ? columns - 1 : 1;
  final int labelWidth = entries
      .where((MenuEntry<T> e) => e.selectable)
      .fold(
        0,
        (int w, MenuEntry<T> e) => e.label.length > w ? e.label.length : w,
      );
  final int badgeWidth = entries.fold(
    0,
    (int w, MenuEntry<T> e) => (e.badge?.length ?? 0) > w ? e.badge!.length : w,
  );
  final bool hasShortcuts = entries.any(
    (MenuEntry<T> e) => e.selectable && e.shortcut != null,
  );

  return <String>[
    for (int i = 0; i < entries.length; i++)
      _renderEntryRow<T>(
        entries[i],
        isSelected: i == selected,
        labelWidth: labelWidth,
        badgeWidth: badgeWidth,
        hasShortcuts: hasShortcuts,
        width: width,
      ),
    Ansi.clipVisible('  ${Ansi.style(hint, Ansi.gray)}', width),
    if (footer != null) Ansi.clipVisible('  $footer', width),
  ];
}

String _renderEntryRow<T>(
  MenuEntry<T> entry, {
  required bool isSelected,
  required int labelWidth,
  required int badgeWidth,
  required bool hasShortcuts,
  required int width,
}) {
  if (entry.isSeparator) {
    if (entry.label.isEmpty) {
      return Ansi.clipVisible(
        '  ${Ansi.style('─' * (labelWidth + badgeWidth + 8), Ansi.gray)}',
        width,
      );
    }
    return Ansi.clipVisible(
      '  ${Ansi.style(entry.label.toUpperCase(), '${Ansi.gray}${Ansi.bold}')}',
      width,
    );
  }

  final String marker = isSelected
      ? Ansi.style('▸', '${Ansi.cyan}${Ansi.bold}')
      : ' ';
  // Shortcut keys render as small [k] button chips; menus without any
  // shortcuts drop the column entirely.
  final String key = !hasShortcuts
      ? ''
      : entry.shortcut == null
      ? '    '
      : ' ${Ansi.style('[', Ansi.gray)}${Ansi.style(entry.shortcut!, Ansi.cyan)}${Ansi.style(']', Ansi.gray)}';
  final String selectedColor = '${entry.labelColor ?? Ansi.cyan}${Ansi.bold}';
  final String label = isSelected
      ? Ansi.style(Ansi.padVisible(entry.label, labelWidth), selectedColor)
      : entry.labelColor == null
      ? Ansi.padVisible(entry.label, labelWidth)
      : Ansi.style(Ansi.padVisible(entry.label, labelWidth), entry.labelColor!);
  final StringBuffer line = StringBuffer('$marker$key  $label');
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
    // Details carrying their own ANSI styling render as-is; plain details get
    // the standard dim treatment.
    final String detail = entry.detail!;
    line.write(
      '  ${detail.contains('\x1B') ? detail : Ansi.style(detail, Ansi.gray)}',
    );
  }

  final String clipped = Ansi.clipVisible(line.toString(), width);
  if (!isSelected) {
    return clipped;
  }
  // Paint the selected row as a full-width bar: re-assert the background after
  // every inner reset, then erase-to-EOL extends it to the edge without moving
  // the cursor into the last column.
  final String painted = clipped.replaceAll(
    Ansi.reset,
    '${Ansi.reset}${Ansi.bgHighlight}',
  );
  return '${Ansi.bgHighlight}$painted${Ansi.eraseToEnd}${Ansi.reset}';
}
