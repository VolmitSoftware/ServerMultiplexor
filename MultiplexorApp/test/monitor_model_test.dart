import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_detail_model.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_landing.dart';
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
  double? networkRxPacketsPerSecond = 120,
  double? networkTxPacketsPerSecond = 80,
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
      networkRxPacketsPerSecond: networkRxPacketsPerSecond == null
          ? null
          : networkRxPacketsPerSecond + index % 5,
      networkTxPacketsPerSecond: networkTxPacketsPerSecond == null
          ? null
          : networkTxPacketsPerSecond + index % 3,
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
  networkRxPacketsPerSecond: null,
  networkTxPacketsPerSecond: null,
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

/// One running instance and one stopped one — the fleet the state-aware
/// selection bar and the `n/a` discipline are read against.
MonitorSnapshot mixedFleet() => MonitorSnapshot(
  instances: const <String>['alpha', 'gamma'],
  history: <String, List<MetricSample>>{
    'alpha': runHistory('alpha'),
    'gamma': stoppedHistory('gamma'),
  },
  consumerName: 'survival',
  activeInstance: 'alpha',
);

/// A fleet far taller than any slim list can show, for the scroll window.
MonitorSnapshot manyServers() {
  final List<String> names = List<String>.generate(
    30,
    (int index) => 'srv-$index',
  );
  return MonitorSnapshot(
    instances: names,
    history: <String, List<MetricSample>>{
      for (final String name in names) name: runHistory(name, count: 6),
    },
    consumerName: 'survival',
  );
}

/// A workspace with nothing in it yet.
MonitorSnapshot emptyWorkspace() => const MonitorSnapshot(
  instances: <String>[],
  history: <String, List<MetricSample>>{},
  consumerName: 'survival',
);

List<String> stripAll(List<String> rows) =>
    rows.map(Ansi.strip).toList(growable: false);

/// The columns the fleet table's name field occupies in a stripped row: the
/// panel rule and a space (2), the selector and a space (2), the status
/// bullet and a space (2), then the 20-column name.
const int _nameStart = 6;
const int _nameEnd = 26;

/// The instance name rendered on [row] of a stripped frame, or the empty
/// string when the row is too short to carry one.
String nameOnRow(String row) => row.length < _nameEnd
    ? ''
    : row.substring(_nameStart, _nameEnd).trimRight();

/// The server-row hitboxes among [hits], in emission order.
List<MonitorHitbox> serverHits(List<MonitorHitbox> hits) => hits
    .where((MonitorHitbox hit) => hit.kind == MonitorHitKind.serverRow)
    .toList(growable: false);

/// The id of the [MonitorHitKind.button] hitbox covering ([row], [col]), or
/// null when no button covers it.
String? buttonAt(
  List<MonitorHitbox> hits, {
  required int row,
  required int col,
}) {
  for (final MonitorHitbox hit in hits) {
    if (hit.kind == MonitorHitKind.button &&
        hit.row == row &&
        col >= hit.colStart &&
        col < hit.colEnd) {
      return hit.id;
    }
  }
  return null;
}

/// Asserts the server hitboxes and the rendered [rows] agree in both
/// directions: the hits are exactly [window] in order, each points at the
/// row its own instance was drawn on, and no rendered instance row was left
/// without a hit.
void expectServerHits(
  List<String> rows,
  List<MonitorHitbox> hits,
  List<String> window, {
  int columns = 80,
}) {
  final List<MonitorHitbox> servers = serverHits(hits);
  expect(
    servers.map((MonitorHitbox hit) => hit.id).toList(),
    <String>[for (final String name in window) '$serverHitPrefix$name'],
    reason: 'the visible window, in order',
  );

  final Set<int> hitRows = <int>{};
  for (final MonitorHitbox hit in servers) {
    expect(hit.colStart, 0);
    expect(hit.colEnd, columns, reason: 'a server hit spans the full row');
    final String name = hit.id.substring(serverHitPrefix.length);
    expect(
      nameOnRow(rows[hit.row]),
      name,
      reason: 'hit row ${hit.row} should render instance $name',
    );
    expect(hitRows.add(hit.row), isTrue, reason: 'duplicate hit row');
  }

  // The reverse direction: no instance row was rendered without a hit.
  for (int row = 0; row < rows.length; row++) {
    if (hitRows.contains(row)) {
      continue;
    }
    expect(
      window,
      isNot(contains(nameOnRow(rows[row]))),
      reason: 'row $row renders an instance but has no hit',
    );
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
      expect(rangeLabel(const Duration(days: 7)), '7d');
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

  group('padFrame', () {
    test('pads rows to size and drops hitboxes past the frame height', () {
      const MonitorFrame frame = MonitorFrame(
        rows: <String>['abc', 'def', 'ghi'],
        hitboxes: <MonitorHitbox>[
          MonitorHitbox(
            id: 'server:alpha',
            row: 0,
            colStart: 0,
            colEnd: 3,
            kind: MonitorHitKind.serverRow,
          ),
          MonitorHitbox(
            id: 'server:beta',
            row: 2,
            colStart: 0,
            colEnd: 3,
            kind: MonitorHitKind.serverRow,
          ),
        ],
      );
      final MonitorFrame padded = padFrame(frame, columns: 5, lines: 2);
      expect(padded.rows, <String>['abc  ', 'def  ']);
      expect(padded.hitboxes, <MonitorHitbox>[frame.hitboxes.first]);
    });

    test('clamps a hitbox past the right edge and drops one beyond it', () {
      const MonitorFrame frame = MonitorFrame(
        rows: <String>['abcdefghij'],
        hitboxes: <MonitorHitbox>[
          MonitorHitbox(
            id: 'wide',
            row: 0,
            colStart: 2,
            colEnd: 40,
            kind: MonitorHitKind.button,
          ),
          MonitorHitbox(
            id: 'offscreen',
            row: 0,
            colStart: 6,
            colEnd: 9,
            kind: MonitorHitKind.button,
          ),
        ],
      );
      final MonitorFrame padded = padFrame(frame, columns: 6, lines: 1);
      expect(padded.hitboxes.length, 1);
      expect(padded.hitboxes.single.id, 'wide');
      expect(padded.hitboxes.single.colStart, 2);
      expect(
        padded.hitboxes.single.colEnd,
        6,
        reason: 'a click can never land past the last painted column',
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
    MonitorFrame frameOf({
      MonitorSnapshot? snapshot,
      int selectedIndex = 0,
      int columns = 80,
      int lines = 24,
      MonitorTheme? theme,
      String? hoveredId,
      String? pressedId,
      Duration window = range,
      int spinner = 0,
      DateTime? clock,
    }) => buildMonitorFrame(
      snapshot: snapshot ?? twoServers(),
      selectedIndex: selectedIndex,
      frame: spinner,
      columns: columns,
      lines: lines,
      theme: theme ?? plain,
      range: window,
      now: now,
      clockNow: clock ?? now,
      hoveredId: hoveredId,
      pressedId: pressedId,
    );

    test(
      'stacks header, kpi strip, body, both bars and the footer at 80x24',
      () {
        final MonitorFrame frame = frameOf();
        expectExactFrame(frame.rows, 80, 24);
        final List<String> rows = stripAll(frame.rows);

        expect(rows[0], startsWith('┌─'));
        expect(rows.take(3).join('\n'), contains('MULTIPLEXOR'));
        expect(rows[1], contains('ACTIVE alpha · RANGE 15m · 2 SERVERS'));
        expect(rows[2], startsWith('└'), reason: 'a three-row header');

        // One three-card strip: every title on the same border row.
        expect(rows[3], contains('FLEET'));
        expect(rows[3], contains('TPS'));
        expect(rows[3], contains('HOST'));
        expect(rows[5], startsWith('└'));

        // The body: the full-width fleet table over the selected server's
        // card. Two running servers at 24 lines: a 5-row table (header row
        // plus one row per instance) and a 10-row card.
        expect(rows[6], startsWith('┌─ SERVERS '));
        expect(rows[6], contains('2/2 UP'));
        expect(rows[7], contains('NAME'));
        expect(rows[7], contains('STATE'));
        expect(nameOnRow(rows[8]), 'alpha');
        expect(nameOnRow(rows[9]), 'beta');
        expect(rows[10], startsWith('└'));
        expect(rows[11], startsWith('┌─ ALPHA '));
        expect(rows[11], contains('running · 15m'));
        expect(rows[20], startsWith('└'));

        expect(rows[21], contains('[ STOP ]'));
        expect(rows[21], contains('[ DETAIL ]'));
        expect(rows[22], contains('[ + NEW ]'));
        expect(rows[22], contains('[ CONSOLES ]'));
        expect(rows[23], contains('q quit'));
      },
    );

    test('keeps the header to the workspace facts the kpi strip omits', () {
      // The fleet numbers moved to the KPI strip. A header that repeats them
      // one row above spends a row of the body saying the same thing twice.
      final List<String> rows = stripAll(
        frameOf(
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
          columns: 100,
          spinner: 1,
        ).rows,
      );
      final String header = rows.take(3).join('\n');
      expect(header, contains('MULTIPLEXOR'));
      expect(header, contains('survival'), reason: 'the consumer badge');
      expect(RegExp(r'\d\d:\d\d').hasMatch(header), isTrue);
      expect(header, contains('ACTIVE beta · RANGE 15m · 3 SERVERS'));
      expect(header, isNot(contains('UP')));
      expect(header, isNot(contains('DOWN')));
      expect(header, isNot(contains('PLAYERS')));
      expect(header, isNot(contains('AVG TPS')));
    });

    test('an unsampled instance is not counted as up', () {
      // MonitorSnapshot documents an instance with no history as "no readings
      // yet ... never as zeros". The roll-up has to agree: an instance
      // nothing has been heard from is neither up nor stopped, so the fleet
      // card counts what is up out of the total rather than claiming a state
      // for every member.
      final List<String> rows = stripAll(
        frameOf(
          snapshot: const MonitorSnapshot(
            instances: <String>['alpha', 'beta', 'gamma'],
            history: <String, List<MetricSample>>{},
            consumerName: 'survival',
          ),
          columns: 100,
        ).rows,
      );
      expect(rows.take(3).join('\n'), contains('3 SERVERS'));
      expect(rows[6], contains('0/3 UP'), reason: 'the slim list badge');
      expect(rows.sublist(3, 6).join('\n'), contains('0/3 UP'));
    });

    test('a stopped instance is not counted as up', () {
      final List<String> rows = stripAll(
        frameOf(snapshot: mixedFleet(), columns: 100).rows,
      );
      expect(rows.sublist(3, 6).join('\n'), contains('1/2 UP'));
      expect(rows[6], contains('1/2 UP'));
    });

    test('reads the fleet roll-up into the three kpi cards', () {
      final String kpi = stripAll(
        frameOf(columns: 100).rows,
      ).sublist(3, 6).join('\n');
      expect(kpi, contains('2/2 UP'));
      expect(kpi, contains('PLAYERS'));
      // Both fleet members' last reading, averaged: (18.4 + 15.2) / 2.
      expect(kpi, contains('16.8'));
      expect(kpi, contains('MEM'));
      expect(kpi, contains('CPU'));
    });

    test('renders every kpi reading as n/a when nothing has been sampled', () {
      final String kpi = stripAll(
        frameOf(
          snapshot: const MonitorSnapshot(
            instances: <String>['alpha', 'beta'],
            history: <String, List<MetricSample>>{},
            consumerName: 'survival',
          ),
          columns: 100,
        ).rows,
      ).sublist(3, 6).join('\n');
      expect(kpi, contains('0/2 UP'));
      expect(
        RegExp('n/a').allMatches(kpi).length,
        4,
        reason: 'players, tps, memory and cpu each read n/a',
      );
      expect(
        kpi,
        contains('–'),
        reason: 'an unread meter is a dash run, never an empty bar',
      );
    });

    test('never clips a kpi reading, however wide the fleet counts run', () {
      // The cards are sized against the readings as rendered, not against a
      // budget: a clipped `CPU 150%` reads as `CPU 150`, which is a smaller
      // load than the one measured. The meter gives up cells instead.
      for (final int count in <int>[1, 5, 12, 100]) {
        final List<String> names = List<String>.generate(
          count,
          (int index) => 'srv-$index',
        );
        final String kpi = stripAll(
          frameOf(
            snapshot: MonitorSnapshot(
              instances: names,
              history: <String, List<MetricSample>>{
                for (final String name in names)
                  name: runHistory(name, count: 4, cpuPercent: 150.0),
              },
              consumerName: 'survival',
            ),
            columns: 80,
          ).rows,
        ).sublist(3, 6).join('\n');
        expect(kpi, contains('$count/$count UP'), reason: 'at $count');
        expect(kpi, contains('PLAYERS'), reason: 'at $count');
        expect(
          RegExp(r'\d[BKMGTP] · CPU \d+%').hasMatch(kpi),
          isTrue,
          reason: 'at $count both readings keep their unit: $kpi',
        );
      }
    });

    test('marks the selection with an accent selector in the fleet table', () {
      final List<String> rows = stripAll(
        frameOf(snapshot: twoServers(active: null), selectedIndex: 1).rows,
      );
      expect(nameOnRow(rows[8]), 'alpha');
      expect(nameOnRow(rows[9]), 'beta');
      expect(rows[8][2], ' ');
      expect(rows[9][2], '▸');
      expect(rows[8][4], '●', reason: 'a running instance keeps its bullet');
    });

    test('shows the selector on a hovered row that is not the selection', () {
      final List<String> rows = stripAll(
        frameOf(selectedIndex: 0, hoveredId: '${serverHitPrefix}beta').rows,
      );
      expect(rows[8][2], '▸', reason: 'the selection');
      expect(rows[9][2], '▸', reason: 'the hover');
    });

    test('paints a hovered row selector with the accent tone', () {
      final List<String> rows = frameOf(
        selectedIndex: 0,
        hoveredId: '${serverHitPrefix}beta',
        theme: color,
      ).rows;
      expect(rows[9], contains('${color.accent}▸'));
    });

    test('reads each instance state and readings into its table row', () {
      final List<String> rows = stripAll(
        frameOf(snapshot: mixedFleet(), columns: 132, lines: 40).rows,
      );
      final String alpha = rows[8];
      expect(nameOnRow(alpha), 'alpha');
      expect(alpha, contains('running'));
      // The last generated sample: 19.6 minus its (39 % 7) * 0.3 wobble.
      expect(alpha, contains('18.4'), reason: 'the latest TPS reading');
      expect(alpha, contains('3.0G'), reason: 'the latest RSS reading');

      final String gamma = rows[9];
      expect(nameOnRow(gamma), 'gamma');
      expect(gamma, contains('stopped'));
      expect(
        RegExp(r'\d').hasMatch(gamma.replaceAll('gamma', '')),
        isFalse,
        reason: 'a stopped instance fabricates no readings: "$gamma"',
      );
    });

    test('expands a running selection into side-by-side charts and facts', () {
      final MonitorFrame frame = frameOf(
        columns: 132,
        lines: 40,
        selectedIndex: 1,
      );
      expectExactFrame(frame.rows, 132, 40);
      final List<String> rows = stripAll(frame.rows);

      // 31 body rows: the card grows to its 15-row ceiling and the table
      // keeps the other 16, so the card's top border sits on row 22.
      expect(rows[22], startsWith('┌─ BETA '));
      expect(rows[22], contains('running · 15m'));

      final String card = rows.sublist(22, 37).join('\n');
      final String labels = rows[23];
      expect(labels, contains('TPS'));
      expect(labels, contains('CPU %'));
      expect(labels, contains('MEM MiB'));
      expect(card, contains('20 ┤'), reason: 'forced 0..20 TPS gutter');
      expect(card, contains('NETWORK PPS'));
      expect(card, contains('RX'));
      expect(card, contains('TX'));
      expect(card, contains('100 ┤'), reason: 'forced 0..100 CPU gutter');
      expect(card, contains('PLAYERS'));
      expect(card, contains('PING'));
      expect(card, contains('MEM 3.0G'));
      expect(card, contains('1.21.4'));
    });

    test('collapses a stopped selection to one quiet line, no chart grid', () {
      final List<String> rows = stripAll(
        frameOf(
          snapshot: mixedFleet(),
          selectedIndex: 1,
          columns: 132,
          lines: 40,
        ).rows,
      );

      // An idle card is three rows on the floor of the body; everything
      // above it belongs to the fleet table.
      expect(rows[34], startsWith('┌─ GAMMA '));
      expect(rows[34], contains('stopped · 15m'));
      expect(rows[35], contains('stopped · START to launch'));
      expect(
        RegExp(r'\d').hasMatch(rows[35]),
        isFalse,
        reason: 'a stopped card fabricates no readings: "${rows[35]}"',
      );
      expect(rows[36], startsWith('└'));
      expect(
        rows.sublist(34, 37).join('\n'),
        isNot(contains('┤')),
        reason: 'no empty chart grid for a server with nothing to plot',
      );
    });

    test('tells an unsampled selection apart from a stopped one', () {
      final List<String> rows = stripAll(
        frameOf(
          snapshot: const MonitorSnapshot(
            instances: <String>['alpha'],
            history: <String, List<MetricSample>>{},
            consumerName: 'survival',
          ),
        ).rows,
      );
      expect(rows.join('\n'), contains('no data · waiting for a first sample'));
    });

    test('keeps the live header clock independent from chart time', () {
      final DateTime clockNow = now.add(const Duration(minutes: 7));
      final List<String> rows = stripAll(
        frameOf(columns: 132, lines: 40, clock: clockNow).rows,
      );
      String localClock(DateTime value) {
        final DateTime local = value.toLocal();
        return '${local.hour.toString().padLeft(2, '0')}:'
            '${local.minute.toString().padLeft(2, '0')}';
      }

      expect(rows.take(3).join('\n'), contains(localClock(clockNow)));

      final String axis = rows.lastWhere(
        (String row) => RegExp(r'\d\d:\d\d.*\d\d:\d\d').hasMatch(row),
        orElse: () => '',
      );
      expect(axis, isNot(isEmpty), reason: 'the chart should have a time axis');
      expect(
        RegExp(r'\d\d:\d\d').allMatches(axis).last.group(0),
        localClock(now),
      );
    });

    test('offers START on a stopped selection and STOP on a running one', () {
      final List<String> stopped = stripAll(
        frameOf(snapshot: mixedFleet(), selectedIndex: 1).rows,
      );
      expect(stopped[21], contains('[ START ]'));
      expect(stopped[21], contains('[ DETAIL ]'));
      expect(stopped[21], contains('[ MORE ]'));
      expect(stopped[21], isNot(contains('[ STOP ]')));
      expect(stopped[21], isNot(contains('[ RESTART ]')));

      final List<String> running = stripAll(
        frameOf(snapshot: mixedFleet(), selectedIndex: 0).rows,
      );
      expect(running[21], contains('[ STOP ]'));
      expect(running[21], contains('[ RESTART ]'));
      expect(running[21], contains('[ CONSOLE ]'));
      expect(running[21], isNot(contains('[ START ]')));
    });

    test('shows every remote address and disables blocked operations', () {
      final MonitorFrame frame = frameOf(
        snapshot: MonitorSnapshot(
          instances: const <String>['alpha'],
          history: <String, List<MetricSample>>{'alpha': runHistory('alpha')},
          consumerName: 'remote:production',
          view: MonitorView.remote,
          displayNames: const <String, String>{'alpha': 'Survival One'},
          advertisedEndpoints: const <String, String>{
            'alpha': 'play.example.test:25565\nalt.example.test:25566',
          },
          bindEndpoints: const <String, String>{
            'alpha': '0.0.0.0:25565\n[::]:25566',
          },
          operationBlockReasons: const <String, String>{
            'alpha': 'server is suspended',
          },
        ),
        columns: 132,
        lines: 40,
      );
      final String text = stripAll(frame.rows).join('\n');
      final Set<String> hits = frame.hitboxes
          .where((MonitorHitbox hit) => hit.kind == MonitorHitKind.button)
          .map((MonitorHitbox hit) => hit.id)
          .toSet();

      expect(text, contains('SURVIVAL ONE'));
      expect(text, contains('BLOCKED: server is suspended'));
      expect(
        text,
        contains('ADVERTISED play.example.test:25565 · alt.example.test:25566'),
      );
      expect(text, contains('BIND 0.0.0.0:25565 · [::]:25566'));
      expect(text, contains('[ STOP ]'));
      expect(text, contains('[ RESTART ]'));
      expect(text, contains('[ CONSOLE ]'));
      expect(hits, isNot(contains('act:stop')));
      expect(hits, isNot(contains('act:restart')));
      expect(hits, isNot(contains('act:console')));
      expect(hits, containsAll(<String>['act:detail', 'act:more']));
    });

    test('empty Remote steers to connection instead of new server', () {
      final MonitorFrame frame = frameOf(
        snapshot: const MonitorSnapshot(
          instances: <String>[],
          history: <String, List<MetricSample>>{},
          consumerName: 'remote:not connected',
          view: MonitorView.remote,
        ),
        columns: 132,
        lines: 40,
      );
      final String text = stripAll(frame.rows).join('\n');
      final Set<String> hits = frame.hitboxes
          .where((MonitorHitbox hit) => hit.kind == MonitorHitKind.button)
          .map((MonitorHitbox hit) => hit.id)
          .toSet();

      expect(text, contains('REMOTE NOT CONNECTED'));
      expect(text, contains('[ CONNECTION ]'));
      expect(text, isNot(contains('[ + NEW ]')));
      expect(hits, contains('ws:connect'));
      expect(hits, isNot(contains('ws:new')));
    });

    test('connected empty Remote still offers server creation', () {
      final MonitorFrame frame = frameOf(
        snapshot: const MonitorSnapshot(
          instances: <String>[],
          history: <String, List<MetricSample>>{},
          consumerName: 'remote:production',
          view: MonitorView.remote,
        ),
        columns: 132,
        lines: 40,
      );
      final String text = stripAll(frame.rows).join('\n');

      expect(text, contains('NO SERVERS'));
      expect(text, contains('[ + NEW ]'));
      expect(text, contains('[ CONNECTION ]'));
    });

    test('paints only the hovered chip with the accent tone', () {
      final List<String> rows = frameOf(
        theme: color,
        hoveredId: 'act:stop',
      ).rows;
      expect(rows[21], contains('${color.bold}${color.accent}[ STOP ]'));
      expect(
        rows[21],
        isNot(contains('${color.bold}${color.accent}[ RESTART ]')),
      );
      expect(
        rows[22],
        isNot(contains('${color.bold}${color.accent}[ + NEW ]')),
      );
    });

    test('flashes the pressed chip instead of its hover tone', () {
      final List<String> rows = frameOf(
        theme: color,
        hoveredId: 'ws:new',
        pressedId: 'ws:new',
      ).rows;
      expect(rows[22], contains('${color.bold}${color.textStrong}[ + NEW ]'));
    });

    test('renders the empty workspace with a prompt and a new-server chip', () {
      final MonitorFrame frame = frameOf(snapshot: emptyWorkspace(), lines: 40);
      expectExactFrame(frame.rows, 80, 40);
      final List<String> rows = stripAll(frame.rows);
      final String joined = rows.join('\n');

      expect(joined, contains('NO SERVERS'));
      expect(joined, contains('0/0 UP'));
      expect(serverHits(frame.hitboxes), isEmpty);
      expect(
        joined,
        isNot(contains('[ DETAIL ]')),
        reason: 'no selection means no selection bar',
      );

      final int promptRow = rows.indexWhere(
        (String row) => row.contains('NO SERVERS'),
      );
      final int chipRow = rows.indexWhere(
        (String row) => row.contains('[ + NEW ]'),
      );
      expect(chipRow, promptRow + 1);
      final int at = rows[chipRow].indexOf('[ + NEW ]');
      expect(buttonAt(frame.hitboxes, row: chipRow, col: at), 'ws:new');
      expect(rows.last, contains('q quit'));
      expect(rows[rows.length - 2], contains('[ CONSOLES ]'));
    });

    test('drops whole footer hints instead of clipping them at 80 columns', () {
      const List<String> allHints = <String>[
        '[tab] local/remote',
        '[enter] open',
        'd detail',
        'Shift+R repaint',
        'S stop',
        'X kill',
        'O console',
        'g consoles',
        'n new',
        'b build',
        'w workspace',
        'c consumer',
        'r range',
        'q quit',
      ];
      for (final int columns in <int>[80, 100, 132, 200]) {
        final List<String> rows = stripAll(frameOf(columns: columns).rows);
        final String footer = rows.last.trimRight();
        expect(footer, contains('[enter] open'), reason: 'at $columns');
        expect(footer, contains('d detail'), reason: 'at $columns');
        expect(footer, contains('Shift+R repaint'), reason: 'at $columns');
        expect(footer, endsWith('q quit'), reason: 'at $columns');
        for (final String hint in footer.split(' · ')) {
          expect(allHints, contains(hint), reason: 'partial hint at $columns');
        }
      }
    });

    test('shows every footer hint once the terminal is wide enough', () {
      final List<String> rows = stripAll(frameOf(columns: 200).rows);
      expect(rows.last, contains('g consoles'));
      expect(rows.last, contains('b build'));
      expect(rows.last, contains('w workspace'));
      expect(rows.last, contains('r range'));
    });

    test('shows provider-specific controls in the Remote footer', () {
      final List<String> rows = stripAll(
        frameOf(
          snapshot: const MonitorSnapshot(
            instances: <String>[],
            history: <String, List<MetricSample>>{},
            consumerName: 'remote:production',
            view: MonitorView.remote,
          ),
          columns: 200,
          lines: 40,
        ).rows,
      );
      final String footer = rows.last.trimRight();

      expect(footer, contains('[tab] local/remote'));
      expect(footer, contains('Shift+R repaint'));
      expect(footer, contains('S stop'));
      expect(footer, contains('X kill'));
      expect(footer, contains('O live console'));
      expect(footer, contains('n new'));
      expect(footer, contains('b bulk'));
      expect(footer, contains('w workspace'));
      expect(footer, contains('c connection'));
      expect(footer, contains('r range'));
      expect(footer, isNot(contains('g consoles')));
      expect(footer, isNot(contains('b build')));
      expect(footer, isNot(contains('c consumer')));
    });

    test('keeps the workspace card hint at the reference width', () {
      // 132x40 is the width the dashboard is designed against, and `w` is
      // the only key that reaches the workspace card — it outranks `b build`,
      // which the card itself carries.
      final List<String> rows = stripAll(frameOf(columns: 132).rows);
      expect(rows.last, contains('w workspace'));
      expect(rows.last, isNot(contains('b build')));
    });

    test('inlays the wordmark as a gradient run under a truecolor theme', () {
      final List<String> rows = frameOf(columns: 132, theme: color).rows;
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
          frameOf(columns: size[0], lines: size[1], spinner: 3).rows,
          size[0],
          size[1],
        );
      }
    });

    test('stays exact with more instances than the slim list can hold', () {
      for (final List<int> size in const <List<int>>[
        <int>[80, 24],
        <int>[132, 40],
      ]) {
        expectExactFrame(
          frameOf(
            snapshot: manyServers(),
            selectedIndex: 17,
            columns: size[0],
            lines: size[1],
          ).rows,
          size[0],
          size[1],
        );
      }
    });

    test('falls back to the resize card below the 80x24 floor', () {
      final List<String> rows = frameOf(columns: 70, lines: 20).rows;
      expectExactFrame(rows, 70, 20);
      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('RESIZE REQUIRED'));
      expect(joined, contains('CURRENT 70x20'));
      expect(joined, isNot(contains('MULTIPLEXOR')));
    });

    test('emits zero escape bytes under MonitorTheme.plain()', () {
      for (final MonitorSnapshot snapshot in <MonitorSnapshot>[
        twoServers(),
        emptyWorkspace(),
        manyServers(),
      ]) {
        final List<String> rows = frameOf(
          snapshot: snapshot,
          columns: 132,
          lines: 40,
          spinner: 1,
          hoveredId: 'act:stop',
          pressedId: 'ws:new',
        ).rows;
        expect(rows.any((String row) => row.contains('\x1B')), isFalse);
      }
    });

    test('paints escapes under a truecolor theme while staying exact', () {
      final List<String> rows = frameOf(
        columns: 132,
        lines: 40,
        theme: color,
        spinner: 1,
      ).rows;
      expectExactFrame(rows, 132, 40);
      expect(rows.any((String row) => row.contains('\x1B')), isTrue);
    });
  });

  group('buildMonitorFrame hitboxes', () {
    MonitorFrame frameOf({
      MonitorSnapshot? snapshot,
      int selectedIndex = 0,
      int columns = 80,
      int lines = 24,
    }) => buildMonitorFrame(
      snapshot: snapshot ?? twoServers(),
      selectedIndex: selectedIndex,
      frame: 0,
      columns: columns,
      lines: lines,
      theme: MonitorTheme.plain(),
      range: range,
      now: now,
      clockNow: now,
    );

    /// Asserts the `[ LABEL ]` chip on [row] is covered by a button hitbox
    /// carrying [id] over exactly its own columns.
    void expectChip(
      List<String> rows,
      List<MonitorHitbox> hits,
      int row,
      String id,
      String label,
    ) {
      final int at = rows[row].indexOf('[ $label ]');
      expect(at, greaterThanOrEqualTo(0), reason: 'no $label chip on row $row');
      final int last = at + label.length + 3;
      expect(
        buttonAt(hits, row: row, col: at),
        id,
        reason: '$id first column',
      );
      expect(
        buttonAt(hits, row: row, col: last),
        id,
        reason: '$id last column',
      );
      expect(buttonAt(hits, row: row, col: at - 1), isNot(id));
      expect(buttonAt(hits, row: row, col: last + 1), isNot(id));
    }

    test('maps rows to the instance rendered on them at 80x24', () {
      final MonitorSnapshot snapshot = twoServers();
      final MonitorFrame frame = frameOf(snapshot: snapshot);
      expectServerHits(
        stripAll(frame.rows),
        frame.hitboxes,
        snapshot.instances,
      );
    });

    test('maps rows to the instance rendered on them at 132x40', () {
      final MonitorSnapshot snapshot = twoServers();
      final MonitorFrame frame = frameOf(
        snapshot: snapshot,
        selectedIndex: 1,
        columns: 132,
        lines: 40,
      );
      expectServerHits(
        stripAll(frame.rows),
        frame.hitboxes,
        snapshot.instances,
        columns: 132,
      );
    });

    test('puts a button hitbox under every chip on both action bars', () {
      final MonitorFrame frame = frameOf();
      final List<String> rows = stripAll(frame.rows);
      expectChip(rows, frame.hitboxes, 21, 'act:stop', 'STOP');
      expectChip(rows, frame.hitboxes, 21, 'act:restart', 'RESTART');
      expectChip(rows, frame.hitboxes, 21, 'act:console', 'CONSOLE');
      expectChip(rows, frame.hitboxes, 21, 'act:detail', 'DETAIL');
      expectChip(rows, frame.hitboxes, 21, 'act:more', 'MORE');
      expectChip(rows, frame.hitboxes, 22, 'ws:new', '+ NEW');
      expectChip(rows, frame.hitboxes, 22, 'ws:builds', 'BUILDS');
      expectChip(rows, frame.hitboxes, 22, 'ws:tuning', 'TUNING');
      expectChip(rows, frame.hitboxes, 22, 'ws:consumer', 'CONSUMER');
      expectChip(rows, frame.hitboxes, 22, 'ws:consoles', 'CONSOLES');
      expectChip(rows, frame.hitboxes, 22, 'ws:more', 'MORE');
    });

    test('makes the top-right Local and Remote tab labels clickable', () {
      final MonitorFrame local = frameOf(columns: 132, lines: 40);
      final MonitorSnapshot base = twoServers();
      final MonitorFrame remote = frameOf(
        snapshot: MonitorSnapshot(
          instances: base.instances,
          history: base.history,
          consumerName: 'remote:production',
          view: MonitorView.remote,
        ),
        columns: 132,
        lines: 40,
      );

      for (final (MonitorFrame frame, String label) in <(MonitorFrame, String)>[
        (local, 'TAB REMOTE'),
        (remote, 'TAB LOCAL'),
      ]) {
        final MonitorHitbox hit = frame.hitboxes.singleWhere(
          (MonitorHitbox item) => item.id == viewSwitchHitId,
        );
        final String row = Ansi.strip(frame.rows[hit.row]);
        expect(row.substring(hit.colStart, hit.colEnd), label);
        expect(
          hitTest(frame.hitboxes, row: hit.row, col: hit.colStart),
          viewSwitchHitId,
        );
        expect(
          hitTest(frame.hitboxes, row: hit.row, col: hit.colEnd - 1),
          viewSwitchHitId,
        );
        expect(
          hitTest(frame.hitboxes, row: hit.row, col: hit.colEnd),
          isNot(viewSwitchHitId),
        );
      }
    });

    test('keeps the view tab visible beside an oversized provider name', () {
      final MonitorSnapshot base = twoServers();
      final MonitorFrame frame = frameOf(
        snapshot: MonitorSnapshot(
          instances: base.instances,
          history: base.history,
          consumerName:
              'remote:${List<String>.filled(12, 'production-panel-').join()}',
          view: MonitorView.remote,
        ),
      );
      final MonitorHitbox hit = frame.hitboxes.singleWhere(
        (MonitorHitbox item) => item.id == viewSwitchHitId,
      );

      expect(
        Ansi.strip(frame.rows.first).substring(hit.colStart, hit.colEnd),
        'TAB LOCAL',
      );
    });

    test('gives the view tab hover and press feedback without moving it', () {
      final MonitorTheme color = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      String header({String? hoveredId, String? pressedId}) =>
          buildMonitorFrame(
            snapshot: twoServers(),
            selectedIndex: 0,
            frame: 0,
            columns: 132,
            lines: 40,
            theme: color,
            range: range,
            now: now,
            clockNow: now,
            hoveredId: hoveredId,
            pressedId: pressedId,
          ).rows.first;

      final String normal = header();
      final String hovered = header(hoveredId: viewSwitchHitId);
      final String pressed = header(
        hoveredId: viewSwitchHitId,
        pressedId: viewSwitchHitId,
      );
      expect(Ansi.strip(hovered), Ansi.strip(normal));
      expect(Ansi.strip(pressed), Ansi.strip(normal));
      expect(hovered, contains('${color.bold}${color.accent}TAB REMOTE'));
      expect(pressed, contains('${color.bold}${color.textStrong}TAB REMOTE'));
    });

    test('swaps in the start chip when the selection is stopped', () {
      final MonitorFrame frame = frameOf(
        snapshot: mixedFleet(),
        selectedIndex: 1,
      );
      final List<String> rows = stripAll(frame.rows);
      expectChip(rows, frame.hitboxes, 21, 'act:start', 'START');
      expect(
        frame.hitboxes.any((MonitorHitbox hit) => hit.id == 'act:stop'),
        isFalse,
      );
    });

    test('makes the selected-server badge a clickable range chip', () {
      final MonitorFrame frame = frameOf(columns: 132, lines: 40);
      final MonitorHitbox chip = frame.hitboxes.firstWhere(
        (MonitorHitbox hit) => hit.kind == MonitorHitKind.rangeChip,
      );
      expect(chip.id, rangeHitId);
      expect(chip.row, 22, reason: 'the card top border, below the table');
      expect(
        stripAll(frame.rows)[22].substring(chip.colStart, chip.colEnd),
        'running · 15m',
      );
      expect(hitTest(frame.hitboxes, row: 22, col: chip.colStart), rangeHitId);
    });

    test('gives the range chip accent feedback under the pointer', () {
      final MonitorTheme color = MonitorTheme.detect(
        env: <String, String>{'COLORTERM': 'truecolor'},
        isTty: true,
      );
      String badgeRow({String? hoveredId}) => buildMonitorFrame(
        snapshot: twoServers(),
        selectedIndex: 0,
        frame: 0,
        columns: 132,
        lines: 40,
        theme: color,
        range: range,
        now: now,
        clockNow: now,
        hoveredId: hoveredId,
      ).rows[22];

      final String hovered = badgeRow(hoveredId: rangeHitId);
      // Same text either way; only the badge's tone moves, and it moves to
      // the accent the button chips use for hover.
      expect(stripAll(<String>[hovered]), stripAll(<String>[badgeRow()]));
      expect(hovered, contains('${color.bold}${color.accent}running · 15m'));
      expect(badgeRow(), contains('${color.faint}running · 15m'));
      expect(
        badgeRow(hoveredId: '${serverHitPrefix}alpha'),
        badgeRow(),
        reason: 'a pointer somewhere else leaves the badge at rest',
      );
    });

    test('follows a deep selection to the end of the fleet', () {
      // 30 running servers at 80x24: the live card keeps its 9-row minimum,
      // the table gets 6 rows — a header, a marker and a two-row window.
      final MonitorSnapshot snapshot = manyServers();
      final MonitorFrame frame = frameOf(snapshot: snapshot, selectedIndex: 29);
      final List<String> rows = stripAll(frame.rows);
      expect(rows[8], contains('+28 more'));
      expectServerHits(rows, frame.hitboxes, snapshot.instances.sublist(28));
      expect(
        frame.hitboxes.any(
          (MonitorHitbox hit) =>
              hit.kind == MonitorHitKind.serverRow && hit.row == 8,
        ),
        isFalse,
        reason: 'a marker row is not clickable',
      );
    });

    test('marks both ends when the window sits inside the fleet', () {
      final MonitorSnapshot snapshot = manyServers();
      final MonitorFrame frame = frameOf(snapshot: snapshot, selectedIndex: 15);
      final List<String> rows = stripAll(frame.rows);
      expect(rows[8], contains('+15 more'));
      expect(rows[10], contains('+14 more'));
      expectServerHits(
        rows,
        frame.hitboxes,
        snapshot.instances.sublist(15, 16),
      );
    });

    test('marks only the tail when the window sits at the top', () {
      final MonitorSnapshot snapshot = manyServers();
      final MonitorFrame frame = frameOf(snapshot: snapshot);
      final List<String> rows = stripAll(frame.rows);
      expect(rows[10], contains('+28 more'));
      expectServerHits(rows, frame.hitboxes, snapshot.instances.sublist(0, 2));
    });

    test('shows the whole fleet when the terminal is tall enough', () {
      // At 132x60 the body has 51 rows: the card takes its 15-row ceiling
      // and the 33-row fleet (header included) fits without a marker.
      final MonitorSnapshot snapshot = manyServers();
      final MonitorFrame frame = frameOf(
        snapshot: snapshot,
        columns: 132,
        lines: 60,
      );
      final List<String> rows = stripAll(frame.rows);
      expect(rows.join('\n'), isNot(contains('more')));
      expectServerHits(rows, frame.hitboxes, snapshot.instances, columns: 132);
    });

    test('emits no hitboxes at all below the size floor', () {
      expect(frameOf(columns: 70, lines: 20).hitboxes, isEmpty);
    });

    test('keeps the workspace bar clickable with no instances', () {
      final MonitorFrame frame = frameOf(
        snapshot: emptyWorkspace(),
        columns: 132,
        lines: 40,
      );
      expect(serverHits(frame.hitboxes), isEmpty);
      expect(
        frame.hitboxes.any((MonitorHitbox hit) => hit.id.startsWith('act:')),
        isFalse,
      );
      expectChip(stripAll(frame.rows), frame.hitboxes, 38, 'ws:more', 'MORE');
    });

    // The bars and `monitor_screen.dart`'s activation switch are pinned to
    // the same list of constants. These two assertions are the emitter half
    // of that contract: everything drawn is a known id, and every known id
    // is drawn somewhere. The dispatcher half is structural — the switch
    // cases *are* these constants, so an id that survives here reaches an
    // action by name rather than by a matching pair of string literals.
    test('draws only ids from monitorBarHitIds', () {
      final Set<String> drawn = <String>{
        for (final MonitorFrame frame in <MonitorFrame>[
          frameOf(snapshot: twoServers(), columns: 132, lines: 40),
          frameOf(snapshot: mixedFleet(), selectedIndex: 1),
          frameOf(snapshot: emptyWorkspace(), columns: 132, lines: 40),
          frameOf(
            snapshot: MonitorSnapshot(
              instances: twoServers().instances,
              history: twoServers().history,
              consumerName: 'dev',
              view: MonitorView.remote,
            ),
            columns: 132,
            lines: 40,
          ),
        ])
          for (final MonitorHitbox hit in frame.hitboxes)
            if (hit.kind == MonitorHitKind.button) hit.id,
      };
      expect(drawn.difference(monitorBarHitIds.toSet()), isEmpty);
    });

    test('draws every id in monitorBarHitIds across the bar states', () {
      final Set<String> drawn = <String>{
        for (final MonitorFrame frame in <MonitorFrame>[
          // A running selection draws STOP/RESTART/CONSOLE, a stopped one
          // draws START, and an empty workspace draws the `+ NEW` prompt —
          // between them every chip the dashboard has.
          frameOf(snapshot: twoServers(), columns: 132, lines: 40),
          frameOf(snapshot: mixedFleet(), selectedIndex: 1),
          frameOf(snapshot: emptyWorkspace(), columns: 132, lines: 40),
          frameOf(
            snapshot: MonitorSnapshot(
              instances: twoServers().instances,
              history: twoServers().history,
              consumerName: 'dev',
              view: MonitorView.remote,
            ),
            columns: 132,
            lines: 40,
          ),
        ])
          for (final MonitorHitbox hit in frame.hitboxes)
            if (hit.kind == MonitorHitKind.button) hit.id,
      };
      expect(monitorBarHitIds.toSet().difference(drawn), isEmpty);
    });
  });

  group('renderSelectedPanel', () {
    List<String> panel(int rows) => stripAll(
      renderSelectedPanel(
        snapshot: twoServers(),
        selectedIndex: 0,
        rows: rows,
        width: 60,
        topRow: 0,
        colOffset: 0,
        theme: plain,
        range: range,
        now: now,
      ).rows,
    );

    test('keeps labels, chart, facts, and the bottom network monitor', () {
      final List<String> rows = panel(9);
      expect(rows.length, 9);
      expect(rows[1], contains('TPS'), reason: 'the chart label row');
      expect(rows[2], contains('20 ┤'), reason: 'forced 0..20 TPS gutter');
      expect(rows[6], contains('PING'), reason: 'the facts row');
      expect(rows[7], contains('NETWORK PPS'));
      expect(rows[7], contains('RX'));
      expect(rows[7], contains('TX'));
    });

    test('keeps the network monitor when the body tightens', () {
      final List<String> rows = panel(8);
      expect(rows.length, 8);
      expect(rows[1], contains('TPS'));
      expect(rows.join('\n'), isNot(contains('PING')));
      expect(rows.join('\n'), contains('NETWORK PPS'));
    });

    test('gives up labels before the chart or network monitor', () {
      final List<String> rows = panel(7);
      expect(rows.length, 7);
      final String joined = rows.join('\n');
      expect(joined, isNot(contains('PING')));
      expect(joined, contains('20 ┤'), reason: 'the chart is what is left');
      expect(joined, contains('NETWORK PPS'));
    });

    test('renders a stopped selection as its single idle line', () {
      final List<String> stopped = stripAll(
        renderSelectedPanel(
          snapshot: mixedFleet(),
          selectedIndex: 1,
          rows: 3,
          width: 60,
          topRow: 0,
          colOffset: 0,
          theme: plain,
          range: range,
          now: now,
        ).rows,
      );
      expect(stopped.length, 3);
      expect(stopped[0], contains('GAMMA'));
      expect(stopped[1], contains('stopped · START to launch'));
    });

    test('falls back to byte throughput when packet telemetry is absent', () {
      final MonitorSnapshot snapshot = MonitorSnapshot(
        instances: const <String>['remote'],
        history: <String, List<MetricSample>>{
          'remote': <MetricSample>[
            MetricSample(
              ts: now,
              instance: 'remote',
              state: RuntimeState.running,
              networkRxBytesPerSecond: 1536,
              networkTxBytesPerSecond: 512,
            ),
          ],
        },
        consumerName: 'remote',
        view: MonitorView.remote,
      );
      final String joined = stripAll(
        renderSelectedPanel(
          snapshot: snapshot,
          selectedIndex: 0,
          rows: 9,
          width: 80,
          topRow: 0,
          colOffset: 0,
          theme: plain,
          range: range,
          now: now,
        ).rows,
      ).join('\n');
      expect(joined, contains('NETWORK B/s'));
      expect(joined, contains('RX 1.5K/s'));
      expect(joined, contains('TX 512B/s'));
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
      ).rows;
    }

    test('renders five charts, a log panel and a footer at 132x40', () {
      final List<String> rows = detail();
      expectExactFrame(rows, 132, 40);

      final String joined = stripAll(rows).join('\n');
      expect(joined, contains('┌─ TPS '));
      expect(joined, contains('┌─ CPU % '));
      expect(joined, contains('┌─ MEM MiB '));
      expect(joined, contains('┌─ PLAYERS '));
      expect(joined, contains('┌─ NETWORK PPS · RX/TX '));
      expect(joined, contains('┌─ LOG '));
      expect(joined, contains('latest.log'));
      expect(joined, contains('[esc] back'));
      expect(joined, contains('DETAIL · 15m'));
      expect(joined, contains('alpha'));
      final String networkTop = stripAll(
        rows,
      ).firstWhere((String row) => row.contains('NETWORK PPS'));
      expect(
        networkTop.split('┌').length - 1,
        1,
        reason: 'the bottom network chart spans the full detail width',
      );
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
      expect(narrow, contains('NETWORK PPS'));
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
