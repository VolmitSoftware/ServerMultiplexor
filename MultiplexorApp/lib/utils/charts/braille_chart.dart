import 'dart:typed_data';

import '../terminal/theme.dart';
import 'chart_scale.dart';

/// Bit weight of each sub-cell inside a braille cell, indexed
/// `[subY & 3][subX & 1]`. A cell's glyph is `0x2800 + mask`, so one terminal
/// column carries 2x4 independently addressable dots.
const List<List<int>> _brailleBits = <List<int>>[
  <int>[0x01, 0x08],
  <int>[0x02, 0x10],
  <int>[0x04, 0x20],
  <int>[0x40, 0x80],
];

/// Cell flag: the cell sits on a horizontal gridline.
const int _flagGrid = 1;

/// Cell flag: the cell sits in a column marked by an event.
const int _flagEvent = 2;

/// Owner-plane sentinel for a cell inked by more than one series.
const int _ownerMixed = 255;

/// Owner-plane values are `seriesIndex + 1`, so this is the highest series
/// index the plane can distinguish before it collides with [_ownerMixed].
const int _maxOwnedSeries = _ownerMixed - 1;

/// Longest run of empty sub-columns a polyline still bridges. Beyond this the
/// series is genuinely missing data and the chart shows a real gap rather than
/// inventing a straight line across it.
const int _maxBridgeSubColumns = 6;

/// Rendered in place of the plot whenever there is nothing truthful to draw.
const String _noData = 'n/a';

/// Smallest plot area (in cells) that can carry a readable chart. Below either
/// bound the renderer degrades to an [_noData] card instead of emitting a
/// misleading sliver of a plot.
const int _minPlotWidth = 4;
const int _minHeight = 3;

/// One sample in a charted series: [value] is `null` when the sample is
/// missing, which renders as a gap — never as a fabricated zero.
class ChartPoint {
  const ChartPoint({required this.ts, required this.value});

  final DateTime ts;
  final double? value;
}

/// One plotted line: its [label], its [points], and a [toneIndex] selecting
/// its color in a multi-series chart (`0` accent, `1` info, anything else the
/// neutral strong text tone). A single-series chart ignores [toneIndex] and
/// uses the vertical load gradient instead.
class ChartSeries {
  const ChartSeries({
    required this.label,
    required this.points,
    this.toneIndex = 0,
  });

  final String label;
  final List<ChartPoint> points;
  final int toneIndex;
}

/// A glyph that wins over everything else in its cell, with the tone it is
/// painted in — used for the latest-sample marker and the [_noData] text.
class _CellOverride {
  const _CellOverride(this.glyph, this.tone);

  final String glyph;
  final String tone;
}

/// Renders [series] as a braille line chart exactly [height] rows tall and
/// [width] visible columns wide.
///
/// Layout: `height - 1` plot rows followed by one time-axis row. Each plot row
/// is a Y-gutter (`<right-aligned tick label> <axis glyph>`, faint) followed by
/// the plot cells; the gutter is `longest tick label + 2` columns wide and the
/// axis glyph is [MonitorGlyphs.axisBase] on the bottom row and
/// [MonitorGlyphs.axisTick] elsewhere. Rows without a tick get a blank label.
///
/// With the unicode glyph set each plot cell is a 2x4 sub-cell grid, so the
/// effective resolution is `plotWidth * 2` by `(height - 1) * 4`; with
/// [MonitorGlyphs.ascii] the grid drops to 1x1 and marks render as `#`.
/// Samples are bucketed into sub-columns by timestamp (bucket value = mean of
/// the non-null samples landing in it) and consecutive non-empty sub-columns
/// are joined by a vertical fill so the line reads as a polyline rather than a
/// dot cloud. A run of more than [_maxBridgeSubColumns] empty sub-columns is
/// left as a real gap.
///
/// The vertical scale comes from [resolveChartScale] over the **in-window**
/// non-null samples, with [forcedLow]/[forcedHigh] pinning either bound
/// verbatim (a TPS chart pins `0..20`). Each [DateTime] in [events] flags its
/// whole plot column, which renders [MonitorGlyphs.event] wherever no data
/// covers it. The last real sample of the first series renders
/// [MonitorGlyphs.latest] painted [MonitorTheme.accent].
///
/// Cell precedence is: override glyph, then braille ink, then event, then
/// grid, then space. Ink is painted by the [MonitorRamp.load] gradient (single
/// series, hot at the top) or by owning series (multi-series, mixed cells
/// neutral); adjacent cells sharing a tone share one escape sequence.
///
/// When there is no data to draw — no series, all samples null, all samples
/// outside the window, or a non-positive window — the frame still renders with
/// [_noData] centered in the plot area. When the plot area would be narrower
/// than [_minPlotWidth] cells, or [height] is below [_minHeight], the result
/// degrades to a blank card with [_noData] on its middle row. A non-positive
/// [height] renders no rows.
///
/// Pure: no clock reads, no IO. Identical inputs always render identical rows.
List<String> renderBrailleChart({
  required List<ChartSeries> series,
  required int width,
  required int height,
  required DateTime start,
  required DateTime end,
  required MonitorTheme theme,
  double? forcedLow,
  double? forcedHigh,
  List<DateTime> events = const <DateTime>[],
}) {
  final int outWidth = width < 0 ? 0 : width;
  final int outHeight = height < 0 ? 0 : height;
  if (outHeight <= 0) {
    return <String>[];
  }
  if (outHeight < _minHeight) {
    return _noDataCard(outWidth, outHeight, theme);
  }

  final int plotRows = outHeight - 1;
  final int spanMicros = end.difference(start).inMicroseconds;
  final bool hasWindow = spanMicros > 0;

  double? dataLow;
  double? dataHigh;
  if (hasWindow) {
    for (final ChartSeries entry in series) {
      for (final ChartPoint point in entry.points) {
        final double? value = point.value;
        if (value == null || !value.isFinite) {
          continue;
        }
        final int offset = point.ts.difference(start).inMicroseconds;
        if (offset < 0 || offset > spanMicros) {
          continue;
        }
        if (dataLow == null || value < dataLow) {
          dataLow = value;
        }
        if (dataHigh == null || value > dataHigh) {
          dataHigh = value;
        }
      }
    }
  }

  final ChartScale scale = resolveChartScale(
    dataLow: dataLow,
    dataHigh: dataHigh,
    rows: plotRows,
    forcedLow: forcedLow,
    forcedHigh: forcedHigh,
  );

  int labelWidth = 1;
  for (final ChartTick tick in scale.ticks) {
    if (tick.label.length > labelWidth) {
      labelWidth = tick.label.length;
    }
  }
  final int gutterWidth = labelWidth + 2;
  final int plotWidth = outWidth - gutterWidth;
  if (plotWidth < _minPlotWidth) {
    return _noDataCard(outWidth, outHeight, theme);
  }

  final bool ascii = theme.glyphs.isAscii;
  final int subColumns = ascii ? plotWidth : plotWidth * 2;
  final int subRows = ascii ? plotRows : plotRows * 4;
  final int cellCount = plotWidth * plotRows;
  final Uint8List mask = Uint8List(cellCount);
  final Uint8List owner = Uint8List(cellCount);
  final Uint8List flags = Uint8List(cellCount);
  final Map<int, _CellOverride> overrides = <int, _CellOverride>{};
  final double span = scale.high - scale.low;

  int cellIndexFor(int subX, int subY) {
    final int cellX = ascii ? subX : subX >> 1;
    final int cellY = ascii ? subY : subY >> 2;
    return cellY * plotWidth + cellX;
  }

  void mark(int seriesIndex, int subX, int subY) {
    if (subX < 0 || subX >= subColumns || subY < 0 || subY >= subRows) {
      return;
    }
    final int index = cellIndexFor(subX, subY);
    mask[index] |= ascii ? 1 : _brailleBits[subY & 3][subX & 1];
    final int ownerValue = seriesIndex < _maxOwnedSeries
        ? seriesIndex + 1
        : _maxOwnedSeries;
    if (owner[index] == 0) {
      owner[index] = ownerValue;
    } else if (owner[index] != ownerValue) {
      owner[index] = _ownerMixed;
    }
  }

  /// Maps a data value to its sub-row, top-down (sub-row `0` is [ChartScale.high]).
  int subYFor(double value) {
    final double fraction = span <= 0 ? 0.5 : (value - scale.low) / span;
    final double clamped = fraction < 0 ? 0.0 : (fraction > 1 ? 1.0 : fraction);
    final int subY = ((1 - clamped) * (subRows - 1)).round();
    return subY < 0 ? 0 : (subY > subRows - 1 ? subRows - 1 : subY);
  }

  bool anyInk = false;
  for (int seriesIndex = 0; seriesIndex < series.length; seriesIndex++) {
    final List<double?> buckets = hasWindow
        ? _bucketSeries(
            points: series[seriesIndex].points,
            start: start,
            spanMicros: spanMicros,
            subColumns: subColumns,
          )
        : List<double?>.filled(subColumns, null);

    int previousSubX = -1;
    int previousSubY = -1;
    int latestSubX = -1;
    int latestSubY = -1;
    for (int subX = 0; subX < subColumns; subX++) {
      final double? value = buckets[subX];
      if (value == null) {
        continue;
      }
      final int subY = subYFor(value);
      mark(seriesIndex, subX, subY);
      if (previousSubX >= 0 &&
          subX - previousSubX - 1 <= _maxBridgeSubColumns &&
          previousSubY != subY) {
        final int from = previousSubY < subY ? previousSubY : subY;
        final int to = previousSubY < subY ? subY : previousSubY;
        for (int y = from; y <= to; y++) {
          mark(seriesIndex, subX, y);
        }
      }
      previousSubX = subX;
      previousSubY = subY;
      latestSubX = subX;
      latestSubY = subY;
      anyInk = true;
    }

    if (seriesIndex == 0 && latestSubX >= 0) {
      overrides[cellIndexFor(latestSubX, latestSubY)] = _CellOverride(
        theme.glyphs.latest,
        theme.accent,
      );
    }
  }

  if (hasWindow) {
    for (final DateTime event in events) {
      final int offset = event.difference(start).inMicroseconds;
      if (offset < 0 || offset > spanMicros) {
        continue;
      }
      final int column = _clampInt(
        (offset / spanMicros * (plotWidth - 1)).round(),
        0,
        plotWidth - 1,
      );
      for (int row = 0; row < plotRows; row++) {
        flags[row * plotWidth + column] |= _flagEvent;
      }
    }
  }

  for (final ChartTick tick in scale.ticks) {
    if (tick.row < 0 || tick.row >= plotRows) {
      continue;
    }
    final int offset = tick.row * plotWidth;
    for (int cellX = 0; cellX < plotWidth; cellX += 2) {
      flags[offset + cellX] |= _flagGrid;
    }
  }

  if (!anyInk) {
    final int row = plotRows ~/ 2;
    final int left = (plotWidth - _noData.length) ~/ 2;
    for (int index = 0; index < _noData.length; index++) {
      overrides[row * plotWidth + left + index] = _CellOverride(
        _noData[index],
        theme.faint,
      );
    }
  }

  final bool single = series.length == 1;
  String seriesTone(int index) {
    if (index < 0 || index >= series.length) {
      return theme.textStrong;
    }
    switch (series[index].toneIndex) {
      case 0:
        return theme.accent;
      case 1:
        return theme.info;
      default:
        return theme.textStrong;
    }
  }

  final Map<int, String> labelByRow = <int, String>{
    for (final ChartTick tick in scale.ticks) tick.row: tick.label,
  };
  final List<String> rows = <String>[];
  for (int cellY = 0; cellY < plotRows; cellY++) {
    final int offset = cellY * plotWidth;
    final String label = (labelByRow[cellY] ?? '').padLeft(labelWidth);
    final String axisGlyph = cellY == plotRows - 1
        ? theme.glyphs.axisBase
        : theme.glyphs.axisTick;
    final StringBuffer line = StringBuffer(
      theme.paint('$label $axisGlyph', theme.faint),
    );

    String segment = '';
    String segmentTone = '';
    void flush() {
      if (segment.isEmpty) {
        return;
      }
      line.write(theme.paint(segment, segmentTone));
      segment = '';
    }

    for (int cellX = 0; cellX < plotWidth; cellX++) {
      final int index = offset + cellX;
      final _CellOverride? override = overrides[index];
      String glyph;
      String tone;
      if (override != null) {
        glyph = override.glyph;
        tone = override.tone;
      } else if (mask[index] != 0) {
        glyph = ascii
            ? theme.glyphs.meterFull
            : String.fromCharCode(0x2800 + mask[index]);
        if (single) {
          tone = theme.rampTone(MonitorRamp.load, 1 - cellY / (plotRows - 1));
        } else if (owner[index] == _ownerMixed) {
          tone = theme.textStrong;
        } else {
          tone = seriesTone(owner[index] - 1);
        }
      } else if ((flags[index] & _flagEvent) != 0) {
        glyph = theme.glyphs.event;
        tone = theme.faint;
      } else if ((flags[index] & _flagGrid) != 0) {
        glyph = theme.glyphs.grid;
        tone = theme.faint;
      } else {
        // A space carries no visible color (the palette is foreground-only),
        // so it joins the run in progress instead of splitting it. On a grid
        // row of alternating dots and blanks that is one escape pair instead
        // of one per cell.
        segment += ' ';
        continue;
      }

      if (tone != segmentTone) {
        flush();
        segmentTone = tone;
      }
      segment += glyph;
    }
    flush();
    rows.add(line.toString());
  }

  final List<String> axisCells = List<String>.filled(plotWidth, ' ');
  if (hasWindow) {
    for (final TimeTick tick in planTimeAxis(
      start: start,
      end: end,
      width: plotWidth,
    )) {
      for (int index = 0; index < tick.label.length; index++) {
        final int position = tick.column + index;
        if (position >= 0 && position < plotWidth) {
          axisCells[position] = tick.label[index];
        }
      }
    }
  }
  rows.add(' ' * gutterWidth + theme.paint(axisCells.join(), theme.faint));
  return rows;
}

/// Averages [points] into [subColumns] buckets by timestamp position within
/// `[start, start + spanMicros]`. Null, non-finite, and out-of-window samples
/// are skipped; a bucket with no members stays `null` (a gap).
List<double?> _bucketSeries({
  required List<ChartPoint> points,
  required DateTime start,
  required int spanMicros,
  required int subColumns,
}) {
  final Float64List sums = Float64List(subColumns);
  final Int32List counts = Int32List(subColumns);
  for (final ChartPoint point in points) {
    final double? value = point.value;
    if (value == null || !value.isFinite) {
      continue;
    }
    final int offset = point.ts.difference(start).inMicroseconds;
    if (offset < 0 || offset > spanMicros) {
      continue;
    }
    final int subX = _clampInt(
      (offset / spanMicros * (subColumns - 1)).round(),
      0,
      subColumns - 1,
    );
    sums[subX] += value;
    counts[subX] += 1;
  }
  return List<double?>.generate(
    subColumns,
    (int index) => counts[index] == 0 ? null : sums[index] / counts[index],
  );
}

/// [height] blank rows of [width] visible columns with [_noData] centered on
/// the middle row — the honest rendering of a viewport too small to chart.
List<String> _noDataCard(int width, int height, MonitorTheme theme) {
  final int middle = height ~/ 2;
  return List<String>.generate(height, (int row) {
    if (row != middle || width < _noData.length) {
      return ' ' * width;
    }
    final int left = (width - _noData.length) ~/ 2;
    return ' ' * left +
        theme.paint(_noData, theme.faint) +
        ' ' * (width - left - _noData.length);
  });
}

int _clampInt(int value, int low, int high) {
  if (value < low) {
    return low;
  }
  return value > high ? high : value;
}
