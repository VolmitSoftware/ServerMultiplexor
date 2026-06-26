import 'package:multiplexor/utils/duration_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatCompactDuration', () {
    test('renders zero and negative durations as 0s', () {
      expect(formatCompactDuration(Duration.zero), '0s');
      expect(formatCompactDuration(const Duration(seconds: -5)), '0s');
      expect(formatCompactDuration(const Duration(milliseconds: 500)), '0s');
    });

    test('renders seconds only under a minute', () {
      expect(formatCompactDuration(const Duration(seconds: 1)), '1s');
      expect(formatCompactDuration(const Duration(seconds: 45)), '45s');
    });

    test('renders minutes and seconds under an hour', () {
      expect(formatCompactDuration(const Duration(minutes: 12)), '12m');
      expect(formatCompactDuration(const Duration(seconds: 90)), '1m 30s');
    });

    test('renders hours and minutes under a day', () {
      expect(formatCompactDuration(const Duration(hours: 1)), '1h');
      expect(
        formatCompactDuration(const Duration(hours: 1, minutes: 4)),
        '1h 4m',
      );
    });

    test('renders days and hours past a day', () {
      expect(formatCompactDuration(const Duration(hours: 48)), '2d');
      expect(formatCompactDuration(const Duration(days: 2, hours: 3)), '2d 3h');
    });
  });
}
