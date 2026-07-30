import 'package:multiplexor/utils/table.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:test/test.dart';

void main() {
  group('renderTable', () {
    const List<TableColumn> columns = <TableColumn>[
      TableColumn(header: 'NAME'),
      TableColumn(header: 'STATUS'),
      TableColumn(header: 'CPU', alignRight: true),
    ];
    final List<List<String>> rows = <List<String>>[
      <String>['alpha', 'running', '3.2'],
      <String>['bananarama', 'stopped', '12.75'],
    ];

    test('column widths fit the widest of header or cell, alignRight pads left', () {
      final List<String> lines = renderTable(
        columns: columns,
        rows: rows,
        bold: false,
      );
      expect(lines.length, 3);
      expect(lines[0], 'NAME        STATUS     CPU');
      expect(lines[1], 'alpha       running    3.2');
      expect(lines[2], 'bananarama  stopped  12.75');
    });

    test('bold wraps the header row in raw SGR bold codes', () {
      final List<String> lines = renderTable(columns: columns, rows: rows);
      expect(lines[0], '\x1B[1mNAME        STATUS     CPU\x1B[22m');
      expect(Ansi.strip(lines[0]), 'NAME        STATUS     CPU');
    });

    test('bold: false leaves the header row unstyled', () {
      final List<String> lines = renderTable(
        columns: columns,
        rows: rows,
        bold: false,
      );
      expect(lines[0], isNot(contains('\x1B[1m')));
    });

    test('paintCell only applies to body cells, never the header', () {
      final List<String> lines = renderTable(
        columns: columns,
        rows: rows,
        bold: false,
        paintCell: (int col, int row, String cell) => '<$cell>',
      );
      expect(lines[0], isNot(contains('<')));
      expect(lines[1], contains('<'));
      expect(lines[2], contains('<'));
    });

    test('paintCell receives the correct column and row indices', () {
      final List<List<int>> seenCols = <List<int>>[];
      renderTable(
        columns: columns,
        rows: rows,
        paintCell: (int col, int row, String cell) {
          seenCols.add(<int>[col, row]);
          return cell;
        },
      );
      expect(seenCols, <List<int>>[
        <int>[0, 0],
        <int>[1, 0],
        <int>[2, 0],
        <int>[0, 1],
        <int>[1, 1],
        <int>[2, 1],
      ]);
    });

    test('paintCell wrapping a padded cell does not break column alignment', () {
      final List<String> painted = renderTable(
        columns: columns,
        rows: rows,
        bold: false,
        paintCell: (int col, int row, String cell) => '\x1B[32m$cell\x1B[0m',
      );
      final List<String> plain = renderTable(
        columns: columns,
        rows: rows,
        bold: false,
      );
      for (int i = 0; i < painted.length; i++) {
        expect(Ansi.strip(painted[i]), plain[i]);
      }
    });

    test('no emitted line has trailing whitespace', () {
      final List<String> lines = renderTable(columns: columns, rows: rows);
      for (final String line in lines) {
        final String visibleOnly = Ansi.strip(line);
        expect(visibleOnly, equals(visibleOnly.trimRight()));
      }
    });

    test('no trailing whitespace even with a ragged short row and painted last cell', () {
      final List<String> lines = renderTable(
        columns: columns,
        rows: <List<String>>[
          <String>['alpha', 'running'],
        ],
        paintCell: (int col, int row, String cell) => cell,
      );
      for (final String line in lines) {
        expect(line, equals(line.trimRight()));
      }
    });

    test('rows shorter than the column count treat missing cells as empty', () {
      final List<String> lines = renderTable(
        columns: <TableColumn>[
          TableColumn(header: 'A'),
          TableColumn(header: 'B'),
          TableColumn(header: 'C'),
        ],
        rows: <List<String>>[
          <String>['x', 'y'],
        ],
        bold: false,
      );
      // C is missing (defaults to '') and is the last, left-aligned column,
      // so it and its preceding gutter contribute nothing to the line.
      expect(lines[1], 'x  y');
    });

    test('rows longer than the column count ignore extra cells', () {
      final List<String> lines = renderTable(
        columns: <TableColumn>[TableColumn(header: 'A'), TableColumn(header: 'B')],
        rows: <List<String>>[
          <String>['x', 'y', 'ignored', 'also ignored'],
        ],
        bold: false,
      );
      expect(lines[1], 'x  y');
    });

    test('exactly a two-space gutter separates columns with no leading or trailing pad', () {
      final List<String> lines = renderTable(
        columns: <TableColumn>[TableColumn(header: 'A'), TableColumn(header: 'B')],
        rows: <List<String>>[
          <String>['1', '2'],
        ],
        bold: false,
      );
      expect(lines[0], 'A  B');
      expect(lines[1], '1  2');
      expect(lines[0], isNot(startsWith(' ')));
    });

    test('ANSI escapes already present in a cell do not inflate its measured width', () {
      final List<String> lines = renderTable(
        columns: <TableColumn>[TableColumn(header: 'NAME'), TableColumn(header: 'X')],
        rows: <List<String>>[
          <String>['\x1B[31mred\x1B[0m', 'y'],
        ],
        bold: false,
      );
      // Visible "red" (3) is shorter than "NAME" (4), so column 0 stays
      // width 4 (4 + 2-space gutter + 1 for column 1 = 7 total) even though
      // the raw cell string is much longer than 4 characters.
      expect(Ansi.visibleLength(lines[0]), 7);
      expect(Ansi.visibleLength(lines[1]), 7);
      expect(lines[1], contains('\x1B[31mred\x1B[0m'));
    });

    test('an empty columns list renders no lines', () {
      final List<String> lines = renderTable(columns: <TableColumn>[], rows: <List<String>>[]);
      expect(lines, <String>[]);
    });

    test('an empty rows list renders only the header', () {
      final List<String> lines = renderTable(
        columns: <TableColumn>[TableColumn(header: 'A')],
        rows: <List<String>>[],
        bold: false,
      );
      expect(lines, <String>['A']);
    });
  });
}
