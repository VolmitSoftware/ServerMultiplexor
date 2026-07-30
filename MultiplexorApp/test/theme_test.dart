import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

/// Every single-width [MonitorGlyphs] field, by name, for both glyph sets.
Map<String, String> _singleWidthFields(MonitorGlyphs glyphs) =>
    <String, String>{
      'frameTl': glyphs.frameTl,
      'frameTr': glyphs.frameTr,
      'frameBl': glyphs.frameBl,
      'frameBr': glyphs.frameBr,
      'frameH': glyphs.frameH,
      'frameV': glyphs.frameV,
      'axisTick': glyphs.axisTick,
      'axisBase': glyphs.axisBase,
      'grid': glyphs.grid,
      'event': glyphs.event,
      'latest': glyphs.latest,
      'selector': glyphs.selector,
      'bulletOn': glyphs.bulletOn,
      'bulletOff': glyphs.bulletOff,
      'sparkGap': glyphs.sparkGap,
      'meterFull': glyphs.meterFull,
      'meterTrack': glyphs.meterTrack,
      'dash': glyphs.dash,
    };

void main() {
  group('detectColorDepth', () {
    test('NO_COLOR wins even when other hints suggest truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'NO_COLOR': '', 'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(depth, ColorDepth.none);
    });

    test('NO_COLOR wins with a non-empty value too', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'NO_COLOR': '1'},
        isTty: true,
      );
      expect(depth, ColorDepth.none);
    });

    test('TERM=dumb forces none', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'dumb'},
        isTty: true,
      );
      expect(depth, ColorDepth.none);
    });

    test('isTty=false forces none regardless of env hints', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: false,
      );
      expect(depth, ColorDepth.none);
    });

    test('COLORTERM=truecolor yields truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'xterm', 'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(depth, ColorDepth.truecolor);
    });

    test('COLORTERM=24bit yields truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'COLORTERM': '24bit'},
        isTty: true,
      );
      expect(depth, ColorDepth.truecolor);
    });

    test('FORCE_COLOR=3 yields truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'FORCE_COLOR': '3'},
        isTty: true,
      );
      expect(depth, ColorDepth.truecolor);
    });

    test('TERM=alacritty yields truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'alacritty'},
        isTty: true,
      );
      expect(depth, ColorDepth.truecolor);
    });

    test('TERM ending in -truecolor yields truecolor', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'tmux-truecolor'},
        isTty: true,
      );
      expect(depth, ColorDepth.truecolor);
    });

    test('TERM=xterm-256color yields ansi256', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      expect(depth, ColorDepth.ansi256);
    });

    test('plain xterm falls back to basic', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{'TERM': 'xterm'},
        isTty: true,
      );
      expect(depth, ColorDepth.basic);
    });

    test('no TERM at all falls back to basic', () {
      final ColorDepth depth = detectColorDepth(
        env: <String, String>{},
        isTty: true,
      );
      expect(depth, ColorDepth.basic);
    });
  });

  group('MonitorGlyphs.ascii', () {
    test('every single-width field is pure ASCII', () {
      _singleWidthFields(MonitorGlyphs.ascii).forEach((
        String name,
        String value,
      ) {
        expect(
          value.codeUnits.every((int c) => c < 128),
          isTrue,
          reason: '$name should be ASCII, was "$value"',
        );
      });
    });

    test('spark is 8 ASCII characters', () {
      expect(MonitorGlyphs.ascii.spark.length, 8);
      expect(
        MonitorGlyphs.ascii.spark.codeUnits.every((int c) => c < 128),
        isTrue,
      );
    });

    test('meterPartial has 7 uniform ASCII entries', () {
      expect(MonitorGlyphs.ascii.meterPartial.length, 7);
      expect(MonitorGlyphs.ascii.meterPartial.toSet(), <String>{'#'});
    });

    test('spinner has 4 ASCII frames matching the classic bar spinner', () {
      expect(MonitorGlyphs.ascii.spinner, <String>['|', '/', '-', '\\']);
    });

    test('dash is a plain ASCII hyphen', () {
      expect(MonitorGlyphs.ascii.dash, '-');
    });

    test('isAscii distinguishes the ascii set from the unicode set', () {
      expect(MonitorGlyphs.ascii.isAscii, isTrue);
      expect(MonitorGlyphs.unicode.isAscii, isFalse);
    });
  });

  group('MonitorGlyphs — missing data never collides with a measured zero', () {
    // The ascii set has no color to fall back on (it is only ever paired with
    // ColorDepth.none), so these separations have to hold in the glyph itself.
    for (final (String name, MonitorGlyphs glyphs) in <(String, MonitorGlyphs)>[
      ('ascii', MonitorGlyphs.ascii),
      ('unicode', MonitorGlyphs.unicode),
    ]) {
      test('$name: the spark gap differs from the lowest spark level', () {
        expect(
          glyphs.sparkGap,
          isNot(glyphs.spark.substring(0, 1)),
          reason:
              'a missing sample and a measured value at the bottom of the '
              'range would render as the same character',
        );
      });

      test('$name: the dash differs from the meter track', () {
        expect(
          glyphs.meterTrack,
          isNot(glyphs.dash),
          reason:
              'a meter with no reading and a measured-zero meter would render '
              'as the same run of characters',
        );
      });
    }
  });

  group('MonitorGlyphs single-width invariant', () {
    test(
      'every single-width field of both glyph sets is exactly one visible column',
      () {
        for (final MonitorGlyphs glyphs in <MonitorGlyphs>[
          MonitorGlyphs.unicode,
          MonitorGlyphs.ascii,
        ]) {
          _singleWidthFields(glyphs).forEach((String name, String value) {
            expect(
              Ansi.visibleLength(value),
              1,
              reason: '$name ("$value") should be one visible column',
            );
          });
        }
      },
    );

    test('spark is 8 characters for both glyph sets', () {
      expect(MonitorGlyphs.unicode.spark.length, 8);
      expect(MonitorGlyphs.ascii.spark.length, 8);
    });

    test('meterPartial has 7 entries for both glyph sets', () {
      expect(MonitorGlyphs.unicode.meterPartial.length, 7);
      expect(MonitorGlyphs.ascii.meterPartial.length, 7);
    });

    test('spinner has 4 entries for both glyph sets', () {
      expect(MonitorGlyphs.unicode.spinner.length, 4);
      expect(MonitorGlyphs.ascii.spinner.length, 4);
    });
  });

  group('MonitorGlyphs.unicode', () {
    test('dash is an en dash', () {
      expect(MonitorGlyphs.unicode.dash, '–');
    });

    test('selector is a filled triangle', () {
      expect(MonitorGlyphs.unicode.selector, '▸');
    });

    test('bullets distinguish on/off state', () {
      expect(MonitorGlyphs.unicode.bulletOn, '●');
      expect(MonitorGlyphs.unicode.bulletOff, '○');
    });
  });

  group('MonitorTheme.plain', () {
    test('uses ColorDepth.none', () {
      expect(MonitorTheme.plain().depth, ColorDepth.none);
    });

    test('uses unicode glyphs', () {
      expect(MonitorTheme.plain().glyphs, same(MonitorGlyphs.unicode));
    });

    test(
      'emits zero escape bytes across every tone, gradientTitle, and rampTone',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        final StringBuffer everything = StringBuffer()
          ..write(theme.frame)
          ..write(theme.frameActive)
          ..write(theme.text)
          ..write(theme.textStrong)
          ..write(theme.faint)
          ..write(theme.muted)
          ..write(theme.ok)
          ..write(theme.warn)
          ..write(theme.crit)
          ..write(theme.accent)
          ..write(theme.info)
          ..write(theme.danger)
          ..write(theme.reset)
          ..write(theme.bold)
          ..write(theme.dim)
          ..write(theme.gradientTitle('MULTIPLEXOR'))
          ..write(theme.rampTone(MonitorRamp.load, 0))
          ..write(theme.rampTone(MonitorRamp.load, 0.5))
          ..write(theme.rampTone(MonitorRamp.load, 1))
          ..write(theme.rampTone(MonitorRamp.title, 0))
          ..write(theme.rampTone(MonitorRamp.title, 0.5))
          ..write(theme.rampTone(MonitorRamp.title, 1));
        expect(everything.toString().contains('\x1B'), isFalse);
      },
    );

    test('gradientTitle returns the raw text unchanged', () {
      expect(MonitorTheme.plain().gradientTitle('MULTIPLEXOR'), 'MULTIPLEXOR');
    });
  });

  group('MonitorTheme.plainAscii', () {
    test('uses ColorDepth.none', () {
      expect(MonitorTheme.plainAscii().depth, ColorDepth.none);
    });

    test('uses the ascii glyph set', () {
      expect(MonitorTheme.plainAscii().glyphs, same(MonitorGlyphs.ascii));
      expect(MonitorTheme.plainAscii().glyphs.isAscii, isTrue);
    });

    test('emits zero escape bytes across every tone and glyph', () {
      final MonitorTheme theme = MonitorTheme.plainAscii();
      final StringBuffer everything = StringBuffer()
        ..write(theme.frame)
        ..write(theme.textStrong)
        ..write(theme.faint)
        ..write(theme.accent)
        ..write(theme.info)
        ..write(theme.reset)
        ..write(theme.dim)
        ..write(theme.gradientTitle('MULTIPLEXOR'))
        ..write(theme.rampTone(MonitorRamp.load, 0.5))
        ..writeAll(_singleWidthFields(theme.glyphs).values);
      final String rendered = everything.toString();
      expect(rendered.contains('\x1B'), isFalse);
      expect(rendered.codeUnits.every((int code) => code < 128), isTrue);
    });
  });

  group('MonitorTheme.detect', () {
    test('resolves depth from the supplied env and isTty', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      expect(theme.depth, ColorDepth.ansi256);
    });

    test('respects NO_COLOR', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'NO_COLOR': '1', 'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(theme.depth, ColorDepth.none);
    });

    test('uses unicode glyphs', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      expect(theme.glyphs, same(MonitorGlyphs.unicode));
    });
  });

  group('MonitorTheme tones — no backgrounds ever', () {
    test('no truecolor tone or ramp string paints a background', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      final List<String> tones = <String>[
        theme.frame,
        theme.frameActive,
        theme.text,
        theme.textStrong,
        theme.faint,
        theme.muted,
        theme.ok,
        theme.warn,
        theme.crit,
        theme.accent,
        theme.info,
        theme.danger,
        theme.gradientTitle('MULTIPLEXOR'),
        for (double f = 0; f <= 1; f += 0.25)
          theme.rampTone(MonitorRamp.load, f),
        for (double f = 0; f <= 1; f += 0.25)
          theme.rampTone(MonitorRamp.title, f),
      ];
      for (final String tone in tones) {
        expect(
          tone.contains('[48;'),
          isFalse,
          reason: 'unexpected background in "$tone"',
        );
      }
    });
  });

  group('MonitorTheme tone encoding by depth', () {
    test('truecolor tones use 38;2 rgb escapes', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(theme.ok, Ansi.fgRgb(79, 191, 123));
      expect(theme.crit, Ansi.fgRgb(224, 82, 92));
    });

    test('ansi256 tones use 38;5 indexed escapes', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      expect(theme.ok, Ansi.fg256(78));
      expect(theme.crit, Ansi.fg256(167));
    });

    test('basic tones use plain 3x escapes', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm'},
        isTty: true,
      );
      expect(theme.ok, '\x1B[32m');
      expect(theme.crit, '\x1B[31m');
    });

    test('basic bright tones use 9x escapes', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm'},
        isTty: true,
      );
      expect(theme.frame, '\x1B[90m');
      expect(theme.textStrong, '\x1B[97m');
    });

    test('none tones are empty strings', () {
      final MonitorTheme theme = MonitorTheme.plain();
      expect(theme.ok, '');
      expect(theme.crit, '');
      expect(theme.reset, '');
      expect(theme.bold, '');
      expect(theme.dim, '');
    });

    test('frameActive mirrors accent at every depth', () {
      for (final MonitorTheme theme in <MonitorTheme>[
        MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        ),
        MonitorTheme.detect(
          env: <String, String>{'TERM': 'xterm-256color'},
          isTty: true,
        ),
        MonitorTheme.detect(
          env: <String, String>{'TERM': 'xterm'},
          isTty: true,
        ),
      ]) {
        expect(theme.frameActive, theme.accent);
      }
    });
  });

  group('MonitorTheme.rampTone', () {
    test('clamps fractions below 0 to the first stop', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(
        theme.rampTone(MonitorRamp.load, -5),
        theme.rampTone(MonitorRamp.load, 0),
      );
    });

    test('clamps fractions above 1 to the last stop', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(
        theme.rampTone(MonitorRamp.load, 5),
        theme.rampTone(MonitorRamp.load, 1),
      );
    });

    test('rampTone(load, 1.0) equals the crit encoding at truecolor depth', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(theme.rampTone(MonitorRamp.load, 1.0), theme.crit);
    });

    test('rampTone(load, 1.0) equals the crit encoding at ansi256 depth', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      expect(theme.rampTone(MonitorRamp.load, 1.0), theme.crit);
    });

    test('rampTone(load, 1.0) equals the crit encoding at basic depth', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm'},
        isTty: true,
      );
      expect(theme.rampTone(MonitorRamp.load, 1.0), theme.crit);
    });

    test(
      'rampTone(load, 1.0) equals the crit encoding at none depth (both empty)',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        expect(theme.rampTone(MonitorRamp.load, 1.0), theme.crit);
        expect(theme.rampTone(MonitorRamp.load, 1.0), '');
      },
    );

    test(
      'rampTone(load, 0.0) is the calm end of the ramp, distinct from crit',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        );
        expect(theme.rampTone(MonitorRamp.load, 0.0), isNot(theme.crit));
        expect(theme.rampTone(MonitorRamp.load, 0.0), Ansi.fgRgb(59, 158, 143));
      },
    );
  });

  group('MonitorTheme.statusTone', () {
    late MonitorTheme theme;

    setUp(() {
      theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
    });

    test('running maps to ok', () {
      expect(theme.statusTone(RuntimeState.running), theme.ok);
    });

    test('starting maps to warn', () {
      expect(theme.statusTone(RuntimeState.starting), theme.warn);
    });

    test('stopping maps to warn', () {
      expect(theme.statusTone(RuntimeState.stopping), theme.warn);
    });

    test('restarting maps to warn', () {
      expect(theme.statusTone(RuntimeState.restarting), theme.warn);
    });

    test('stopped maps to faint', () {
      expect(theme.statusTone(RuntimeState.stopped), theme.faint);
    });
  });

  group('MonitorTheme.tpsTone', () {
    late MonitorTheme theme;

    setUp(() {
      theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
    });

    test('null tps maps to faint', () {
      expect(theme.tpsTone(null), theme.faint);
    });

    test('tps at or above 18 maps to ok', () {
      expect(theme.tpsTone(20.0), theme.ok);
      expect(theme.tpsTone(18.0), theme.ok);
    });

    test('tps between 15 and 18 maps to warn', () {
      expect(theme.tpsTone(17.9), theme.warn);
      expect(theme.tpsTone(15.0), theme.warn);
    });

    test('tps below 15 maps to crit', () {
      expect(theme.tpsTone(14.9), theme.crit);
      expect(theme.tpsTone(0.0), theme.crit);
    });
  });

  group('MonitorTheme.paint', () {
    test('returns text unchanged when tone is empty', () {
      final MonitorTheme theme = MonitorTheme.plain();
      expect(theme.paint('hello', ''), 'hello');
    });

    test(
      'wraps text with tone and a trailing reset when tone is non-empty',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        );
        expect(
          theme.paint('hello', theme.ok),
          '${theme.ok}hello${theme.reset}',
        );
      },
    );
  });

  group('MonitorTheme.gradientTitle', () {
    test('returns text unchanged at ColorDepth.none', () {
      expect(MonitorTheme.plain().gradientTitle('MULTIPLEXOR'), 'MULTIPLEXOR');
    });

    test(
      'at basic depth is bold + textStrong with no per-run gradient, then a reset',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'TERM': 'xterm'},
          isTty: true,
        );
        final String rendered = theme.gradientTitle('MULTIPLEXOR');
        expect(
          rendered,
          '${theme.bold}${theme.textStrong}MULTIPLEXOR${theme.reset}',
        );
      },
    );

    test(
      'at truecolor depth is bold, ends with reset, and preserves the visible text',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        );
        final String rendered = theme.gradientTitle('MULTIPLEXOR');
        expect(rendered.startsWith(theme.bold), isTrue);
        expect(rendered.endsWith(theme.reset), isTrue);
        expect(Ansi.strip(rendered), 'MULTIPLEXOR');
      },
    );

    test(
      'at truecolor depth uses more than one distinct color run for long text',
      () {
        final MonitorTheme theme = MonitorTheme.detect(
          env: <String, String>{'COLORTERM': 'truecolor'},
          isTty: true,
        );
        final String rendered = theme.gradientTitle('MULTIPLEXOR');
        final int rgbRunCount = RegExp(
          r'\x1B\[38;2;',
        ).allMatches(rendered).length;
        expect(rgbRunCount, greaterThan(1));
      },
    );

    test('at ansi256 depth uses indexed color runs', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'TERM': 'xterm-256color'},
        isTty: true,
      );
      final String rendered = theme.gradientTitle('MULTIPLEXOR');
      expect(rendered.contains('\x1B[38;5;'), isTrue);
      expect(Ansi.strip(rendered), 'MULTIPLEXOR');
    });

    test('handles text shorter than the ramp without throwing', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(Ansi.strip(theme.gradientTitle('HI')), 'HI');
    });

    test('handles empty text without throwing', () {
      final MonitorTheme theme = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      expect(Ansi.strip(theme.gradientTitle('')), '');
    });
  });

  group('ToneToken', () {
    test('stores rgb, ansi256, basic, and bright', () {
      const ToneToken token = ToneToken(
        rgb: <int>[1, 2, 3],
        ansi256: 42,
        basic: 5,
        bright: true,
      );
      expect(token.rgb, <int>[1, 2, 3]);
      expect(token.ansi256, 42);
      expect(token.basic, 5);
      expect(token.bright, isTrue);
    });

    test('bright defaults to false', () {
      const ToneToken token = ToneToken(
        rgb: <int>[1, 2, 3],
        ansi256: 42,
        basic: 5,
      );
      expect(token.bright, isFalse);
    });
  });
}
