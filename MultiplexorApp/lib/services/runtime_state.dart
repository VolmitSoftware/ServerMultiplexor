/// Lifecycle states for a managed server instance.
enum RuntimeState {
  stopped,
  starting,
  running,
  stopping,
  restarting,
}

/// How long a restart-pending marker is trusted before it is considered
/// stale. The generated restart script gives up after 180s, so anything
/// older than this means the relaunch never happened.
const Duration runtimeRestartMarkerTtl = Duration(seconds: 240);

const String _doneMarker = ']: done (';
const List<String> _stopMarkers = <String>[
  'stopping server',
  'stopping the server',
  'attempting to restart',
];

/// Classifies the log tail of a live session into starting, running, or
/// stopping. The log file is truncated on every launch, so the most recent
/// marker in the tail reflects the current phase of this run.
RuntimeState classifyRuntimeLogTail(String logTail) {
  final String lower = logTail.toLowerCase();
  final int doneIndex = lower.lastIndexOf(_doneMarker);
  int stopIndex = -1;
  for (final String marker in _stopMarkers) {
    final int index = lower.lastIndexOf(marker);
    if (index > stopIndex) {
      stopIndex = index;
    }
  }

  if (stopIndex > doneIndex) {
    return RuntimeState.stopping;
  }
  if (doneIndex >= 0) {
    return RuntimeState.running;
  }
  return RuntimeState.starting;
}

/// Whether a restart-pending marker written at [modified] is still trusted
/// at [now]. Small clock skew into the future is tolerated.
bool runtimeRestartMarkerFresh(DateTime modified, DateTime now) {
  final Duration age = now.difference(modified);
  if (age.isNegative) {
    return age.abs() <= const Duration(seconds: 30);
  }
  return age <= runtimeRestartMarkerTtl;
}
