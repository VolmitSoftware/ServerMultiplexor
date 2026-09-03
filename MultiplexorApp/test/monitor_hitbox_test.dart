import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:test/test.dart';

void main() {
  group('MonitorHitbox', () {
    test('stores id, row, column range, and kind', () {
      const MonitorHitbox box = MonitorHitbox(
        id: 'srv-1',
        row: 3,
        colStart: 5,
        colEnd: 10,
        kind: MonitorHitKind.serverRow,
      );
      expect(box.id, 'srv-1');
      expect(box.row, 3);
      expect(box.colStart, 5);
      expect(box.colEnd, 10);
      expect(box.kind, MonitorHitKind.serverRow);
    });
  });

  group('MonitorFrame', () {
    test('stores rows and hitboxes', () {
      const MonitorHitbox box = MonitorHitbox(
        id: 'a',
        row: 0,
        colStart: 0,
        colEnd: 1,
        kind: MonitorHitKind.button,
      );
      const MonitorFrame frame = MonitorFrame(
        rows: <String>['abc'],
        hitboxes: <MonitorHitbox>[box],
      );
      expect(frame.rows, <String>['abc']);
      expect(frame.hitboxes, <MonitorHitbox>[box]);
    });
  });

  group('MonitorHitKind', () {
    test('has exactly the kinds the dashboard needs', () {
      expect(MonitorHitKind.values, <MonitorHitKind>[
        MonitorHitKind.serverRow,
        MonitorHitKind.checkbox,
        MonitorHitKind.button,
        MonitorHitKind.chart,
        MonitorHitKind.rangeChip,
        MonitorHitKind.modalScrim,
      ]);
    });
  });

  group('hitTest', () {
    test(
      'returns the id of a hitbox whose row and column range contain the point',
      () {
        const MonitorHitbox box = MonitorHitbox(
          id: 'btn-1',
          row: 2,
          colStart: 4,
          colEnd: 8,
          kind: MonitorHitKind.button,
        );
        expect(hitTest(<MonitorHitbox>[box], row: 2, col: 4), 'btn-1');
        expect(hitTest(<MonitorHitbox>[box], row: 2, col: 7), 'btn-1');
      },
    );

    test('colEnd is exclusive', () {
      const MonitorHitbox box = MonitorHitbox(
        id: 'btn-1',
        row: 2,
        colStart: 4,
        colEnd: 8,
        kind: MonitorHitKind.button,
      );
      expect(hitTest(<MonitorHitbox>[box], row: 2, col: 8), isNull);
    });

    test('colStart is inclusive', () {
      const MonitorHitbox box = MonitorHitbox(
        id: 'btn-1',
        row: 2,
        colStart: 4,
        colEnd: 8,
        kind: MonitorHitKind.button,
      );
      expect(hitTest(<MonitorHitbox>[box], row: 2, col: 4), 'btn-1');
      expect(hitTest(<MonitorHitbox>[box], row: 2, col: 3), isNull);
    });

    test('a mismatched row is a miss even when the column matches', () {
      const MonitorHitbox box = MonitorHitbox(
        id: 'btn-1',
        row: 2,
        colStart: 4,
        colEnd: 8,
        kind: MonitorHitKind.button,
      );
      expect(hitTest(<MonitorHitbox>[box], row: 3, col: 5), isNull);
    });

    test('returns null for an empty hitbox list', () {
      expect(hitTest(<MonitorHitbox>[], row: 0, col: 0), isNull);
    });

    test('when two hitboxes overlap, the last one in the list wins', () {
      const MonitorHitbox back = MonitorHitbox(
        id: 'back',
        row: 1,
        colStart: 0,
        colEnd: 10,
        kind: MonitorHitKind.chart,
      );
      const MonitorHitbox front = MonitorHitbox(
        id: 'front',
        row: 1,
        colStart: 3,
        colEnd: 6,
        kind: MonitorHitKind.button,
      );
      expect(hitTest(<MonitorHitbox>[back, front], row: 1, col: 4), 'front');
      // Outside the overlap, the earlier one is still reachable.
      expect(hitTest(<MonitorHitbox>[back, front], row: 1, col: 8), 'back');
    });

    test(
      'iterates strictly last-to-first: a later non-matching box does not block an earlier match',
      () {
        const MonitorHitbox earlier = MonitorHitbox(
          id: 'earlier',
          row: 5,
          colStart: 0,
          colEnd: 5,
          kind: MonitorHitKind.serverRow,
        );
        const MonitorHitbox later = MonitorHitbox(
          id: 'later',
          row: 9,
          colStart: 0,
          colEnd: 5,
          kind: MonitorHitKind.serverRow,
        );
        expect(
          hitTest(<MonitorHitbox>[earlier, later], row: 5, col: 2),
          'earlier',
        );
      },
    );

    test('distinguishes every MonitorHitKind value', () {
      for (final MonitorHitKind kind in MonitorHitKind.values) {
        final MonitorHitbox box = MonitorHitbox(
          id: kind.name,
          row: 0,
          colStart: 0,
          colEnd: 1,
          kind: kind,
        );
        expect(hitTest(<MonitorHitbox>[box], row: 0, col: 0), kind.name);
      }
    });
  });

  group('monitorReleaseTarget', () {
    test('activates only a press released over the same hitbox', () {
      expect(
        monitorReleaseTarget(
          pressedId: viewSwitchHitId,
          releasedId: viewSwitchHitId,
          primaryButton: true,
        ),
        viewSwitchHitId,
      );
      expect(
        monitorReleaseTarget(
          pressedId: viewSwitchHitId,
          releasedId: wsMoreHitId,
          primaryButton: true,
        ),
        isNull,
      );
      expect(
        monitorReleaseTarget(
          pressedId: viewSwitchHitId,
          releasedId: null,
          primaryButton: true,
        ),
        isNull,
      );
      expect(
        monitorReleaseTarget(
          pressedId: null,
          releasedId: viewSwitchHitId,
          primaryButton: true,
        ),
        isNull,
      );
      expect(
        monitorReleaseTarget(
          pressedId: viewSwitchHitId,
          releasedId: viewSwitchHitId,
          primaryButton: false,
        ),
        isNull,
      );
    });
  });
}
