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

  group('formatBytes', () {
    test('renders n/a for null', () {
      expect(formatBytes(null), 'n/a');
    });

    test('renders sub-kilobyte counts with a B suffix', () {
      expect(formatBytes(512), '512B');
    });

    test('renders kilobytes with one decimal below 10', () {
      expect(formatBytes(1536), '1.5K');
    });

    test('renders megabytes with no decimal at or above 10', () {
      expect(formatBytes(88 * 1024 * 1024), '88M');
    });

    test('renders gigabytes with one decimal below 10', () {
      expect(formatBytes(6553600000).startsWith('6.1G'), isTrue);
    });

    test('renders zero bytes', () {
      expect(formatBytes(0), '0B');
    });
  });

  group('formatBytesPerSecond', () {
    test('formats throughput and preserves unavailable readings', () {
      expect(formatBytesPerSecond(null), 'n/a');
      expect(formatBytesPerSecond(1536), '1.5K/s');
      expect(formatBytesPerSecond(0), '0B/s');
    });
  });

  group('formatPacketsPerSecond', () {
    test('formats packet rates and preserves unavailable readings', () {
      expect(formatPacketsPerSecond(null), 'n/a');
      expect(formatPacketsPerSecond(1234), '1.2kpps');
      expect(formatPacketsPerSecond(0), '0pps');
    });
  });

  group('formatCpuPercent', () {
    test('renders n/a for null', () {
      expect(formatCpuPercent(null), 'n/a');
    });

    test('renders one decimal place with a percent suffix', () {
      expect(formatCpuPercent(4.24), '4.2%');
      expect(formatCpuPercent(0), '0.0%');
      expect(formatCpuPercent(137.5), '137.5%');
    });
  });

  group('formatCompactNumber', () {
    test('renders n/a for null', () {
      expect(formatCompactNumber(null), 'n/a');
    });

    test('renders sub-thousand values with no suffix', () {
      expect(formatCompactNumber(999), '999');
    });

    test('renders thousands with one decimal below 10k', () {
      expect(formatCompactNumber(1234), '1.2k');
    });

    test('renders tens of thousands with no decimal', () {
      expect(formatCompactNumber(12345), '12k');
    });

    test('renders millions with no decimal at or above 10M', () {
      expect(formatCompactNumber(88000000), '88M');
    });

    test('stays within five characters', () {
      expect(formatCompactNumber(1234).length, lessThanOrEqualTo(5));
      expect(formatCompactNumber(88000000).length, lessThanOrEqualTo(5));
    });
  });
}
