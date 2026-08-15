import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_create_push.dart';
import 'package:multiplexor/services/monitor/monitor_keymap.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_models.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_errors.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:multiplexor/utils/user_prompt.dart';
import 'package:test/test.dart';

void main() {
  group('Remote transfer destination policy', () {
    test('offers linked, existing, and new targets when available', () {
      expect(
        remoteTransferDestinations(hasLink: true, hasProfiles: true),
        <RemoteTransferDestination>[
          RemoteTransferDestination.linked,
          RemoteTransferDestination.existing,
          RemoteTransferDestination.createNew,
          RemoteTransferDestination.done,
        ],
      );
    });

    test('does not offer dead-end target choices', () {
      expect(
        remoteTransferDestinations(hasLink: false, hasProfiles: false),
        <RemoteTransferDestination>[RemoteTransferDestination.done],
      );
      expect(
        remoteTransferDestinations(hasLink: false, hasProfiles: true),
        <RemoteTransferDestination>[
          RemoteTransferDestination.existing,
          RemoteTransferDestination.createNew,
          RemoteTransferDestination.done,
        ],
      );
    });

    test('suggests a safe and recognizable Local instance name', () {
      expect(
        remotePullDefaultLocalName(
          remoteName: 'Survival Main #1',
          serverIdentifier: 'a1b2c3',
        ),
        'Survival-Main-1-local',
      );
      expect(
        remotePullDefaultLocalName(
          remoteName: '... ---',
          serverIdentifier: 'a1b2c3',
        ),
        'a1b2c3-local',
      );
      expect(
        remotePullDefaultLocalName(
          remoteName: 'staging-local',
          serverIdentifier: 'a1b2c3',
        ),
        'staging-local',
      );
    });

    test('only mirror requires an exact case-sensitive typed token', () {
      expect(
        remoteTransferRequiresTypedConfirmation(PterodactylTransferMode.update),
        isFalse,
      );
      expect(
        remoteTransferRequiresTypedConfirmation(PterodactylTransferMode.mirror),
        isTrue,
      );
      expect(
        remoteTransferConfirmationMatches(
          expected: 'MIRROR abc123',
          typed: 'MIRROR abc123',
        ),
        isTrue,
      );
      expect(
        remoteTransferConfirmationMatches(
          expected: 'MIRROR abc123',
          typed: 'mirror abc123',
        ),
        isFalse,
      );
      expect(remoteMirrorConfirmationPhrase(' abc123 '), 'MIRROR abc123');
    });

    test('an existing link is never replaced by default', () {
      expect(remoteTransferRelinkDefault(hasExistingLink: false), isTrue);
      expect(remoteTransferRelinkDefault(hasExistingLink: true), isFalse);
    });

    test('preflight preserves and sanitizes every engine warning', () {
      final PterodactylTransferPlan plan = PterodactylTransferPlan(
        direction: PterodactylTransferDirection.push,
        mode: PterodactylTransferMode.update,
        localInstanceName: 'local',
        profileId: 'production',
        serverIdentifier: 'abc123',
        remoteServerName: 'Remote',
        targetExists: true,
        targetWasRunning: false,
        sourceFingerprint: 'source',
        confirmationToken: 'token',
        createdAt: DateTime.utc(2026, 8, 14),
        changes: const <PterodactylTransferChange>[],
        warnings: const <String>[
          'Symlink skipped',
          '\u001b[31mUnsafe\u001b[0m\nSecond line',
        ],
      );

      expect(remoteTransferPlanWarnings(plan), <String>[
        'Symlink skipped',
        'Unsafe Second line',
      ]);
    });

    test('runtime result distinguishes a new start from state restoration', () {
      expect(
        remoteTransferRuntimeResultMessage(
          remoteStarted: true,
          newTarget: true,
        ),
        'The new Remote target was started after validation.',
      );
      expect(
        remoteTransferRuntimeResultMessage(
          remoteStarted: true,
          newTarget: false,
        ),
        'The Remote target was restored to its previous running state.',
      );
      expect(
        remoteTransferRuntimeResultMessage(
          remoteStarted: false,
          newTarget: true,
        ),
        isNull,
      );
    });

    test(
      'ambiguous intents resume and completed intents never create again',
      () {
        expect(
          remoteCreatePushClaimAction(
            shouldCreate: true,
            alreadyCompleted: false,
          ),
          RemoteCreatePushClaimAction.create,
        );
        expect(
          remoteCreatePushClaimAction(
            shouldCreate: false,
            alreadyCompleted: false,
          ),
          RemoteCreatePushClaimAction.resume,
        );
        expect(
          remoteCreatePushClaimAction(
            shouldCreate: false,
            alreadyCompleted: true,
          ),
          RemoteCreatePushClaimAction.completed,
        );
        expect(
          () => remoteCreatePushClaimAction(
            shouldCreate: true,
            alreadyCompleted: true,
          ),
          throwsStateError,
        );
      },
    );

    test('postcondition failures route only resumable intents to repair', () {
      expect(
        remoteCreatePushUsesPostconditionRepair(
          action: RemoteCreatePushClaimAction.resume,
          needsPostconditionRepair: true,
        ),
        isTrue,
      );
      expect(
        remoteCreatePushUsesPostconditionRepair(
          action: RemoteCreatePushClaimAction.resume,
          needsPostconditionRepair: false,
        ),
        isFalse,
      );
      expect(
        remoteCreatePushUsesPostconditionRepair(
          action: RemoteCreatePushClaimAction.create,
          needsPostconditionRepair: false,
        ),
        isFalse,
      );
      for (final RemoteCreatePushClaimAction action
          in <RemoteCreatePushClaimAction>[
            RemoteCreatePushClaimAction.create,
            RemoteCreatePushClaimAction.completed,
          ]) {
        expect(
          () => remoteCreatePushUsesPostconditionRepair(
            action: action,
            needsPostconditionRepair: true,
          ),
          throwsStateError,
          reason: action.name,
        );
      }
    });

    test(
      'exact create preview shows every field without environment values',
      () {
        final PterodactylCreatePushPlan unresolved =
            PterodactylCreatePushPlan.template(
              plan: PterodactylTemplateCreatePlan.fromTemplate(
                template: _template(
                  environment: const <String, String>{
                    'Z_SECRET': 'do-not-print',
                    'A_TOKEN': 'also-secret',
                  },
                  limits: const PterodactylServerLimits(
                    memoryMiB: 6144,
                    swapMiB: -1,
                    diskMiB: 20480,
                    ioWeight: 750,
                    cpuPercent: 225,
                    threads: '0-3',
                    oomDisabled: true,
                  ),
                  featureLimits: const PterodactylFeatureLimits(
                    databases: 2,
                    allocations: 3,
                    backups: 4,
                  ),
                  startup: 'java -Xms128M -jar server.jar --nogui',
                ),
                name: 'New Remote',
                ownerId: 7,
                startOnCompletion: false,
              ),
              ownerName: 'owner',
              nodeName: 'node',
            );
        final PterodactylTransferPlan transferPlan = PterodactylTransferPlan(
          direction: PterodactylTransferDirection.push,
          mode: PterodactylTransferMode.update,
          localInstanceName: 'local-one',
          localConsumer: 'plugin',
          localInstancePath: '/workspace/instances/local-one',
          profileId: 'production',
          serverIdentifier: 'New Remote',
          remoteServerName: 'New Remote',
          targetExists: false,
          targetWasRunning: false,
          sourceFingerprint: 'sha256:source-fingerprint',
          confirmationToken: 'transfer-token',
          createdAt: DateTime.utc(2026, 8, 14),
          changes: const <PterodactylTransferChange>[],
        );
        final String intentId = pterodactylCreatePushIntentId(
          transferPlan: transferPlan,
          canonicalCreation: unresolved.canonicalJson,
          startAfterTransfer: true,
          persistNewLink: false,
        );
        final PterodactylCreatePushPlan resolved = unresolved.withExternalId(
          intentId,
        );
        final String confirmation = pterodactylCreatePushConfirmationToken(
          transferConfirmationToken: transferPlan.confirmationToken,
          canonicalCreation: resolved.canonicalJson,
          startAfterTransfer: true,
          persistNewLink: false,
        );

        expect(unresolved.externalId, isNull);
        expect(resolved.externalId, intentId);
        expect(intentId, startsWith('multiplexor-push-'));
        expect(confirmation, startsWith('push-new:'));
        final DateTime linkedAt = DateTime.utc(2026, 8, 13);
        final PterodactylRemoteLink existingLink = PterodactylRemoteLink(
          profileId: 'legacy',
          serverIdentifier: 'old12345',
          serverUuid: '00000000-0000-0000-0000-000000000099',
          serverName: 'Old Remote',
          localInstanceName: 'local-one',
          localConsumer: 'plugin',
          linkedAt: linkedAt,
          lastTransferredAt: linkedAt,
        );
        final List<MapEntry<String, String>> detailEntries =
            remoteCreatePushPreviewDetails(
              creation: resolved,
              transferPlan: transferPlan,
              existingLink: existingLink,
              startAfterTransfer: true,
              persistNewLink: false,
              intentId: intentId,
              confirmationToken: confirmation,
            );
        final Map<String, String> details = Map<String, String>.fromEntries(
          detailEntries,
        );
        expect(details.keys, <String>[
          'create from',
          'template UUID',
          'egg ID',
          'server name',
          'external ID',
          'owner',
          'node',
          'image',
          'startup',
          'environment',
          'resources',
          'features',
          'create flags',
          'final state',
          'link action',
          'transfer fingerprint',
          'transfer token',
          'intent',
          'confirmation token',
        ]);
        expect(details['create from'], 'template · Template');
        expect(
          details['template UUID'],
          '00000000-0000-0000-0000-000000000001',
        );
        expect(details['egg ID'], '20');
        expect(details['server name'], 'New Remote');
        expect(details['external ID'], intentId);
        expect(details['owner'], '7 · owner');
        expect(details['node'], '1 · node');
        expect(details['image'], 'ghcr.io/pterodactyl/yolks:java_21');
        expect(details['startup'], 'java -Xms128M -jar server.jar --nogui');
        expect(
          details['environment'],
          'A_TOKEN=<redacted>, Z_SECRET=<redacted>',
        );
        expect(
          details['resources'],
          'memory=6144 MiB · swap=-1 MiB · disk=20480 MiB · io=750 · '
          'cpu=225% · threads=0-3',
        );
        expect(details['features'], 'databases=2 · allocations=3 · backups=4');
        expect(
          details['create flags'],
          'oom_disabled=true · skip_scripts=false · start_on_completion=false',
        );
        expect(details['final state'], 'running after validation');
        expect(
          details['link action'],
          'preserve legacy/old12345 · new server is one-time',
        );
        expect(details['transfer fingerprint'], 'sha256:source-fingerprint');
        expect(details['transfer token'], 'transfer-token');
        expect(details['intent'], intentId);
        expect(details['confirmation token'], confirmation);
        final String preview = detailEntries
            .map<String>(
              (MapEntry<String, String> detail) =>
                  '${detail.key}: ${detail.value}',
            )
            .join('\n');
        expect(preview, isNot(contains('do-not-print')));
        expect(preview, isNot(contains('also-secret')));
        expect(
          pterodactylCreatePushConfirmationToken(
            transferConfirmationToken: 'transfer-token',
            canonicalCreation: resolved.canonicalJson,
            startAfterTransfer: false,
            persistNewLink: false,
          ),
          isNot(confirmation),
        );
        expect(
          pterodactylCreatePushConfirmationToken(
            transferConfirmationToken: 'transfer-token',
            canonicalCreation: resolved.canonicalJson,
            startAfterTransfer: true,
            persistNewLink: true,
          ),
          isNot(confirmation),
        );
        final PterodactylTransferPlan changedSourcePlan =
            PterodactylTransferPlan(
              direction: PterodactylTransferDirection.push,
              mode: PterodactylTransferMode.update,
              localInstanceName: transferPlan.localInstanceName,
              localConsumer: transferPlan.localConsumer,
              localInstancePath: transferPlan.localInstancePath,
              profileId: transferPlan.profileId,
              serverIdentifier: transferPlan.serverIdentifier,
              remoteServerName: transferPlan.remoteServerName,
              targetExists: false,
              targetWasRunning: false,
              sourceFingerprint: 'sha256:changed-source',
              confirmationToken: 'transfer-token-after-change',
              createdAt: DateTime.utc(2026, 8, 15),
              changes: const <PterodactylTransferChange>[],
            );
        expect(
          pterodactylCreatePushIntentId(
            transferPlan: changedSourcePlan,
            canonicalCreation: unresolved.canonicalJson,
            startAfterTransfer: true,
            persistNewLink: false,
          ),
          intentId,
        );
        expect(
          pterodactylCreatePushConfirmationToken(
            transferConfirmationToken: changedSourcePlan.confirmationToken,
            canonicalCreation: resolved.canonicalJson,
            startAfterTransfer: true,
            persistNewLink: false,
          ),
          isNot(confirmation),
        );

        final PterodactylEgg egg = _egg();
        final PterodactylCreatePushPlan eggCreation =
            PterodactylCreatePushPlan.egg(
              name: 'Egg Remote',
              source: egg,
              plan: PterodactylEggCreatePlan(
                ownerId: 9,
                nodeId: 4,
                eggId: egg.id,
                eggUuid: egg.uuid,
                dockerImage: 'ghcr.io/pterodactyl/yolks:java_21',
                startup: 'java -jar {{SERVER_JARFILE}}',
                environment: const <String, String>{
                  'SERVER_JARFILE': 'egg-secret.jar',
                },
              ),
              ownerName: 'egg-owner',
              nodeName: 'egg-node',
            ).withExternalId('multiplexor-push-egg-source');
        final Map<String, String> eggDetails = Map<String, String>.fromEntries(
          remoteCreatePushPreviewDetails(
            creation: eggCreation,
            transferPlan: transferPlan,
            existingLink: null,
            startAfterTransfer: false,
            persistNewLink: true,
            intentId: eggCreation.externalId!,
            confirmationToken: 'push-new:egg-confirmation',
          ),
        );
        expect(eggDetails['create from'], 'egg · Paper');
        expect(eggDetails['egg UUID'], '00000000-0000-0000-0000-000000000020');
        expect(eggDetails['egg ID'], '20');
        expect(eggDetails, isNot(contains('template UUID')));
        expect(eggDetails['environment'], 'SERVER_JARFILE=<redacted>');
        expect(eggDetails.values.join('\n'), isNot(contains('egg-secret.jar')));
        expect(
          eggDetails['link action'],
          'save new Remote server · Local is unlinked',
        );
      },
    );
  });

  group('Pterodactyl account key enrollment', () {
    test(
      'accepts the expected standard prefix and legacy unknown prefixes',
      () {
        expect(
          pterodactylCredentialMatchesRole(
            PterodactylCredential('ptlc_client'),
            PterodactylCredentialRole.client,
          ),
          isTrue,
        );
        expect(
          pterodactylCredentialMatchesRole(
            PterodactylCredential('legacy-token'),
            PterodactylCredentialRole.application,
          ),
          isTrue,
        );
      },
    );

    test('rejects a standard prefix for the opposite credential role', () {
      expect(
        pterodactylCredentialMatchesRole(
          PterodactylCredential('ptla_application'),
          PterodactylCredentialRole.client,
        ),
        isFalse,
      );
      expect(
        pterodactylCredentialMatchesRole(
          PterodactylCredential('ptlc_client'),
          PterodactylCredentialRole.application,
        ),
        isFalse,
      );
    });
  });

  group('Remote quick-action runtime policy', () {
    test('offline restart starts instead', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: ' OFFLINE ',
        ),
        RemoteQuickActionEffect.start,
      );
    });

    test('offline stop, kill, and console are no-ops', () {
      for (final MonitorAction action in <MonitorAction>[
        MonitorAction.stop,
        MonitorAction.kill,
        MonitorAction.console,
      ]) {
        expect(
          remoteQuickActionEffect(action: action, currentState: 'offline'),
          RemoteQuickActionEffect.none,
          reason: action.name,
        );
      }
    });

    test('live shortcuts preserve their requested effects', () {
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.restart,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.restart,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.stop,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.stop,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.kill,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.kill,
      );
      expect(
        remoteQuickActionEffect(
          action: MonitorAction.console,
          currentState: 'running',
        ),
        RemoteQuickActionEffect.console,
      );
    });
  });

  group('Remote bulk target policy', () {
    final List<PterodactylFleetSample> fleet = <PterodactylFleetSample>[
      _sample('offline1', 'Offline', state: 'offline'),
      _sample('running1', 'Running', state: 'running'),
      _sample('starting', 'Starting', state: 'starting'),
      _sample('suspend1', 'Suspended', state: 'running', suspended: true),
      _sample('maintain', 'Maintenance', state: 'running', maintenance: true),
      _sample('install1', 'Installing', state: 'offline', status: 'installing'),
      _sample('unknown1', 'Unavailable'),
    ];

    test('start and live power actions retain only actionable states', () {
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.start,
            scope: RemoteBulkTargetScope.all,
          ),
        ),
        <String>['offline1'],
      );
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.restart,
            scope: RemoteBulkTargetScope.all,
          ),
        ),
        <String>['running1', 'starting'],
      );
    });

    test('selected scope follows the dashboard selection exactly', () {
      expect(
        _ids(
          remoteBulkTargets(
            fleet: fleet,
            action: RemoteBulkAction.delete,
            scope: RemoteBulkTargetScope.selected,
            selectedIdentifier: 'RUNNING1',
          ),
        ),
        <String>['running1'],
      );
    });

    test(
      'management actions can include suspended and unavailable servers',
      () {
        expect(
          _ids(
            remoteBulkTargets(
              fleet: fleet,
              action: RemoteBulkAction.reinstall,
              scope: RemoteBulkTargetScope.all,
            ),
          ),
          <String>[
            'offline1',
            'running1',
            'starting',
            'suspend1',
            'maintain',
            'install1',
            'unknown1',
          ],
        );
        expect(
          _ids(
            remoteBulkTargets(
              fleet: fleet,
              action: RemoteBulkAction.delete,
              scope: RemoteBulkTargetScope.running,
            ),
          ),
          <String>['running1', 'starting', 'suspend1', 'maintain'],
        );
      },
    );

    test('destructive actions use exact count or whole-profile phrases', () {
      expect(remoteBulkConfirmationPhrase(RemoteBulkAction.kill, 3), 'KILL 3');
      expect(
        remoteBulkConfirmationPhrase(
          RemoteBulkAction.delete,
          8,
          allProfileId: 'Production',
        ),
        'DELETE ALL production',
      );
      expect(
        remoteBulkActionRequiresTypedConfirmation(RemoteBulkAction.reinstall),
        isTrue,
      );
      expect(
        remoteBulkActionRequiresTypedConfirmation(RemoteBulkAction.stop),
        isFalse,
      );
    });
  });

  group('Remote create workspace policy', () {
    test('zero-server panels offer egg creation instead of dead-ending', () {
      expect(
        remoteCreateSources(hasPanelEggs: true, hasTemplates: false),
        <RemoteCreateSource>[
          RemoteCreateSource.panelEgg,
          RemoteCreateSource.done,
        ],
      );
    });

    test('a truly empty catalog has no synthetic credential-repair source', () {
      expect(
        remoteCreateSources(hasPanelEggs: false, hasTemplates: false),
        <RemoteCreateSource>[RemoteCreateSource.done],
      );
    });

    test('partial egg inventory proceeds with clone without key repair', () {
      final PterodactylCreationCatalog catalog = _catalog(
        templates: <PterodactylApplicationServer>[_template()],
        eggInventoryUnavailablePermission: 'Eggs READ',
      );

      expect(remoteCreateUsableEggs(catalog), isEmpty);
      expect(
        remoteCreateSources(
          hasPanelEggs: remoteCreateUsableEggs(catalog).isNotEmpty,
          hasTemplates: catalog.templates.isNotEmpty,
        ),
        <RemoteCreateSource>[
          RemoteCreateSource.cloneExisting,
          RemoteCreateSource.done,
        ],
      );
      expect(
        remoteCreatePartialEggInventoryNote(catalog),
        'Panel egg creation is unavailable (missing Eggs READ); '
        'continuing with clone existing.',
      );
      expect(remoteCreationCatalogErrorNeedsCredentialRepair(catalog), isFalse);
    });

    test('existing panels offer both egg and clone sources', () {
      expect(
        remoteCreateSources(hasPanelEggs: true, hasTemplates: true),
        <RemoteCreateSource>[
          RemoteCreateSource.panelEgg,
          RemoteCreateSource.cloneExisting,
          RemoteCreateSource.done,
        ],
      );
    });

    test('an empty panel with one configured egg remains creation-ready', () {
      final PterodactylEgg egg = _egg();
      final PterodactylCreationCatalog catalog = _catalog(
        eggs: <PterodactylEgg>[egg],
      );

      expect(catalog.templates, isEmpty);
      expect(remoteCreateUsableEggs(catalog), <PterodactylEgg>[egg]);
      expect(
        remoteCreateSources(
          hasPanelEggs: remoteCreateUsableEggs(catalog).isNotEmpty,
          hasTemplates: catalog.templates.isNotEmpty,
        ),
        <RemoteCreateSource>[
          RemoteCreateSource.panelEgg,
          RemoteCreateSource.done,
        ],
      );
    });

    test('required blank variables are prompted even when not editable', () {
      const PterodactylEggVariable requiredBlank = PterodactylEggVariable(
        name: 'Minecraft version',
        environmentVariable: 'MC_VERSION',
        defaultValue: '',
        rules: 'required|string',
        userEditable: false,
        userViewable: false,
      );
      const PterodactylEggVariable requiredDefault = PterodactylEggVariable(
        name: 'Jar file',
        environmentVariable: 'SERVER_JARFILE',
        defaultValue: 'server.jar',
        rules: 'required|string',
        userEditable: false,
        userViewable: true,
      );
      const PterodactylEggVariable editableOptional = PterodactylEggVariable(
        name: 'Message',
        environmentVariable: 'MESSAGE',
        defaultValue: '',
        rules: 'nullable|string',
        userEditable: true,
        userViewable: true,
      );
      const PterodactylEggVariable hiddenOptional = PterodactylEggVariable(
        name: 'Hidden',
        environmentVariable: 'HIDDEN',
        defaultValue: '',
        rules: 'nullable|string',
        userEditable: false,
        userViewable: false,
      );
      final PterodactylEgg egg = _egg(
        variables: const <PterodactylEggVariable>[
          requiredBlank,
          requiredDefault,
          editableOptional,
          hiddenOptional,
        ],
      );

      expect(remoteCreatePromptVariables(egg), <PterodactylEggVariable>[
        requiredBlank,
        editableOptional,
      ]);
      expect(remoteCreateVariableUsesSecretInput(requiredBlank), isTrue);
      expect(remoteCreateVariableUsesSecretInput(editableOptional), isTrue);
    });

    test('node eligibility excludes maintenance and under-allocated nodes', () {
      final PterodactylNode ready = _node(1, 'Ready');
      final PterodactylNode maintenance = _node(
        2,
        'Maintenance',
        maintenance: true,
      );
      final PterodactylNode short = _node(3, 'Short');
      final PterodactylCreationCatalog catalog = _catalog(
        nodes: <PterodactylNode>[ready, maintenance, short],
        freeAllocationsByNode: <int, List<PterodactylAllocation>>{
          1: <PterodactylAllocation>[_allocation(1), _allocation(2)],
          2: <PterodactylAllocation>[_allocation(3), _allocation(4)],
          3: <PterodactylAllocation>[_allocation(5)],
        },
      );

      expect(remoteCreateEligibleNodes(catalog, 2), <PterodactylNode>[ready]);
    });

    test('connected panel owner is preselected when present', () {
      final List<PterodactylUser> users = <PterodactylUser>[
        _user(4, 'other'),
        _user(9, 'connected'),
      ];
      expect(remoteCreateOwnerInitialIndex(users, 9), 1);
      expect(remoteCreateOwnerInitialIndex(users, 99), 0);
    });

    test('name patterns are exact for single and multi-create', () {
      expect(remoteCreateNames(pattern: 'Survival {n}', count: 3), <String>[
        'Survival 1',
        'Survival 2',
        'Survival 3',
      ]);
      expect(remoteCreateNames(pattern: 'Proxy', count: 2), <String>[
        'Proxy 1',
        'Proxy 2',
      ]);
      expect(remoteCreateNames(pattern: 'Lobby', count: 1), <String>['Lobby']);
    });

    test('name planning rejects empty names and unsafe batch sizes', () {
      expect(
        () => remoteCreateNames(pattern: '  ', count: 1),
        throwsArgumentError,
      );
      expect(
        () => remoteCreateNames(pattern: 'Server', count: 0),
        throwsRangeError,
      );
      expect(
        () => remoteCreateNames(pattern: 'Server', count: 101),
        throwsRangeError,
      );
    });

    test('final creation confirmation is default-No', () {
      expect(remoteCreateFinalConfirmationDefault, isFalse);
    });

    test('Escape unwinds one creation source step', () async {
      expect(
        await remoteCreateStepOrBack(() async {
          throw const PromptBackNavigation();
        }),
        isFalse,
      );
      expect(await remoteCreateStepOrBack(() async {}), isTrue);
    });

    test('create-many result rows retain service order and positions', () {
      final PterodactylBulkResult result = PterodactylBulkResult(
        action: PterodactylBulkAction.create,
        items: const <PterodactylBulkItemResult>[
          PterodactylBulkItemResult(
            target: 'Lobby 1',
            name: 'Lobby 1',
            identifier: 'first',
            succeeded: true,
          ),
          PterodactylBulkItemResult(
            target: 'Lobby 2',
            name: 'Lobby 2',
            identifier: null,
            succeeded: false,
            error: 'allocation unavailable',
          ),
          PterodactylBulkItemResult(
            target: 'Lobby 3',
            name: 'Lobby 3',
            identifier: 'third',
            succeeded: true,
          ),
        ],
      );

      final List<RemoteCreateResultRow> rows = remoteCreateResultRows(result);
      expect(rows.map((RemoteCreateResultRow row) => row.item.target), <String>[
        'Lobby 1',
        'Lobby 2',
        'Lobby 3',
      ]);
      expect(rows.map((RemoteCreateResultRow row) => row.position), <int>[
        1,
        2,
        3,
      ]);
      expect(rows.every((RemoteCreateResultRow row) => row.total == 3), isTrue);
    });

    test('typed catalog ACL failures enter credential repair policy', () {
      expect(
        remoteCreationCatalogErrorNeedsCredentialRepair(
          const PterodactylCreationCatalogPermissionException(
            permission: 'Eggs READ',
          ),
        ),
        isTrue,
      );
      expect(
        remoteCreationCatalogErrorNeedsCredentialRepair(
          PterodactylApiException(
            statusCode: 403,
            method: 'GET',
            uri: Uri.parse('https://panel.example.test/api/application/nests'),
            message: 'Forbidden',
          ),
        ),
        isTrue,
      );
      expect(
        remoteCreationCatalogErrorNeedsCredentialRepair(StateError('broken')),
        isFalse,
      );
    });

    test('catalog access does not require creation readiness', () {
      final PterodactylProfile profile = PterodactylProfile(
        id: 'panel',
        name: 'Panel',
        panelUri: Uri.parse('https://panel.example.test'),
      );
      final PterodactylVerification inventoryOnly = PterodactylVerification(
        profile: profile,
        serverCount: 0,
        nodeCount: 0,
        capabilities: const <PterodactylCapability>{
          PterodactylCapability.view,
          PterodactylCapability.configure,
        },
        warnings: const <String>['Panel needs at least one node.'],
      );
      expect(
        inventoryOnly.capabilities.contains(PterodactylCapability.create),
        isFalse,
      );
      expect(remoteCreationCatalogAccessAvailable(inventoryOnly), isTrue);
    });
  });
}

List<String> _ids(Iterable<PterodactylFleetSample> samples) => samples
    .map((PterodactylFleetSample sample) => sample.server.identifier)
    .toList(growable: false);

PterodactylFleetSample _sample(
  String identifier,
  String name, {
  String? state,
  bool suspended = false,
  bool maintenance = false,
  String? status,
}) => PterodactylFleetSample(
  server: PterodactylClientServer(
    identifier: identifier,
    internalId: identifier.hashCode.abs() + 1,
    uuid: '00000000-0000-0000-0000-000000000001',
    name: name,
    nodeName: 'node',
    description: '',
    isOwner: true,
    isNodeUnderMaintenance: maintenance,
    status: status,
    sftpHost: 'wings.example.test',
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
  ),
  resources: state == null
      ? null
      : PterodactylResourceUsage(
          currentState: state,
          isSuspended: suspended,
          memoryBytes: 0,
          cpuAbsolute: 0,
          diskBytes: 0,
          networkRxBytes: 0,
          networkTxBytes: 0,
          uptime: Duration.zero,
        ),
);

PterodactylCreationCatalog _catalog({
  List<PterodactylApplicationServer> templates =
      const <PterodactylApplicationServer>[],
  List<PterodactylEgg> eggs = const <PterodactylEgg>[],
  List<PterodactylNode> nodes = const <PterodactylNode>[],
  Map<int, List<PterodactylAllocation>> freeAllocationsByNode =
      const <int, List<PterodactylAllocation>>{},
  String? eggInventoryUnavailablePermission,
}) => PterodactylCreationCatalog(
  templates: templates,
  users: const <PterodactylUser>[],
  nodes: nodes,
  nests: const <PterodactylNest>[
    PterodactylNest(
      id: 10,
      uuid: '00000000-0000-0000-0000-000000000010',
      name: 'Minecraft',
      author: 'support@example.test',
    ),
  ],
  eggs: eggs,
  freeAllocationsByNode: freeAllocationsByNode,
  eggInventoryUnavailablePermission: eggInventoryUnavailablePermission,
);

PterodactylApplicationServer _template({
  Map<String, String> environment = const <String, String>{},
  PterodactylServerLimits limits = const PterodactylServerLimits(
    memoryMiB: 4096,
    swapMiB: 0,
    diskMiB: 0,
    ioWeight: 500,
    cpuPercent: 0,
    threads: null,
    oomDisabled: false,
  ),
  PterodactylFeatureLimits featureLimits = const PterodactylFeatureLimits(
    databases: 0,
    allocations: 0,
    backups: 0,
  ),
  String startup = 'java -jar server.jar',
}) => PterodactylApplicationServer(
  id: 1,
  uuid: '00000000-0000-0000-0000-000000000001',
  identifier: 'template',
  name: 'Template',
  description: '',
  status: null,
  ownerId: 1,
  nodeId: 1,
  allocationId: 1,
  nestId: 10,
  eggId: 20,
  limits: limits,
  featureLimits: featureLimits,
  image: 'ghcr.io/pterodactyl/yolks:java_21',
  startup: startup,
  skipScripts: false,
  environment: environment,
);

PterodactylEgg _egg({
  List<PterodactylEggVariable> variables = const <PterodactylEggVariable>[],
}) => PterodactylEgg(
  id: 20,
  uuid: '00000000-0000-0000-0000-000000000020',
  name: 'Paper',
  nestId: 10,
  author: 'support@example.test',
  startup: 'java -jar {{SERVER_JARFILE}}',
  dockerImages: const <String, String>{
    'Java 21': 'ghcr.io/pterodactyl/yolks:java_21',
  },
  variables: variables,
);

PterodactylUser _user(int id, String username) => PterodactylUser(
  id: id,
  uuid: '00000000-0000-0000-0000-${id.toString().padLeft(12, '0')}',
  username: username,
  email: '$username@example.test',
  firstName: username,
  lastName: 'User',
  isRootAdmin: false,
);

PterodactylNode _node(int id, String name, {bool maintenance = false}) =>
    PterodactylNode(
      id: id,
      uuid: '00000000-0000-0000-0000-${id.toString().padLeft(12, '0')}',
      name: name,
      fqdn: 'node$id.example.test',
      scheme: 'https',
      public: true,
      behindProxy: false,
      maintenanceMode: maintenance,
      memoryMiB: 16384,
      diskMiB: 100000,
      allocatedMemoryMiB: 0,
      allocatedDiskMiB: 0,
      daemonPort: 8080,
      sftpPort: 2022,
    );

PterodactylAllocation _allocation(int id) => PterodactylAllocation(
  id: id,
  ip: '127.0.0.1',
  port: 25564 + id,
  isAssigned: false,
);
