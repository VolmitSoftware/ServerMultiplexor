import 'dart:async';
import 'dart:io';

import 'package:multiplexor/services/monitor/monitor_frame_util.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/services/monitor/monitor_model.dart';
import 'package:multiplexor/services/monitor/monitor_update.dart';
import 'package:multiplexor/services/self_update_release.dart';
import 'package:multiplexor/services/self_update_service.dart';
import 'package:multiplexor/services/self_update_settings.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late _Client client;
  MonitorUpdate updater({bool release = true, bool supported = true}) =>
      MonitorUpdate(
        SelfUpdateService(
          currentVersion: UpdateVersion.parse('0.2.9'),
          executablePath: '${directory.path}/multiplexor',
          releaseBuild: release,
          platform: supported
              ? const UpdatePlatform(
                  archiveSuffix: 'macos-arm64.tar.gz',
                  executableName: 'multiplexor',
                )
              : null,
          store: SelfUpdateStore(directory, '${directory.path}/multiplexor'),
          client: client,
        ),
      );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('monitor-update-test-');
    client = _Client();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'checks are nonblocking, deduplicated, and expose the verified version',
    () async {
      final MonitorUpdate update = updater();
      final Future<void> checking = update.check();
      expect(update.state, MonitorUpdateState.checking);
      await update.check();
      expect(client.checks, 1);
      client.pending.complete(
        SelfUpdateRelease(
          version: UpdateVersion.parse('0.2.10'),
          downloadUrl: Uri.parse('https://example.invalid/update'),
          assetName: 'update.tar.gz',
          sha256: 'fixture',
          size: 1,
        ),
      );
      await checking;
      expect(update.state, MonitorUpdateState.available);
      expect(update.label, 'u UPDATE v0.2.10');
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'failure retains the cause and a successful retry reports current',
    () async {
      final MonitorUpdate update = updater();
      final Future<void> failed = update.check();
      client.pending.completeError(const SocketException('offline'));
      await failed;
      expect(update.state, MonitorUpdateState.failed);
      expect(update.error, contains('offline'));
      client.pending = Completer<SelfUpdateRelease?>();
      final Future<void> retried = update.check();
      client.pending.complete(null);
      await retried;
      expect(update.state, MonitorUpdateState.current);
      expect(update.error, isNull);
    },
  );

  test(
    'development and unsupported builds cannot accidentally check or install',
    () async {
      final MonitorUpdate source = updater(release: false);
      final MonitorUpdate unsupported = updater(supported: false);
      await source.check();
      await unsupported.check();
      expect(source.state, MonitorUpdateState.development);
      expect(unsupported.state, MonitorUpdateState.unsupported);
      expect(client.checks, 0);
    },
  );

  test('update shortcut is lowercase u', () {
    expect(
      monitorActionForEvent(const TermEvent(TermEventKind.char, char: 'u')),
      MonitorAction.update,
    );
    expect(
      monitorActionForEvent(const TermEvent(TermEventKind.char, char: 'U')),
      MonitorAction.none,
    );
  });

  for (final int columns in <int>[80, 132]) {
    for (final MonitorView view in MonitorView.values) {
      test('update button stays bottom-right at $columns columns in $view', () {
        final DateTime now = DateTime.utc(2026);
        MonitorFrame frame({
          bool checking = false,
          String label = 'u CHECK FOR UPDATE',
        }) => buildMonitorFrame(
          snapshot: MonitorSnapshot(
            instances: const <String>[],
            history: const {},
            consumerName: 'plugin',
            view: view,
          ),
          selectedIndex: 0,
          frame: 0,
          columns: columns,
          lines: 24,
          theme: MonitorTheme.plain(),
          range: const Duration(minutes: 15),
          now: now,
          clockNow: now,
          updateLabel: label,
          updateChecking: checking,
        );
        final MonitorFrame ready = frame();
        expect(Ansi.strip(ready.rows.last), endsWith('[ u CHECK FOR UPDATE ]'));
        expect(Ansi.strip(ready.rows.last), contains('q quit'));
        final MonitorHitbox hit = ready.hitboxes.singleWhere(
          (MonitorHitbox hit) => hit.id == updateHitId,
        );
        expect(hit.row, 23);
        expect(hit.colEnd, columns);
        expect(hitTest(ready.hitboxes, row: 23, col: columns - 1), updateHitId);
        expect(
          frame(
            checking: true,
          ).hitboxes.where((MonitorHitbox hit) => hit.id == updateHitId),
          isEmpty,
        );
        final MonitorFrame longVersion = frame(label: 'u UPDATE v${'1' * 100}');
        expect(Ansi.visibleLength(longVersion.rows.last), columns);
        expect(Ansi.strip(longVersion.rows.last), contains('q quit'));
      });
    }
  }
}

class _Client implements GithubUpdateClient {
  Completer<SelfUpdateRelease?> pending = Completer<SelfUpdateRelease?>();
  int checks = 0;
  @override
  Future<SelfUpdateRelease?> latest(
    UpdateVersion current,
    UpdatePlatform platform,
  ) {
    checks++;
    return pending.future;
  }

  @override
  Future<void> download(SelfUpdateRelease release, File destination) =>
      throw StateError('checks must not download');
  @override
  void close() {}
}
