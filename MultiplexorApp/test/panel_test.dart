import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/panel.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  final MonitorTheme plain = MonitorTheme.plain();

  group('renderPanel', () {
    test('every row is exactly width visible columns across many widths', () {
      for (final int width in <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 20, 40]) {
        final List<String> rows = renderPanel(
          title: 'STATUS',
          badge: '3',
          content: <String>['one', 'two row', ''],
          width: width,
          theme: plain,
        );
        for (final String row in rows) {
          expect(
            Ansi.visibleLength(row),
            width < 0 ? 0 : width,
            reason: 'width=$width row="$row"',
          );
        }
      }
    });

    test('total row count is content.length + 2', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        content: <String>['a', 'b', 'c', 'd'],
        width: 30,
        theme: plain,
      );
      expect(rows.length, 6);
    });

    test('no badge omits the badge segment from the top border', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        content: <String>[],
        width: 30,
        theme: plain,
      );
      expect(rows.first, '┌─ HOSTS ────────────────────┐');
    });

    test('badge is right-aligned against the closing corner', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        badge: '3/5',
        content: <String>[],
        width: 30,
        theme: plain,
      );
      final String top = rows.first;
      expect(top, endsWith(' 3/5 ─┐'));
      expect(top.startsWith('┌─ HOSTS '), isTrue);
    });

    test('title is rendered verbatim without case transformation', () {
      final List<String> rows = renderPanel(
        title: 'lower title',
        content: <String>[],
        width: 30,
        theme: plain,
      );
      expect(rows.first, contains('lower title'));
    });

    test(
      'when title plus badge overflow, the badge is dropped before the title is clipped',
      () {
        // "VERY LONG TITLE HERE" is 21 chars; with an 8-char badge and an
        // 8-char frame budget (┌─  ─┐ scaffolding, 8 chars) that needs 37
        // visible columns total to keep both intact. At width 33 there is
        // room for the full (unclipped) title once the badge is dropped,
        // but not room for both title and badge together.
        const String title = 'VERY LONG TITLE HERE';
        const String badge = 'BADGE123';
        final List<String> withBoth = renderPanel(
          title: title,
          badge: badge,
          content: <String>[],
          width: 33,
          theme: plain,
        );
        final List<String> withoutBadge = renderPanel(
          title: title,
          content: <String>[],
          width: 33,
          theme: plain,
        );

        expect(withBoth.first, withoutBadge.first);
        expect(withBoth.first, contains(title));
        expect(withBoth.first, isNot(contains(badge)));
      },
    );

    test(
      'when even the bare title overflows, the title itself is clipped',
      () {
        const String title = 'AN EXTREMELY LONG PANEL TITLE THAT CANNOT FIT';
        final List<String> rows = renderPanel(
          title: title,
          content: <String>[],
          width: 20,
          theme: plain,
        );
        final String top = rows.first;
        expect(Ansi.visibleLength(top), 20);
        expect(top, isNot(contains(title)));
        // Clipped title budget is width - 6.
        final String expectedClip = Ansi.clipVisible(title, 20 - 6);
        expect(top, contains(Ansi.strip(expectedClip)));
      },
    );

    test('content rows are wrapped and clipped/padded to width - 4', () {
      final List<String> rows = renderPanel(
        title: 'X',
        content: <String>['hi', 'a very long row that will need to be clipped'],
        width: 20,
        theme: plain,
      );
      expect(rows[1], startsWith('│ '));
      expect(rows[1], endsWith(' │'));
      expect(Ansi.visibleLength(rows[1]), 20);
    });

    test('bottom border spans the full width between corners', () {
      final List<String> rows = renderPanel(
        title: 'X',
        content: <String>['a'],
        width: 16,
        theme: plain,
      );
      expect(rows.last, '└──────────────┘');
    });

    test('widths of 2 or less render content-free frame-glyph rows', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        content: <String>['a', 'b'],
        width: 2,
        theme: plain,
      );
      expect(rows.length, 4);
      for (final String row in rows) {
        expect(row, '──');
      }
    });

    test('width of 1 renders a single frame glyph column per row', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        content: <String>[],
        width: 1,
        theme: plain,
      );
      for (final String row in rows) {
        expect(row, '─');
      }
    });

    test('width below 8 renders a solid border with no title', () {
      final List<String> rows = renderPanel(
        title: 'HOSTS',
        content: <String>[],
        width: 7,
        theme: plain,
      );
      expect(rows.first, '┌─────┐');
      expect(rows.first, isNot(contains('H')));
    });

    test('ascii glyph set is honored for borders', () {
      final List<String> rows = renderPanel(
        title: 'X',
        content: <String>['a'],
        width: 10,
        theme: MonitorTheme.plainAscii(),
      );
      expect(rows.first.startsWith('+-'), isTrue);
      expect(rows.last, '+--------+');
    });

    group('emphasis tones', () {
      final MonitorTheme truecolor = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );

      test('normal emphasis paints the border with the frame tone', () {
        final List<String> rows = renderPanel(
          title: 'X',
          content: <String>['a'],
          width: 20,
          theme: truecolor,
        );
        expect(rows.first, contains(truecolor.frame));
        expect(rows.last, contains(truecolor.frame));
      });

      test('active emphasis paints the border with the frameActive tone', () {
        final List<String> rows = renderPanel(
          title: 'X',
          content: <String>['a'],
          width: 20,
          theme: truecolor,
          emphasis: PanelEmphasis.active,
        );
        expect(rows.first, contains(truecolor.frameActive));
        expect(rows.last, contains(truecolor.frameActive));
      });

      test('danger emphasis paints the border with the danger tone', () {
        final List<String> rows = renderPanel(
          title: 'X',
          content: <String>['a'],
          width: 20,
          theme: truecolor,
          emphasis: PanelEmphasis.danger,
        );
        expect(rows.first, contains(truecolor.danger));
        expect(rows.last, contains(truecolor.danger));
      });

      test('title is painted textStrong and bold', () {
        final List<String> rows = renderPanel(
          title: 'X',
          content: <String>[],
          width: 20,
          theme: truecolor,
        );
        expect(rows.first, contains(truecolor.textStrong));
        expect(rows.first, contains(truecolor.bold));
      });

      test('badge is painted faint', () {
        final List<String> rows = renderPanel(
          title: 'X',
          badge: 'B',
          content: <String>[],
          width: 20,
          theme: truecolor,
        );
        expect(rows.first, contains(truecolor.faint));
      });
    });
  });

  group('joinBlocks', () {
    test('an empty list of blocks yields an empty result', () {
      expect(joinBlocks(<List<String>>[]), <String>[]);
    });

    test('a 3-row and a 5-row block combine into 5 rows', () {
      final List<List<String>> blocks = <List<String>>[
        <String>['aa', 'bb', 'cc'],
        <String>['1', '2', '3', '4', '5'],
      ];
      final List<String> joined = joinBlocks(blocks);
      expect(joined.length, 5);
    });

    test('shorter blocks are padded at the bottom with all-spaces rows', () {
      final List<List<String>> blocks = <List<String>>[
        <String>['aa', 'bb', 'cc'],
        <String>['1', '2', '3', '4', '5'],
      ];
      final List<String> joined = joinBlocks(blocks);
      expect(joined[0], 'aa 1');
      expect(joined[2], 'cc 3');
      expect(joined[3], '   4');
      expect(joined[4], '   5');
    });

    test('rows are joined with the default single-space gap', () {
      final List<String> joined = joinBlocks(<List<String>>[
        <String>['left'],
        <String>['right'],
      ]);
      expect(joined, <String>['left right']);
    });

    test('a custom gap string is honored', () {
      final List<String> joined = joinBlocks(<List<String>>[
        <String>['left'],
        <String>['right'],
      ], gap: ' | ');
      expect(joined, <String>['left | right']);
    });

    test('each block is normalized to its own max visible row width', () {
      final List<List<String>> blocks = <List<String>>[
        <String>['a', 'bbb'],
        <String>['X'],
      ];
      final List<String> joined = joinBlocks(blocks);
      expect(joined[0], 'a   X');
      expect(joined[1], 'bbb  ');
    });
  });

  group('padBlock', () {
    test('short rows are padded with trailing spaces to exact width', () {
      final List<String> result = padBlock(<String>['ab', 'a'], 5);
      expect(result, <String>['ab   ', 'a    ']);
    });

    test('long rows are clipped to exact width', () {
      final List<String> result = padBlock(<String>['abcdefgh'], 4);
      expect(result, <String>['abcd']);
    });

    test('every row in the result has exactly the requested visible width', () {
      final List<String> result = padBlock(<String>['', 'x', 'longer row'], 6);
      for (final String row in result) {
        expect(Ansi.visibleLength(row), 6);
      }
    });
  });
}
