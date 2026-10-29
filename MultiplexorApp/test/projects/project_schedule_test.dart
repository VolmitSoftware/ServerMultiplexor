import 'package:multiplexor/services/projects/project_build_limits.dart';
import 'package:multiplexor/services/projects/project_model.dart';
import 'package:multiplexor/services/projects/project_schedule.dart';
import 'package:test/test.dart';

void main() {
  ProjectScheduleEntry entry(
    String key, {
    int memoryMiB = 1024,
    int workers = 2,
    bool exclusive = false,
    Duration duration = const Duration(minutes: 1),
    Duration? priority,
  }) => ProjectScheduleEntry(
    key: key,
    project: key.split(':').first,
    memoryMiB: memoryMiB,
    workers: workers,
    exclusive: exclusive,
    duration: duration,
    priority: priority ?? duration,
  );

  Map<String, Object?> job(String key, DateTime start, Duration duration) =>
      <String, Object?>{
        'key': key,
        'status': 'succeeded',
        'startedAt': start.toIso8601String(),
        'finishedAt': start.add(duration).toIso8601String(),
      };

  Map<String, Object?> target(String id, {List<String> dependsOn = const []}) =>
      <String, Object?>{
        'id': id,
        'tasks': <String>['build'],
        'dependsOn': dependsOn,
      };

  BuildProject project(String id, List<Map<String, Object?>> targets) =>
      BuildProject.fromJson(<String, Object?>{
        'schema': 1,
        'id': id,
        'name': id,
        'sandbox': 'per-target',
        'parallelTargets': true,
        'sourceRoot': '/sources',
        'relativePath': id,
        'targets': targets,
      });

  test('the longest critical path starts first', () {
    expect(
      projectScheduleStarts(
        budget: ProjectBuildLimits(jobs: 1, memoryMiB: 8192, workers: 8),
        running: <ProjectScheduleEntry>[],
        ready: <ProjectScheduleEntry>[
          entry('small:one'),
          entry('heavy:one', duration: const Duration(minutes: 10)),
        ],
      ),
      <String>['heavy:one'],
    );
  });

  test(
    'a reserved heavy target is only backfilled by work that cannot delay it',
    () {
      expect(
        projectScheduleStarts(
          budget: ProjectBuildLimits(jobs: 6, memoryMiB: 65536, workers: 16),
          running: <ProjectScheduleEntry>[
            entry('a:one', workers: 8, duration: const Duration(minutes: 5)),
            entry('b:one', workers: 6, duration: const Duration(minutes: 1)),
          ],
          ready: <ProjectScheduleEntry>[
            entry(
              'heavy:one',
              workers: 8,
              duration: const Duration(minutes: 10),
            ),
            entry('long:one', duration: const Duration(minutes: 9)),
            entry('short:one', duration: const Duration(seconds: 30)),
          ],
        ),
        <String>['short:one'],
      );
    },
  );

  test('backfill uses capacity left over after the reservation starts', () {
    expect(
      projectScheduleStarts(
        budget: ProjectBuildLimits(jobs: 6, memoryMiB: 65536, workers: 16),
        running: <ProjectScheduleEntry>[
          entry('a:one', workers: 10, duration: const Duration(minutes: 2)),
        ],
        ready: <ProjectScheduleEntry>[
          entry(
            'heavy:one',
            workers: 12,
            duration: const Duration(minutes: 10),
          ),
          entry('long:one', duration: const Duration(minutes: 9)),
          entry('later:one', workers: 4, duration: const Duration(minutes: 8)),
        ],
      ),
      <String>['long:one'],
    );
  });

  test('exclusive projects never overlap their own targets', () {
    expect(
      projectScheduleStarts(
        budget: ProjectBuildLimits(jobs: 4, memoryMiB: 8192, workers: 8),
        running: <ProjectScheduleEntry>[entry('serial:one', exclusive: true)],
        ready: <ProjectScheduleEntry>[
          entry(
            'serial:two',
            exclusive: true,
            duration: const Duration(minutes: 9),
          ),
          entry('other:one'),
        ],
      ),
      <String>['other:one'],
    );
  });

  test('targets that fit together all start in priority order', () {
    expect(
      projectScheduleStarts(
        budget: ProjectBuildLimits(jobs: 3, memoryMiB: 8192, workers: 8),
        running: <ProjectScheduleEntry>[],
        ready: <ProjectScheduleEntry>[
          entry('a:one'),
          entry('b:one', duration: const Duration(minutes: 3)),
          entry('c:one', duration: const Duration(minutes: 2)),
          entry('d:one', duration: const Duration(minutes: 4)),
        ],
      ),
      <String>['d:one', 'b:one', 'c:one'],
    );
  });

  test(
    'estimates use the recent median and unknown targets assume the longest',
    () {
      DateTime start = DateTime.utc(2026, 10, 1);
      Map<String, Duration> estimates = projectDurationEstimates(
        <Map<String, Object?>>[
          <String, Object?>{
            'jobs': <Object?>[
              job('a:one', start, const Duration(minutes: 2)),
              job('b:one', start, const Duration(minutes: 7)),
              <String, Object?>{
                ...job('a:one', start, const Duration(minutes: 90)),
                'reusedFrom': 'older',
              },
            ],
          },
          <String, Object?>{
            'jobs': <Object?>[job('a:one', start, const Duration(minutes: 3))],
          },
          <String, Object?>{
            'jobs': <Object?>[
              job('a:one', start, const Duration(minutes: 40)),
              <String, Object?>{
                ...job('b:one', start, const Duration(minutes: 60)),
                'status': 'failed',
              },
            ],
          },
        ],
        <String>['a:one', 'b:one', 'new:one'],
      );
      expect(estimates['a:one'], const Duration(minutes: 3));
      expect(estimates['b:one'], const Duration(minutes: 7));
      expect(estimates['new:one'], const Duration(minutes: 7));
    },
  );

  test('critical paths include the targets waiting on a prerequisite', () {
    ProjectPlan plan = ProjectPlan(
      <String, BuildProject>{
        'lib': project('lib', <Map<String, Object?>>[target('api')]),
        'app': project('app', <Map<String, Object?>>[
          target('jar', dependsOn: <String>['lib:api']),
        ]),
        'other': project('other', <Map<String, Object?>>[target('jar')]),
      },
      <String>['app:jar', 'other:jar'],
    );
    Map<String, Duration> paths = projectCriticalPaths(plan, <String, Duration>{
      'lib:api': const Duration(minutes: 1),
      'app:jar': const Duration(minutes: 10),
      'other:jar': const Duration(minutes: 5),
    });
    expect(paths['lib:api'], const Duration(minutes: 11));
    expect(paths['app:jar'], const Duration(minutes: 10));
    expect(paths['other:jar'], const Duration(minutes: 5));
  });
}
