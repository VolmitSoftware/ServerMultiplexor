import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 10, 30, 18, 40);
const Duration _range = Duration(minutes: 15);

MetricSample _sample(Duration ago, {double? cpu = 12}) => MetricSample(
  ts: _now.subtract(ago),
  instance: 'lobby',
  state: cpu == null ? RuntimeState.stopped : RuntimeState.running,
  cpuPercent: cpu,
);

void main() {
  group('chartWindowStart', () {
    test('keeps the full range when readings cover it', () {
      expect(
        chartWindowStart(
          history: <MetricSample>[
            _sample(const Duration(minutes: 20)),
            _sample(const Duration(minutes: 10)),
          ],
          now: _now,
          range: _range,
        ),
        _now.subtract(_range),
      );
    });

    test('starts at the first reading of a server that just started', () {
      expect(
        chartWindowStart(
          history: <MetricSample>[
            _sample(const Duration(minutes: 12), cpu: null),
            _sample(const Duration(minutes: 3)),
            _sample(const Duration(minutes: 1)),
          ],
          now: _now,
          range: _range,
        ),
        _now.subtract(const Duration(minutes: 3)),
      );
    });

    test('starts at the restart when an earlier run stopped', () {
      expect(
        chartWindowStart(
          history: <MetricSample>[
            _sample(const Duration(hours: 2)),
            _sample(const Duration(minutes: 119)),
            _sample(const Duration(minutes: 4)),
            _sample(const Duration(minutes: 2)),
          ],
          now: _now,
          range: _range,
        ),
        _now.subtract(const Duration(minutes: 4)),
      );
    });

    test('never narrows the window below one minute', () {
      expect(
        chartWindowStart(
          history: <MetricSample>[_sample(const Duration(seconds: 10))],
          now: _now,
          range: _range,
        ),
        _now.subtract(const Duration(minutes: 1)),
      );
    });

    test('keeps the full range when there is no reading at all', () {
      expect(
        chartWindowStart(
          history: <MetricSample>[_sample(Duration.zero, cpu: null)],
          now: _now,
          range: _range,
        ),
        _now.subtract(_range),
      );
    });
  });
}
