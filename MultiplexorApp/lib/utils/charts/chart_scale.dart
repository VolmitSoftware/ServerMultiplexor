import 'dart:math' as math;

/// Rounds [rough] up to the nearest "nice" number on the `1 / 2 / 2.5 / 5`
/// ladder (scaled by a power of ten): `niceStep(0.7) == 1`,
/// `niceStep(2.3) == 2.5`, `niceStep(23) == 25`. Used to pick both axis
/// bounds and tick spacing so labels land on round numbers instead of
/// arbitrary fractions.
///
/// Non-positive input (`rough <= 0`) always returns `1.0` — there is no
/// "nice" step for a non-positive span.
double niceStep(double rough) {
  if (rough <= 0) {
    return 1.0;
  }
  final double magnitude = math
      .pow(10, (math.log(rough) / math.ln10).floor())
      .toDouble();
  final double fraction = rough / magnitude;
  const List<double> ladder = <double>[1, 2, 2.5, 5];
  for (final double candidate in ladder) {
    if (fraction <= candidate + 1e-9) {
      return candidate * magnitude;
    }
  }
  return 10 * magnitude;
}

/// A single labeled gridline on a chart's vertical axis: [value] is the
/// data value it marks, [label] is its already-formatted display text, and
/// [row] is the zero-based plot row (from the top) it lands on.
class ChartTick {
  const ChartTick({
    required this.value,
    required this.label,
    required this.row,
  });

  final double value;
  final String label;
  final int row;
}

/// The resolved vertical scale for a chart: [low] and [high] bound the
/// plotted value range, and [ticks] are the gridlines to draw within it.
class ChartScale {
  const ChartScale({
    required this.low,
    required this.high,
    required this.ticks,
  });

  final double low;
  final double high;
  final List<ChartTick> ticks;
}

/// Resolves the vertical axis bounds and gridlines for a chart with [rows]
/// plot rows, given the plotted data's [dataLow]/[dataHigh] extent (either
/// or both may be `null` when there is no data yet).
///
/// - When both [forcedLow] and [forcedHigh] are given, they are used
///   verbatim as [ChartScale.low]/[ChartScale.high] — no headroom, no
///   snapping (e.g. a TPS chart pins `0..20`).
/// - When only one of [forcedLow]/[forcedHigh] is given, it pins that bound
///   verbatim and the other is computed from the data as below.
/// - With no data and no forced bounds, the scale is `0..1`.
/// - Otherwise an unforced low near zero (`dataLow >= 0 && dataLow <= 0.35 *
///   dataHigh`) is floored to exactly `0`, an unforced high gets 8%
///   headroom above the data, and — using the *same* step ticks land on
///   (`niceStep((high - low) / desired)`, `desired = max(2, rows ~/ 3)`) —
///   each unforced bound snaps outward to a multiple of that step. Bounds
///   snap to the tick step itself, not a coarser whole-range step, so the
///   axis never overshoots past the nearest tick (e.g. a `0..59` ramp
///   resolves to `0..80`, not `0..100`).
/// - Flat data (`dataLow == dataHigh`) is widened above before headroom so
///   the result never degenerates to a zero span.
///
/// Ticks land on multiples of that same step, each mapped to an integer
/// plot row and deduplicated so every row holds at most one tick — the
/// first value generated for a row wins it. The top row (value `high`) and
/// bottom row (value `low`) are then always (re-)written, overriding
/// whatever nice multiple a prior pass placed there, so the true bounds are
/// always visible.
ChartScale resolveChartScale({
  required double? dataLow,
  required double? dataHigh,
  required int rows,
  double? forcedLow,
  double? forcedHigh,
}) {
  final int safeRows = rows < 1 ? 1 : rows;
  final int desired = math.max(2, safeRows ~/ 3);
  late final double low;
  late final double high;
  late final double step;

  if (forcedLow != null && forcedHigh != null) {
    low = forcedLow;
    high = forcedHigh;
    step = niceStep((high - low) / desired);
  } else if (dataLow == null &&
      dataHigh == null &&
      forcedLow == null &&
      forcedHigh == null) {
    low = 0.0;
    high = 1.0;
    step = niceStep((high - low) / desired);
  } else {
    double effectiveDataLow = dataLow ?? 0.0;
    double effectiveDataHigh = dataHigh ?? 1.0;
    if (dataLow != null && dataHigh != null && dataLow == dataHigh) {
      // Degenerate flat data: widen above so the headroom/step math below
      // never operates on a zero span.
      effectiveDataHigh += 1.0;
    }

    double resolvedLow = forcedLow ?? effectiveDataLow;
    double preSnapHigh = forcedHigh ?? effectiveDataHigh;

    if (forcedLow == null &&
        resolvedLow >= 0 &&
        preSnapHigh > 0 &&
        resolvedLow <= 0.35 * preSnapHigh) {
      resolvedLow = 0.0;
    }
    if (forcedHigh == null) {
      preSnapHigh += 0.08 * (preSnapHigh - resolvedLow);
    }

    // Snap to the same step ticks will use below, not a coarser whole-range
    // step (niceStep(range) alone) — the latter is what let a 0..59 ramp
    // overshoot to 0..100 instead of landing on the nearest tick, 0..80.
    final double tickStep = niceStep((preSnapHigh - resolvedLow) / desired);

    double resolvedHigh =
        forcedHigh ?? (preSnapHigh / tickStep).ceil() * tickStep;
    if (forcedLow == null) {
      resolvedLow = (resolvedLow / tickStep).floor() * tickStep;
    }
    if (resolvedHigh <= resolvedLow) {
      resolvedHigh = resolvedLow + tickStep;
    }

    low = resolvedLow;
    high = resolvedHigh;
    step = tickStep;
  }

  return ChartScale(
    low: low,
    high: high,
    ticks: _planTicks(low: low, high: high, rows: safeRows, step: step),
  );
}

List<ChartTick> _planTicks({
  required double low,
  required double high,
  required int rows,
  required double step,
}) {
  final double span = high - low;
  final Map<int, ChartTick> byRow = <int, ChartTick>{};

  int rowFor(double value) {
    final int row = ((high - value) / span * (rows - 1)).round();
    return row < 0 ? 0 : (row > rows - 1 ? rows - 1 : row);
  }

  void addTick(double value, {bool force = false}) {
    final int row = rowFor(value);
    if (byRow.containsKey(row) && !force) {
      return;
    }
    byRow[row] = ChartTick(
      value: value,
      label: _formatTickLabel(value),
      row: row,
    );
  }

  if (span > 0) {
    final int first = ((low / step) - 1e-9).ceil();
    final int last = ((high / step) + 1e-9).floor();
    for (int multiple = first; multiple <= last; multiple++) {
      addTick(multiple * step);
    }
    addTick(high, force: true);
    addTick(low, force: true);
  } else {
    // Zero-span scale (only reachable via verbatim-equal forced bounds):
    // every row maps to the same value, but the top/bottom rows still each
    // get a tick.
    byRow[0] = ChartTick(value: high, label: _formatTickLabel(high), row: 0);
    if (rows > 1) {
      byRow[rows - 1] = ChartTick(
        value: low,
        label: _formatTickLabel(low),
        row: rows - 1,
      );
    }
  }

  final List<ChartTick> ticks = byRow.values.toList()
    ..sort((a, b) => a.row.compareTo(b.row));
  return ticks;
}

/// Formats [value] for a tick label: trailing `.0` is trimmed (`5.0` ->
/// `5`), and if the result is wider than 6 characters, the fractional part
/// is dropped rather than the leading digits (`123457.5` -> `123457`).
String _formatTickLabel(double value) {
  final double rounded = double.parse(value.toStringAsFixed(6));
  String label = rounded.toString();
  if (label.contains('.')) {
    label = label.replaceFirst(RegExp(r'0+$'), '');
    if (label.endsWith('.')) {
      label = label.substring(0, label.length - 1);
    }
  }
  if (label.length > 6) {
    final int dot = label.indexOf('.');
    if (dot >= 0) {
      label = label.substring(0, dot);
    }
  }
  return label;
}

/// A single time-axis label: [column] is its zero-based left edge column
/// and [label] is its already-formatted display text.
class TimeTick {
  const TimeTick({required this.column, required this.label});

  final int column;
  final String label;
}

/// Plans up to [targetTicks] evenly-spaced time labels across a
/// [width]-column horizontal axis spanning `[start, end]`.
///
/// Labels render `HH:mm` in the given [DateTime]s' own time zone (24-hour,
/// zero-padded); when the span exceeds 24 hours, each label is prefixed
/// with `MM-dd ` (e.g. `07-29 08:14`).
///
/// The first tick is left-anchored at column `0`, the last is right-anchored
/// (`column = width - label.length`), and middle ticks are centered on
/// their evenly-spaced anchor position. A tick whose column would land
/// before the previous label's end (plus a 2-column gap) is dropped rather
/// than shifted. If even the first label cannot fit in [width], the result
/// is empty — as it is for any non-positive [width].
List<TimeTick> planTimeAxis({
  required DateTime start,
  required DateTime end,
  required int width,
  int targetTicks = 4,
}) {
  if (width <= 0) {
    return <TimeTick>[];
  }
  final int count = targetTicks < 2 ? 2 : targetTicks;
  final Duration span = end.difference(start);
  final bool withDate = span > const Duration(hours: 24);

  final List<TimeTick> ticks = <TimeTick>[];
  int nextFree = 0;
  for (int index = 0; index < count; index++) {
    final double fraction = count == 1 ? 0.0 : index / (count - 1);
    final int microseconds = (span.inMicroseconds * fraction).round();
    final DateTime moment = start.add(Duration(microseconds: microseconds));
    final String label = _formatTimeLabel(moment, withDate: withDate);

    if (label.length > width) {
      if (index == 0) {
        return <TimeTick>[];
      }
      continue;
    }

    final int anchor = (fraction * (width - 1)).round();
    final int maxColumn = width - label.length;
    int column;
    if (index == 0) {
      column = 0;
    } else if (index == count - 1) {
      column = maxColumn;
    } else {
      column = anchor - (label.length ~/ 2);
    }
    if (column < 0) {
      column = 0;
    } else if (column > maxColumn) {
      column = maxColumn;
    }

    if (column < nextFree) {
      continue;
    }
    ticks.add(TimeTick(column: column, label: label));
    nextFree = column + label.length + 2;
  }
  return ticks;
}

/// Formats [moment] as `HH:mm` (24-hour, zero-padded), prefixed with
/// `MM-dd ` when [withDate] is true.
String _formatTimeLabel(DateTime moment, {required bool withDate}) {
  final String hh = moment.hour.toString().padLeft(2, '0');
  final String mm = moment.minute.toString().padLeft(2, '0');
  final String clock = '$hh:$mm';
  if (!withDate) {
    return clock;
  }
  final String month = moment.month.toString().padLeft(2, '0');
  final String day = moment.day.toString().padLeft(2, '0');
  return '$month-$day $clock';
}
