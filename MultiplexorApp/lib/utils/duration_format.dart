/// Formats [duration] as a compact, human-readable uptime string.
///
/// Examples: `45s`, `12m`, `1h 4m`, `2d 3h`. Only the two most significant
/// non-zero units are shown. Negative or sub-second durations render as `0s`.
String formatCompactDuration(Duration duration) {
  if (duration.inSeconds <= 0) {
    return '0s';
  }

  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  final seconds = duration.inSeconds % 60;

  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  if (minutes > 0) {
    return seconds > 0 ? '${minutes}m ${seconds}s' : '${minutes}m';
  }
  return '${seconds}s';
}

/// Formats [bytes] as a compact size string using a base-1024 ladder:
/// `512B`, `1.2K`, `88M`, `6.2G`. Values below 10 in the chosen unit render
/// with one decimal place; values at or above 10 render as whole numbers.
/// Returns `n/a` when [bytes] is null.
String formatBytes(int? bytes) {
  if (bytes == null) {
    return 'n/a';
  }
  if (bytes < 1024) {
    return '${bytes}B';
  }

  const List<String> units = <String>['B', 'K', 'M', 'G', 'T', 'P'];
  final (double scaled, int magnitude) = _scaleMagnitude(
    bytes.toDouble(),
    1024,
    units.length - 1,
  );
  return '${_formatScaled(scaled)}${units[magnitude]}';
}

/// Formats [value] as a compact number string, at most 5 characters, using
/// a base-1000 ladder: `999`, `1.2k`, `12k`, `88M`. Values below 10 in the
/// chosen magnitude render with one decimal place; values at or above 10
/// render as whole numbers. Returns `n/a` when [value] is null.
String formatCompactNumber(num? value) {
  if (value == null) {
    return 'n/a';
  }

  final double asDouble = value.toDouble();
  if (asDouble.abs() < 1000) {
    return asDouble.round().toString();
  }

  const List<String> suffixes = <String>['', 'k', 'M', 'B', 'T'];
  final (double scaled, int magnitude) = _scaleMagnitude(
    asDouble,
    1000,
    suffixes.length - 1,
  );
  return '${_formatScaled(scaled)}${suffixes[magnitude]}';
}

/// Divides [value] by [base] repeatedly until it is smaller than [base] or
/// [maxMagnitude] divisions have been applied. Returns the scaled value and
/// how many divisions were performed.
(double, int) _scaleMagnitude(double value, double base, int maxMagnitude) {
  double scaled = value;
  int magnitude = 0;
  while (scaled.abs() >= base && magnitude < maxMagnitude) {
    scaled /= base;
    magnitude++;
  }
  return (scaled, magnitude);
}

/// Renders [scaled] with one decimal place when below 10, otherwise as a
/// rounded whole number.
String _formatScaled(double scaled) {
  if (scaled.abs() < 10) {
    return scaled.toStringAsFixed(1);
  }
  return scaled.round().toString();
}
