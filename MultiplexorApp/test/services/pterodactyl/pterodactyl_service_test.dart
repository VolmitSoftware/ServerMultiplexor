import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_credential_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_console_session.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:test/test.dart';

void main() {
  test('remote polling stays at the Panel cache floor for small fleets', () {
    expect(
      PterodactylService.recommendedPollInterval(10),
      const Duration(seconds: 20),
    );
  });

  test('remote polling slows down before a large fleet hits rate limits', () {
    final Duration interval = PterodactylService.recommendedPollInterval(85);
    final double requestsPerMinute = 86 * 60 / interval.inSeconds;

    expect(interval, const Duration(seconds: 52));
    expect(requestsPerMinute, lessThanOrEqualTo(100));
  });

  test('shared servers are not offered as creation templates', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-pterodactyl-service-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylProfile profile = PterodactylProfile(
      id: 'remote',
      name: 'Remote',
      panelUri: Uri.parse('https://panel.example.test'),
    );
    final PterodactylProfileStore profiles = PterodactylProfileStore(
      temporary.path,
    )..save(profile);
    final PterodactylService service = PterodactylService(
      profileStore: profiles,
      credentialStore: PterodactylCredentialStore(
        temporary.path,
        environment: const <String, String>{},
      ),
    );

    expect(
      service.canUseAsTemplate(profile.id, _server(isOwner: false)),
      isFalse,
    );
    expect(
      service.canUseAsTemplate(profile.id, _server(isOwner: true)),
      isTrue,
    );
  });

  test('openConsole returns an unstarted owned connection', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-pterodactyl-console-service-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylProfile profile = PterodactylProfile(
      id: 'remote',
      name: 'Remote',
      panelUri: Uri.parse('https://panel.example.test'),
    );
    final PterodactylProfileStore profiles = PterodactylProfileStore(
      temporary.path,
    )..save(profile);
    final String credentialVariable =
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        );
    final String originVariable =
        PterodactylCredentialStore.environmentOriginVariableFor(profile);
    final PterodactylService service = PterodactylService(
      profileStore: profiles,
      credentialStore: PterodactylCredentialStore(
        temporary.path,
        environment: <String, String>{
          credentialVariable: 'client-api-key',
          originVariable: profile.origin,
        },
      ),
    );
    final _RecordingConnector connector = _RecordingConnector();

    final PterodactylConsoleConnection connection = await service.openConsole(
      profile.id,
      'abc12345',
      connector: connector,
    );

    expect(connector.connectCount, 0);
    await expectLater(connection.requestStats(), throwsStateError);
    await connection.close();
    await connection.done;
    expect(connector.connectCount, 0);
  });
}

final class _RecordingConnector implements PterodactylConsoleSocketConnector {
  int connectCount = 0;

  @override
  Future<PterodactylConsoleSocket> connect(
    Uri socketUri, {
    required String origin,
  }) async {
    connectCount++;
    throw StateError('Unexpected socket connection.');
  }
}

PterodactylClientServer _server({required bool isOwner}) =>
    PterodactylClientServer(
      identifier: 'abc12345',
      internalId: 1,
      uuid: '00000000-0000-0000-0000-000000000001',
      name: 'Template',
      nodeName: 'node',
      description: '',
      isOwner: isOwner,
      isNodeUnderMaintenance: false,
      status: null,
      sftpHost: 'panel.example.test',
      sftpPort: 2022,
      limits: const PterodactylServerLimits(
        memoryMiB: 1024,
        swapMiB: 0,
        diskMiB: 1024,
        ioWeight: 500,
        cpuPercent: 100,
        threads: null,
        oomDisabled: false,
      ),
      featureLimits: const PterodactylFeatureLimits(
        databases: 0,
        allocations: 0,
        backups: 0,
      ),
      allocations: const <PterodactylAllocation>[],
    );
