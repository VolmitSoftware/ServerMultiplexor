import 'package:multiplexor/utils/charts/sparkline.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

String _glyphAt(String ramp, int index) => ramp.substring(index, index + 1);

void main() {
  final MonitorTheme plain = MonitorTheme.plain();
  final MonitorTheme truecolor = MonitorTheme.detect(
    env: <String, String>{'COLORTERM': 'truecolor'},
    isTty: true,
  );

  group('renderSparkline — visible width invariant', () {
    test('width <= 0 always renders the empty string', () {
      for (final int width in <int>[0, -1, -20]) {
        expect(
          renderSparkline(
            values: <double?>[1, 2, 3],
            width: width,
            theme: truecolor,
          ),
          '',
        );
        expect(
          renderSparkline(values: <double?>[], width: width, theme: truecolor),
          '',
        );
      }
    });

    test('empty values with a positive width still occupies width columns', () {
      final String rendered = renderSparkline(
        values: <double?>[],
        width: 6,
        theme: truecolor,
      );
      expect(Ansi.visibleLength(rendered), 6);
    });

    test('an all-null series occupies width columns', () {
      final String rendered = renderSparkline(
        values: <double?>[null, null, null],
        width: 3,
        theme: truecolor,
      );
      expect(Ansi.visibleLength(rendered), 3);
    });

    test('fewer samples than width occupies width columns', () {
      final String rendered = renderSparkline(
        values: <double?>[1, 2],
        width: 7,
        theme: truecolor,
      );
      expect(Ansi.visibleLength(rendered), 7);
    });

    test('samples equal to width occupies width columns', () {
      final String rendered = renderSparkline(
        values: <double?>[1, 2, 3, 4],
        width: 4,
        theme: truecolor,
      );
      expect(Ansi.visibleLength(rendered), 4);
    });

    test('more samples than width occupies width columns', () {
      final String rendered = renderSparkline(
        values: List<double?>.generate(97, (int i) => i.toDouble()),
        width: 12,
        theme: truecolor,
      );
      expect(Ansi.visibleLength(rendered), 12);
    });

    test(
      'mixed null/real samples of every size relationship occupy width columns',
      () {
        final List<List<double?>> cases = <List<double?>>[
          <double?>[],
          <double?>[null],
          <double?>[1, null, 3],
          <double?>[1, null, 3, null, 5, 6, 7, 8, 9, 10],
        ];
        for (final List<double?> values in cases) {
          for (final int width in <int>[1, 3, 5, 10]) {
            final String rendered = renderSparkline(
              values: values,
              width: width,
              theme: truecolor,
            );
            expect(
              Ansi.visibleLength(rendered),
              width,
              reason: 'values=$values width=$width rendered="$rendered"',
            );
          }
        }
      },
    );
  });

  group('renderSparkline — empty and all-gap input', () {
    test('empty values renders every cell as the gap glyph, painted faint', () {
      final String rendered = renderSparkline(
        values: <double?>[],
        width: 4,
        theme: plain,
      );
      expect(rendered, '····');
    });

    test('all-null values renders every cell as the gap glyph', () {
      final String rendered = renderSparkline(
        values: <double?>[null, null, null],
        width: 3,
        theme: plain,
      );
      expect(rendered, '···');
    });

    test('gap cells are painted faint at truecolor depth', () {
      final String rendered = renderSparkline(
        values: <double?>[],
        width: 2,
        theme: truecolor,
      );
      expect(
        rendered,
        '${truecolor.faint}·${truecolor.reset}${truecolor.faint}·${truecolor.reset}',
      );
    });
  });

  group('renderSparkline — right-alignment when fewer samples than width', () {
    test('pads gaps on the left; the most recent sample lands rightmost', () {
      // 2 samples into 5 cells: 3 leading gaps, then the data at the right edge.
      final String rendered = renderSparkline(
        values: <double?>[1, 5],
        width: 5,
        theme: plain,
      );
      expect(rendered, '···${'▁'}${'█'}');
    });

    test('a single sample lands on the final cell', () {
      final String rendered = renderSparkline(
        values: <double?>[3],
        width: 4,
        theme: plain,
        min: 0,
        max: 10,
      );
      expect(rendered, '···${_glyphAt(MonitorGlyphs.unicode.spark, 2)}');
    });
  });

  group('renderSparkline — flat data', () {
    test(
      'zero-span data renders the middle spark level for every non-null cell',
      () {
        final String rendered = renderSparkline(
          values: <double?>[5, 5, 5],
          width: 3,
          theme: plain,
        );
        final String mid = _glyphAt(MonitorGlyphs.unicode.spark, 3);
        expect(rendered, mid * 3);
      },
    );

    test(
      'a single non-null sample (trivially flat) renders the middle level',
      () {
        final String rendered = renderSparkline(
          values: <double?>[42],
          width: 1,
          theme: plain,
        );
        expect(rendered, _glyphAt(MonitorGlyphs.unicode.spark, 3));
      },
    );

    test('flat data is painted at ramp fraction 0.5', () {
      final String rendered = renderSparkline(
        values: <double?>[5, 5],
        width: 2,
        theme: truecolor,
      );
      final String tone = truecolor.rampTone(MonitorRamp.load, 0.5);
      final String glyph = _glyphAt(MonitorGlyphs.unicode.spark, 3);
      expect(
        rendered,
        '$tone$glyph${truecolor.reset}$tone$glyph${truecolor.reset}',
      );
    });
  });

  group('renderSparkline — null gaps mixed with real data', () {
    test('a null sample renders the gap glyph at its own position', () {
      final String rendered = renderSparkline(
        values: <double?>[1, null, 3],
        width: 3,
        theme: plain,
      );
      expect(
        rendered,
        '${_glyphAt(MonitorGlyphs.unicode.spark, 0)}·${_glyphAt(MonitorGlyphs.unicode.spark, 7)}',
      );
    });

    test('a bucket with zero non-null members renders as a gap', () {
      // width=2 downsamples [null, null, 5, 5]: bucket 0 = [null, null] (gap),
      // bucket 1 = [5, 5] (flat, mid level).
      final String rendered = renderSparkline(
        values: <double?>[null, null, 5, 5],
        width: 2,
        theme: plain,
      );
      expect(rendered, '·${_glyphAt(MonitorGlyphs.unicode.spark, 3)}');
    });

    test('never fabricates a value for a missing sample', () {
      final String withGap = renderSparkline(
        values: <double?>[1, null, 3],
        width: 3,
        theme: plain,
      );
      final String withZero = renderSparkline(
        values: <double?>[1, 0, 3],
        width: 3,
        theme: plain,
      );
      expect(withGap, isNot(withZero));
    });
  });

  group('renderSparkline — min/max override the data extent', () {
    test('explicit min/max change the level selected for the same values', () {
      final String autoScaled = renderSparkline(
        values: <double?>[0, 10],
        width: 2,
        theme: plain,
      );
      final String fixedScaled = renderSparkline(
        values: <double?>[0, 10],
        width: 2,
        theme: plain,
        min: 0,
        max: 100,
      );
      expect(autoScaled, isNot(fixedScaled));
      expect(
        fixedScaled.substring(0, 1),
        _glyphAt(MonitorGlyphs.unicode.spark, 0),
      );
    });

    test('values outside min/max clamp into range rather than overflowing', () {
      final String rendered = renderSparkline(
        values: <double?>[-50, 500],
        width: 2,
        theme: plain,
        min: 0,
        max: 100,
      );
      expect(
        rendered,
        '${_glyphAt(MonitorGlyphs.unicode.spark, 0)}${_glyphAt(MonitorGlyphs.unicode.spark, 7)}',
      );
    });
  });

  group('renderSparkline — downsampling aggregate', () {
    test('mean and max diverge on a bucket containing a spike', () {
      // n=6 into width=2: bucket0=[0,0,0], bucket1=[10,0,0].
      final List<double?> values = <double?>[0, 0, 0, 10, 0, 0];
      final String meanRendered = renderSparkline(
        values: values,
        width: 2,
        theme: plain,
        min: 0,
        max: 10,
      );
      final String maxRendered = renderSparkline(
        values: values,
        width: 2,
        theme: plain,
        min: 0,
        max: 10,
        aggregate: SparkAggregate.max,
      );
      expect(meanRendered, isNot(maxRendered));
      expect(
        meanRendered,
        '${_glyphAt(MonitorGlyphs.unicode.spark, 0)}${_glyphAt(MonitorGlyphs.unicode.spark, 2)}',
      );
      expect(
        maxRendered,
        '${_glyphAt(MonitorGlyphs.unicode.spark, 0)}${_glyphAt(MonitorGlyphs.unicode.spark, 7)}',
      );
    });

    test(
      'last picks the final non-null sample in the bucket, distinct from mean and max',
      () {
        final List<double?> values = <double?>[5, 1, 2];
        final String lastRendered = renderSparkline(
          values: values,
          width: 1,
          theme: plain,
          min: 0,
          max: 5,
          aggregate: SparkAggregate.last,
        );
        final String meanRendered = renderSparkline(
          values: values,
          width: 1,
          theme: plain,
          min: 0,
          max: 5,
        );
        final String maxRendered = renderSparkline(
          values: values,
          width: 1,
          theme: plain,
          min: 0,
          max: 5,
          aggregate: SparkAggregate.max,
        );
        expect(lastRendered, isNot(meanRendered));
        expect(lastRendered, isNot(maxRendered));
        expect(maxRendered, _glyphAt(MonitorGlyphs.unicode.spark, 7));
      },
    );

    test('last skips trailing nulls to find the final real sample', () {
      final String rendered = renderSparkline(
        values: <double?>[1, 9, null, null],
        width: 1,
        theme: plain,
        min: 0,
        max: 10,
        aggregate: SparkAggregate.last,
      );
      // last non-null = 9; fraction 9/10 = 0.9 -> round(0.9 * 7) = round(6.3) = 6.
      expect(rendered, _glyphAt(MonitorGlyphs.unicode.spark, 6));
    });
  });

  group('renderSparkline — per-cell tone', () {
    test('each non-null cell is painted rampTone(load, fraction)', () {
      final String rendered = renderSparkline(
        values: <double?>[0, 10],
        width: 2,
        theme: truecolor,
        min: 0,
        max: 10,
      );
      final String low = truecolor.rampTone(MonitorRamp.load, 0);
      final String high = truecolor.rampTone(MonitorRamp.load, 1);
      expect(
        rendered,
        '$low${_glyphAt(MonitorGlyphs.unicode.spark, 0)}${truecolor.reset}'
        '$high${_glyphAt(MonitorGlyphs.unicode.spark, 7)}${truecolor.reset}',
      );
    });
  });

  // MonitorTheme exposes only plain() and detect(), both hardcoded to
  // MonitorGlyphs.unicode (Task 2's committed implementation) — there is no
  // public way to build a themed instance carrying MonitorGlyphs.ascii.
  // sparklineCell() is the pure, color-free level-selection core
  // renderSparkline itself calls, so it is verified directly against
  // MonitorGlyphs.ascii here without needing an ascii MonitorTheme.
  group('sparklineCell — ascii glyph set', () {
    test('a missing sample renders the ascii gap glyph', () {
      final ({String glyph, double fraction}) cell = sparklineCell(
        value: null,
        low: 0,
        high: 10,
        glyphs: MonitorGlyphs.ascii,
      );
      expect(cell.glyph, MonitorGlyphs.ascii.sparkGap);
    });

    test('level selection stays within the ascii spark ramp', () {
      for (double value = 0; value <= 10; value += 1) {
        final ({String glyph, double fraction}) cell = sparklineCell(
          value: value,
          low: 0,
          high: 10,
          glyphs: MonitorGlyphs.ascii,
        );
        expect(MonitorGlyphs.ascii.spark.contains(cell.glyph), isTrue);
      }
    });

    test('flat data renders the middle ascii spark level at fraction 0.5', () {
      final ({String glyph, double fraction}) cell = sparklineCell(
        value: 5,
        low: 5,
        high: 5,
        glyphs: MonitorGlyphs.ascii,
      );
      expect(cell.glyph, _glyphAt(MonitorGlyphs.ascii.spark, 3));
      expect(cell.fraction, 0.5);
    });

    test('both glyph sets pick the same level index for the same fraction', () {
      final ({String glyph, double fraction}) unicodeCell = sparklineCell(
        value: 7,
        low: 0,
        high: 10,
        glyphs: MonitorGlyphs.unicode,
      );
      final ({String glyph, double fraction}) asciiCell = sparklineCell(
        value: 7,
        low: 0,
        high: 10,
        glyphs: MonitorGlyphs.ascii,
      );
      final int unicodeIndex = MonitorGlyphs.unicode.spark.indexOf(
        unicodeCell.glyph,
      );
      final int asciiIndex = MonitorGlyphs.ascii.spark.indexOf(asciiCell.glyph);
      expect(unicodeIndex, asciiIndex);
    });
  });

  group('renderSparkline — gaps are distinguishable from measured lows', () {
    for (final (String name, MonitorTheme theme) in <(String, MonitorTheme)>[
      ('plain', MonitorTheme.plain()),
      ('plainAscii', MonitorTheme.plainAscii()),
    ]) {
      test('$name: an all-null series differs from an all-zero series', () {
        // The TPS sparkline in a server row is pinned to 0..20, so a server
        // measured at 0 TPS lands on level 0. That is a real reading and must
        // not look like the gap drawn for a sample that never arrived.
        final String gaps = renderSparkline(
          values: <double?>[null, null, null, null],
          theme: theme,
          width: 4,
          min: 0,
          max: 20,
        );
        final String zeros = renderSparkline(
          values: <double?>[0, 0, 0, 0],
          theme: theme,
          width: 4,
          min: 0,
          max: 20,
        );
        expect(gaps, isNot(zeros));
        expect(Ansi.visibleLength(gaps), 4);
        expect(Ansi.visibleLength(zeros), 4);
      });
    }
  });
}
