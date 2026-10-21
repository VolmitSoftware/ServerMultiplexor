import 'dart:io';
import 'dart:math';

class ProjectBuildLimits {
  ProjectBuildLimits({
    required this.jobs,
    required this.memoryMiB,
    required this.workers,
  }) {
    _positive('jobs', jobs);
    _positive('memoryMiB', memoryMiB);
    _positive('workers', workers);
  }

  factory ProjectBuildLimits.defaults() => _defaults;

  factory ProjectBuildLimits.fromJson(Map<String, Object?> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Invalid project build limits schema');
    }
    return ProjectBuildLimits(
      jobs: _positive('jobs', json['jobs']),
      memoryMiB: _positive('memoryMiB', json['memoryMiB']),
      workers: _positive('workers', json['workers']),
    );
  }

  static final ProjectBuildLimits _defaults = ProjectBuildLimits(
    jobs: min(4, max(1, Platform.numberOfProcessors)),
    memoryMiB: projectDefaultMemory(),
    workers: max(1, Platform.numberOfProcessors),
  );

  final int jobs;
  final int memoryMiB;
  final int workers;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'jobs': jobs,
    'memoryMiB': memoryMiB,
    'workers': workers,
  };

  static int _positive(String name, Object? value) {
    if (value is! int || value < 1) {
      throw FormatException(
        'Project build limit $name must be a positive integer',
      );
    }
    return value;
  }
}

int projectDefaultMemory() {
  int bytes = 0;
  if (Platform.isMacOS) {
    ProcessResult result = Process.runSync('sysctl', <String>[
      '-n',
      'hw.memsize',
    ]);
    if (result.exitCode == 0) {
      bytes = int.tryParse('${result.stdout}'.trim()) ?? 0;
    }
  } else if (Platform.isLinux && File('/proc/meminfo').existsSync()) {
    RegExpMatch? match = RegExp(
      r'MemTotal:\s+(\d+)',
    ).firstMatch(File('/proc/meminfo').readAsStringSync());
    bytes = match == null ? 0 : int.parse(match[1]!) * 1024;
  }
  return bytes == 0 ? 8192 : max(4096, min(65536, bytes ~/ (1024 * 1024 * 2)));
}
