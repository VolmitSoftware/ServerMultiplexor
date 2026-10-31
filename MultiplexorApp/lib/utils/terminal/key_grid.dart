/// Keyed action grids: `▸ [k] Label` cells laid out in aligned columns, the
/// layout the dashboard's action cards use. A grid is a menu, so its focused
/// cell carries the theme's selection bar the way a prompt menu's row does.
///
/// Everything in this library is pure: no clock reads, no IO, no mutation.
library;

import 'ansi.dart';
import 'button.dart';
import 'theme.dart';

/// Columns a cell spends around its label: the marker, a space, the
/// three-column `[k]` key chip, and a space.
const int _cellChrome = 6;

/// The visible columns [button]'s cell needs.
int keyGridCellWidth(ButtonSpec button) => button.label.length + _cellChrome;

/// The widths of a grid that lays each of [groups] out row by row, at most
/// [columns] cells per row, with every group sharing one set of columns so
/// cells line up across groups. Each width is its column's widest cell; a
/// column no group reaches is left out.
List<int> keyGridColumnWidths(List<List<ButtonSpec>> groups, int columns) {
  final int count = columns < 1 ? 1 : columns;
  final List<int> widths = List<int>.filled(count, 0);
  for (final List<ButtonSpec> group in groups) {
    for (int index = 0; index < group.length; index++) {
      final int column = index % count;
      final int width = keyGridCellWidth(group[index]);
      if (width > widths[column]) widths[column] = width;
    }
  }
  return widths.where((int width) => width > 0).toList(growable: false);
}

/// The visible columns a grid of [columnWidths] spans with [gap] between
/// consecutive columns.
int keyGridWidth(List<int> columnWidths, {int gap = 2}) {
  if (columnWidths.isEmpty) return 0;
  return columnWidths.fold(0, (int total, int width) => total + width) +
      gap * (columnWidths.length - 1);
}

/// Lays [buttons] out as one grid row exactly [width] visible columns wide,
/// the n-th button in the n-th of [columnWidths], with [gap] spaces between
/// columns.
///
/// A cell that would not fit within [width] is dropped whole, along with
/// every cell after it. Each enabled cell gets a [ButtonSpan] covering its
/// whole column, so the click target is the column rather than the label. A
/// disabled cell renders faint and gets no span.
ButtonRowRender layoutKeyGridRow({
  required List<ButtonSpec> buttons,
  required List<int> columnWidths,
  required int width,
  required MonitorTheme theme,
  String? hoveredId,
  String? pressedId,
  int gap = 2,
}) {
  final int safeWidth = width < 0 ? 0 : width;
  final StringBuffer buffer = StringBuffer();
  final List<ButtonSpan> spans = <ButtonSpan>[];
  int cursor = 0;
  final int count = buttons.length < columnWidths.length
      ? buttons.length
      : columnWidths.length;
  for (int index = 0; index < count; index++) {
    final ButtonSpec button = buttons[index];
    final int gapBefore = index == 0 ? 0 : gap;
    final int start = cursor + gapBefore;
    final int end = start + columnWidths[index];
    if (end > safeWidth) break;
    buffer
      ..write(' ' * gapBefore)
      ..write(
        _renderCell(
          button,
          columnWidths[index],
          buttonStateFor(button, hoveredId, pressedId),
          theme,
        ),
      );
    if (button.enabled) {
      spans.add(ButtonSpan(id: button.id, colStart: start, colEnd: end));
    }
    cursor = end;
  }
  return ButtonRowRender(
    row: Ansi.padVisible(
      Ansi.clipVisible(buffer.toString(), safeWidth),
      safeWidth,
    ),
    spans: spans,
  );
}

/// One cell, padded to [width]: the marker (the selector glyph when focused),
/// the `[k]` key chip, and the label. A focused cell sits on the theme's
/// selection bar, re-asserted after every reset so it spans the whole cell.
String _renderCell(
  ButtonSpec button,
  int width,
  ButtonState state,
  MonitorTheme theme,
) {
  final bool focused =
      state == ButtonState.hover || state == ButtonState.pressed;
  final String keyTone = switch (state) {
    ButtonState.disabled => theme.faint,
    ButtonState.pressed => '${theme.bold}${theme.textStrong}',
    _ =>
      '${focused ? theme.bold : ''}'
          '${button.danger ? theme.danger : theme.accent}',
  };
  final String labelTone = switch (state) {
    ButtonState.disabled => theme.faint,
    ButtonState.pressed => '${theme.bold}${theme.textStrong}',
    ButtonState.hover =>
      '${theme.bold}${button.danger ? theme.danger : theme.textStrong}',
    ButtonState.normal => button.danger ? theme.danger : theme.text,
  };
  final String marker = focused
      ? theme.paint(theme.glyphs.selector, '${theme.bold}${theme.accent}')
      : ' ';
  final int slack = width - keyGridCellWidth(button);
  final String body =
      '$marker '
      '${theme.paint('[', theme.faint)}'
      '${theme.paint(button.shortcut ?? ' ', keyTone)}'
      '${theme.paint(']', theme.faint)} '
      '${theme.paint(button.label, labelTone)}'
      '${' ' * (slack < 0 ? 0 : slack)}';
  final String bar = focused ? theme.selectionBar : '';
  if (bar.isEmpty) return body;
  return '$bar${body.replaceAll(Ansi.reset, '${Ansi.reset}$bar')}${Ansi.reset}';
}
