import 'package:multiplexor/models/build_cache.dart';
import 'package:multiplexor/models/build_version_catalog.dart';
import 'package:multiplexor/services/monitor/metric_sample.dart';
import 'package:multiplexor/services/monitor/metrics_sampler.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/services/runtime_state.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cache freshness never confuses a patch prefix with a different version',
    () {
      const List<BuildCacheEntry> cache = <BuildCacheEntry>[
        BuildCacheEntry(
          type: 'paper',
          jarName: 'paper-1.21.11-90.jar',
          age: Duration(hours: 1),
        ),
      ];
      expect(newestCachedAge(cache, version: '1.21.1'), isNull);
      expect(
        newestCachedAge(cache, version: '1.21.11'),
        const Duration(hours: 1),
      );
    },
  );
  test(
    'preview cache versions sort by release numbers before prerelease labels',
    () {
      final BuildVersionCatalog catalog = BuildVersionCatalog(
        type: 'paper',
        supported: const <String>[],
        latest: null,
        cache: <BuildCacheEntry>[
          for (final String version in <String>[
            '26.1',
            '26.2-pre-1',
            '26.2-rc-1',
            '26.2',
          ])
            BuildCacheEntry(
              type: 'paper',
              jarName: 'paper-$version-10.jar',
              age: Duration.zero,
            ),
        ],
      );
      expect(catalog.versions, <String>[
        '26.2',
        '26.2-rc-1',
        '26.2-pre-1',
        '26.1',
      ]);
    },
  );

  test(
    'offline version choices come from cached Minecraft versions in descending order',
    () {
      final BuildVersionCatalog catalog = BuildVersionCatalog(
        type: 'paper',
        supported: const <String>[],
        latest: null,
        cache: <BuildCacheEntry>[
          for (final String filename in <String>[
            'paper-1.21.9-1.jar',
            'paper-26.2-30.jar',
            'paper-1.21.11-10.jar',
            'paper-1.21.11-11.jar',
            'latest.jar',
          ])
            BuildCacheEntry(
              type: 'paper',
              jarName: filename,
              age: const Duration(days: 3),
            ),
        ],
      );
      expect(catalog.metadataUnavailable, isTrue);
      expect(catalog.versions, <String>['26.2', '1.21.11', '1.21.9']);
    },
  );

  test(
    'unavailable metadata cannot invent a latest version or treat NeoForge loader numbers as Minecraft',
    () {
      final BuildVersionCatalog empty = BuildVersionCatalog(
        type: 'paper',
        supported: const <String>[],
        latest: null,
        cache: const <BuildCacheEntry>[],
      );
      expect(empty.versions, isEmpty);
      final BuildVersionCatalog neoforge = BuildVersionCatalog(
        type: 'neoforge',
        supported: const <String>[],
        latest: null,
        cache: const <BuildCacheEntry>[
          BuildCacheEntry(
            type: 'neoforge',
            jarName: 'neoforge-21.1.90-installer.jar',
            age: Duration.zero,
          ),
        ],
      );
      expect(neoforge.versions, isEmpty);
      expect(neoforge.latest, isNull);
    },
  );

  test(
    'failed metrics capture preserves known instances and freshness until successful empty capture',
    () async {
      DateTime now = DateTime.utc(2026, 9, 5);
      String raw = metricsTsvRow(
        name: 'survival',
        state: RuntimeState.running,
        locked: false,
        isolated: false,
        port: 25565,
      );
      bool fail = false;
      final MetricsSampler sampler = MetricsSampler(
        captureMetrics: () async {
          if (fail) throw StateError('fixture unavailable');
          return raw;
        },
        clock: () => now,
      );
      await sampler.sweep();
      final DateTime? firstSweep = sampler.lastSuccessfulSweep;
      expect(sampler.instances, <String>['survival']);
      now = now.add(const Duration(seconds: 2));
      fail = true;
      await sampler.sweep();
      expect(sampler.instances, <String>['survival']);
      expect(sampler.history('survival'), hasLength(1));
      expect(sampler.lastError, contains('fixture unavailable'));
      expect(sampler.lastSuccessfulSweep, firstSweep);
      fail = false;
      raw = '';
      now = now.add(const Duration(seconds: 2));
      await sampler.sweep();
      expect(sampler.instances, isEmpty);
      expect(sampler.lastError, isNull);
      expect(sampler.lastSuccessfulSweep, now);
    },
  );

  for (final MonitorModalState modal in <MonitorModalState>[
    const InstanceModal('survival'),
    const WorkspaceModal(),
  ]) {
    test(
      '${modal.runtimeType} exposes new actions with mouse and keyboard at 80x24',
      () {
        final MonitorFrame frame = overlayModal(
          base: MonitorFrame(
            rows: List<String>.filled(24, ' ' * 80),
            hitboxes: const <MonitorHitbox>[],
          ),
          modal: modal,
          latest: MetricSample(
            ts: DateTime.utc(2026),
            instance: 'survival',
            state: RuntimeState.stopped,
            port: 25565,
          ),
          locked: false,
          isolated: false,
          theme: MonitorTheme.plain(),
          columns: 80,
          lines: 24,
        );
        final List<MonitorHitbox> buttons = frame.hitboxes
            .where((MonitorHitbox box) => box.kind == MonitorHitKind.button)
            .toList();
        final Set<String> expected = modal is InstanceModal
            ? <String>{'im:backups', 'im:settings'}
            : <String>{'wm:diagnostics', 'wm:templates'};
        expect(
          buttons.map((MonitorHitbox box) => box.id),
          containsAll(expected),
        );
        expect(frame.rows, hasLength(24));
        for (final String row in frame.rows) {
          expect(Ansi.visibleLength(row), 80);
        }
        for (final MonitorHitbox button in buttons) {
          expect(button.row, inInclusiveRange(0, 23));
          expect(button.colStart, greaterThanOrEqualTo(0));
          expect(button.colEnd, lessThanOrEqualTo(80));
          expect(
            hitTest(frame.hitboxes, row: button.row, col: button.colStart),
            button.id,
          );
          expect(
            modalActionIdForHotkey(
              frame.hitboxes,
              modalHotkeyForId(button.id)!,
            ),
            button.id,
          );
        }
        final Set<String> reached = <String>{buttons.first.id};
        final List<String> pending = <String>[buttons.first.id];
        while (pending.isNotEmpty) {
          final String selected = pending.removeLast();
          for (final ModalMove move in ModalMove.values) {
            final String? next = moveModalSelection(
              frame.hitboxes,
              selected,
              move,
            );
            if (next != null && reached.add(next)) pending.add(next);
          }
        }
        expect(reached, containsAll(expected));
      },
    );
  }
}
