import 'ansi.dart';
import 'theme.dart';

/// Visual emphasis for a panel's border, mapped to a theme border tone.
enum PanelEmphasis { normal, active, danger }

/// Resolves the border tone for [emphasis] from [theme].
String _borderTone(MonitorTheme theme, PanelEmphasis emphasis) {
  switch (emphasis) {
    case PanelEmphasis.normal:
      return theme.frame;
    case PanelEmphasis.active:
      return theme.frameActive;
    case PanelEmphasis.danger:
      return theme.danger;
  }
}

/// Clips [text] to at most [width] visible columns (never negative).
String _clip(String text, int width) => Ansi.clipVisible(text, width < 0 ? 0 : width);

/// Forces [text] to exactly [width] visible columns, clipping or padding as
/// needed. A defensive final step so every emitted row satisfies the width
/// invariant even at the narrow, arithmetically awkward widths.
String _forceWidth(String text, int width) {
  final int safe = width < 0 ? 0 : width;
  return Ansi.padVisible(Ansi.clipVisible(text, safe), safe);
}

/// Builds the top border: an inlaid title (and optional badge) between the
/// frame corners. Follows the layout:
/// - with badge:    `┌─ TITLE ` + `─`*fill + ` BADGE ─┐`
/// - without badge: `┌─ TITLE ` + `─`*fill + `┐`
///
/// If title and badge together overflow [width], the badge is dropped
/// first. If the title alone still overflows, it is clipped to fit
/// `width - 6`. Below width 8 there is no room for a readable inlaid title
/// at all, so a solid border is rendered instead.
String _buildTopBorder({
  required String title,
  required String? badge,
  required int width,
  required MonitorTheme theme,
  required String borderTone,
}) {
  final MonitorGlyphs glyphs = theme.glyphs;

  if (width < 8) {
    final String solid =
        '${glyphs.frameTl}${glyphs.frameH * (width - 2)}${glyphs.frameTr}';
    return _forceWidth(theme.paint(solid, borderTone), width);
  }

  final String titleTone = '${theme.bold}${theme.textStrong}';

  if (badge != null) {
    final int fill = width - 8 - Ansi.visibleLength(title) - Ansi.visibleLength(badge);
    if (fill >= 0) {
      final StringBuffer buffer = StringBuffer()
        ..write(theme.paint('${glyphs.frameTl}${glyphs.frameH} ', borderTone))
        ..write(theme.paint(title, titleTone))
        ..write(theme.paint(' ${glyphs.frameH * fill} ', borderTone))
        ..write(theme.paint(badge, theme.faint))
        ..write(theme.paint(' ${glyphs.frameH}${glyphs.frameTr}', borderTone));
      return _forceWidth(buffer.toString(), width);
    }
  }

  final String clippedTitle = _clip(title, width - 6);
  final int fill = width - 5 - Ansi.visibleLength(clippedTitle);
  final StringBuffer buffer = StringBuffer()
    ..write(theme.paint('${glyphs.frameTl}${glyphs.frameH} ', borderTone))
    ..write(theme.paint(clippedTitle, titleTone))
    ..write(theme.paint(' ${glyphs.frameH * (fill < 0 ? 0 : fill)}', borderTone))
    ..write(theme.paint(glyphs.frameTr, borderTone));
  return _forceWidth(buffer.toString(), width);
}

/// Renders a titled panel box: a top border with the title (and optional
/// badge) inlaid, [content] rows wrapped between vertical rules, and a
/// plain bottom border. Every row of the result is exactly [width] visible
/// columns; the result always has `content.length + 2` rows.
///
/// At `width <= 2` there is no room for corners or an inlaid title at all,
/// so every row (including content rows) collapses to a solid run of the
/// horizontal frame glyph.
List<String> renderPanel({
  required String title,
  String? badge,
  required List<String> content,
  required int width,
  required MonitorTheme theme,
  PanelEmphasis emphasis = PanelEmphasis.normal,
}) {
  final int safeWidth = width < 0 ? 0 : width;
  final String borderTone = _borderTone(theme, emphasis);
  final MonitorGlyphs glyphs = theme.glyphs;

  if (safeWidth <= 2) {
    final String row = _forceWidth(
      theme.paint(glyphs.frameH * safeWidth, borderTone),
      safeWidth,
    );
    return List<String>.generate(content.length + 2, (int _) => row);
  }

  final List<String> rows = <String>[
    _buildTopBorder(
      title: title,
      badge: badge,
      width: safeWidth,
      theme: theme,
      borderTone: borderTone,
    ),
  ];

  final int innerWidth = safeWidth - 4 < 0 ? 0 : safeWidth - 4;
  final String frameV = theme.paint(glyphs.frameV, borderTone);
  for (final String line in content) {
    final String padded = Ansi.padVisible(_clip(line, innerWidth), innerWidth);
    rows.add(_forceWidth('$frameV $padded $frameV', safeWidth));
  }

  final String bottom =
      '${glyphs.frameBl}${glyphs.frameH * (safeWidth - 2)}${glyphs.frameBr}';
  rows.add(_forceWidth(theme.paint(bottom, borderTone), safeWidth));

  return rows;
}

/// Pads or clips every row of [block] to exactly [width] visible columns.
List<String> padBlock(List<String> block, int width) {
  final int safeWidth = width < 0 ? 0 : width;
  return block
      .map((String row) => Ansi.padVisible(_clip(row, safeWidth), safeWidth))
      .toList();
}

/// Joins [blocks] side by side, separated by [gap]. Each block is first
/// normalized to its own max visible row width, then all blocks are padded
/// to the tallest block's height with all-spaces rows appended at the
/// bottom, before rows are joined column-wise.
List<String> joinBlocks(List<List<String>> blocks, {String gap = ' '}) {
  if (blocks.isEmpty) {
    return <String>[];
  }

  final List<int> widths = blocks.map((List<String> block) {
    int maxWidth = 0;
    for (final String row in block) {
      final int visible = Ansi.visibleLength(row);
      if (visible > maxWidth) {
        maxWidth = visible;
      }
    }
    return maxWidth;
  }).toList();

  int tallest = 0;
  for (final List<String> block in blocks) {
    if (block.length > tallest) {
      tallest = block.length;
    }
  }

  final List<List<String>> normalized = <List<String>>[];
  for (int i = 0; i < blocks.length; i++) {
    final List<String> padded = padBlock(blocks[i], widths[i]);
    while (padded.length < tallest) {
      padded.add(' ' * widths[i]);
    }
    normalized.add(padded);
  }

  final List<String> result = <String>[];
  for (int row = 0; row < tallest; row++) {
    final StringBuffer buffer = StringBuffer();
    for (int b = 0; b < normalized.length; b++) {
      if (b > 0) {
        buffer.write(gap);
      }
      buffer.write(normalized[b][row]);
    }
    result.add(buffer.toString());
  }
  return result;
}
