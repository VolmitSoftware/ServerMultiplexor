/// Frame primitives shared by every monitor view.
///
/// The dashboard (`monitor_model.dart`) and the single-instance detail view
/// (`monitor_detail_model.dart`) are separate layouts over the same
/// vocabulary: one size floor, one resize card, one padding rule, one set of
/// `n/a`-disciplined cell formatters, one spinner and one range label. They
/// live here so the two builders can never drift apart on any of them.
///
/// Everything in this library is pure: no clock reads and no IO.
library;

import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import 'metric_sample.dart';

/// The smallest terminal the dashboard will render into. Below either bound
/// the frame degrades to [buildResizeRequiredFrame] rather than emitting a
/// squeezed, misleading layout.
const int monitorMinColumns = 80;
const int monitorMinLines = 24;

/// The short label for a chart/window [range]: the four cycled ranges get
/// their canonical names, anything else falls back to a compact duration.
String rangeLabel(Duration range) => switch (range.inMinutes) {
  15 => '15m',
  60 => '1h',
  360 => '6h',
  1440 => '24h',
  _ => formatCompactDuration(range),
};

/// The busy-spinner glyph for [frame] from [theme]'s glyph set.
String monitorSpinner(MonitorTheme theme, int frame) {
  final List<String> spinner = theme.glyphs.spinner;
  return spinner[frame.abs() % spinner.length];
}

/// Forces [rows] to exactly [lines] rows of exactly [columns] visible
/// columns: long rows are clipped, short rows padded, missing rows emitted
/// as all-spaces. Every frame builder ends with this so a frame can never
/// scroll or wrap the terminal it is painted into.
List<String> padMonitorFrame({
  required List<String> rows,
  required int columns,
  required int lines,
}) {
  final int width = columns < 0 ? 0 : columns;
  return List<String>.generate(
    lines < 0 ? 0 : lines,
    (int index) => index >= rows.length
        ? ' ' * width
        : Ansi.padVisible(Ansi.clipVisible(rows[index], width), width),
  );
}

/// The state name for [sample], or `no data` when nothing has been sampled
/// yet — an unsampled instance is not a stopped one.
String monitorStateText(MetricSample? sample) =>
    sample == null ? 'no data' : sample.state.name;

/// [value], or the theme's dash glyph when it is missing.
String monitorNumberText(num? value, MonitorTheme theme) =>
    value == null ? theme.glyphs.dash : '$value';

/// `<players>/<max>` for [sample], with the dash glyph standing in for
/// either half when it is missing, and for the whole field when there is no
/// player count at all.
String monitorPlayersText(MetricSample? sample, MonitorTheme theme) {
  final int? players = sample?.players;
  if (players == null) {
    return theme.glyphs.dash;
  }
  return '$players/${monitorNumberText(sample?.maxPlayers, theme)}';
}

/// [tps] to one decimal place, or the dash glyph when there is no reading.
String monitorTpsText(double? tps, MonitorTheme theme) =>
    tps == null ? theme.glyphs.dash : tps.toStringAsFixed(1);

/// A framed, centered card telling the user the terminal is too small.
/// Never throws at any size: when even the card cannot fit, the three lines
/// render as plain clipped rows.
List<String> buildResizeRequiredFrame({
  required int columns,
  required int lines,
  required MonitorTheme theme,
}) {
  final List<String> facts = <String>[
    'RESIZE REQUIRED',
    'CURRENT ${columns}x$lines',
    'MINIMUM ${monitorMinColumns}x$monitorMinLines',
  ];
  final int cardWidth =
      facts.fold<int>(0, (int a, String f) => f.length > a ? f.length : a) + 4;
  if (columns < cardWidth || lines < facts.length + 2) {
    final int top = (lines - facts.length) ~/ 2;
    return padMonitorFrame(
      rows: <String>[
        for (int index = 0; index < (top < 0 ? 0 : top); index++) '',
        ...facts,
      ],
      columns: columns,
      lines: lines,
    );
  }

  final List<String> card = renderPanel(
    title: 'TERMINAL',
    content: <String>[
      theme.paint(facts[0], '${theme.bold}${theme.danger}'),
      theme.paint(facts[1], theme.text),
      theme.paint(facts[2], theme.faint),
    ],
    width: cardWidth,
    theme: theme,
    emphasis: PanelEmphasis.danger,
  );

  final int left = (columns - cardWidth) ~/ 2;
  final int top = (lines - card.length) ~/ 2;
  return padMonitorFrame(
    rows: <String>[
      for (int index = 0; index < top; index++) '',
      for (final String row in card) '${' ' * left}$row',
    ],
    columns: columns,
    lines: lines,
  );
}
