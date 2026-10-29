import 'project_build_limits.dart';
import 'project_model.dart';

const int projectEstimateSamples = 5;

class ProjectScheduleEntry {
  const ProjectScheduleEntry({
    required this.key,
    required this.project,
    required this.memoryMiB,
    required this.workers,
    required this.exclusive,
    required this.duration,
    this.priority = Duration.zero,
  });

  final String key;
  final String project;
  final int memoryMiB;
  final int workers;
  final bool exclusive;
  final Duration duration;
  final Duration priority;
}

List<String> projectScheduleStarts({
  required ProjectBuildLimits budget,
  required List<ProjectScheduleEntry> running,
  required List<ProjectScheduleEntry> ready,
}) {
  _Capacity free = _Capacity(
    budget.jobs,
    budget.memoryMiB,
    budget.workers,
  ).minusAll(running);
  List<ProjectScheduleEntry> active = <ProjectScheduleEntry>[...running];
  List<int> order = List<int>.generate(ready.length, (int index) => index)
    ..sort((int a, int b) {
      int priority = _byPriority(ready[a], ready[b]);
      return priority != 0 ? priority : a.compareTo(b);
    });
  List<ProjectScheduleEntry> ordered = <ProjectScheduleEntry>[
    for (int index in order) ready[index],
  ];
  List<String> starts = <String>[];
  Duration? shadow;
  _Capacity? extra;
  for (ProjectScheduleEntry entry in ordered) {
    if (entry.exclusive &&
        active.any(
          (ProjectScheduleEntry item) => item.project == entry.project,
        )) {
      continue;
    }
    bool fits = free.fits(entry);
    if (shadow == null) {
      if (fits) {
        starts.add(entry.key);
        free = free.minus(entry);
        active.add(entry);
        continue;
      }
      (Duration, _Capacity) reservation = _reserve(entry, free, active);
      shadow = reservation.$1;
      extra = reservation.$2.minus(entry);
      continue;
    }
    if (!fits) continue;
    if (entry.duration <= shadow) {
      starts.add(entry.key);
      free = free.minus(entry);
      active.add(entry);
    } else if (extra!.fits(entry)) {
      starts.add(entry.key);
      free = free.minus(entry);
      extra = extra.minus(entry);
      active.add(entry);
    }
  }
  return starts;
}

Map<String, Duration> projectDurationEstimates(
  List<Map<String, Object?>> runs,
  Iterable<String> keys,
) {
  Map<String, List<Duration>> samples = <String, List<Duration>>{};
  for (Map<String, Object?> run in runs) {
    for (Object? item in run['jobs'] as List<Object?>? ?? <Object?>[]) {
      if (item is! Map<String, Object?> ||
          item['status'] != 'succeeded' ||
          item['reusedFrom'] != null ||
          item['startedAt'] is! String ||
          item['finishedAt'] is! String) {
        continue;
      }
      List<Duration> durations = samples.putIfAbsent(
        item['key'] as String,
        () => <Duration>[],
      );
      if (durations.length == projectEstimateSamples) continue;
      durations.add(
        DateTime.parse(
          item['finishedAt'] as String,
        ).difference(DateTime.parse(item['startedAt'] as String)),
      );
    }
  }
  Map<String, Duration> known = <String, Duration>{
    for (MapEntry<String, List<Duration>> entry in samples.entries)
      entry.key: (entry.value..sort())[entry.value.length ~/ 2],
  };
  Duration fallback = known.values.fold(
    Duration.zero,
    (Duration longest, Duration value) => value > longest ? value : longest,
  );
  return <String, Duration>{
    for (String key in keys) key: known[key] ?? fallback,
  };
}

Map<String, Duration> projectCriticalPaths(
  ProjectPlan plan,
  Map<String, Duration> estimates,
) {
  Map<String, List<String>> dependents = <String, List<String>>{};
  for (String key in plan.keys) {
    ProjectTarget target = plan.targetFor(key);
    for (String dependency in <String>{
      ...target.dependsOn,
      ...target.artifactProperties.values,
    }) {
      dependents.putIfAbsent(dependency, () => <String>[]).add(key);
    }
  }
  Map<String, Duration> paths = <String, Duration>{};
  for (String key in plan.keys.reversed) {
    Duration longest = Duration.zero;
    for (String dependent in dependents[key] ?? <String>[]) {
      if (paths[dependent]! > longest) longest = paths[dependent]!;
    }
    paths[key] = (estimates[key] ?? Duration.zero) + longest;
  }
  return paths;
}

int _byPriority(ProjectScheduleEntry a, ProjectScheduleEntry b) {
  int priority = b.priority.compareTo(a.priority);
  if (priority != 0) return priority;
  return (b.memoryMiB * b.workers).compareTo(a.memoryMiB * a.workers);
}

(Duration, _Capacity) _reserve(
  ProjectScheduleEntry entry,
  _Capacity free,
  List<ProjectScheduleEntry> active,
) {
  List<ProjectScheduleEntry> finishing = <ProjectScheduleEntry>[...active]
    ..sort(
      (ProjectScheduleEntry a, ProjectScheduleEntry b) =>
          a.duration.compareTo(b.duration),
    );
  _Capacity available = free;
  int sameProject = active
      .where((ProjectScheduleEntry item) => item.project == entry.project)
      .length;
  for (ProjectScheduleEntry item in finishing) {
    available = available.plus(item);
    if (item.project == entry.project) sameProject--;
    if (available.fits(entry) && (!entry.exclusive || sameProject == 0)) {
      return (item.duration, available);
    }
  }
  return (
    finishing.isEmpty ? Duration.zero : finishing.last.duration,
    available,
  );
}

class _Capacity {
  const _Capacity(this.jobs, this.memoryMiB, this.workers);

  final int jobs;
  final int memoryMiB;
  final int workers;

  bool fits(ProjectScheduleEntry entry) =>
      jobs >= 1 && memoryMiB >= entry.memoryMiB && workers >= entry.workers;

  _Capacity minus(ProjectScheduleEntry entry) =>
      _Capacity(jobs - 1, memoryMiB - entry.memoryMiB, workers - entry.workers);

  _Capacity plus(ProjectScheduleEntry entry) =>
      _Capacity(jobs + 1, memoryMiB + entry.memoryMiB, workers + entry.workers);

  _Capacity minusAll(List<ProjectScheduleEntry> entries) => entries.fold(
    this,
    (_Capacity capacity, ProjectScheduleEntry entry) => capacity.minus(entry),
  );
}
