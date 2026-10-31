import '../terminal/theme.dart';
import 'braille_chart.dart';
import 'chart_scale.dart';

/// Longest run of empty columns an area still bridges, interpolating
/// between its neighbours. Wider runs are missing data and stay empty.
const int _maxBridgeColumns = 4;

/// Smallest plot (in cells) that can carry a readable area.
const int _minPlotWidth = 4;
const int _minHeight = 3;

/// Renders one series as a filled area chart exactly [height] rows tall and
/// [width] visible columns wide.
///
/// The layout matches [renderBrailleChart]: `height - 1` plot rows, each led
/// by a faint Y gutter, then one time-axis row. Each plot column is one time
/// bucket (the mean of its samples) filled up from the baseline in eighths
/// of a cell, so the top edge moves smoothly. The column's top cell is drawn
/// in [MonitorTheme.accent] and the fill below it in
/// [MonitorTheme.accentSoft], which keeps a large area from reading as one
/// loud block. A measured zero still draws the lowest eighth, so it never
/// looks like a gap.
///
/// Gaps of up to [_maxBridgeColumns] empty columns are interpolated across;
/// longer gaps stay empty. The plot carries no gridlines. With nothing to
/// draw it shows [chartNoDataText], and a plot too small to read degrades to
/// [chartNoDataCard].
///
/// Pure: identical inputs always render identical rows.
List<String> renderAreaChart({
  required List<ChartPoint> points,
  required int width,
  required int height,
  required DateTime start,
  required DateTime end,
  required MonitorTheme theme,
  double? forcedLow,
  double? forcedHigh,
}) {
  final int outWidth = width < 0 ? 0 : width;
  if (height <= 0) {
    return <String>[];
  }
  if (height < _minHeight) {
    return chartNoDataCard(outWidth, height, theme);
  }

  final int plotRows = height - 1;
  final int spanMicros = end.difference(start).inMicroseconds;
  final bool hasWindow = spanMicros > 0;

  double? dataLow;
  double? dataHigh;
  if (hasWindow) {
    for (final ChartPoint point in points) {
      final double? value = point.value;
      final int offset = point.ts.difference(start).inMicroseconds;
      if (value == null ||
          !value.isFinite ||
          offset < 0 ||
          offset > spanMicros) {
        continue;
      }
      if (dataLow == null || value < dataLow) dataLow = value;
      if (dataHigh == null || value > dataHigh) dataHigh = value;
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
    if (tick.label.length > labelWidth) labelWidth = tick.label.length;
  }
  final int gutterWidth = labelWidth + 2;
  final int plotWidth = outWidth - gutterWidth;
  if (plotWidth < _minPlotWidth) {
    return chartNoDataCard(outWidth, height, theme);
  }

  final List<double?> columns = hasWindow
      ? _bridge(
          bucketChartPoints(
            points: points,
            start: start,
            spanMicros: spanMicros,
            subColumns: plotWidth,
          ),
        )
      : List<double?>.filled(plotWidth, null);

  final double span = scale.high - scale.low;
  final int fullEighths = plotRows * 8;
  final List<int> eighths = <int>[
    for (final double? value in columns)
      if (value == null)
        0
      else
        _clampInt(
          ((span <= 0 ? 0.5 : (value - scale.low) / span) * fullEighths)
              .round(),
          1,
          fullEighths,
        ),
  ];
  final bool anyInk = eighths.any((int level) => level > 0);

  final bool ascii = theme.glyphs.isAscii;
  final Map<int, String> labelByRow = <int, String>{
    for (final ChartTick tick in scale.ticks) tick.row: tick.label,
  };
  final int noDataRow = plotRows ~/ 2;
  final int noDataLeft = (plotWidth - chartNoDataText.length) ~/ 2;

  final List<String> rows = <String>[];
  for (int row = 0; row < plotRows; row++) {
    final String label = (labelByRow[row] ?? '').padLeft(labelWidth);
    final String axisGlyph = row == plotRows - 1
        ? theme.glyphs.axisBase
        : theme.glyphs.axisTick;
    final StringBuffer line = StringBuffer(
      theme.paint('$label $axisGlyph', theme.faint),
    );
    final int floor = (plotRows - 1 - row) * 8;

    String segment = '';
    String segmentTone = '';
    void flush() {
      if (segment.isNotEmpty) line.write(theme.paint(segment, segmentTone));
      segment = '';
    }

    for (int column = 0; column < plotWidth; column++) {
      if (!anyInk && row == noDataRow) {
        final int index = column - noDataLeft;
        if (index >= 0 && index < chartNoDataText.length) {
          if (segmentTone != theme.faint) {
            flush();
            segmentTone = theme.faint;
          }
          segment += chartNoDataText[index];
          continue;
        }
      }
      final int fill = _clampInt(eighths[column] - floor, 0, 8);
      if (fill == 0) {
        segment += ' ';
        continue;
      }
      final bool top = eighths[column] - floor <= 8;
      final String glyph = ascii
          ? (fill >= 4 ? '#' : '_')
          : fill == 8
          ? '█'
          : theme.glyphs.spark[fill - 1];
      final String tone = top ? theme.accent : theme.accentSoft;
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

/// Fills runs of at most [_maxBridgeColumns] empty columns that sit between
/// two known columns by linear interpolation.
List<double?> _bridge(List<double?> columns) {
  final List<double?> out = List<double?>.of(columns);
  int previous = -1;
  for (int index = 0; index < out.length; index++) {
    final double? value = columns[index];
    if (value == null) continue;
    final int gap = index - previous - 1;
    if (previous >= 0 && gap > 0 && gap <= _maxBridgeColumns) {
      final double from = columns[previous]!;
      for (int step = 1; step <= gap; step++) {
        out[previous + step] = from + (value - from) * step / (gap + 1);
      }
    }
    previous = index;
  }
  return out;
}

int _clampInt(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);
