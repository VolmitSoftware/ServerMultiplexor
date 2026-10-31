import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/button.dart';
import 'package:multiplexor/utils/terminal/key_grid.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

const ButtonSpec _stop = ButtonSpec(id: 'stop', label: 'Stop', shortcut: 's');
const ButtonSpec _restart = ButtonSpec(
  id: 'restart',
  label: 'Restart',
  shortcut: 'r',
);
const ButtonSpec _console = ButtonSpec(
  id: 'console',
  label: 'Console',
  shortcut: 'c',
  enabled: false,
);
const ButtonSpec _delete = ButtonSpec(
  id: 'delete',
  label: 'Delete',
  shortcut: 'd',
  danger: true,
);

MonitorTheme _color() => MonitorTheme.detect(
  env: <String, String>{'COLORTERM': 'truecolor', 'TERM': 'xterm-256color'},
  isTty: true,
);

void main() {
  final MonitorTheme plain = MonitorTheme.plain();

  group('keyGridColumnWidths', () {
    test('sizes each column to its widest cell across every group', () {
      final List<int> widths = keyGridColumnWidths(<List<ButtonSpec>>[
        <ButtonSpec>[_stop, _restart, _console],
        <ButtonSpec>[_delete],
      ], 2);
      // Column 0 holds Stop, Console and Delete; column 1 holds Restart.
      expect(widths, <int>[
        keyGridCellWidth(_console),
        keyGridCellWidth(_restart),
      ]);
    });

    test('a cell is the marker, the key chip, and the label', () {
      expect(keyGridCellWidth(_stop), '▸ [s] Stop'.length);
    });
  });

  group('layoutKeyGridRow', () {
    test('renders aligned cells at exactly the given width', () {
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _restart],
        columnWidths: <int>[12, 14],
        width: 40,
        theme: plain,
      );
      expect(Ansi.visibleLength(render.row), 40);
      expect(render.row, startsWith('  [s] Stop      [r] Restart'));
    });

    test('marks the hovered cell with the selector glyph', () {
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _restart],
        columnWidths: <int>[12, 14],
        width: 40,
        theme: plain,
        hoveredId: 'restart',
      );
      expect(render.row, contains('▸ [r] Restart'));
      expect(render.row, startsWith('  [s] Stop'));
    });

    test('spans cover whole columns and skip disabled cells', () {
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _console, _delete],
        columnWidths: <int>[12, 14, 12],
        width: 60,
        theme: plain,
        gap: 2,
      );
      expect(render.spans.map((ButtonSpan span) => span.id), <String>[
        'stop',
        'delete',
      ]);
      expect(render.spans.first.colStart, 0);
      expect(render.spans.first.colEnd, 12);
      expect(render.spans.last.colStart, 12 + 2 + 14 + 2);
    });

    test('drops a cell whole rather than clipping it', () {
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _restart],
        columnWidths: <int>[12, 14],
        width: 20,
        theme: plain,
      );
      expect(render.row, isNot(contains('Restart')));
      expect(render.spans, hasLength(1));
    });

    test('paints the focused cell with the selection bar', () {
      final MonitorTheme theme = _color();
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _restart],
        columnWidths: <int>[12, 14],
        width: 40,
        theme: theme,
        hoveredId: 'stop',
      );
      expect(render.row, contains(theme.selectionBar));
      expect(Ansi.visibleLength(render.row), 40);
    });

    test('colors a danger label and fades a disabled one', () {
      final MonitorTheme theme = _color();
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_delete, _console],
        columnWidths: <int>[12, 13],
        width: 40,
        theme: theme,
      );
      expect(render.row, contains(theme.paint('Delete', theme.danger)));
      expect(render.row, contains(theme.paint('Console', theme.faint)));
    });

    test('a plain theme emits no escape bytes', () {
      final ButtonRowRender render = layoutKeyGridRow(
        buttons: <ButtonSpec>[_stop, _delete],
        columnWidths: <int>[12, 12],
        width: 30,
        theme: plain,
        hoveredId: 'stop',
      );
      expect(render.row, Ansi.strip(render.row));
    });
  });
}
