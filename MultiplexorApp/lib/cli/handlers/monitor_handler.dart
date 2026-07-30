/// `runtime watch` — the full-screen monitor, and its one-shot snapshot.
///
/// Interactive runs land on exactly the dashboard the wizard lands on, with
/// the same flows behind every hand-off: this handler builds the wizard and
/// calls [InteractiveWizard.runMonitor], so the dispatch lives in one place.
/// `--once` is the scriptable half — one sweep, one frame, no terminal
/// required and no escape bytes emitted.
library;

import 'dart:io';

import '../../services/app_context.dart';
import '../../services/interactive_wizard.dart';
import '../../services/monitor/metric_sample.dart';
import '../../services/monitor/metrics_sampler.dart';
import '../../services/monitor/monitor_frame_util.dart';
import '../../services/monitor/monitor_hitbox.dart';
import '../../services/monitor/monitor_keymap.dart';
import '../../services/monitor/monitor_model.dart';
import '../../utils/process_runner.dart';
import '../../utils/terminal/theme.dart';
import '../../utils/user_prompt.dart';

/// Frame geometry for a snapshot with no terminal to measure — wide enough
/// for the full server row and tall enough for the bottom band, so piped
/// output is the same shape everywhere.
const int _snapshotColumns = 100;
const int _snapshotLines = 32;

/// Runs `runtime watch`. With `--once`, prints a single frame to stdout and
/// returns; otherwise opens the live dashboard.
Future<int> handleRuntimeWatch(List<String> args) async {
  if (args.contains('--once')) {
    return _printSnapshot();
  }
  if (!Ui.hasTerminal) {
    // start.sh keeps its own noise on stderr and so does this: stdout stays
    // the frame, whether or not `--once` was the way it was asked for.
    stderr.writeln(
      '[WARN] runtime watch needs an interactive terminal; '
      'printing a single frame instead (see runtime watch --once).',
    );
    return _printSnapshot();
  }

  final InteractiveWizard wizard = InteractiveWizard(
    consumerService: consumerService,
    passthrough: passthroughService,
    requestedConsumer: appContext.requestedConsumer,
  );
  await wizard.runMonitor();
  return 0;
}

/// Sweeps metrics once and writes one plain frame to stdout.
Future<int> _printSnapshot() async {
  // The lock and isolation columns are tee'd off the sampler's own capture
  // rather than asked for again, exactly as the live dashboard does it, so a
  // snapshot carries the same workspace facts a frame does.
  Map<String, InstanceFlags> flags = const <String, InstanceFlags>{};
  Future<String> captureMetrics() async {
    final String raw = await _captureMetrics();
    if (raw.isNotEmpty) {
      flags = metricsTsvFlagsByInstance(raw);
    }
    return raw;
  }

  final MetricsSampler sampler = MetricsSampler(captureMetrics: captureMetrics);
  await sampler.sweep();

  final List<String> instances = sampler.instances;
  final MonitorSnapshot snapshot = MonitorSnapshot(
    instances: instances,
    history: <String, List<MetricSample>>{
      for (final String instance in instances)
        instance: sampler.history(instance),
    },
    flags: flags,
    consumerName: (appContext.requestedConsumer ?? consumerService.readActive())
        .shortName,
    activeInstance: await _activeInstance(),
  );

  final (int columns, int lines) = _snapshotSize();
  final MonitorFrame frame = buildMonitorFrame(
    snapshot: snapshot,
    selectedIndex: 0,
    frame: 0,
    columns: columns,
    lines: lines,
    theme: _snapshotTheme(),
    range: monitorRanges.first,
    now: DateTime.now().toUtc(),
  );
  stdout.writeln(frame.rows.join('\n'));
  return 0;
}

/// Geometry for the snapshot: the real terminal when there is one big enough
/// to hold a frame, the default otherwise.
///
/// A snapshot is read by scripts and logs, not by whoever's window happens to
/// be open, so a terminal under the dashboard's minimum falls back to the
/// default rather than emitting the resize placeholder where the data should
/// be. `--once` always produces a data frame.
(int, int) _snapshotSize() {
  if (!stdout.hasTerminal) {
    return (_snapshotColumns, _snapshotLines);
  }
  final int columns = stdout.terminalColumns;
  final int lines = stdout.terminalLines;
  if (columns < monitorMinColumns || lines < monitorMinLines) {
    return (_snapshotColumns, _snapshotLines);
  }
  return (columns, lines);
}

/// A colorless theme for the snapshot, ASCII-only unless the locale says the
/// consumer of this output can render UTF-8. Either way it emits no escape
/// bytes, so the frame stays greppable.
///
/// The charset question is the same one the interactive theme asks, so it is
/// asked in the same place ([detectMonitorGlyphs]); only the color half is
/// overridden here.
MonitorTheme _snapshotTheme() {
  final MonitorGlyphs glyphs = detectMonitorGlyphs(
    env: Platform.environment,
    isTty: stdout.hasTerminal,
  );
  return glyphs.isAscii ? MonitorTheme.plainAscii() : MonitorTheme.plain();
}

/// One `runtime metrics` capture. A failed capture reads as no rows rather
/// than an error: an empty frame is a truthful snapshot of nothing running.
Future<String> _captureMetrics() async {
  final CapturedResult result = await passthroughService.capture(<String>[
    'runtime',
    'metrics',
  ]);
  return result.success ? result.stdout : '';
}

Future<String?> _activeInstance() async {
  final String? line = await passthroughService.captureStdoutLine(<String>[
    'instance',
    'current',
  ]);
  final String cleaned = (line ?? '').trim();
  return cleaned.isEmpty ? null : cleaned;
}
