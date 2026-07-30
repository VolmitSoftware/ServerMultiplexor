import '../terminal/theme.dart';

/// The bar's raw glyph run before color is applied: [ink] covers the filled
/// full cells plus at most one eighth-cell partial glyph, and [track] covers
/// the remaining unfilled cells. `ink.length + track.length` always equals
/// [cells].
///
/// Exposed as its own pure function (no [MonitorTheme] dependency) so the
/// eighth-cell fill algorithm can be verified against any [MonitorGlyphs]
/// set — including [MonitorGlyphs.ascii] — independent of color painting.
/// [renderMeter] calls this directly for its own fill computation.
({String ink, String track}) meterFillGlyphs({
  required double fraction,
  required int cells,
  required MonitorGlyphs glyphs,
}) {
  final double clamped = fraction < 0 ? 0.0 : (fraction > 1 ? 1.0 : fraction);
  final double exact = clamped * cells;
  int full = exact.floor();
  if (full > cells) {
    full = cells;
  }
  final int partialIndex = ((exact - full) * 8).floor();
  final StringBuffer ink = StringBuffer(glyphs.meterFull * full);
  int used = full;
  if (used < cells && partialIndex > 0) {
    ink.write(glyphs.meterPartial[partialIndex - 1]);
    used += 1;
  }
  final String track = used < cells ? glyphs.meterTrack * (cells - used) : '';
  return (ink: ink.toString(), track: track);
}

/// Renders a fixed-width bar meter representing [fraction] (`0..1`, clamped)
/// as full block cells plus at most one eighth-cell partial glyph, the whole
/// ink run painted a single [MonitorTheme.rampTone] at [ramp] and [fraction];
/// unfilled cells render [MonitorGlyphs.meterTrack] painted
/// [MonitorTheme.faint].
///
/// A `null` [fraction] (no reading yet) never renders a fabricated zero bar;
/// it renders [MonitorGlyphs.dash] repeated [cells] times, painted
/// [MonitorTheme.faint]. The result's visible width always equals [cells]
/// (a negative [cells] is treated as `0`, returning the empty string).
String renderMeter({
  required double? fraction,
  required int cells,
  required MonitorTheme theme,
  MonitorRamp ramp = MonitorRamp.load,
}) {
  final int width = cells < 0 ? 0 : cells;
  if (width == 0) {
    return '';
  }
  final MonitorGlyphs glyphs = theme.glyphs;
  if (fraction == null) {
    return theme.paint(glyphs.dash * width, theme.faint);
  }
  final ({String ink, String track}) fill = meterFillGlyphs(
    fraction: fraction,
    cells: width,
    glyphs: glyphs,
  );
  final StringBuffer output = StringBuffer();
  if (fill.ink.isNotEmpty) {
    output.write(theme.paint(fill.ink, theme.rampTone(ramp, fraction)));
  }
  if (fill.track.isNotEmpty) {
    output.write(theme.paint(fill.track, theme.faint));
  }
  return output.toString();
}
