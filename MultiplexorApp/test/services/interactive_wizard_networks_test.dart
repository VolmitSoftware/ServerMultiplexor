import 'dart:convert';

import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:multiplexor/services/monitor/monitor_hitbox.dart';
import 'package:multiplexor/services/monitor/monitor_modal.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

Map<String, Object?> network() => <String, Object?>{
  'name': 'dev',
  'proxy': 'dev-proxy',
  'bind': '127.0.0.1',
  'port': 25565,
  'onlineMode': true,
  'defaultServer': 'lobby',
  'fallbackServers': <String>[],
  'members': <Object?>[
    <String, Object?>{
      'consumer': 'plugin',
      'instance': 'lobby',
      'alias': 'lobby',
      'port': 25566,
    },
    <String, Object?>{
      'consumer': 'plugin',
      'instance': 'survival',
      'alias': 'survival',
      'port': 25567,
    },
  ],
};

Map<String, Object?> status({
  String state = 'stopped',
  String backendState = 'stopped',
  String proxyState = 'stopped',
  String survivalState = 'stopped',
}) => <String, Object?>{
  'network': network(),
  'state': state,
  'instances': <Object?>[
    <String, Object?>{
      'name': 'dev-proxy',
      'role': 'proxy',
      'state': proxyState,
      'port': 25565,
    },
    <String, Object?>{
      'name': 'lobby',
      'role': 'backend',
      'state': backendState,
      'port': 25566,
    },
    <String, Object?>{
      'name': 'survival',
      'role': 'backend',
      'state': survivalState,
      'port': 25567,
    },
  ],
  'issues': <String>[],
};

void main() {
  test(
    'network list preserves routing aliases and shows a useful join address',
    () {
      final WizardNetwork parsed = WizardNetwork.parseList(
        jsonEncode(<Object?>[network()]),
      ).single;
      expect(parsed.name, 'dev');
      expect(parsed.address, '127.0.0.1:25565');
      expect(parsed.monitorGroup.proxy, 'dev-proxy');
      expect(parsed.monitorGroup.port, 25565);
      expect(parsed.monitorGroup.members.first.instance, 'lobby');
      expect(parsed.monitorGroup.members.first.port, 25566);
      expect(parsed.members.map((WizardNetworkMember m) => m.alias), <String>[
        'lobby',
        'survival',
      ]);
      final WizardNetwork lan = WizardNetwork.fromJson(
        network()..['bind'] = '0.0.0.0',
      );
      expect(lan.address, 'LAN address:25565');
    },
  );

  test('configuration actions require every process to be stopped', () {
    final WizardNetworkStatus stopped = WizardNetworkStatus.parse(
      jsonEncode(status()),
    );
    expect(
      stopped.actions,
      containsAll(<String>[
        'start',
        'add',
        'remove',
        'configure',
        'repair',
        'plugins-sync',
        'delete',
      ]),
    );
    expect(stopped.actions, isNot(contains('stop')));
    final WizardNetworkStatus degraded = WizardNetworkStatus.parse(
      jsonEncode(status(state: 'degraded', backendState: 'starting')),
    );
    expect(degraded.allStopped, isFalse);
    expect(
      degraded.actions,
      containsAll(<String>['start', 'stop', 'restart', 'status', 'check']),
    );
    for (final String action in <String>[
      'console',
      'add',
      'remove',
      'configure',
      'repair',
      'delete',
    ]) {
      expect(degraded.actions, isNot(contains(action)));
    }
  });

  test(
    'network menu shows proxy players and distinguishes zero from unavailable',
    () {
      for (final int count in <int>[0, 1, 12]) {
        final Map<String, Object?> snapshot = status()
          ..['playersOnline'] = count;
        final WizardNetworkStatus parsed = WizardNetworkStatus.parse(
          jsonEncode(snapshot),
        );
        expect(parsed.playersOnline, count);
        expect(
          parsed.menuTitle,
          'dev · stopped · 127.0.0.1:25565 · $count ${count == 1 ? 'player' : 'players'}',
        );
      }
      final WizardNetworkStatus unavailable = WizardNetworkStatus.parse(
        jsonEncode(status()..['playersOnline'] = null),
      );
      expect(unavailable.playersOnline, isNull);
      expect(unavailable.menuTitle, endsWith('players unavailable'));
      expect(unavailable.menuTitle, isNot(contains('0 players')));
    },
  );

  test(
    'missing or malformed player telemetry leaves network controls available',
    () {
      for (final Map<String, Object?> snapshot in <Map<String, Object?>>[
        status(),
        status()..['playersOnline'] = -1,
        status()..['playersOnline'] = '12',
        status()..['playersOnline'] = 1.5,
      ]) {
        final WizardNetworkStatus parsed = WizardNetworkStatus.parse(
          jsonEncode(snapshot),
        );
        expect(parsed.playersOnline, isNull);
        expect(parsed.menuTitle, endsWith('players unavailable'));
        expect(
          parsed.actions,
          containsAll(<String>['start', 'check', 'repair']),
        );
      }
    },
  );

  test('partial fleet can resume and console requires its proxy process', () {
    final WizardNetworkStatus partial = WizardNetworkStatus.parse(
      jsonEncode(status(state: 'degraded', backendState: 'running')),
    );
    expect(partial.actions, contains('start'));
    expect(partial.actions, contains('plugins-sync'));
    expect(partial.actions, isNot(contains('console')));
    final WizardNetworkStatus proxyUp = WizardNetworkStatus.parse(
      jsonEncode(status(state: 'degraded', proxyState: 'running')),
    );
    expect(proxyUp.actions, containsAll(<String>['start', 'console']));
    expect(proxyUp.actions, isNot(contains('plugins-sync')));
    final WizardNetworkStatus running = WizardNetworkStatus.parse(
      jsonEncode(
        status(
          state: 'running',
          proxyState: 'running',
          backendState: 'running',
          survivalState: 'running',
        ),
      ),
    );
    expect(running.actions, isNot(contains('start')));
    expect(running.actions, contains('console'));
  });

  test('remove choices exclude both entry and fallback references', () {
    final WizardNetwork available = WizardNetwork.fromJson(network());
    expect(
      available.removableMembers.map(
        (WizardNetworkMember member) => member.alias,
      ),
      <String>['survival'],
    );
    final Map<String, Object?> definition = network()
      ..['fallbackServers'] = <String>['survival'];
    expect(WizardNetwork.fromJson(definition).removableMembers, isEmpty);
    final Map<String, Object?> snapshot = status()..['network'] = definition;
    expect(
      WizardNetworkStatus.parse(jsonEncode(snapshot)).actions,
      isNot(contains('remove')),
    );
  });

  test(
    'malformed or incomplete status cannot unlock configuration actions',
    () {
      for (final Map<String, Object?> malformed in <Map<String, Object?>>[
        status()..['instances'] = <Object?>[],
        status()..['state'] = 'unknown',
        status(backendState: 'unknown'),
        status()..['issues'] = <Object?>[false],
        status()..remove('network'),
      ]) {
        expect(
          () => WizardNetworkStatus.parse(jsonEncode(malformed)),
          throwsFormatException,
        );
      }
    },
  );

  test('candidate catalog uses the engine compatibility decisions', () {
    final List<WizardNetworkCandidate> candidates =
        WizardNetworkCandidate.parseList(
          jsonEncode(<Object?>[
            <String, Object?>{
              'instance': 'lobby',
              'type': 'paper',
              'minecraft': '26.1',
              'port': 25566,
              'isolated': true,
            },
          ]),
        );
    expect(candidates.single.label, 'lobby (paper 26.1, port 25566)');
    expect(
      () => WizardNetworkCandidate.parseList('[{"instance":"broken"}]'),
      throwsFormatException,
    );
  });

  test('Networks workspace action is available only when enabled locally', () {
    Set<String> buttons({required bool networks, required bool remote}) {
      final MonitorFrame frame = overlayModal(
        base: MonitorFrame(
          rows: List<String>.filled(24, ' ' * 80),
          hitboxes: const <MonitorHitbox>[],
        ),
        modal: const WorkspaceModal(),
        latest: null,
        locked: false,
        isolated: false,
        networks: networks,
        remote: remote,
        theme: MonitorTheme.plain(),
        columns: 80,
        lines: 24,
      );
      return frame.hitboxes.map((MonitorHitbox box) => box.id).toSet();
    }

    final String id = workspaceModalHitId(WorkspaceModalAction.networks);
    expect(buttons(networks: true, remote: false), contains(id));
    expect(buttons(networks: false, remote: false), isNot(contains(id)));
    expect(buttons(networks: true, remote: true), isNot(contains(id)));
    expect(workspaceModalActionHotkey(WorkspaceModalAction.networks), 'v');
  });
}
