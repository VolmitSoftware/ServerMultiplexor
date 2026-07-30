import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_detail_model.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

/// Fixed clock for every frame under test. UTC, as builders require.
final DateTime now = DateTime.utc(2026, 7, 30, 14, 5);

const Duration range = Duration(minutes: 15);

/// Builds a chronological run of samples for [instance] ending at [now],
/// one every 30 seconds, with plausible varying metrics.
List<MetricSample> runHistory(
  String instance, {
  int count = 40,
  RuntimeState state = RuntimeState.running,
  int? port = 25565,
  int? players = 7,
  int? maxPlayers = 40,
  double? tps = 19.6,
  int? latencyMs = 14,
  double? cpuPercent = 62.5,
  int? rssBytes = 3221225472,
  int? uptimeSeconds = 9042,
  String? version = '1.21.4',
  String? logPath = '/srv/mc/alpha/logs/latest.log',
}) {
  return List<MetricSample>.generate(count, (int index) {
    final double wobble = (index % 7) * 0.3;
    return MetricSample(
      ts: now.subtract(Duration(seconds: 30 * (count - 1 - index))),
      instance: instance,
      state: state,
      port: port,
      players: players == null ? null : players + (index % 3),
      maxPlayers: maxPlayers,
      tps: tps == null ? null : tps - wobble,
      latencyMs: latencyMs,
      cpuPercent: cpuPercent == null ? null : cpuPercent - wobble * 4,
      rssBytes: rssBytes == null ? null : rssBytes - index * 1048576,
      uptimeSeconds: uptimeSeconds == null ? null : uptimeSeconds + index * 30,
      version: version,
      logPath: logPath,
    );
  });
}

/// A stopped instance: present, but with no live readings at all.
List<MetricSample> stoppedHistory(String instance) => runHistory(
  instance,
  count: 4,
  state: RuntimeState.stopped,
  port: null,
  players: null,
  maxPlayers: null,
  tps: null,
  latencyMs: null,
  cpuPercent: null,
  rssBytes: null,
  uptimeSeconds: null,
  version: null,
  logPath: null,
);

MonitorSnapshot twoServers({String? active = 'alpha'}) => MonitorSnapshot(
  instances: const <String>['alpha', 'beta'],
  history: <String, List<MetricSample>>{
    'alpha': runHistory('alpha'),
    'beta': runHistory('beta', tps: 16.4, players: 2, cpuPercent: 18.0),
  },
  consumerName: 'survival',
  activeInstance: active,
);

List<String> stripAll(List<String> rows) =>
    rows.map(Ansi.strip).toList(growable: false);

/// Asserts [hits] and the rendered [rows] agree in both directions: every
/// hit points at the row its own instance was drawn on (name starting at
/// column 4, right after the panel rule and the selector), and every server
/// row that carries an instance name has exactly one hit.
void expectHitsMatchRows(
  List<String> rows,
  List<MonitorHitRow> hits,
  List<String> instances,
) {
  final Set<int> hitRows = <int>{};
  for (final MonitorHitRow hit in hits) {
    final String name = instances[hit.instanceIndex];
    expect(
      rows[hit.row].substring(4),
      startsWith(name),
      reason: 'hit row ${hit.row} should start instance $name at column 4',
    );
    expect(hitRows.add(hit.row), isTrue, reason: 'duplicate hit row');
  }
  expect(
    hits.map((MonitorHitRow hit) => hit.instanceIndex).toList(),
    List<int>.generate(hits.length, (int index) => index),
    reason: 'hits are the first N instances, in order',
  );

  // The reverse direction: no instance row was rendered without a hit.
  for (int row = 0; row < rows.length; row++) {
    if (hitRows.contains(row) || rows[row].length < 5) {
      continue;
    }
    for (final String name in instances) {
      expect(
        rows[row].substring(4),
        isNot(startsWith(name)),
        reason: 'row $row renders $name but has no hit',
      );
    }
  }
}

void expectExactFrame(List<String> rows, int columns, int lines) {
  expect(rows.length, lines, reason: 'row count for ${columns}x$lines');
  for (int index = 0; index < rows.length; index++) {
    expect(
      Ansi.visibleLength(rows[index]),
      columns,
      reason: 'row $index of ${columns}x$lines: "${Ansi.strip(rows[index])}"',
    );
  }
}

void main() {
  final MonitorTheme plain = MonitorTheme.plain();
  final MonitorTheme color = MonitorTheme.detect(
    env: const <String, String>{'COLORTERM': 'truecolor'},
    isTty: true,
  );

  group('rangeLabel', () {
    test('maps each cycled range to its short label', () {
      expect(rangeLabel(const Duration(minutes: 15)), '15m');
      expect(rangeLabel(const Duration(hours: 1)), '1h');
      expect(rangeLabel(const Duration(hours: 6)), '6h');
      expect(rangeLabel(const Duration(hours: 24)), '24h');
    });

    test('falls back to a compact duration for an off-cycle range', () {
      expect(rangeLabel(const Duration(minutes: 90)), '1h 30m');
    });
  });

  group('padMonitorFrame', () {
    test('pads short rows and a short row list to the exact frame size', () {
      final List<String> rows = padMonitorFrame(
        rows: <String>['abc', ''],
        columns: 6,
        lines: 4,
      );
      expect(rows, <String>['abc   ', '      ', '      ', '      ']);
    });

    test('clips long rows and drops rows past the frame height', () {
      final List<String> rows = padMonitorFrame(
        rows: <String>['abcdefgh', 'ij', 'kl'],
        columns: 4,
        lines: 2,
      );
      expect(rows, <String>['abcd', 'ij  ']);
    });

    test('keeps escapes intact while measuring only visible width', () {
      final List<String> rows = padMonitorFrame(
        rows: <String>['\x1B[31mred\x1B[0m'],
        columns: 5,
        lines: 1,
      );
      expect(Ansi.visibleLength(rows.single), 5);
      expect(rows.single, contains('\x1B[31m'));
    });

    test('treats negative sizes as empty rather than throwing', () {
      expect(
        padMonitorFrame(rows: <String>['abc'], columns: -4, lines: 2),
        <String>['', ''],
      );
      expect(
        padMonitorFrame(rows: <String>['abc'], columns: 4, lines: -1),
        isEmpty,
      );
    });
  });

  group('buildResizeRequiredFrame', () {
    test('renders the card with the current and minimum sizes', () {
      final List<String> rows = stripAll(
        buildResizeRequiredFrame(columns: 70, lines: 20, theme: plain),
      );
      expect(rows.join('\n'), contains('RESIZE REQUIRED'));
      expect(rows.join('\n'), contains('CURRENT 70x20'));
      expect(rows.join('\n'), contains('MINIMUM 80x24'));
    });

    test('is exactly the requested size at every size down to 1x1', () {
      for (final List<int> size in const <List<int>>[
        <int>[1, 1],
        <int>[3, 2],
        <int>[12, 5],
        <int>[40, 10],
        <int>[70, 20],
        <int>[79, 23],
      ]) {
        expectExactFrame(
          buildResizeRequiredFrame(
            columns: size[0],
            lines: size[1],
            theme: plain,
          ),
          size[0],
          size[1],
        );
      }
    });
  });

  group('buildMonitorFrame', () {
    test('renders a complete 80x24 layout with no bottom band', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 0,
        columns: 80,
        lines: 24,
        theme: plain,
        range: range,
        now: now,
      );
      expectExactFrame(rows, 80, 24);

      final List<String> stripped = stripAll(rows);
      final String joined = stripped.join('\n');
      expect(stripped.first, startsWith('┌─'));
      expect(joined, contains('MULTIPLEXOR'));
      expect(joined, contains('SERVERS'));
      expect(joined, contains('survival'));
      expect(joined, contains('[enter] open'));
      expect(
        joined,
        isNot(contains('· HOST')),
        reason: '24 lines is below the bottom-band floor of 30',
      );
    });

    test('shows the header roll-up with up/down counts, players and tps', () {
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: MonitorSnapshot(
            instances: const <String>['alpha', 'beta', 'gamma'],
            history: <String, List<MetricSample>>{
              'alpha': runHistory('alpha', tps: 20.0, players: 5),
              'beta': runHistory('beta', tps: 18.0, players: 3),
              'gamma': stoppedHistory('gamma'),
            },
            consumerName: 'survival',
            activeInstance: 'beta',
          ),
          selectedIndex: 0,
          frame: 1,
          columns: 100,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final String header = rows.take(4).join('\n');
      expect(header, contains('2 UP'));
      expect(header, contains('1 DOWN'));
      expect(header, contains('PLAYERS'));
      expect(header, contains('AVG TPS'));
      expect(header, contains('ACTIVE beta'));
      expect(header, contains('RANGE 15m'));
      expect(header, contains('3 SERVERS'));
      expect(RegExp(r'\d\d:\d\d').hasMatch(header), isTrue);
    });

    test('the chart axis ends on the same clock the header shows', () {
      // The header localizes `now` and the log tail carries local
      // timestamps, so a chart axis left in UTC puts two different clocks
      // in one frame. The right-hand tick is `now`, so it must read the
      // same as the header.
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: twoServers(),
          selectedIndex: 0,
          frame: 0,
          columns: 132,
          lines: 40,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final DateTime local = now.toLocal();
      final String clock =
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';

      expect(rows.take(4).join('\n'), contains(clock));

      final String axis = rows.lastWhere(
        (String row) => RegExp(r'\d\d:\d\d.*\d\d:\d\d').hasMatch(row),
        orElse: () => '',
      );
      expect(
        axis,
        isNot(isEmpty),
        reason: 'the bottom band should have a time axis',
      );
      // The row runs on into the host card, so the window's end tick is the
      // last clock on it rather than the one at the end of the line.
      expect(RegExp(r'\d\d:\d\d').allMatches(axis).last.group(0), clock);
    });

    test('marks the selected instance row with the selector glyph', () {
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: twoServers(active: null),
          selectedIndex: 1,
          frame: 0,
          columns: 80,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final String alphaRow = rows.firstWhere(
        (String row) => row.contains('alpha') && row.contains('running'),
      );
      final String betaRow = rows.firstWhere(
        (String row) => row.contains('beta') && row.contains('running'),
      );
      expect(betaRow, contains('▸ beta'));
      expect(alphaRow, isNot(contains('▸')));
    });

    test('renders a stopped instance with dashes and never a zero', () {
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: MonitorSnapshot(
            instances: const <String>['alpha', 'gamma'],
            history: <String, List<MetricSample>>{
              'alpha': runHistory('alpha'),
              'gamma': stoppedHistory('gamma'),
            },
            consumerName: 'survival',
          ),
          selectedIndex: 0,
          frame: 0,
          columns: 80,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final String gammaRow = rows.firstWhere(
        (String row) => row.contains('gamma'),
      );
      expect(gammaRow, contains('stopped'));
      expect(gammaRow, contains('–'));
      expect(
        RegExp(r'\d').hasMatch(gammaRow),
        isFalse,
        reason: 'a stopped row fabricates no numbers: "$gammaRow"',
      );
    });

    test('renders the empty-workspace row when there are no instances', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: const MonitorSnapshot(
          instances: <String>[],
          history: <String, List<MetricSample>>{},
          consumerName: 'survival',
        ),
        selectedIndex: 0,
        frame: 0,
        columns: 80,
        lines: 40,
        theme: plain,
        range: range,
        now: now,
      );
      expectExactFrame(rows, 80, 40);
      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('NO SERVERS'));
      expect(joined, contains('press n to create one'));
      expect(joined, contains('0/0 UP'));
      expect(joined, isNot(contains('· HOST')));
    });

    test('adds the bottom band at 132x40 with a TPS chart and a host card', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 1,
        frame: 2,
        columns: 132,
        lines: 40,
        theme: plain,
        range: range,
        now: now,
      );
      expectExactFrame(rows, 132, 40);

      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('┌─ BETA · TPS '));
      expect(joined, contains('┌─ BETA · HOST '));
      expect(joined, contains('20 ┤'), reason: 'forced 0..20 TPS gutter');
      expect(joined, contains('MEM'));
      expect(joined, contains('CPU'));
      expect(joined, contains('PING'));
    });

    test('caps the bottom band so the servers panel absorbs the slack', () {
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: twoServers(),
          selectedIndex: 0,
          frame: 0,
          columns: 132,
          lines: 40,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final int bandTop = rows.indexWhere(
        (String row) => row.contains('· TPS '),
      );
      expect(bandTop, greaterThan(0));
      // Band + footer fill the rest of the frame, and the band stops at 16.
      expect(rows.length - 1 - bandTop, 16);
      // Everything above it belongs to the header (4) and servers panel.
      expect(bandTop, 4 + 19);
      expect(rows[bandTop - 1], startsWith('└'));
    });

    test('drops whole footer hints instead of clipping them at 80 columns', () {
      const List<String> allHints = <String>[
        '[enter] open',
        'd detail',
        'R restart',
        'S stop',
        'X kill',
        'O console',
        'g consoles',
        'n new',
        'b build',
        'c consumer',
        'r range',
        'q quit',
      ];
      for (final int columns in <int>[80, 100, 132, 200]) {
        final List<String> rows = stripAll(
          buildMonitorFrame(
            snapshot: twoServers(),
            selectedIndex: 0,
            frame: 0,
            columns: columns,
            lines: 24,
            theme: plain,
            range: range,
            now: now,
          ),
        );
        final String footer = rows.last.trimRight();
        expect(footer, contains('[enter] open'), reason: 'at $columns');
        expect(footer, contains('d detail'), reason: 'at $columns');
        expect(footer, endsWith('q quit'), reason: 'at $columns');
        for (final String hint in footer.split(' · ')) {
          expect(allHints, contains(hint), reason: 'partial hint at $columns');
        }
      }
    });

    test('shows every footer hint once the terminal is wide enough', () {
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: twoServers(),
          selectedIndex: 0,
          frame: 0,
          columns: 132,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      expect(rows.last, contains('g consoles'));
      expect(rows.last, contains('b build'));
      expect(rows.last, contains('r range'));
    });

    test('inlays the wordmark as a gradient run under a truecolor theme', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 0,
        columns: 132,
        lines: 24,
        theme: color,
        range: range,
        now: now,
      );
      expect(Ansi.strip(rows.first), contains('MULTIPLEXOR'));
      expect(Ansi.visibleLength(rows.first), 132);
      // A gradient is several colour runs, not the single run a plain
      // panel title would emit.
      expect(
        RegExp(r'\x1B\[38;2;').allMatches(rows.first).length,
        greaterThan(3),
      );
    });

    test('is exactly the requested size across a spread of terminal sizes', () {
      for (final List<int> size in const <List<int>>[
        <int>[80, 24],
        <int>[81, 25],
        <int>[100, 30],
        <int>[132, 40],
        <int>[200, 60],
        <int>[80, 29],
        <int>[70, 20],
        <int>[40, 10],
        <int>[1, 1],
      ]) {
        expectExactFrame(
          buildMonitorFrame(
            snapshot: twoServers(),
            selectedIndex: 0,
            frame: 3,
            columns: size[0],
            lines: size[1],
            theme: plain,
            range: range,
            now: now,
          ),
          size[0],
          size[1],
        );
      }
    });

    test('stays exact with more instances than the servers panel can hold', () {
      final List<String> names = List<String>.generate(
        30,
        (int index) => 'srv-$index',
      );
      final MonitorSnapshot snapshot = MonitorSnapshot(
        instances: names,
        history: <String, List<MetricSample>>{
          for (final String name in names) name: runHistory(name, count: 6),
        },
        consumerName: 'survival',
      );
      expectExactFrame(
        buildMonitorFrame(
          snapshot: snapshot,
          selectedIndex: 0,
          frame: 0,
          columns: 80,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
        80,
        24,
      );
      expectExactFrame(
        buildMonitorFrame(
          snapshot: snapshot,
          selectedIndex: 0,
          frame: 0,
          columns: 132,
          lines: 40,
          theme: plain,
          range: range,
          now: now,
        ),
        132,
        40,
      );
    });

    test('falls back to the resize card below the 80x24 floor', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 0,
        columns: 70,
        lines: 20,
        theme: plain,
        range: range,
        now: now,
      );
      expectExactFrame(rows, 70, 20);
      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('RESIZE REQUIRED'));
      expect(joined, contains('CURRENT 70x20'));
      expect(joined, isNot(contains('MULTIPLEXOR')));
    });

    test('emits zero escape bytes under MonitorTheme.plain()', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 1,
        columns: 132,
        lines: 40,
        theme: plain,
        range: range,
        now: now,
      );
      expect(rows.any((String row) => row.contains('\x1B')), isFalse);
    });

    test('paints escapes under a truecolor theme while staying exact', () {
      final List<String> rows = buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 1,
        columns: 132,
        lines: 40,
        theme: color,
        range: range,
        now: now,
      );
      expectExactFrame(rows, 132, 40);
      expect(rows.any((String row) => row.contains('\x1B')), isTrue);
    });
  });

  group('monitorServerRowHits', () {
    test('maps rows to the instance rendered on them at 80x24', () {
      final MonitorSnapshot snapshot = twoServers();
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: snapshot,
          selectedIndex: 0,
          frame: 0,
          columns: 80,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      expectHitsMatchRows(
        rows,
        monitorServerRowHits(snapshot: snapshot, columns: 80, lines: 24),
        snapshot.instances,
      );
    });

    test('maps rows to the instance rendered on them at 132x40', () {
      final MonitorSnapshot snapshot = twoServers();
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: snapshot,
          selectedIndex: 1,
          frame: 0,
          columns: 132,
          lines: 40,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      expectHitsMatchRows(
        rows,
        monitorServerRowHits(snapshot: snapshot, columns: 132, lines: 40),
        snapshot.instances,
      );
    });

    test('only maps the instance rows the panel actually rendered', () {
      final List<String> names = List<String>.generate(
        30,
        (int index) => 'srv-$index',
      );
      final MonitorSnapshot snapshot = MonitorSnapshot(
        instances: names,
        history: <String, List<MetricSample>>{
          for (final String name in names) name: runHistory(name, count: 6),
        },
        consumerName: 'survival',
      );
      final List<String> rows = stripAll(
        buildMonitorFrame(
          snapshot: snapshot,
          selectedIndex: 0,
          frame: 0,
          columns: 80,
          lines: 24,
          theme: plain,
          range: range,
          now: now,
        ),
      );
      final List<MonitorHitRow> hits = monitorServerRowHits(
        snapshot: snapshot,
        columns: 80,
        lines: 24,
      );
      expect(hits, isNotEmpty);
      expect(hits.length, lessThan(names.length));
      expectHitsMatchRows(rows, hits, names);
    });

    test('returns no hits below the floor or with no instances', () {
      expect(
        monitorServerRowHits(snapshot: twoServers(), columns: 70, lines: 20),
        isEmpty,
      );
      expect(
        monitorServerRowHits(
          snapshot: const MonitorSnapshot(
            instances: <String>[],
            history: <String, List<MetricSample>>{},
            consumerName: 'survival',
          ),
          columns: 132,
          lines: 40,
        ),
        isEmpty,
      );
    });
  });

  group('buildDetailFrame', () {
    List<String> detail({
      int columns = 132,
      int lines = 40,
      List<String>? logLines,
      List<MetricSample>? history,
      MonitorTheme? theme,
    }) {
      return buildDetailFrame(
        instance: 'alpha',
        history: history ?? runHistory('alpha'),
        logLines:
            logLines ??
            List<String>.generate(
              40,
              (int index) =>
                  '[14:0${index % 10}:11] [Server thread/INFO]: '
                  'tick $index completed',
            ),
        frame: 1,
        columns: columns,
        lines: lines,
        theme: theme ?? MonitorTheme.plain(),
        range: range,
        now: now,
      );
    }

    test('renders four charts, a log panel and a footer at 132x40', () {
      final List<String> rows = detail();
      expectExactFrame(rows, 132, 40);

      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('┌─ TPS '));
      expect(joined, contains('┌─ CPU % '));
      expect(joined, contains('┌─ MEM MiB '));
      expect(joined, contains('┌─ PLAYERS '));
      expect(joined, contains('┌─ LOG '));
      expect(joined, contains('latest.log'));
      expect(joined, contains('[esc] back'));
      expect(joined, contains('DETAIL · 15m'));
      expect(joined, contains('alpha'));
    });

    test('stacks the charts full width at 90x32', () {
      final List<String> rows = detail(columns: 90, lines: 32);
      expectExactFrame(rows, 90, 32);
      final List<String> stripped = stripAll(rows);
      final String joined = stripped.join('\n');
      expect(joined, contains('┌─ TPS '));
      expect(joined, contains('┌─ LOG '));
      for (final String row in stripped) {
        expect(
          row.split('┌').length - 1,
          lessThanOrEqualTo(1),
          reason: 'stacked layout puts at most one panel per row: "$row"',
        );
      }
    });

    test('drops trailing header facts instead of clipping them at 80x24', () {
      final String wide = stripAll(detail()).join('\n');
      final String narrow = stripAll(detail(columns: 80, lines: 24)).join('\n');
      expect(wide, contains('UP '));
      expect(narrow, contains('STATE running'));
      expect(narrow, contains('PLAYERS'));
      expect(narrow, isNot(contains('UP ')));
    });

    test('renders the log-empty row when there are no log lines', () {
      final String joined = stripAll(
        detail(logLines: const <String>[]),
      ).join('\n');
      expect(joined, contains('log empty'));
      expect(joined, contains('latest.log'));
    });

    test('badges the log panel "no log" when the sample has no log path', () {
      final String joined = stripAll(
        detail(history: stoppedHistory('alpha')),
      ).join('\n');
      expect(joined, contains('no log'));
    });

    test('renders n/a rather than zeros when the latest sample is bare', () {
      final String joined = stripAll(
        detail(history: stoppedHistory('alpha')),
      ).join('\n');
      expect(joined, contains('n/a'));
      expect(joined, contains('stopped'));
    });

    test('falls back to the resize card below the floor', () {
      final List<String> rows = detail(columns: 70, lines: 20);
      expectExactFrame(rows, 70, 20);
      expect(stripAll(rows).join('\n'), contains('RESIZE REQUIRED'));
    });

    test('is exactly the requested size across a spread of sizes', () {
      for (final List<int> size in const <List<int>>[
        <int>[80, 24],
        <int>[90, 32],
        <int>[99, 26],
        <int>[100, 30],
        <int>[132, 40],
        <int>[200, 60],
        <int>[1, 1],
      ]) {
        expectExactFrame(
          detail(columns: size[0], lines: size[1]),
          size[0],
          size[1],
        );
      }
    });

    test('emits zero escape bytes under MonitorTheme.plain()', () {
      expect(detail().any((String row) => row.contains('\x1B')), isFalse);
    });

    test('paints escapes under a truecolor theme while staying exact', () {
      final List<String> rows = detail(theme: color);
      expectExactFrame(rows, 132, 40);
      expect(rows.any((String row) => row.contains('\x1B')), isTrue);
    });
  });
}
