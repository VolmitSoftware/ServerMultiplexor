import 'dart:io';

import 'package:multiplexor/services/runtime_state.dart';

import 'ansi.dart';

/// Terminal color capability, from no color at all through 24-bit truecolor.
enum ColorDepth { none, basic, ansi256, truecolor }

/// Named color ramps used for continuous data (load) and the brand wordmark.
enum MonitorRamp { load, title }

/// Resolves the terminal color depth from the environment. Never guesses up:
/// an unrecognized or absent hint falls back to the safest usable depth.
///
/// Detection order:
/// 1. Not a TTY, `NO_COLOR` present (any value, per the NO_COLOR spec), or
///    `TERM=dumb` -> [ColorDepth.none].
/// 2. `FORCE_COLOR=3`, `COLORTERM` matching `truecolor`/`24bit`, or `TERM`
///    matching `kitty`/`alacritty`/`wezterm`/`-truecolor` -> [ColorDepth.truecolor].
/// 3. `TERM` containing `256color` -> [ColorDepth.ansi256].
/// 4. Otherwise -> [ColorDepth.basic].
ColorDepth detectColorDepth({
  required Map<String, String> env,
  required bool isTty,
}) {
  final String term = env['TERM'] ?? '';
  if (!isTty || env.containsKey('NO_COLOR') || term == 'dumb') {
    return ColorDepth.none;
  }
  final String colorTerm = env['COLORTERM'] ?? '';
  if (env['FORCE_COLOR'] == '3' ||
      RegExp('truecolor|24bit', caseSensitive: false).hasMatch(colorTerm) ||
      RegExp(
        'kitty|alacritty|wezterm|-truecolor',
        caseSensitive: false,
      ).hasMatch(term)) {
    return ColorDepth.truecolor;
  }
  if (term.contains('256color')) {
    return ColorDepth.ansi256;
  }
  return ColorDepth.basic;
}

/// Locale values naming a UTF-8 charset, in either of its two spellings.
final RegExp _utf8Charset = RegExp('utf-?8', caseSensitive: false);

/// The locale variables that decide a process's charset, in POSIX
/// precedence order: the first one that is set wins outright.
const List<String> _localeVars = <String>['LC_ALL', 'LC_CTYPE', 'LANG'];

/// Resolves the glyph set the terminal can actually render.
///
/// The charset comes from the locale, read in POSIX precedence order
/// ([_localeVars]): the first variable that is set and non-empty decides,
/// so `LC_ALL=C` forces ASCII even alongside a UTF-8 `LANG`. A value naming
/// a UTF-8 charset (either spelling, any case) gets
/// [MonitorGlyphs.unicode]; any other value gets [MonitorGlyphs.ascii].
///
/// With no locale set at all the charset is genuinely unknown, so this falls
/// back to [isTty]: an interactive terminal gets unicode (a modern terminal
/// with an unset locale — under launchd, or a bare `ssh` — is far more
/// likely to render it than not), while captured or piped output gets ASCII,
/// where the cost of guessing wrong is a file of mojibake nobody can grep.
MonitorGlyphs detectMonitorGlyphs({
  required Map<String, String> env,
  required bool isTty,
}) {
  for (final String key in _localeVars) {
    final String value = env[key] ?? '';
    if (value.isEmpty) {
      continue;
    }
    return _utf8Charset.hasMatch(value)
        ? MonitorGlyphs.unicode
        : MonitorGlyphs.ascii;
  }
  return isTty ? MonitorGlyphs.unicode : MonitorGlyphs.ascii;
}

/// A single tri-encoded color: a truecolor RGB triple, an ANSI 256-color
/// index, and a hand-authored 16-color (basic) fallback. Basic fallbacks are
/// authored per-token rather than computed, so structural greys and hued
/// data tones stay visually distinct even on a 3-bit terminal.
class ToneToken {
  const ToneToken({
    required this.rgb,
    required this.ansi256,
    required this.basic,
    this.bright = false,
  });

  /// Truecolor components, `[r, g, b]`, each 0-255.
  final List<int> rgb;

  /// Index into the 256-color palette.
  final int ansi256;

  /// Basic (16-color) index, 0-7 (combined with [bright] to pick 3x/9x).
  final int basic;

  /// Whether the basic-mode encoding uses the bright (9x) variant.
  final bool bright;
}

/// Encodes [token] as an SGR foreground escape for [depth]. Never emits a
/// background sequence and never emits any bytes at [ColorDepth.none].
String _encodeTone(ToneToken token, ColorDepth depth) {
  switch (depth) {
    case ColorDepth.truecolor:
      return Ansi.fgRgb(token.rgb[0], token.rgb[1], token.rgb[2]);
    case ColorDepth.ansi256:
      return Ansi.fg256(token.ansi256);
    case ColorDepth.basic:
      return token.bright ? '\x1B[9${token.basic}m' : '\x1B[3${token.basic}m';
    case ColorDepth.none:
      return '';
  }
}

/// Palette tones: structure (frame/text/faint/muted) stays neutral grey,
/// only data and state tones (ok/warn/crit/accent/info/danger) carry hue.
/// `frameActive` intentionally mirrors `accent` (an active frame border is
/// the same brand hue as the accent tone).
class _Palette {
  _Palette._();

  static const ToneToken frame = ToneToken(
    rgb: <int>[98, 104, 112],
    ansi256: 242,
    basic: 0,
    bright: true,
  );
  static const ToneToken text = ToneToken(
    rgb: <int>[222, 226, 232],
    ansi256: 253,
    basic: 7,
  );
  static const ToneToken textStrong = ToneToken(
    rgb: <int>[240, 244, 250],
    ansi256: 255,
    basic: 7,
    bright: true,
  );
  static const ToneToken faint = ToneToken(
    rgb: <int>[130, 136, 144],
    ansi256: 245,
    basic: 0,
    bright: true,
  );
  static const ToneToken muted = ToneToken(
    rgb: <int>[160, 166, 174],
    ansi256: 248,
    basic: 7,
  );
  static const ToneToken ok = ToneToken(
    rgb: <int>[79, 191, 123],
    ansi256: 78,
    basic: 2,
  );
  static const ToneToken warn = ToneToken(
    rgb: <int>[216, 163, 46],
    ansi256: 179,
    basic: 3,
  );
  static const ToneToken crit = ToneToken(
    rgb: <int>[224, 82, 92],
    ansi256: 167,
    basic: 1,
  );
  static const ToneToken accent = ToneToken(
    rgb: <int>[64, 196, 222],
    ansi256: 45,
    basic: 6,
  );
  static const ToneToken frameActive = accent;
  static const ToneToken info = ToneToken(
    rgb: <int>[96, 145, 235],
    ansi256: 69,
    basic: 4,
  );
  static const ToneToken danger = ToneToken(
    rgb: <int>[209, 86, 138],
    ansi256: 168,
    basic: 5,
  );
}

/// Ramp stops for [MonitorRamp]. Basic-mode codes are authored (not
/// distance-computed) so the load ramp's saturated end matches `crit`
/// exactly and the title ramp stays within the brand's cyan-to-blue hues.
class _Ramps {
  _Ramps._();

  /// Reads as a temperature: calm teal/green through to a saturated red.
  /// The final stop is deliberately identical to [_Palette.crit].
  static const List<ToneToken> load = <ToneToken>[
    ToneToken(rgb: <int>[59, 158, 143], ansi256: 72, basic: 2),
    ToneToken(rgb: <int>[72, 178, 133], ansi256: 78, basic: 2),
    ToneToken(rgb: <int>[121, 192, 100], ansi256: 113, basic: 2),
    ToneToken(rgb: <int>[180, 200, 70], ansi256: 149, basic: 3),
    ToneToken(rgb: <int>[216, 190, 50], ansi256: 178, basic: 3),
    ToneToken(rgb: <int>[227, 166, 60], ansi256: 214, basic: 3),
    ToneToken(rgb: <int>[230, 124, 60], ansi256: 208, basic: 1),
    ToneToken(rgb: <int>[224, 82, 92], ansi256: 167, basic: 1),
  ];

  /// Brand wordmark ramp: cyan through to blue.
  static const List<ToneToken> title = <ToneToken>[
    ToneToken(rgb: <int>[0, 255, 255], ansi256: 51, basic: 6),
    ToneToken(rgb: <int>[0, 255, 215], ansi256: 50, basic: 6),
    ToneToken(rgb: <int>[0, 215, 255], ansi256: 45, basic: 6),
    ToneToken(rgb: <int>[0, 175, 255], ansi256: 44, basic: 6),
    ToneToken(rgb: <int>[0, 135, 255], ansi256: 39, basic: 6),
    ToneToken(rgb: <int>[0, 95, 255], ansi256: 38, basic: 4),
    ToneToken(rgb: <int>[0, 95, 215], ansi256: 33, basic: 4),
  ];

  static List<ToneToken> forRamp(MonitorRamp ramp) => switch (ramp) {
    MonitorRamp.load => load,
    MonitorRamp.title => title,
  };
}

/// The full glyph set used to draw frames, meters, sparklines, and status
/// markers. Every single-width field renders as exactly one terminal
/// column; [spark] is an 8-character intensity ramp and [meterPartial] is a
/// 7-entry sub-cell fill ramp.
class MonitorGlyphs {
  const MonitorGlyphs({
    required this.frameTl,
    required this.frameTr,
    required this.frameBl,
    required this.frameBr,
    required this.frameH,
    required this.frameV,
    required this.axisTick,
    required this.axisBase,
    required this.grid,
    required this.event,
    required this.latest,
    required this.selector,
    required this.bulletOn,
    required this.bulletOff,
    required this.sparkGap,
    required this.meterFull,
    required this.meterTrack,
    required this.dash,
    required this.spark,
    required this.meterPartial,
    required this.spinner,
  });

  final String frameTl;
  final String frameTr;
  final String frameBl;
  final String frameBr;
  final String frameH;
  final String frameV;
  final String axisTick;
  final String axisBase;
  final String grid;
  final String event;
  final String latest;
  final String selector;
  final String bulletOn;
  final String bulletOff;
  final String sparkGap;
  final String meterFull;
  final String meterTrack;

  /// Placeholder for a missing value in meters and rows.
  final String dash;

  /// 8-step sparkline intensity ramp, low to high.
  final String spark;

  /// 7-step sub-cell meter fill ramp, low to high.
  final List<String> meterPartial;

  /// 4-frame busy spinner.
  final List<String> spinner;

  /// Whether this is the ASCII-only glyph set. Renderers that change their
  /// geometry (not just their characters) when unicode is unavailable — the
  /// braille chart drops from a 2x4 sub-cell grid to 1x1 — branch on this.
  bool get isAscii => identical(this, MonitorGlyphs.ascii);

  static const MonitorGlyphs unicode = MonitorGlyphs(
    frameTl: '┌',
    frameTr: '┐',
    frameBl: '└',
    frameBr: '┘',
    frameH: '─',
    frameV: '│',
    axisTick: '┤',
    axisBase: '└',
    grid: '·',
    event: '┊',
    latest: '◆',
    selector: '▸',
    bulletOn: '●',
    bulletOff: '○',
    sparkGap: '·',
    meterFull: '█',
    meterTrack: '─',
    dash: '–',
    spark: '▁▂▃▄▅▆▇█',
    meterPartial: <String>['▏', '▎', '▍', '▌', '▋', '▊', '▉'],
    spinner: <String>['◴', '◷', '◶', '◵'],
  );

  static const MonitorGlyphs ascii = MonitorGlyphs(
    frameTl: '+',
    frameTr: '+',
    frameBl: '+',
    frameBr: '+',
    frameH: '-',
    frameV: '|',
    axisTick: '+',
    axisBase: '+',
    grid: '.',
    event: ':',
    latest: '*',
    selector: '>',
    bulletOn: '*',
    bulletOff: 'o',
    sparkGap: '.',
    meterFull: '#',
    // Not the dash: an empty meter is a *measured* zero and a dash run is
    // "no reading at all". This set is only ever used at ColorDepth.none, so
    // there is no color left to tell them apart.
    meterTrack: '.',
    dash: '-',
    // Starts at '_' rather than '.' for the same reason: '.' is the gap glyph
    // for a sample that never arrived, so it cannot also be the bottom of the
    // measured range.
    spark: '_-~=+*#@',
    meterPartial: <String>['#', '#', '#', '#', '#', '#', '#'],
    spinner: <String>['|', '/', '-', '\\'],
  );
}

/// Clamps [value] into the inclusive `0..1` range.
double _clampUnit(double value) {
  if (value < 0) {
    return 0.0;
  }
  if (value > 1) {
    return 1.0;
  }
  return value;
}

/// Full visual theme for the monitoring dashboard: a resolved [ColorDepth],
/// a [MonitorGlyphs] set, and every tone/ramp accessor later tasks render
/// with. Color is a data channel, not decoration: only [ok]/[warn]/[crit]/
/// [accent]/[info]/[danger] and the ramps carry hue — [frame], [text],
/// [faint], and [muted] stay neutral grey.
class MonitorTheme {
  const MonitorTheme._(this.depth, this.glyphs);

  final ColorDepth depth;
  final MonitorGlyphs glyphs;

  /// Resolves both the color depth ([detectColorDepth]) and the glyph set
  /// ([detectMonitorGlyphs]) from [env] and [isTty], defaulting to the real
  /// process environment and terminal state when either is omitted.
  ///
  /// The two are independent: a truecolor terminal under a `C` locale gets
  /// full color and ASCII glyphs, and a UTF-8 terminal under `NO_COLOR` gets
  /// the unicode set with no color at all.
  factory MonitorTheme.detect({Map<String, String>? env, bool? isTty}) {
    final Map<String, String> resolvedEnv = env ?? Platform.environment;
    final bool resolvedTty = isTty ?? stdout.hasTerminal;
    return MonitorTheme._(
      detectColorDepth(env: resolvedEnv, isTty: resolvedTty),
      detectMonitorGlyphs(env: resolvedEnv, isTty: resolvedTty),
    );
  }

  /// A colorless theme with unicode glyphs, for `--once` snapshots and any
  /// other output that must never carry escape bytes.
  factory MonitorTheme.plain() =>
      const MonitorTheme._(ColorDepth.none, MonitorGlyphs.unicode);

  /// A colorless theme with ASCII-only glyphs, for terminals (or captured
  /// output) that can render neither escapes nor the unicode glyph set.
  factory MonitorTheme.plainAscii() =>
      const MonitorTheme._(ColorDepth.none, MonitorGlyphs.ascii);

  static MonitorTheme? _override;
  static MonitorTheme? _detected;

  /// The process-wide theme for surfaces that render one row at a time and
  /// have no frame to carry a theme down from — the prompts and the cooked-mode
  /// menu. [detect] reads the environment on every call, so it is resolved once
  /// here and reused.
  ///
  /// Renderers that are handed a theme keep taking it as a parameter; this is
  /// only for the entry points that have nowhere to get one from.
  static MonitorTheme get cached =>
      _override ?? (_detected ??= MonitorTheme.detect());

  /// Pins [cached] to a fixed theme, or restores detection when set to null.
  /// For tests: production code reads [cached].
  static set cachedOverride(MonitorTheme? value) => _override = value;

  String get frame => _encodeTone(_Palette.frame, depth);
  String get frameActive => _encodeTone(_Palette.frameActive, depth);
  String get text => _encodeTone(_Palette.text, depth);
  String get textStrong => _encodeTone(_Palette.textStrong, depth);
  String get faint => _encodeTone(_Palette.faint, depth);
  String get muted => _encodeTone(_Palette.muted, depth);
  String get ok => _encodeTone(_Palette.ok, depth);
  String get warn => _encodeTone(_Palette.warn, depth);
  String get crit => _encodeTone(_Palette.crit, depth);
  String get accent => _encodeTone(_Palette.accent, depth);
  String get info => _encodeTone(_Palette.info, depth);
  String get danger => _encodeTone(_Palette.danger, depth);

  String get reset => depth == ColorDepth.none ? '' : Ansi.reset;
  String get bold => depth == ColorDepth.none ? '' : Ansi.bold;
  String get dim => depth == ColorDepth.none ? '' : Ansi.dim;

  /// The tone at [fraction] (clamped `0..1`) along [ramp].
  String rampTone(MonitorRamp ramp, double fraction) {
    final List<ToneToken> stops = _Ramps.forRamp(ramp);
    final double clamped = _clampUnit(fraction);
    final int index = (clamped * (stops.length - 1)).round();
    return _encodeTone(stops[index], depth);
  }

  /// Maps a runtime lifecycle state to its status tone.
  String statusTone(RuntimeState state) {
    switch (state) {
      case RuntimeState.running:
        return ok;
      case RuntimeState.starting:
      case RuntimeState.stopping:
      case RuntimeState.restarting:
        return warn;
      case RuntimeState.stopped:
        return faint;
    }
  }

  /// Maps a ticks-per-second reading to a health tone. `null` (no reading
  /// yet) is faint, not an error.
  String tpsTone(double? tps) {
    if (tps == null) {
      return faint;
    }
    if (tps >= 18) {
      return ok;
    }
    if (tps >= 15) {
      return warn;
    }
    return crit;
  }

  /// Wraps [text] in [tone], appending a reset. An empty [tone] (as at
  /// [ColorDepth.none]) returns [text] unchanged, with no reset either.
  String paint(String text, String tone) =>
      tone.isEmpty ? text : '$tone$text$reset';

  /// Renders [text] as the brand wordmark. At [ColorDepth.none] this is the
  /// unchanged text (zero escape bytes). At [ColorDepth.basic] it is a
  /// single bold + [textStrong] run, since a 3-bit terminal cannot render a
  /// meaningful per-run gradient. At [ColorDepth.ansi256] and
  /// [ColorDepth.truecolor] it splits [text] into up to 7 run-length
  /// segments across the title ramp, bold, ending with a reset.
  String gradientTitle(String text) {
    if (depth == ColorDepth.none) {
      return text;
    }
    if (depth == ColorDepth.basic) {
      return '$bold$textStrong$text$reset';
    }
    if (text.isEmpty) {
      return text;
    }
    final List<ToneToken> table = _Ramps.title;
    int runs = 7;
    if (text.length < runs) {
      runs = text.length;
    }
    if (table.length < runs) {
      runs = table.length;
    }
    final StringBuffer output = StringBuffer(bold);
    int cursor = 0;
    for (int run = 0; run < runs; run++) {
      final int end = ((run + 1) * text.length / runs).round();
      final String segment = text.substring(cursor, end);
      cursor = end;
      if (segment.isEmpty) {
        continue;
      }
      final int stopIndex = runs == 1
          ? 0
          : (run / (runs - 1) * (table.length - 1)).round();
      output
        ..write(_encodeTone(table[stopIndex], depth))
        ..write(segment);
    }
    output.write(reset);
    return output.toString();
  }
}
