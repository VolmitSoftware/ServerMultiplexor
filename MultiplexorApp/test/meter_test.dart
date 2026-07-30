import 'package:multiplexor/utils/charts/meter.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  final MonitorTheme plain = MonitorTheme.plain();
  final MonitorTheme truecolor = MonitorTheme.detect(
    env: <String, String>{'COLORTERM': 'truecolor'},
    isTty: true,
  );

  group('renderMeter — visible width invariant', () {
    test('null fraction always occupies exactly cells columns', () {
      for (final int cells in <int>[0, 1, 5, 20]) {
        final String rendered = renderMeter(
          fraction: null,
          cells: cells,
          theme: truecolor,
        );
        expect(Ansi.visibleLength(rendered), cells);
      }
    });

    test(
      'every fraction across the unit range occupies exactly cells columns',
      () {
        for (final int cells in <int>[1, 3, 7, 10, 20]) {
          for (double fraction = 0; fraction <= 1; fraction += 0.05) {
            final String rendered = renderMeter(
              fraction: fraction,
              cells: cells,
              theme: truecolor,
            );
            expect(
              Ansi.visibleLength(rendered),
              cells,
              reason: 'fraction=$fraction cells=$cells rendered "$rendered"',
            );
          }
        }
      },
    );

    test('out-of-range fractions still occupy exactly cells columns', () {
      for (final double fraction in <double>[-5, -0.001, 1.001, 50]) {
        final String rendered = renderMeter(
          fraction: fraction,
          cells: 8,
          theme: truecolor,
        );
        expect(Ansi.visibleLength(rendered), 8);
      }
    });

    test('cells=0 renders the empty string regardless of fraction', () {
      expect(renderMeter(fraction: null, cells: 0, theme: plain), '');
      expect(renderMeter(fraction: 0.5, cells: 0, theme: plain), '');
    });
  });

  group('renderMeter — null fraction (missing data)', () {
    test('renders dash repeated cells times, painted faint', () {
      final String rendered = renderMeter(
        fraction: null,
        cells: 6,
        theme: plain,
      );
      expect(rendered, '–' * 6);
    });

    test('painted with the faint tone at truecolor depth', () {
      final String rendered = renderMeter(
        fraction: null,
        cells: 4,
        theme: truecolor,
      );
      expect(rendered, '${truecolor.faint}${'–' * 4}${truecolor.reset}');
    });

    test('never fabricates a zero-fraction bar', () {
      final String nullBar = renderMeter(
        fraction: null,
        cells: 6,
        theme: plain,
      );
      final String zeroBar = renderMeter(fraction: 0, cells: 6, theme: plain);
      expect(nullBar, isNot(zeroBar));
    });
  });

  group('renderMeter — full/track split', () {
    test('0.5 of 10 cells renders 5 full blocks then 5 track cells', () {
      final String rendered = renderMeter(
        fraction: 0.5,
        cells: 10,
        theme: plain,
      );
      expect(rendered, '█' * 5 + '─' * 5);
    });

    test('fraction 0 renders an all-track bar', () {
      final String rendered = renderMeter(
        fraction: 0.0,
        cells: 6,
        theme: plain,
      );
      expect(rendered, '─' * 6);
    });

    test('fraction 1 renders an all-full bar with no track', () {
      final String rendered = renderMeter(
        fraction: 1.0,
        cells: 6,
        theme: plain,
      );
      expect(rendered, '█' * 6);
    });

    test('fraction above 1 clamps to an all-full bar', () {
      final String rendered = renderMeter(
        fraction: 1.5,
        cells: 6,
        theme: plain,
      );
      expect(rendered, '█' * 6);
    });

    test('fraction below 0 clamps to an all-track bar', () {
      final String rendered = renderMeter(
        fraction: -0.5,
        cells: 6,
        theme: plain,
      );
      expect(rendered, '─' * 6);
    });
  });

  group('renderMeter — eighth-cell partial glyph', () {
    test(
      'fraction 1/16 with 1 cell yields partial index 0 -> no partial glyph, all track '
      '(overrides the naive guess that 1/16 renders a partial)',
      () {
        final String rendered = renderMeter(
          fraction: 1 / 16,
          cells: 1,
          theme: plain,
        );
        expect(rendered, '─');
      },
    );

    test(
      'fraction 0.2 with 1 cell yields partial index 1 -> first partial glyph',
      () {
        // exact = 0.2, full = 0, partialIndex = floor(0.2 * 8) = 1 -> meterPartial[0].
        final String rendered = renderMeter(
          fraction: 0.2,
          cells: 1,
          theme: plain,
        );
        expect(rendered, '▏');
      },
    );

    test('fraction 0.99 with 1 cell yields the highest partial glyph', () {
      // exact = 0.99, full = 0, partialIndex = floor(0.99 * 8) = 7 -> meterPartial[6].
      final String rendered = renderMeter(
        fraction: 0.99,
        cells: 1,
        theme: plain,
      );
      expect(rendered, '▉');
    });

    test('partial glyph never appears once the bar is already fully ink', () {
      // fraction exactly 1.0 -> full == cells, so no partial is possible even
      // though the formula would otherwise compute a nonzero remainder.
      final String rendered = renderMeter(
        fraction: 1.0,
        cells: 3,
        theme: plain,
      );
      expect(rendered.contains('▏'), isFalse);
      expect(rendered, '███');
    });

    test('a fractional fill combines full blocks with one partial glyph', () {
      // cells=4, fraction=0.55 -> exact=2.2, full=2, partialIndex=floor(0.2*8)=1.
      final String rendered = renderMeter(
        fraction: 0.55,
        cells: 4,
        theme: plain,
      );
      expect(rendered, '██▏─');
    });
  });

  group('renderMeter — tone painting', () {
    test(
      'the entire ink run (full + partial) is painted a single rampTone(ramp, fraction)',
      () {
        final String rendered = renderMeter(
          fraction: 0.55,
          cells: 4,
          theme: truecolor,
        );
        final String tone = truecolor.rampTone(MonitorRamp.load, 0.55);
        expect(
          rendered,
          '$tone██▏${truecolor.reset}${truecolor.faint}─${truecolor.reset}',
        );
      },
    );

    test('track is always painted faint, independent of ramp', () {
      final String rendered = renderMeter(
        fraction: 0.3,
        cells: 5,
        theme: truecolor,
      );
      expect(rendered.contains(truecolor.faint), isTrue);
    });

    test('defaults to MonitorRamp.load when ramp is omitted', () {
      final String withDefault = renderMeter(
        fraction: 0.8,
        cells: 5,
        theme: truecolor,
      );
      final String explicit = renderMeter(
        fraction: 0.8,
        cells: 5,
        theme: truecolor,
        ramp: MonitorRamp.load,
      );
      expect(withDefault, explicit);
    });

    test('a different ramp changes the ink tone', () {
      final String loadRendered = renderMeter(
        fraction: 0.8,
        cells: 5,
        theme: truecolor,
        ramp: MonitorRamp.load,
      );
      final String titleRendered = renderMeter(
        fraction: 0.8,
        cells: 5,
        theme: truecolor,
        ramp: MonitorRamp.title,
      );
      expect(loadRendered, isNot(titleRendered));
    });
  });

  // MonitorTheme currently exposes only plain() and detect(), both of which
  // hardcode MonitorGlyphs.unicode (Task 2's committed implementation) — there
  // is no public way to build a themed instance carrying MonitorGlyphs.ascii.
  // meterFillGlyphs() is the pure, color-free glyph-selection core renderMeter
  // itself calls, so the eighth-cell fill algorithm is verified directly
  // against MonitorGlyphs.ascii here without needing an ascii MonitorTheme.
  group('meterFillGlyphs — ascii glyph set', () {
    test('full/partial/track glyphs are all ASCII', () {
      final ({String ink, String track}) fill = meterFillGlyphs(
        fraction: 0.55,
        cells: 4,
        glyphs: MonitorGlyphs.ascii,
      );
      expect(
        '${fill.ink}${fill.track}'.codeUnits.every((int c) => c < 128),
        isTrue,
      );
    });

    test('uses the hash for both full and partial cells, dots for track', () {
      final ({String ink, String track}) fill = meterFillGlyphs(
        fraction: 0.55,
        cells: 4,
        glyphs: MonitorGlyphs.ascii,
      );
      expect(fill.ink, '###');
      // Dots, not hyphens: a hyphen run is what renderMeter draws when there
      // is no reading at all, so the unfilled part of a measured bar must not
      // use the same character.
      expect(fill.track, '.');
    });

    test('ink + track always spans exactly cells columns', () {
      for (final MonitorGlyphs glyphs in <MonitorGlyphs>[
        MonitorGlyphs.unicode,
        MonitorGlyphs.ascii,
      ]) {
        for (double fraction = 0; fraction <= 1; fraction += 0.1) {
          final ({String ink, String track}) fill = meterFillGlyphs(
            fraction: fraction,
            cells: 9,
            glyphs: glyphs,
          );
          expect(fill.ink.length + fill.track.length, 9);
        }
      }
    });
  });

  group('renderMeter — no reading is distinguishable from a measured zero', () {
    for (final (String name, MonitorTheme theme) in <(String, MonitorTheme)>[
      ('plain', MonitorTheme.plain()),
      ('plainAscii', MonitorTheme.plainAscii()),
    ]) {
      test('$name: a null fraction does not render as a zero-filled bar', () {
        // Both themes are colorless, so the bar itself has to carry the
        // difference. `runtime watch --once` picks plainAscii from the
        // locale, and a scripted reader cannot tell "no reading" from a
        // server measured at 0% if the two strings are equal.
        final String missing = renderMeter(
          fraction: null,
          cells: 12,
          theme: theme,
        );
        final String measuredZero = renderMeter(
          fraction: 0,
          cells: 12,
          theme: theme,
        );
        expect(missing, isNot(measuredZero));
        expect(Ansi.visibleLength(missing), 12);
        expect(Ansi.visibleLength(measuredZero), 12);
      });
    }
  });
}
