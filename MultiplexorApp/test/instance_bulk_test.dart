import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/instance_bulk.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('instance bulk eligibility', () {
    for (final RuntimeState state in RuntimeState.values) {
      test('uses live ${state.name} state for power actions', () {
        expect(
          instanceBulkSkipReason(
            InstanceBulkAction.start,
            state,
            locked: false,
          ),
          state == RuntimeState.stopped ? isNull : isNotNull,
        );
        expect(
          instanceBulkSkipReason(InstanceBulkAction.stop, state, locked: false),
          state == RuntimeState.stopped ? isNotNull : isNull,
        );
        expect(
          instanceBulkSkipReason(
            InstanceBulkAction.restart,
            state,
            locked: false,
          ),
          state == RuntimeState.running ? isNull : isNotNull,
        );
      });
    }

    test('delete skips locked instances regardless of runtime state', () {
      for (final RuntimeState state in RuntimeState.values) {
        expect(
          instanceBulkSkipReason(
            InstanceBulkAction.delete,
            state,
            locked: true,
          ),
          contains('locked'),
        );
        expect(
          instanceBulkSkipReason(
            InstanceBulkAction.delete,
            state,
            locked: false,
          ),
          isNull,
        );
      }
    });

    test(
      'confirmation binds the exact set independent of order or duplicates',
      () {
        expect(
          instanceBulkDeleteToken(<String>['beta', 'alpha', 'beta']),
          'DELETE alpha,beta',
        );
        expect(
          instanceBulkDeleteToken(<String>['alpha', 'beta']),
          instanceBulkDeleteToken(<String>['beta', 'alpha']),
        );
        expect(
          instanceBulkDeleteToken(<String>['alpha']),
          isNot(instanceBulkDeleteToken(<String>['alpha', 'beta'])),
        );
        expect(() => instanceBulkDeleteToken(<String>[]), throwsArgumentError);
        expect(
          () => instanceBulkDeleteToken(<String>['']),
          throwsArgumentError,
        );
      },
    );
  });

  group('instance bulk commands', () {
    late Directory root;
    late NativeCommandService service;
    late String consumerRoot;

    setUp(() {
      root = Directory.systemTemp.createTempSync('multiplexor-bulk-');
      final ManagerContext context = ManagerContext(
        rootDir: root.path,
        verbose: false,
      );
      final ConsumerService consumers = ConsumerService(context);
      consumerRoot = consumers.rootFor(ConsumerProfile.plugin);
      service = NativeCommandService(
        context: context,
        consumerService: consumers,
      );
    });

    tearDown(() {
      service.disposeRcon();
      root.deleteSync(recursive: true);
    });

    // Runtime session names are global, so never use common live server names.
    String name(String suffix) => '${p.basename(root.path)}-$suffix';
    Directory instance(String target) =>
        Directory(p.join(consumerRoot, 'instances', target));

    Future<void> create(String target) async {
      final CapturedResult result = await service.execute(<String>[
        'instance',
        'create',
        target,
        '--isolated',
      ], stream: false);
      expect(result.exitCode, 0, reason: result.stderr);
    }

    Future<CapturedResult> bulk(List<String> args) =>
        service.execute(<String>['instance', 'bulk', ...args], stream: false);

    File pendingMarker(String target) =>
        File(
            p.join(consumerRoot, 'state', 'runtime', '$target.restart-pending'),
          )
          ..createSync(recursive: true)
          ..writeAsStringSync('pending')
          ..setLastModifiedSync(DateTime(2000));

    test(
      'empty selection never widens to all or the active instance',
      () async {
        final String target = name('active');
        await create(target);
        final CapturedResult activated = await service.execute(<String>[
          'instance',
          'activate',
          target,
        ], stream: false);
        expect(activated.exitCode, 0, reason: activated.stderr);

        for (final InstanceBulkAction action in InstanceBulkAction.values) {
          final CapturedResult result = await bulk(<String>[action.name]);
          expect(result.exitCode, 2);
          expect(result.stderr, contains('Usage: instance bulk'));
          expect(instance(target).existsSync(), isTrue);
        }
      },
    );

    test('unknown actions, flags and malformed names are rejected', () async {
      final String target = name('kept');
      await create(target);
      final List<List<String>> invalid = <List<String>>[
        <String>['wipe', target],
        <String>['delete', target, '--all'],
        <String>['delete', target, '../outside'],
        <String>['delete', target, ''],
        <String>['delete', target, '--confirm'],
        <String>['delete', target, '--confirm', 'first', '--confirm', 'second'],
        <String>['stop', target, '--confirm', 'unnecessary'],
      ];

      for (final List<String> args in invalid) {
        final CapturedResult result = await bulk(args);
        expect(result.exitCode, 2, reason: args.join(' '));
        expect(instance(target).existsSync(), isTrue);
      }
    });

    test('every target is validated before any selected deletion', () async {
      final String target = name('kept');
      final String unknown = name('missing');
      await create(target);
      final File marker = pendingMarker(target);

      final CapturedResult result = await bulk(<String>[
        'delete',
        target,
        unknown,
        '--confirm',
        instanceBulkDeleteToken(<String>[target, unknown]),
      ]);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('Instance not found: $unknown'));
      expect(instance(target).existsSync(), isTrue);
      expect(marker.readAsStringSync(), 'pending');
    });

    test(
      'missing or mismatched confirmation does not mutate selected state',
      () async {
        final String target = name('kept');
        await create(target);
        final File marker = pendingMarker(target);
        final String expected = instanceBulkDeleteToken(<String>[target]);

        for (final List<String> args in <List<String>>[
          <String>['delete', target],
          <String>['delete', target, '--confirm', 'DELETE another'],
        ]) {
          final CapturedResult result = await bulk(args);
          expect(result.exitCode, 2);
          expect(result.stderr, contains(expected));
          expect(result.stdout, contains('selected (1): $target'));
          expect(instance(target).existsSync(), isTrue);
          expect(marker.readAsStringSync(), 'pending');
        }
      },
    );

    test(
      'confirmed deletion affects only the explicit unique selection',
      () async {
        final String first = name('first');
        final String second = name('second');
        final String untouched = name('untouched');
        for (final String target in <String>[first, second, untouched]) {
          await create(target);
        }

        final CapturedResult result = await bulk(<String>[
          'delete',
          second,
          first,
          second,
          '--confirm',
          instanceBulkDeleteToken(<String>[first, second]),
        ]);

        expect(result.exitCode, 0, reason: result.stderr);
        expect(instance(first).existsSync(), isFalse);
        expect(instance(second).existsSync(), isFalse);
        expect(instance(untouched).existsSync(), isTrue);
        expect(result.stdout, contains('selected (2): $second, $first'));
        expect(result.stdout, contains('2 succeeded, 0 skipped, 0 failed'));
      },
    );

    test(
      'locked targets are explicitly skipped while unlocked targets delete',
      () async {
        final String locked = name('locked');
        final String unlocked = name('unlocked');
        await create(locked);
        await create(unlocked);
        File(
          p.join(instance(locked).path, '.server-source'),
        ).writeAsStringSync('\nlocked=true\n', mode: FileMode.append);

        final CapturedResult result = await bulk(<String>[
          'delete',
          locked,
          unlocked,
          '--confirm',
          instanceBulkDeleteToken(<String>[locked, unlocked]),
        ]);

        expect(result.exitCode, 0, reason: result.stderr);
        expect(instance(locked).existsSync(), isTrue);
        expect(instance(unlocked).existsSync(), isFalse);
        expect(result.stdout, contains('[SKIP] $locked: instance is locked'));
        expect(result.stdout, contains('1 succeeded, 1 skipped, 0 failed'));
      },
    );

    test(
      'one target failure does not prevent remaining targets from completing',
      () async {
        final String broken = name('broken');
        final String healthy = name('healthy');
        await create(broken);
        await create(healthy);
        File(
          p.join(instance(broken).path, '.server-source'),
        ).writeAsBytesSync(<int>[0xff, 0xff]);

        final CapturedResult result = await bulk(<String>[
          'delete',
          broken,
          healthy,
          '--confirm',
          instanceBulkDeleteToken(<String>[broken, healthy]),
        ]);

        expect(result.exitCode, 1);
        expect(instance(broken).existsSync(), isTrue);
        expect(instance(healthy).existsSync(), isFalse);
        expect(result.stderr, contains('[ERROR] $broken: delete failed:'));
        expect(result.stdout, contains('[OK] $healthy: delete'));
        expect(result.stdout, contains('1 succeeded, 0 skipped, 1 failed'));
      },
    );

    test('stop and restart report stopped targets as skipped', () async {
      final String target = name('stopped');
      await create(target);

      for (final String action in <String>['stop', 'restart']) {
        final CapturedResult result = await bulk(<String>[action, target]);
        expect(result.exitCode, 0, reason: result.stderr);
        expect(result.stdout, contains('[SKIP] $target:'));
        expect(result.stdout, contains('0 succeeded, 1 skipped, 0 failed'));
        expect(instance(target).existsSync(), isTrue);
      }
    });
  });
}
