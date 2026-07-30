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

/// Strips only genuine trailing space characters from [text]. Unlike a
/// blind `trimRight()`, this only ever removes bytes that sit at the true
/// end of the string, so it can never reach into (or corrupt) an ANSI
/// escape sequence — a painted cell's trailing spaces are only stripped
/// when nothing (not even a reset code) follows them.
String _trimTrailingSpaces(String text) => text.replaceAll(RegExp(r' +$'), '');

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
/// whitespace: a left-aligned last column is emitted unpadded (so a short
/// or missing value contributes nothing), and any residual trailing
/// whitespace left by a blank right-aligned last column is trimmed from
/// the assembled line.
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

  String alignedCell(int columnIndex, String raw) {
    final TableColumn column = columns[columnIndex];
    final bool isLast = columnIndex == columnCount - 1;
    if (isLast && !column.alignRight) {
      return raw;
    }
    return column.alignRight
        ? _padLeft(raw, widths[columnIndex])
        : _padRight(raw, widths[columnIndex]);
  }

  String buildLine(List<String> cells, {required int rowIndex, required bool isHeader}) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < columnCount; i++) {
      if (i > 0) {
        buffer.write('  ');
      }
      final String raw = i < cells.length ? cells[i] : '';
      final String padded = alignedCell(i, raw);
      final String emitted =
          !isHeader && paintCell != null ? paintCell(i, rowIndex, padded) : padded;
      buffer.write(emitted);
    }
    return _trimTrailingSpaces(buffer.toString());
  }

  final List<String> headerCells = columns.map((TableColumn c) => c.header).toList();
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
