import 'dart:io';

import 'package:multiplexor/cli/handlers/remote_handler.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_create_push.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_smb_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:test/test.dart';

void main() {
  group('remote creation catalog output', () {
    test('exposes exact image and environment choices for headless create', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(
          egg: _egg(
            images: const <String, String>{
              'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
            },
            variables: const <PterodactylEggVariable>[
              PterodactylEggVariable(
                name: 'Server Jar',
                environmentVariable: 'SERVER_JARFILE',
                defaultValue: 'server.jar',
                rules: 'required|string',
                userEditable: true,
                userViewable: true,
              ),
              PterodactylEggVariable(
                name: 'Secret Token',
                environmentVariable: 'TOKEN',
                defaultValue: '',
                rules: 'required|string',
                userEditable: false,
                userViewable: false,
              ),
            ],
          ),
        ),
      );

      expect(
        lines,
        contains('image\t20\tJava 21\tghcr.io/pterodactyl/yolks:java_21'),
      );
      expect(
        lines,
        contains(
          'variable\t20\tSERVER_JARFILE\trequired-default\teditable\t'
          'default=server.jar\trules=required|string',
        ),
      );
      expect(
        lines,
        contains(
          'variable\t20\tTOKEN\trequired-blank\tfixed\t'
          'default=<blank>\trules=required|string',
        ),
      );
      expect(
        lines.where((String line) => line.startsWith('egg\t')).single,
        endsWith('\tready'),
      );
    });

    test('does not label eggs without an allowed image ready', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(egg: _egg(images: const <String, String>{})),
      );

      expect(
        lines.where((String line) => line.startsWith('egg\t')).single,
        endsWith('\tno image'),
      );
    });

    test('sanitizes provider text before writing tab-separated rows', () {
      final List<String> lines = pterodactylCreationCatalogLines(
        _catalog(
          egg: _egg(
            name: 'Paper\nInjected\tColumn',
            images: const <String, String>{'Java\t21': 'image\nvalue'},
          ),
        ),
      );

      expect(lines.any((String line) => line.contains('\n')), isFalse);
      final String imageLine = lines
          .where((String line) => line.startsWith('image\t20\t'))
          .single;
      expect(imageLine, isNot(contains('\n')));
      expect(imageLine, isNot(contains('\tJava\t21\t')));
      expect(imageLine, endsWith('\timage value'));
    });
  });

  group('remote transfer preflight output', () {
    test('shows a stable file-diff summary before push confirmation', () {
      final PterodactylTransferPlan plan = PterodactylTransferPlan(
        direction: PterodactylTransferDirection.push,
        mode: PterodactylTransferMode.mirror,
        localInstanceName: 'survival-local',
        profileId: 'production',
        serverIdentifier: 'abc12345',
        remoteServerName: 'Survival',
        targetExists: true,
        targetWasRunning: true,
        sourceFingerprint: 'source-fingerprint',
        confirmationToken: 'mirror:production:abc12345:source-fingerprint',
        createdAt: DateTime.utc(2026, 8, 14),
        changes: const <PterodactylTransferChange>[
          PterodactylTransferChange(
            path: 'world/level.dat',
            kind: PterodactylTransferChangeKind.update,
            sourceSize: 80,
            targetSize: 72,
          ),
          PterodactylTransferChange(
            path: 'plugins/new.jar',
            kind: PterodactylTransferChangeKind.add,
            sourceSize: 20,
          ),
          PterodactylTransferChange(
            path: 'old-config.yml',
            kind: PterodactylTransferChangeKind.delete,
            targetSize: 10,
          ),
        ],
      );

      expect(pterodactylTransferPlanLines(plan), <String>[
        'direction:    push',
        'mode:         mirror',
        'local:        survival-local',
        'remote:       production/abc12345',
        'add:          1',
        'update:       1',
        'delete:       1',
        'transfer:     100 bytes',
        'was running:  true',
      ]);
    });

    test('names the proposed target before create-and-push', () {
      final PterodactylTransferPlan plan = PterodactylTransferPlan(
        direction: PterodactylTransferDirection.push,
        mode: PterodactylTransferMode.update,
        localInstanceName: 'local',
        profileId: 'production',
        serverIdentifier: '',
        remoteServerName: 'New Server',
        targetExists: false,
        targetWasRunning: false,
        sourceFingerprint: 'fingerprint',
        confirmationToken: 'push-new:token',
        createdAt: DateTime.utc(2026, 8, 14),
        changes: const <PterodactylTransferChange>[],
      );

      expect(
        pterodactylTransferPlanLines(plan),
        contains('remote:       production/New Server'),
      );
    });

    test('rejects a create-and-push token from another configuration', () {
      final JsonObject configurationA = <String, Object?>{
        'source_kind': 'egg',
        'source_id': 20,
        'owner_id': 4,
        'node_id': 8,
        'docker_image': 'java:21',
        'startup': 'java -jar server.jar',
        'environment': <String, String>{'SERVER_JARFILE': 'server.jar'},
        'limits': <String, Object?>{'memory': 4096, 'disk': 0},
        'feature_limits': <String, Object?>{'backups': 1},
      };
      final JsonObject configurationB = <String, Object?>{
        ...configurationA,
        'limits': <String, Object?>{'memory': 8192, 'disk': 0},
      };

      final String tokenA = pterodactylCreatePushConfirmationToken(
        transferConfirmationToken: 'transfer-token',
        canonicalCreation: configurationA,
        startAfterTransfer: false,
        persistNewLink: true,
      );
      final String tokenB = pterodactylCreatePushConfirmationToken(
        transferConfirmationToken: 'transfer-token',
        canonicalCreation: configurationB,
        startAfterTransfer: false,
        persistNewLink: true,
      );

      expect(tokenA, isNot(tokenB));
    });

    test('binds final start and durable-link decisions into confirmation', () {
      final JsonObject configuration = <String, Object?>{
        'source_kind': 'template',
        'source_uuid': 'template-uuid',
      };
      final String stopped = pterodactylCreatePushConfirmationToken(
        transferConfirmationToken: 'transfer-token',
        canonicalCreation: configuration,
        startAfterTransfer: false,
        persistNewLink: false,
      );

      expect(
        pterodactylCreatePushConfirmationToken(
          transferConfirmationToken: 'transfer-token',
          canonicalCreation: configuration,
          startAfterTransfer: true,
          persistNewLink: false,
        ),
        isNot(stopped),
      );
      expect(
        pterodactylCreatePushConfirmationToken(
          transferConfirmationToken: 'transfer-token',
          canonicalCreation: configuration,
          startAfterTransfer: false,
          persistNewLink: true,
        ),
        isNot(stopped),
      );
    });

    test('redacts every resolved environment value from preview output', () {
      final String summary = pterodactylResolvedEnvironmentSummary(
        const <String, String>{
          'TOKEN': 'super-secret-token',
          'DATABASE_PASSWORD': 'hunter2',
        },
      );

      expect(summary, 'DATABASE_PASSWORD=<redacted>, TOKEN=<redacted>');
      expect(summary, isNot(contains('super-secret-token')));
      expect(summary, isNot(contains('hunter2')));
    });
  });

  group('remote transfer Drive preparation', () {
    test('account-only preparation supports an empty Panel', () {
      final PterodactylTransferDrivePreparation preparation =
          pterodactylTransferDrivePreparation(
            settings: null,
            profileId: 'production',
            accountOnly: true,
          );

      expect(preparation.needsAccount, isTrue);
      expect(preparation.inspectTarget, isFalse);
    });

    test('full preparation reuses an enabled Drive account', () {
      final String temporaryRoot = Directory.systemTemp.path;
      final PterodactylSmbSettings settings = PterodactylSmbSettings(
        shareName: 'Multiplexor Drive',
        mountRoot: '$temporaryRoot/multiplexor-drive-test',
        knownHostsFile: '$temporaryRoot/multiplexor-known-hosts-test',
        accounts: <PterodactylSftpAccount>[
          PterodactylSftpAccount(
            profileId: 'production',
            panelUsername: 'operator',
          ),
        ],
      );

      final PterodactylTransferDrivePreparation preparation =
          pterodactylTransferDrivePreparation(
            settings: settings,
            profileId: 'production',
            accountOnly: false,
          );

      expect(preparation.needsAccount, isFalse);
      expect(preparation.inspectTarget, isTrue);
    });
  });

  test('explicit Push postconditions fail closed after data commit', () {
    expect(
      pterodactylMissingTransferPostconditions(
        requirePersistedLink: true,
        linkPersisted: false,
        requireRunning: true,
        remoteRestarted: false,
      ),
      <String>['durable Remote link', 'requested running state'],
    );
    expect(
      pterodactylMissingTransferPostconditions(
        requirePersistedLink: false,
        linkPersisted: false,
        requireRunning: false,
        remoteRestarted: false,
      ),
      isEmpty,
    );
  });
}

PterodactylCreationCatalog _catalog({required PterodactylEgg egg}) =>
    PterodactylCreationCatalog(
      templates: const <PterodactylApplicationServer>[],
      users: const <PterodactylUser>[
        PterodactylUser(
          id: 1,
          uuid: '00000000-0000-0000-0000-000000000001',
          username: 'operator',
          email: 'operator@example.test',
          firstName: 'Panel',
          lastName: 'Operator',
          isRootAdmin: true,
        ),
      ],
      nodes: const <PterodactylNode>[
        PterodactylNode(
          id: 5,
          uuid: '00000000-0000-0000-0000-000000000005',
          name: 'node-a',
          fqdn: 'node-a.example.test',
          scheme: 'https',
          public: true,
          behindProxy: false,
          maintenanceMode: false,
          memoryMiB: 16384,
          diskMiB: 65536,
          allocatedMemoryMiB: 4096,
          allocatedDiskMiB: 8192,
          daemonPort: 8080,
          sftpPort: 2022,
        ),
      ],
      nests: const <PterodactylNest>[
        PterodactylNest(
          id: 10,
          uuid: '00000000-0000-0000-0000-000000000010',
          name: 'Minecraft',
          author: 'support@example.test',
        ),
      ],
      eggs: <PterodactylEgg>[egg],
      freeAllocationsByNode: const <int, List<PterodactylAllocation>>{
        5: <PterodactylAllocation>[
          PterodactylAllocation(
            id: 50,
            ip: '127.0.0.1',
            port: 25565,
            isAssigned: false,
          ),
        ],
      },
      recommendedOwnerId: 1,
    );

PterodactylEgg _egg({
  String name = 'Paper',
  required Map<String, String> images,
  List<PterodactylEggVariable> variables = const <PterodactylEggVariable>[],
}) => PterodactylEgg(
  id: 20,
  uuid: '00000000-0000-0000-0000-000000000020',
  name: name,
  nestId: 10,
  author: 'support@example.test',
  startup: 'java -jar {{SERVER_JARFILE}}',
  dockerImages: images,
  variables: variables,
);
