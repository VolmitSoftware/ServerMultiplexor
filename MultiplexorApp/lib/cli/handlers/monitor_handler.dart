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
  final MetricsSampler sampler = MetricsSampler(
    captureMetrics: _captureMetrics,
  );
  await sampler.sweep();

  final List<String> instances = sampler.instances;
  final MonitorSnapshot snapshot = MonitorSnapshot(
    instances: instances,
    history: <String, List<MetricSample>>{
      for (final String instance in instances)
        instance: sampler.history(instance),
    },
    consumerName: (appContext.requestedConsumer ?? consumerService.readActive())
        .shortName,
    activeInstance: await _activeInstance(),
  );

  final bool measurable = stdout.hasTerminal;
  final List<String> rows = buildMonitorFrame(
    snapshot: snapshot,
    selectedIndex: 0,
    frame: 0,
    columns: measurable ? stdout.terminalColumns : _snapshotColumns,
    lines: measurable ? stdout.terminalLines : _snapshotLines,
    theme: _snapshotTheme(),
    range: monitorRanges.first,
    now: DateTime.now().toUtc(),
  );
  stdout.writeln(rows.join('\n'));
  return 0;
}

/// A colorless theme for the snapshot, ASCII-only unless the locale says the
/// consumer of this output can render UTF-8. Either way it emits no escape
/// bytes, so the frame stays greppable.
MonitorTheme _snapshotTheme() {
  final Map<String, String> env = Platform.environment;
  final String locale =
      '${env['LC_ALL'] ?? ''}|${env['LC_CTYPE'] ?? ''}|${env['LANG'] ?? ''}'
          .toUpperCase();
  final bool utf8Locale = locale.contains('UTF-8') || locale.contains('UTF8');
  return utf8Locale ? MonitorTheme.plain() : MonitorTheme.plainAscii();
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
