import 'terminal/ansi.dart';

/// A single table column: its header text and alignment. Column width is
/// always measured, never fixed — the widest visible cell (header or body)
/// in the column determines it.
class TableColumn {
  const TableColumn({required this.header, this.alignRight = false});

  final String header;
  final bool alignRight;
}

/// Right-pads (left-aligns) [text] to [width] visible columns.
String _padRight(String text, int width) => Ansi.padVisible(text, width);

/// Left-pads (right-aligns) [text] to [width] visible columns.
String _padLeft(String text, int width) {
  final int visible = Ansi.visibleLength(text);
  if (visible >= width) {
    return text;
  }
  return (' ' * (width - visible)) + text;
}

/// Index of the rightmost cell in [cells] (over [columnCount] columns,
/// missing trailing cells treated as `''`) with nonzero visible length, or
/// `-1` if every cell is blank.
///
/// Columns after this index are omitted from the emitted line entirely —
/// no padding, no gutter, and critically no [renderTable]'s `paintCell`
/// call — which is what keeps a blank trailing cell from ever producing
/// trailing whitespace. A post-hoc string trim cannot do this safely: a
/// real painter wraps its cell in escape codes (e.g. a trailing reset), so
/// any trailing padding spaces end up *inside* the painted string, not at
/// its true end, and a trim anchored to the string's end can't reach them
/// without risking corruption of legitimate styling on real content.
int _lastVisibleIndex(List<String> cells, int columnCount) {
  for (int i = columnCount - 1; i >= 0; i--) {
    final String raw = i < cells.length ? cells[i] : '';
    if (Ansi.visibleLength(raw) > 0) {
      return i;
    }
  }
  return -1;
}

/// Renders a plain-text table: [columns] sized to the widest visible
/// header or cell, a 2-space gutter between (never before or after)
/// columns, and an optional [paintCell] applied to body cells after they
/// are padded so painting never shifts column alignment.
///
/// This module has no theme dependency: [bold] wraps the header row in raw
/// SGR bold/unbold codes (`\x1B[1m`…`\x1B[22m`), not a [MonitorTheme] tone.
///
/// Rows shorter than [columns] treat missing cells as `''`; rows longer
/// than [columns] ignore the extra cells. No emitted line carries trailing
/// whitespace: trailing blank cells (missing or `''`) are omitted from the
/// line entirely — including their gutter and any [paintCell] call — and
/// the rightmost remaining cell is treated as the row's last column for
/// alignment purposes, so a left-aligned one is emitted unpadded.
List<String> renderTable({
  required List<TableColumn> columns,
  required List<List<String>> rows,
  String Function(int columnIndex, int rowIndex, String cell)? paintCell,
  bool bold = true,
}) {
  if (columns.isEmpty) {
    return <String>[];
  }

  final int columnCount = columns.length;
  final List<int> widths = List<int>.generate(columnCount, (int i) {
    int width = Ansi.visibleLength(columns[i].header);
    for (final List<String> row in rows) {
      final String cell = i < row.length ? row[i] : '';
      final int visible = Ansi.visibleLength(cell);
      if (visible > width) {
        width = visible;
      }
    }
    return width;
  });

  String alignedCell(
    int columnIndex,
    String raw, {
    required bool isLastRendered,
  }) {
    final TableColumn column = columns[columnIndex];
    if (isLastRendered && !column.alignRight) {
      return raw;
    }
    return column.alignRight
        ? _padLeft(raw, widths[columnIndex])
        : _padRight(raw, widths[columnIndex]);
  }

  String buildLine(
    List<String> cells, {
    required int rowIndex,
    required bool isHeader,
  }) {
    final int lastVisible = _lastVisibleIndex(cells, columnCount);
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i <= lastVisible; i++) {
      if (i > 0) {
        buffer.write('  ');
      }
      final String raw = i < cells.length ? cells[i] : '';
      final String padded = alignedCell(
        i,
        raw,
        isLastRendered: i == lastVisible,
      );
      final String emitted = !isHeader && paintCell != null
          ? paintCell(i, rowIndex, padded)
          : padded;
      buffer.write(emitted);
    }
    return buffer.toString();
  }

  final List<String> headerCells = columns
      .map((TableColumn c) => c.header)
      .toList();
  String headerLine = buildLine(headerCells, rowIndex: -1, isHeader: true);
  if (bold) {
    headerLine = '\x1B[1m$headerLine\x1B[22m';
  }

  final List<String> output = <String>[headerLine];
  for (int r = 0; r < rows.length; r++) {
    output.add(buildLine(rows[r], rowIndex: r, isHeader: false));
  }
  return output;
}
