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
