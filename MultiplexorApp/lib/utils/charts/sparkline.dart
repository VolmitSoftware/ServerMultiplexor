import '../terminal/theme.dart';

/// How a downsample bucket collapses multiple raw samples into one
/// sparkline cell.
enum SparkAggregate {
  /// Arithmetic mean of the bucket's non-null samples.
  mean,

  /// Largest of the bucket's non-null samples.
  max,

  /// The bucket's final (most recent) non-null sample.
  last,
}

/// A single sparkline cell's raw glyph (no color) and the normalized `0..1`
/// fraction used to pick its ramp tone.
///
/// Exposed as its own pure function (no [MonitorTheme] dependency) so the
/// level-selection algorithm can be verified against any [MonitorGlyphs] set
/// — including [MonitorGlyphs.ascii] — independent of color painting.
/// [renderSparkline] calls this directly for each cell.
///
/// `value == null` (a missing sample) always yields [MonitorGlyphs.sparkGap]
/// at fraction `0` (unused — gap cells are always painted faint, never by
/// ramp). Flat data (`high <= low`) yields the middle spark level at
/// fraction `0.5`. Otherwise [value] clamps into `[low, high]` before its
/// fraction is computed.
({String glyph, double fraction}) sparklineCell({
  required double? value,
  required double low,
  required double high,
  required MonitorGlyphs glyphs,
}) {
  if (value == null) {
    return (glyph: glyphs.sparkGap, fraction: 0.0);
  }
  final double span = high - low;
  if (span <= 0) {
    return (glyph: glyphs.spark.substring(3, 4), fraction: 0.5);
  }
  final double clamped = value < low ? low : (value > high ? high : value);
  double fraction = (clamped - low) / span;
  if (fraction < 0) {
    fraction = 0.0;
  } else if (fraction > 1) {
    fraction = 1.0;
  }
  final int levelIndex = (fraction * (glyphs.spark.length - 1)).round();
  return (
    glyph: glyphs.spark.substring(levelIndex, levelIndex + 1),
    fraction: fraction,
  );
}

/// Renders [values] as a fixed-width sparkline, one glyph per cell from
/// [MonitorGlyphs.spark] (an 8-step intensity ramp), each non-null cell
/// painted [ramp] by its normalized value — [MonitorRamp.load] by default,
/// [MonitorRamp.tps] for readings where high is health rather than heat.
/// Missing samples (`null`) never render as a fabricated zero; they render
/// [MonitorGlyphs.sparkGap] painted [MonitorTheme.faint].
///
/// - When `values.length > width`, samples are bucket-downsampled: bucket
///   `i` spans `[i*n~/width, max(i*n~/width + 1, (i+1)*n~/width))` and
///   collapses via [aggregate]. A bucket with zero non-null members renders
///   as a gap.
/// - When `values.length < width`, this is a live time series: the data is
///   right-aligned (the most recent sample lands on the rightmost cell) and
///   the remaining left cells render as gaps.
/// - [min]/[max] override the data extent when provided; values clamp into
///   the resulting range. Flat data (zero span) renders every non-null cell
///   at the middle spark level, tone fraction `0.5`.
///
/// The result's visible width always equals [width]. `width <= 0` returns
/// the empty string.
String renderSparkline({
  required List<double?> values,
  required int width,
  required MonitorTheme theme,
  double? min,
  double? max,
  SparkAggregate aggregate = SparkAggregate.mean,
  MonitorRamp ramp = MonitorRamp.load,
}) {
  if (width <= 0) {
    return '';
  }
  final List<double?> cellValues = _bucketize(values, width, aggregate);

  double? observedLow;
  double? observedHigh;
  if (min == null || max == null) {
    for (final double? value in cellValues) {
      if (value == null) {
        continue;
      }
      if (observedLow == null || value < observedLow) {
        observedLow = value;
      }
      if (observedHigh == null || value > observedHigh) {
        observedHigh = value;
      }
    }
  }
  final double low = min ?? observedLow ?? 0.0;
  final double high = max ?? observedHigh ?? 1.0;

  final MonitorGlyphs glyphs = theme.glyphs;
  final StringBuffer output = StringBuffer();
  for (final double? value in cellValues) {
    final ({String glyph, double fraction}) cell = sparklineCell(
      value: value,
      low: low,
      high: high,
      glyphs: glyphs,
    );
    final String tone = value == null
        ? theme.faint
        : theme.rampTone(ramp, cell.fraction);
    output.write(theme.paint(cell.glyph, tone));
  }
  return output.toString();
}

/// Maps [values] onto exactly [width] cells.
///
/// When there are at least as many samples as cells, downsamples via bucket
/// [aggregate]. When there are fewer samples than cells, right-aligns the
/// data (the most recent sample lands on the rightmost cell) and left-pads
/// the remaining cells with gaps (`null`).
List<double?> _bucketize(
  List<double?> values,
  int width,
  SparkAggregate aggregate,
) {
  final int sampleCount = values.length;
  final List<double?> cellValues = List<double?>.filled(width, null);
  if (sampleCount >= width) {
    for (int i = 0; i < width; i++) {
      final int from = i * sampleCount ~/ width;
      int to = (i + 1) * sampleCount ~/ width;
      if (to < from + 1) {
        to = from + 1;
      }
      cellValues[i] = _aggregateBucket(values, from, to, aggregate);
    }
  } else if (sampleCount > 0) {
    final int offset = width - sampleCount;
    for (int i = 0; i < sampleCount; i++) {
      cellValues[offset + i] = values[i];
    }
  }
  return cellValues;
}

/// Collapses `values[from, to)` into a single value via [aggregate], over
/// non-null samples only. Returns `null` (a gap) when the bucket has no
/// non-null samples.
double? _aggregateBucket(
  List<double?> values,
  int from,
  int to,
  SparkAggregate aggregate,
) {
  switch (aggregate) {
    case SparkAggregate.last:
      double? last;
      for (int i = from; i < to; i++) {
        final double? value = values[i];
        if (value != null) {
          last = value;
        }
      }
      return last;
    case SparkAggregate.max:
      double? best;
      for (int i = from; i < to; i++) {
        final double? value = values[i];
        if (value != null && (best == null || value > best)) {
          best = value;
        }
      }
      return best;
    case SparkAggregate.mean:
      double total = 0;
      int count = 0;
      for (int i = from; i < to; i++) {
        final double? value = values[i];
        if (value != null) {
          total += value;
          count += 1;
        }
      }
      return count > 0 ? total / count : null;
  }
}
