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

/// Index of the entry drawn on screen row [row], or null when that row is not
/// an entry row: the frame's first row is its top border, and its last rows are
/// the footer and the bottom border.
///
/// [frameTop] is the screen row the top border occupies, as the last draw
/// measured it.
int? menuEntryAtRow({
  required int row,
  required int frameTop,
  required int entryCount,
}) {
  final int index = row - frameTop - 1;
  if (index < 0 || index >= entryCount) {
    return null;
  }
  return index;
}

/// The screen rows a frame of [frameHeight] rows drawn at [top] occupies, both
/// inclusive: the band that has to be erased to take the frame off the screen.
///
/// The cursor parks on [top] — the row the top border occupied — so whatever
/// the caller prints next lands in the menu's place.
({int top, int bottom}) menuClearBand({
  required int top,
  required int frameHeight,
}) => (top: top, bottom: top + frameHeight - 1);

/// The cursor moves that erase a frame of [frameHeight] rows when the terminal
/// does not report a cursor position, starting from where a draw parks the
/// cursor: column 1 of the frame's last row.
///
/// [up] reaches the frame's first row, [erase] rows are then erased downward
/// (each erase advances a row), and [back] returns to the first row.
({int up, int erase, int back}) menuClearMoves({required int frameHeight}) =>
    (up: frameHeight - 1, erase: frameHeight, back: frameHeight);

/// Columns a framed row spends on its borders and their padding: `│ ` and
/// ` │`.
const int _menuChromeWidth = 4;

/// Columns a border spends around its inlay: `┌─ `, a trailing space, and the
/// closing corner.
const int _menuInlayChromeWidth = 5;

/// Columns a rule spends around an inlaid heading: `── ` and the space before
/// the tail.
const int _menuRuleChromeWidth = 4;

/// Shortest tail an inlaid run keeps after it, so a title or heading never
/// runs into the corner it is inlaid before.
const int _menuInlayTailWidth = 2;

/// Shortest border that still has room for a readable inlaid run. Below this
/// the border is drawn solid instead.
const int _menuMinInlayWidth = 8;

/// The background the selected row is painted with. The cooked-mode menu is
/// the one place a background bar is used: the monitor's rows carry meaning in
/// their foreground tone alone, but a menu needs an unmissable cursor.
///
/// A 3-bit terminal has no dim background to spend, so it inverts the row
/// instead; a colorless terminal gets no bar at all and relies on the marker
/// glyph.
String _selectionBar(MonitorTheme theme) {
  switch (theme.depth) {
    case ColorDepth.truecolor:
    case ColorDepth.ansi256:
      return Ansi.bgHighlight;
    case ColorDepth.basic:
      return Ansi.inverse;
    case ColorDepth.none:
      return '';
  }
}

/// Whether [theme] forbids escape bytes entirely (`NO_COLOR`, a dumb terminal,
/// captured output). Caller-supplied colors — an entry's [MenuEntry.labelColor]
/// or [MenuEntry.badgeColor], a pre-styled detail — are dropped there rather
/// than emitted unbalanced, so the frame is byte-for-byte plain text.
bool _isColorless(MonitorTheme theme) => theme.depth == ColorDepth.none;

/// Forces [text] to exactly [width] visible columns, clipping or padding as
/// needed, so every emitted row lines up under the borders.
String _menuForceWidth(String text, int width) {
  final int safe = width < 0 ? 0 : width;
  return Ansi.padVisible(Ansi.clipVisible(text, safe), safe);
}

/// A border row of [width] columns with [inlay] set into it after the corner:
/// `┌─ INLAY ────┐`. Falls back to a solid rule when the border is too narrow
/// to read an inlay in, and clips an inlay that would not fit.
String _menuBorder({
  required String left,
  required String right,
  required String inlay,
  required int width,
  required MonitorTheme theme,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;
  final String tone = theme.frame;
  if (width < _menuMinInlayWidth || Ansi.visibleLength(inlay) == 0) {
    final String solid = '$left${glyphs.frameH * (width - 2)}$right';
    return _menuForceWidth(theme.paint(solid, tone), width);
  }
  final String clipped = Ansi.clipVisible(
    inlay,
    width - _menuInlayChromeWidth - _menuInlayTailWidth,
  );
  final int fill = width - _menuInlayChromeWidth - Ansi.visibleLength(clipped);
  final StringBuffer buffer = StringBuffer()
    ..write(theme.paint('$left${glyphs.frameH} ', tone))
    ..write(clipped)
    ..write(
      theme.paint(' ${glyphs.frameH * (fill < 0 ? 0 : fill)}$right', tone),
    );
  return _menuForceWidth(buffer.toString(), width);
}

/// Wraps [content] in the frame's vertical rules, padded to [width] columns.
///
/// A selected row is painted as a bar spanning everything between the rules:
/// the background is re-asserted after every reset the content carries, or the
/// bar would break up wherever a badge or detail ends its own styling.
String _menuFramedRow(
  String content, {
  required bool isSelected,
  required int width,
  required MonitorTheme theme,
}) {
  final int inner = width - _menuChromeWidth < 0 ? 0 : width - _menuChromeWidth;
  final String body = Ansi.padVisible(Ansi.clipVisible(content, inner), inner);
  final String rule = theme.paint(theme.glyphs.frameV, theme.frame);
  final String bar = isSelected ? _selectionBar(theme) : '';
  if (bar.isEmpty) {
    return _menuForceWidth('$rule $body $rule', width);
  }
  final String painted = body.replaceAll(Ansi.reset, '${Ansi.reset}$bar');
  return _menuForceWidth('$rule$bar $painted ${Ansi.reset}$rule', width);
}

/// A separator drawn as a rule across the frame's [inner] columns, with
/// [heading] — already uppercased, so it is sized as it is drawn — inlaid:
/// `── SECTION ──────`.
String _menuSeparatorRow(
  String heading, {
  required int inner,
  required MonitorTheme theme,
}) {
  final String dash = theme.glyphs.frameH;
  if (heading.isEmpty || inner < _menuMinInlayWidth) {
    return theme.paint(dash * inner, theme.frame);
  }
  final String text = Ansi.clipVisible(
    heading,
    inner - _menuRuleChromeWidth - _menuInlayTailWidth,
  );
  final int fill = inner - _menuRuleChromeWidth - Ansi.visibleLength(text);
  return theme.paint('$dash$dash ', theme.frame) +
      theme.paint(text, '${theme.bold}${theme.faint}') +
      theme.paint(' ${dash * (fill < 0 ? 0 : fill)}', theme.frame);
}

/// An inlaid run styled for [theme]: the tone where the theme has color, and
/// stripped of any escapes the caller brought where it has none — the same
/// rule the frame's rows follow.
String _menuInlay(String text, String tone, MonitorTheme theme) =>
    _isColorless(theme) ? Ansi.strip(text) : theme.paint(text, tone);

/// Styles a caller-provided run — a menu footer or an entry detail — that may
/// already carry its own escapes: pre-styled text is passed through, plain text
/// gets the faint tone, and a colorless theme gets neither.
String _menuCallerText(String text, MonitorTheme theme) {
  if (_isColorless(theme)) {
    return Ansi.strip(text);
  }
  return text.contains('\x1B') ? text : theme.paint(text, theme.faint);
}

/// The line a finished prompt leaves in its place: `✓ Prompt · value`.
///
/// Shared by every prompt that answers in a line — the menu, line input,
/// secrets, confirmations — so they all report the same shape. [valueTone]
/// overrides the tone of [value] (a declined confirmation is faint, not ok).
/// A colorless theme emits the same text with no escape bytes at all, and an
/// ascii theme swaps the check for `*` rather than emitting a rune the
/// terminal cannot draw.
String renderPromptResult({
  required String prompt,
  required String value,
  required MonitorTheme theme,
  String? valueTone,
}) =>
    '${theme.paint(theme.glyphs.check, theme.ok)} '
    '${theme.paint(prompt, '${theme.bold}${theme.text}')} '
    '${theme.paint('·', theme.faint)} '
    '${theme.paint(value, valueTone ?? theme.ok)}';

/// The terminal rows of one menu frame, in draw order: the top border with
/// [title] inlaid, one row per entry, the footer row when [footer] is set, and
/// the bottom border with [hint] inlaid. `entries.length + 2` rows, one more
/// with a footer.
///
/// The box is sized to its widest content and never wider than one column
/// short of [columns]. A row that reaches the last column soft-wraps into a
/// second terminal line, which makes the frame taller than the repaint
/// arithmetic expects and leaves stale copies of its top rows behind on every
/// refresh.
List<String> renderMenuRows<T>(
  List<MenuEntry<T>> entries, {
  required int selected,
  required String title,
  required String hint,
  required String? footer,
  required int columns,
  required MonitorTheme theme,
}) {
  final int maxWidth = columns > 1 ? columns - 1 : 1;
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

  // Entry content is width-independent, so it is built first and its widest
  // row sizes the box. Separators are rules across the frame, so they can only
  // be drawn once that width is known.
  final List<String?> contents = <String?>[
    for (int i = 0; i < entries.length; i++)
      entries[i].isSeparator
          ? null
          : _renderEntryContent<T>(
              entries[i],
              isSelected: i == selected,
              labelWidth: labelWidth,
              badgeWidth: badgeWidth,
              hasShortcuts: hasShortcuts,
              theme: theme,
            ),
  ];
  final String styledFooter = footer == null
      ? ''
      : _menuCallerText(footer, theme);
  // Headings and the title are drawn uppercased, so they are measured that way
  // too: uppercasing can change a string's length.
  final List<String> headings = <String>[
    for (final MenuEntry<T> entry in entries)
      entry.isSeparator ? entry.label.toUpperCase() : '',
  ];
  final String upperTitle = title.toUpperCase();

  int contentWidth = 0;
  void demand(int width) {
    if (width > contentWidth) {
      contentWidth = width;
    }
  }

  /// Width the frame needs for a run inlaid in a border rather than in a row:
  /// the border's own chrome and tail, less the side padding a row spends.
  int inlayDemand(String text) =>
      Ansi.visibleLength(text) +
      _menuInlayChromeWidth +
      _menuInlayTailWidth -
      _menuChromeWidth;

  for (int i = 0; i < entries.length; i++) {
    final String? content = contents[i];
    if (content != null) {
      demand(Ansi.visibleLength(content));
    } else if (headings[i].isNotEmpty) {
      demand(
        Ansi.visibleLength(headings[i]) +
            _menuRuleChromeWidth +
            _menuInlayTailWidth,
      );
    }
  }
  if (footer != null) {
    demand(Ansi.visibleLength(styledFooter));
  }
  demand(inlayDemand(upperTitle));
  demand(inlayDemand(hint));

  final int desired = contentWidth + _menuChromeWidth;
  final int width = desired > maxWidth ? maxWidth : desired;
  final int inner = width - _menuChromeWidth < 0 ? 0 : width - _menuChromeWidth;

  return <String>[
    _menuBorder(
      left: theme.glyphs.frameTl,
      right: theme.glyphs.frameTr,
      inlay: _menuInlay(upperTitle, '${theme.bold}${theme.textStrong}', theme),
      width: width,
      theme: theme,
    ),
    for (int i = 0; i < entries.length; i++)
      _menuFramedRow(
        contents[i] ??
            _menuSeparatorRow(headings[i], inner: inner, theme: theme),
        isSelected: contents[i] != null && i == selected,
        width: width,
        theme: theme,
      ),
    if (footer != null)
      _menuFramedRow(
        styledFooter,
        isSelected: false,
        width: width,
        theme: theme,
      ),
    _menuBorder(
      left: theme.glyphs.frameBl,
      right: theme.glyphs.frameBr,
      inlay: _menuInlay(hint, theme.faint, theme),
      width: width,
      theme: theme,
    ),
  ];
}

/// One entry's content, without the frame around it: marker, hotkey chip,
/// label, badge, and detail columns.
String _renderEntryContent<T>(
  MenuEntry<T> entry, {
  required bool isSelected,
  required int labelWidth,
  required int badgeWidth,
  required bool hasShortcuts,
  required MonitorTheme theme,
}) {
  final bool colorless = _isColorless(theme);
  final String marker = isSelected
      ? theme.paint(theme.glyphs.selector, '${theme.bold}${theme.accent}')
      : ' ';
  // Shortcut keys render as small [k] button chips, lit on the selected row;
  // menus without any shortcuts drop the column entirely.
  final String key = !hasShortcuts
      ? ''
      : entry.shortcut == null
      ? '    '
      : ' ${theme.paint('[', theme.faint)}'
            '${theme.paint(entry.shortcut!, isSelected ? theme.accent : theme.faint)}'
            '${theme.paint(']', theme.faint)}';
  final String? labelColor = colorless ? null : entry.labelColor;
  final String padded = Ansi.padVisible(entry.label, labelWidth);
  final String label = isSelected
      ? theme.paint(padded, '${theme.bold}${labelColor ?? theme.textStrong}')
      : labelColor == null
      ? theme.paint(padded, theme.text)
      : theme.paint(padded, labelColor);
  final StringBuffer line = StringBuffer('$marker$key  $label');
  if (entry.badge != null) {
    final String badge = Ansi.padVisible(entry.badge!, badgeWidth);
    line.write('  ');
    line.write(
      colorless ? badge : theme.paint(badge, entry.badgeColor ?? theme.faint),
    );
  } else if (badgeWidth > 0) {
    line.write('  ${' ' * badgeWidth}');
  }
  if (entry.detail != null && entry.detail!.isNotEmpty) {
    line.write('  ${_menuCallerText(entry.detail!, theme)}');
  }
  return line.toString();
}
