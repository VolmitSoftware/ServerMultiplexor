/// Frame primitives shared by every monitor view.
///
/// The dashboard (`monitor_model.dart`), the landing panels it composes
/// (`monitor_landing.dart`) and the single-instance detail view
/// (`monitor_detail_model.dart`) are separate layouts over the same
/// vocabulary: one snapshot type, one size floor, one resize card, one
/// padding rule, one set of `n/a`-disciplined cell formatters, one spinner
/// and one range label. They live here so the builders can never drift apart
/// on any of them.
///
/// Everything in this library is pure: no clock reads and no IO.
library;

import '../../utils/duration_format.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/theme.dart';
import 'metric_sample.dart';
import 'monitor_hitbox.dart';

/// The smallest terminal the dashboard will render into. Below either bound
/// the frame degrades to [buildResizeRequiredFrame] rather than emitting a
/// squeezed, misleading layout.
const int monitorMinColumns = 80;
const int monitorMinLines = 24;

/// The flags of an instance nothing is known about: an instance whose row
/// never made it into a capture is treated as neither locked nor isolated.
///
/// This fails open — an unread locked instance offers LOCK and keeps its
/// destructive chips live — and that is deliberate. These flags decide what
/// a *card* draws, not what a command permits: `instance delete` and
/// `instance reset` both call `_ensureUnlocked` themselves, so a click that
/// reaches a locked instance is refused at the command layer with its PIN
/// prompt intact. Failing closed instead would mean a missed capture
/// silently greys out working buttons and offers UNLOCK on an unlocked
/// instance — a worse lie, and one nothing downstream corrects.
const InstanceFlags _defaultFlags = InstanceFlags(
  locked: false,
  isolated: false,
);

/// Which fleet the dashboard is currently presenting.
enum MonitorView { local, remote }

/// Everything the dashboard needs to draw one frame: which instances exist,
/// their metric history (chronological, oldest first), their lock/isolation
/// flags, the active consumer profile's name, and which instance is the
/// active one.
class MonitorSnapshot {
  const MonitorSnapshot({
    required this.instances,
    required this.history,
    required this.consumerName,
    this.flags = const <String, InstanceFlags>{},
    this.activeInstance,
    this.view = MonitorView.local,
    this.displayNames = const <String, String>{},
    this.advertisedEndpoints = const <String, String>{},
    this.bindEndpoints = const <String, String>{},
    this.operationBlockReasons = const <String, String>{},
  });

  /// Instance names in display order.
  final List<String> instances;

  /// Metric history per instance, oldest sample first. An instance with no
  /// entry (or an empty list) has no readings yet and renders as such —
  /// never as zeros.
  final Map<String, List<MetricSample>> history;

  /// Name of the consumer profile the workspace is pointed at.
  final String consumerName;

  /// Lock and isolation flags per instance. An instance with no entry has no
  /// known flags and reads as unlocked and shared — see [flagsFor].
  final Map<String, InstanceFlags> flags;

  /// The instance marked active in the workspace, if any.
  final String? activeInstance;

  /// The provider tab whose servers these readings belong to.
  final MonitorView view;

  /// Human names keyed by the stable identifiers in [instances].
  final Map<String, String> displayNames;

  /// Provider-advertised endpoints. They are never inferred from bind
  /// addresses because aliases and NAT can change both host and port.
  final Map<String, String> advertisedEndpoints;

  /// Interface addresses the server process actually binds, when known.
  final Map<String, String> bindEndpoints;

  /// Why provider operations are unavailable for a server, keyed by its
  /// stable identifier. A reason disables power and command actions while
  /// leaving read-only navigation available.
  final Map<String, String> operationBlockReasons;

  String displayNameFor(String instance) => displayNames[instance] ?? instance;

  String? advertisedEndpointFor(String instance) =>
      advertisedEndpoints[instance];

  String? bindEndpointFor(String instance) => bindEndpoints[instance];

  /// Every advertised endpoint for [instance], in provider order.
  List<String> advertisedEndpointsFor(String instance) =>
      _endpointList(advertisedEndpoints[instance]);

  /// Every bind endpoint for [instance], in provider order.
  List<String> bindEndpointsFor(String instance) =>
      _endpointList(bindEndpoints[instance]);

  String? operationBlockReasonFor(String instance) =>
      operationBlockReasons[instance];

  /// [instance]'s history, or an empty list when it has none.
  List<MetricSample> historyFor(String instance) =>
      history[instance] ?? const <MetricSample>[];

  /// [instance]'s flags, or unlocked-and-shared when none are known.
  InstanceFlags flagsFor(String instance) => flags[instance] ?? _defaultFlags;

  /// [instance]'s most recent sample, or null when it has none.
  MetricSample? latestFor(String instance) {
    final List<MetricSample> samples = historyFor(instance);
    return samples.isEmpty ? null : samples.last;
  }
}

List<String> _endpointList(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    return const <String>[];
  }
  return List<String>.unmodifiable(
    encoded.split('\n').where((String endpoint) => endpoint.isNotEmpty),
  );
}

/// The short label for a chart/window [range]: the cycled ranges get
/// their canonical names, anything else falls back to a compact duration.
String rangeLabel(Duration range) => switch (range.inMinutes) {
  15 => '15m',
  60 => '1h',
  360 => '6h',
  1440 => '24h',
  10080 => '7d',
  _ => formatCompactDuration(range),
};

/// The busy-spinner glyph for [frame] from [theme]'s glyph set.
///
/// A negative frame means the provider is idle and deliberately renders a
/// blank cell. The badge keeps its width without animating an idle dashboard.
String monitorSpinner(MonitorTheme theme, int frame) {
  if (frame < 0) {
    return ' ';
  }
  final List<String> spinner = theme.glyphs.spinner;
  return spinner[frame % spinner.length];
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

/// Pads [frame] to exactly [lines] rows of exactly [columns] visible columns
/// via [padMonitorFrame], and clips its hitboxes to the same rectangle: a
/// hitbox over a row or a column that padding clipped away can never be
/// clicked, so it has no business surviving in the result.
///
/// A hitbox past the last row, or starting past the last column, is dropped
/// whole; one that merely runs past the right edge keeps the columns that
/// were actually painted.
MonitorFrame padFrame(
  MonitorFrame frame, {
  required int columns,
  required int lines,
}) {
  final int width = columns < 0 ? 0 : columns;
  final List<MonitorHitbox> clipped = <MonitorHitbox>[];
  for (final MonitorHitbox hitbox in frame.hitboxes) {
    if (hitbox.row >= lines || hitbox.colStart >= width) {
      continue;
    }
    clipped.add(
      hitbox.colEnd <= width
          ? hitbox
          : MonitorHitbox(
              id: hitbox.id,
              row: hitbox.row,
              colStart: hitbox.colStart,
              colEnd: width,
              kind: hitbox.kind,
            ),
    );
  }
  return MonitorFrame(
    rows: padMonitorFrame(rows: frame.rows, columns: columns, lines: lines),
    hitboxes: clipped.toList(growable: false),
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
