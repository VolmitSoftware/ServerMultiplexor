import 'dart:convert';
import 'dart:io';

import '../../services/app_context.dart';
import '../../services/monitor/metric_sample.dart';
import '../../services/pterodactyl/pterodactyl_console_protocol.dart';
import '../../services/pterodactyl/pterodactyl_console_session.dart';
import '../../services/pterodactyl/pterodactyl_console_terminal.dart';
import '../../services/pterodactyl/pterodactyl_credential.dart';
import '../../services/pterodactyl/pterodactyl_create_push.dart';
import '../../services/pterodactyl/pterodactyl_history_service.dart';
import '../../services/pterodactyl/pterodactyl_models.dart';
import '../../services/pterodactyl/pterodactyl_profile.dart';
import '../../services/pterodactyl/pterodactyl_service.dart';
import '../../services/pterodactyl/pterodactyl_smb_models.dart';
import '../../services/pterodactyl/pterodactyl_transfer_models.dart';
import '../../utils/user_prompt.dart';

Future<int> handleRemote(List<String> args) async {
  final String subcommand = args.isEmpty ? 'list' : args.first;
  final List<String> rest = args.skip(1).toList(growable: false);
  final _RemoteArguments parsed = _RemoteArguments(rest);
  try {
    switch (subcommand) {
      case 'connect':
        return _connect(parsed);
      case 'account':
      case 'accounts':
        return _account(parsed);
      case 'profiles':
        return _listAccounts();
      case 'verify':
      case 'doctor':
        final PterodactylVerification result = await pterodactylService.verify(
          _profileId(parsed),
        );
        _printVerification(result);
        return 0;
      case 'list':
        final List<PterodactylClientServer> servers = await pterodactylService
            .listServers(_profileId(parsed));
        final Map<String, List<String>> resolved = await _resolveAliases(
          servers,
        );
        for (final PterodactylClientServer server in servers) {
          final String advertised = _advertisedEndpoints(server, resolved);
          final String bind = _bindEndpoints(server);
          stdout.writeln(
            '${_safe(server.identifier)}\t${_safe(server.name)}\t$advertised\t$bind',
          );
        }
        return 0;
      case 'nodes':
        final List<PterodactylNode> nodes = await pterodactylService.listNodes(
          _profileId(parsed),
        );
        for (final PterodactylNode node in nodes) {
          stdout.writeln(
            '${_safe(node.name)}\t${_safe(node.fqdn)}\t'
            'memory ${node.allocatedMemoryMiB}/${node.memoryMiB} MiB\t'
            'disk ${node.allocatedDiskMiB}/${node.diskMiB} MiB\t'
            'daemon ${node.daemonPort}\tsftp ${node.sftpPort}',
          );
        }
        return 0;
      case 'catalog':
        return _printCreationCatalog(_profileId(parsed));
      case 'stats':
        if (parsed.flag('all')) {
          return _printFleetStats(_profileId(parsed));
        }
        final String server = _server(parsed);
        final PterodactylResourceUsage usage = await pterodactylService
            .resources(_profileId(parsed), server);
        stdout.writeln('state:       ${_safe(usage.currentState)}');
        stdout.writeln('cpu:         ${usage.cpuAbsolute.toStringAsFixed(2)}%');
        stdout.writeln('memory:      ${usage.memoryBytes} bytes');
        stdout.writeln('disk:        ${usage.diskBytes} bytes');
        stdout.writeln('network rx:  ${usage.networkRxBytes} bytes');
        stdout.writeln('network tx:  ${usage.networkTxBytes} bytes');
        stdout.writeln('uptime:      ${usage.uptime.inSeconds}s');
        return 0;
      case 'permissions':
        final PterodactylClientServerAccess access = await pterodactylService
            .serverAccess(_profileId(parsed), _server(parsed));
        stdout.writeln('server:      ${_safe(access.server.name)}');
        stdout.writeln('owner:       ${access.isOwner}');
        final List<String> permissions = access.permissions.toList()..sort();
        stdout.writeln(
          'permissions: ${access.isOwner ? '*' : permissions.join(', ')}',
        );
        return 0;
      case 'activity':
        final int page = _integerInRange(parsed, 'page', minimum: 1) ?? 1;
        final int perPage =
            _integerInRange(parsed, 'per-page', minimum: 1, maximum: 100) ?? 25;
        final PterodactylPage<PterodactylActivity> activity =
            await pterodactylService.activity(
              _profileId(parsed),
              _server(parsed),
              page: page,
              perPage: perPage,
            );
        for (final PterodactylActivity item in activity.items) {
          stdout.writeln(
            '${item.timestamp.toIso8601String()}\t${_safe(item.event)}\t'
            '${_safe(item.description)}\t${_safe(jsonEncode(item.properties))}',
          );
        }
        stdout.writeln(
          'page ${activity.pagination.currentPage}/'
          '${activity.pagination.totalPages}\t${activity.pagination.total} total',
        );
        return 0;
      case 'history':
        return _printHistory(parsed);
      case 'drive':
      case 'files':
      case 'smb':
        return _drive(parsed, legacyNamespace: subcommand != 'drive');
      case 'pull':
        return _pullRemote(parsed);
      case 'push':
        return _pushRemote(parsed);
      case 'settings':
        return _printSettings(_profileId(parsed), _server(parsed));
      case 'rename':
        final String? name =
            parsed.option('name') ??
            (parsed.positionals.length > 1
                ? parsed.positionals.skip(1).join(' ')
                : null);
        if (name == null || name.trim().isEmpty) {
          stderr.writeln(
            'Usage: remote rename <server> <name> [--description <text>]',
          );
          return 2;
        }
        await pterodactylService.rename(
          profileId: _profileId(parsed),
          server: _server(parsed),
          name: name,
          description: parsed.option('description'),
        );
        stdout.writeln('[OK] Server renamed');
        return 0;
      case 'reinstall':
        final String reinstallTarget = _server(parsed);
        if (!_confirmed(parsed, reinstallTarget)) {
          stderr.writeln(
            'Reinstall replaces server files. Repeat with '
            '--confirm ${_safe(reinstallTarget)}.',
          );
          return 2;
        }
        await pterodactylService.reinstall(_profileId(parsed), reinstallTarget);
        stdout.writeln('[OK] Server reinstall requested');
        return 0;
      case 'delete':
        final String deleteTarget = _server(parsed);
        if (!_confirmed(parsed, deleteTarget)) {
          stderr.writeln(
            'Deletion is permanent. Repeat with '
            '--confirm ${_safe(deleteTarget)}.',
          );
          return 2;
        }
        await pterodactylService.delete(
          _profileId(parsed),
          deleteTarget,
          force: parsed.flag('force'),
        );
        stdout.writeln('[OK] Server deleted');
        return 0;
      case 'bulk':
        return _bulk(parsed);
      case 'variable':
        return _updateVariable(parsed);
      case 'image':
        return _updateImage(parsed);
      case 'limits':
        return _updateLimits(parsed);
      case 'startup':
        return _updateStartup(parsed);
      case 'start':
      case 'stop':
      case 'restart':
      case 'kill':
        final PterodactylPowerSignal signal = PterodactylPowerSignal.values
            .byName(subcommand);
        await pterodactylService.power(
          _profileId(parsed),
          _server(parsed),
          signal,
        );
        stdout.writeln('[OK] ${signal.name} signal sent');
        return 0;
      case 'command':
        final String command =
            parsed.option('command') ??
            parsed.positionals.skip(1).join(' ').trim();
        if (command.isEmpty) {
          stderr.writeln('Usage: remote command <server> <command>');
          return 2;
        }
        await pterodactylService.command(
          _profileId(parsed),
          _server(parsed),
          command,
        );
        stdout.writeln('[OK] Command sent');
        return 0;
      case 'console':
        if (!Ui.hasTerminal) {
          stderr.writeln(
            '[ERROR] The live remote console requires an interactive terminal.',
          );
          return 2;
        }
        final String identifier = _server(parsed);
        final PterodactylConsoleConnection connection = await pterodactylService
            .openConsole(_profileId(parsed), identifier);
        stdout.writeln(
          'Attaching to $identifier. Press Esc, Ctrl-C, or enter :exit to detach.',
        );
        await PterodactylConsoleTerminal(connection: connection).run();
        return 0;
      case 'create':
        final String? name =
            parsed.option('name') ?? parsed.positionals.firstOrNull;
        final String? template = parsed.option('template');
        final String? egg = parsed.option('egg');
        if (name == null ||
            name.trim().isEmpty ||
            (template == null) == (egg == null)) {
          stderr.writeln(
            'Usage: remote create <name> '
            '(--template <server> | --egg <id|name>) '
            '[--owner <id|username|email>] [--node <id|name>] '
            '[--image <label|value>] [--env <KEY=VALUE,...>] '
            '[--memory <MiB>] [--swap <MiB>] [--disk <MiB>] '
            '[--io <10-1000>] [--cpu <percent>] [--databases <count>] '
            '[--allocations <count>] [--backups <count>] [--start]',
          );
          return 2;
        }
        _validateCreationOptionValues(parsed);
        if (parsed.has('concurrency')) {
          throw ArgumentError('--concurrency applies only to create-many.');
        }
        final PterodactylApplicationServer created = await _createRemoteServer(
          parsed: parsed,
          profileId: _profileId(parsed),
          name: name,
          template: template,
          egg: egg,
          startOnCompletion: parsed.flag('start'),
        );
        stdout.writeln(
          '[OK] Created ${_safe(created.name)} (${_safe(created.identifier)})',
        );
        return 0;
      case 'create-many':
        return _createMany(parsed);
      default:
        stderr.writeln(
          'Usage: remote <account|connect|profiles|verify|list|nodes|catalog|stats|history|drive|pull|push|permissions|activity|settings|start|stop|restart|kill|bulk|console|command|create|create-many|rename|reinstall|delete|variable|image|limits|startup>',
        );
        return 2;
    }
  } catch (error) {
    stderr.writeln('[ERROR] $error');
    return 1;
  }
}

const String _remotePullUsage =
    'Usage: remote pull <server> --as <local> [--profile <id>]';
const String _remotePushUsage =
    'Usage: remote push <local> [--to <server>] [--mirror] [--link] '
    '[--start|--no-restart] [--confirm <token>] [--profile <id>]\n'
    '       remote push <local> --new <name> '
    '(--template <server> | --egg <id|name>) [creation options] [--link] '
    '[--start] [--confirm <token>] [--profile <id>]';

Future<int> _pullRemote(_RemoteArguments parsed) async {
  final String? server = parsed.positionals.length == 1
      ? parsed.positionals.single.trim()
      : null;
  final String? localInstanceName = parsed.option('as')?.trim();
  if (server == null ||
      server.isEmpty ||
      localInstanceName == null ||
      localInstanceName.isEmpty ||
      parsed.flag('as') ||
      parsed.flag('profile') ||
      parsed.hasAny(_pullUnsupportedOptions)) {
    stderr.writeln(_remotePullUsage);
    return 2;
  }
  try {
    final String profileId = _profileId(parsed);
    await _prepareDirectTransferFiles(profileId, serverIdentifier: server);
    final PterodactylTransferPlan plan = await pterodactylTransferService
        .planPull(
          profileId: profileId,
          serverIdentifier: server,
          localInstanceName: localInstanceName,
        );
    _printTransferPlan(plan);
    final PterodactylTransferResult result = await pterodactylTransferService
        .pull(
          profileId: plan.profileId,
          serverIdentifier: plan.serverIdentifier,
          localInstanceName: plan.localInstanceName,
          expectedPlanToken: plan.confirmationToken,
        );
    stdout.writeln(
      '[OK] Pulled ${result.plan.changes.length} file change(s) into '
      '${_safe(result.plan.localInstanceName)}, stopped and linked to '
      '${_safe(result.plan.profileId)}/${_safe(result.plan.serverIdentifier)}.',
    );
    return 0;
  } on ArgumentError catch (error) {
    stderr.writeln('[ERROR] $error');
    stderr.writeln(_remotePullUsage);
    return 2;
  }
}

Future<int> _pushRemote(_RemoteArguments parsed) async {
  final String? localInstanceName = parsed.positionals.length == 1
      ? parsed.positionals.single.trim()
      : null;
  if (localInstanceName == null || localInstanceName.isEmpty) {
    stderr.writeln(_remotePushUsage);
    return 2;
  }
  if (parsed.has('new')) {
    return _pushRemoteToNew(parsed, localInstanceName);
  }
  return _pushRemoteToExisting(parsed, localInstanceName);
}

Future<int> _pushRemoteToExisting(
  _RemoteArguments parsed,
  String localInstanceName,
) async {
  final String? serverIdentifier = parsed.option('to')?.trim();
  if (parsed.flag('to') ||
      parsed.flag('confirm') ||
      parsed.flag('profile') ||
      (serverIdentifier != null && serverIdentifier.isEmpty) ||
      parsed.has('as') ||
      parsed.hasAny(_pushNewOnlyOptions) ||
      (parsed.flag('start') && parsed.flag('no-restart'))) {
    stderr.writeln(_remotePushUsage);
    return 2;
  }
  try {
    final String? requestedProfileId = parsed.option('profile');
    late final String driveProfileId;
    late final String driveServerIdentifier;
    if (serverIdentifier != null) {
      driveProfileId = requestedProfileId ?? _profileId(parsed);
      driveServerIdentifier = serverIdentifier;
    } else {
      final PterodactylRemoteLink? link = await pterodactylTransferService
          .linkForLocalInstance(localInstanceName);
      if (link == null) {
        throw StateError(
          'Local $localInstanceName is not linked. Choose a Remote target '
          'with --to.',
        );
      }
      if (requestedProfileId != null &&
          link.profileId.toLowerCase() !=
              requestedProfileId.trim().toLowerCase()) {
        throw ArgumentError(
          '--profile $requestedProfileId does not match the saved Remote '
          'link (${link.profileId}).',
        );
      }
      driveProfileId = link.profileId;
      driveServerIdentifier = link.serverIdentifier;
    }
    await _prepareDirectTransferFiles(
      driveProfileId,
      serverIdentifier: driveServerIdentifier,
    );
    final PterodactylTransferMode mode = parsed.flag('mirror')
        ? PterodactylTransferMode.mirror
        : PterodactylTransferMode.update;
    final PterodactylTransferPlan plan = await pterodactylTransferService
        .planPush(
          localInstanceName: localInstanceName,
          profileId: serverIdentifier == null ? null : driveProfileId,
          serverIdentifier: serverIdentifier,
          mode: mode,
        );
    _printTransferPlan(plan);
    if (parsed.option('confirm') != plan.confirmationToken) {
      final String warning = mode == PterodactylTransferMode.mirror
          ? 'Mirror deletes remote-only files.'
          : 'Push can replace changed remote files.';
      stderr.writeln(
        '$warning Repeat with --confirm '
        '${_safe(plan.confirmationToken)}.',
      );
      return 2;
    }
    final PterodactylTransferResult result = await pterodactylTransferService
        .push(
          localInstanceName: localInstanceName,
          profileId: serverIdentifier == null ? null : plan.profileId,
          serverIdentifier: serverIdentifier == null
              ? null
              : plan.serverIdentifier,
          mode: mode,
          expectedPlanToken: plan.confirmationToken,
          relink: parsed.flag('link'),
          restorePreviousRunningState: !parsed.flag('no-restart'),
          startIfStopped: parsed.flag('start'),
        );
    _printTransferResult(result);
    final List<String> missingPostconditions =
        pterodactylMissingTransferPostconditions(
          requirePersistedLink: parsed.flag('link'),
          linkPersisted: result.linkPersisted,
          requireRunning: parsed.flag('start'),
          remoteRestarted: result.remoteRestarted,
        );
    if (missingPostconditions.isNotEmpty) {
      stderr.writeln(
        '[ERROR] Remote files were committed, but these requested outcomes '
        'were not verified: ${missingPostconditions.join(', ')}. Rerun the '
        'same Push workflow to preview and confirm an idempotent repair.',
      );
      return 1;
    }
    return 0;
  } on ArgumentError catch (error) {
    stderr.writeln('[ERROR] $error');
    stderr.writeln(_remotePushUsage);
    return 2;
  }
}

List<String> pterodactylMissingTransferPostconditions({
  required bool requirePersistedLink,
  required bool linkPersisted,
  required bool requireRunning,
  required bool remoteRestarted,
}) => <String>[
  if (requirePersistedLink && !linkPersisted) 'durable Remote link',
  if (requireRunning && !remoteRestarted) 'requested running state',
];

Future<int> _pushRemoteToNew(
  _RemoteArguments parsed,
  String localInstanceName,
) async {
  final String? newServerName = parsed.option('new')?.trim();
  final String? template = parsed.option('template')?.trim();
  final String? egg = parsed.option('egg')?.trim();
  if (parsed.flag('new') ||
      parsed.flag('confirm') ||
      parsed.flag('profile') ||
      parsed.flag('template') ||
      parsed.flag('egg') ||
      newServerName == null ||
      newServerName.isEmpty ||
      parsed.has('as') ||
      parsed.has('to') ||
      parsed.flag('mirror') ||
      parsed.flag('no-restart') ||
      parsed.has('concurrency') ||
      (template == null) == (egg == null) ||
      template?.isEmpty == true ||
      egg?.isEmpty == true) {
    stderr.writeln(_remotePushUsage);
    return 2;
  }
  try {
    _validateCreationOptionValues(parsed);
    final String profileId = _profileId(parsed);
    final PterodactylRemoteLink? existingLink = await pterodactylTransferService
        .linkForLocalInstance(localInstanceName);
    final bool persistNewLink = existingLink == null || parsed.flag('link');
    final PterodactylTransferPlan transferPlan =
        await pterodactylTransferService.planNewPush(
          localInstanceName: localInstanceName,
          profileId: profileId,
          proposedServerName: newServerName,
        );
    final PterodactylCreatePushPlan unresolvedCreation =
        await _resolveRemoteCreation(
          parsed: parsed,
          profileId: profileId,
          name: newServerName,
          template: template,
          egg: egg,
        );
    final String intentId = pterodactylCreatePushIntentId(
      transferPlan: transferPlan,
      canonicalCreation: unresolvedCreation.canonicalJson,
      startAfterTransfer: parsed.flag('start'),
      persistNewLink: persistNewLink,
    );
    final PterodactylCreatePushPlan creation = unresolvedCreation
        .withExternalId(intentId);
    final String confirmationToken = pterodactylCreatePushConfirmationToken(
      transferConfirmationToken: transferPlan.confirmationToken,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: parsed.flag('start'),
      persistNewLink: persistNewLink,
    );
    _printTransferPlan(transferPlan);
    _printResolvedRemoteCreation(
      creation,
      startAfterTransfer: parsed.flag('start'),
      existingLink: existingLink,
      persistNewLink: persistNewLink,
    );
    if (parsed.option('confirm') != confirmationToken) {
      stderr.writeln(
        'Creating a server changes the Panel. Repeat with --confirm '
        '${_safe(confirmationToken)}.',
      );
      return 2;
    }
    final PterodactylCreatePushIntentCoordinator intentCoordinator =
        PterodactylCreatePushIntentCoordinator(
          metadataDirectoryPath: appContext.metadataDir,
          service: pterodactylService,
        );
    final PterodactylCreatePushIntentClaim intent = await intentCoordinator
        .claim(
          id: intentId,
          confirmationToken: confirmationToken,
          transferPlan: transferPlan,
          creation: creation,
          startAfterTransfer: parsed.flag('start'),
          persistNewLink: persistNewLink,
        );
    try {
      stdout.writeln('intent:       ${_safe(intent.path)}');
      final PterodactylApplicationServer? completedServer = intent.server;
      if (intent.alreadyCompleted) {
        stdout.writeln(
          '[OK] Create & Push already completed for '
          '${_safe(completedServer!.name)} '
          '(${_safe(completedServer.identifier)}).',
        );
        return 0;
      }
      if (intent.needsPostconditionRepair) {
        final PterodactylApplicationServer repairTarget =
            intent.server ??
            (throw StateError(
              'A repairable Create & Push intent has no Remote server.',
            ));
        stdout.writeln(
          '[OK] Repairing completion for ${_safe(repairTarget.name)} '
          '(${_safe(repairTarget.identifier)}); no files will be uploaded.',
        );
        try {
          final PterodactylTransferResult repaired =
              await pterodactylTransferService.repairNewPushPostconditions(
                plan: transferPlan,
                createdServerIdentifier: repairTarget.identifier,
                relink: persistNewLink,
                startAfter: parsed.flag('start'),
              );
          _printTransferResult(repaired);
          intent.complete(
            created: repairTarget,
            result: repaired,
            filesTransferred: false,
          );
          return 0;
        } catch (error, stackTrace) {
          intent.record(
            state: 'postconditions-failed',
            created: repairTarget,
            failure: '$error',
          );
          stderr.writeln(
            '[RECOVERY] No files were uploaded. Repeat this exact confirmed '
            'command to continue repairing the saved link or requested '
            'running state using ${_safe(intent.path)}.',
          );
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
      await _prepareDirectTransferFiles(profileId, accountOnly: true);
      PterodactylApplicationServer? created = intent.server;
      if (created == null) {
        try {
          intent.record(state: 'creating');
          created = await creation.create(
            service: pterodactylService,
            profileId: profileId,
          );
          intent.record(state: 'created', created: created);
          stdout.writeln(
            '[OK] Created ${_safe(created.name)} '
            '(${_safe(created.identifier)}), stopped for file transfer.',
          );
        } catch (error, stackTrace) {
          intent.record(state: 'create-unknown', failure: '$error');
          stderr.writeln(
            '[RECOVERY] Server creation may have committed. Repeat this exact '
            'confirmed command to discover Panel external ID '
            '${_safe(intentId)} and resume using ${_safe(intent.path)}.',
          );
          Error.throwWithStackTrace(error, stackTrace);
        }
      } else {
        stdout.writeln(
          '[OK] Resuming Create & Push with ${_safe(created.name)} '
          '(${_safe(created.identifier)}) discovered by external ID.',
        );
      }
      late final PterodactylTransferResult result;
      try {
        intent.record(state: 'waiting-for-install', created: created);
        await pterodactylTransferService.waitForNewTargetReady(
          profileId: profileId,
          serverIdentifier: created.identifier,
        );
        await _prepareDirectTransferFiles(
          profileId,
          serverIdentifier: created.identifier,
        );
        intent.record(state: 'transferring', created: created);
        result = await pterodactylTransferService.pushNew(
          plan: transferPlan,
          createdServerIdentifier: created.identifier,
          relink: persistNewLink,
          startAfter: parsed.flag('start'),
        );
      } catch (error, stackTrace) {
        intent.record(
          state: 'transfer-failed',
          created: created,
          failure: '$error',
        );
        final String consumer =
            (appContext.requestedConsumer ?? consumerService.readActive())
                .shortName;
        stderr.writeln(
          '[RECOVERY] New Remote ${_safe(created.name)} '
          '(${_safe(created.identifier)}) was left stopped. Repeat this exact '
          'confirmed Create & Push command for automatic resume, or preview '
          'a one-time retry with `./start.sh --consumer $consumer remote push '
          '${_safe(localInstanceName)} --to ${_safe(created.identifier)} '
          '--profile ${_safe(profileId)}'
          '${persistNewLink ? ' --link' : ''}'
          '${parsed.flag('start') ? ' --start' : ''}`.',
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
      _printTransferResult(result);
      intent.complete(created: created, result: result);
      return 0;
    } finally {
      intent.close();
    }
  } on ArgumentError catch (error) {
    stderr.writeln('[ERROR] $error');
    stderr.writeln(_remotePushUsage);
    return 2;
  }
}

Future<void> _prepareDirectTransferFiles(
  String profileId, {
  String? serverIdentifier,
  bool accountOnly = false,
}) async {
  final String normalizedProfileId = PterodactylProfile.normalizeId(profileId);
  final PterodactylTransferDrivePreparation preparation =
      pterodactylTransferDrivePreparation(
        settings: pterodactylSmbService.settings,
        profileId: normalizedProfileId,
        accountOnly: accountOnly,
      );
  if (preparation.needsAccount) {
    if (!Ui.hasTerminal) {
      final String trustRecovery = serverIdentifier == null
          ? 'then retry this command'
          : 'then run `remote drive trust ${serverIdentifier.trim()} '
                '--profile $normalizedProfileId` and retry';
      throw StateError(
        'Multiplexor Drive has no enabled account for $normalizedProfileId. '
        'Run `remote drive install --profile $normalizedProfileId --no-open`, '
        '$trustRecovery.',
      );
    }
    await pterodactylSmbService.installDrive(
      profileIds: <String>[normalizedProfileId],
    );
    stdout.writeln('[OK] Added Drive account $normalizedProfileId');
  }
  if (!preparation.inspectTarget) return;
  final String target = serverIdentifier?.trim() ?? '';
  if (target.isEmpty) {
    throw ArgumentError('A Remote server is required for file preflight.');
  }

  if (!await pterodactylSmbService.isServerHostKeyTrusted(
    profileId: normalizedProfileId,
    serverIdentifier: target,
  )) {
    if (!Ui.hasTerminal) {
      throw StateError(
        'The selected Remote SFTP host is not trusted. Run `remote drive '
        'install --profile $normalizedProfileId --no-open`, then `remote '
        'drive trust $target --profile $normalizedProfileId`, verify that '
        'fingerprint, and retry.',
      );
    }
    final List<PterodactylSshHostKeyCandidate> candidates =
        await pterodactylSmbService.scanServerHostKeys(
          profileId: normalizedProfileId,
          serverIdentifier: target,
        );
    if (!await _confirmDriveHostKeys(candidates)) {
      throw StateError(
        'The selected Remote host trust was not approved; transfer cancelled.',
      );
    }
  }

  try {
    await pterodactylSmbService.verifyDirectServerFilesReady(
      profileId: normalizedProfileId,
      serverIdentifier: target,
    );
  } catch (error) {
    throw StateError(
      'Direct Remote file access is not ready for $normalizedProfileId/'
      '$target. Run `remote drive install --profile $normalizedProfileId '
      '--no-open`, then `remote drive trust $target --profile '
      '$normalizedProfileId`, and retry: $error',
    );
  }
}

/// Determines whether transfer setup may stop after account provisioning.
///
/// Create-and-push uses [accountOnly] before the first server exists, because
/// a zero-server Panel has no SFTP target whose host key can be trusted or
/// mounted yet.
PterodactylTransferDrivePreparation pterodactylTransferDrivePreparation({
  required PterodactylSmbSettings? settings,
  required String profileId,
  required bool accountOnly,
}) {
  final String normalizedProfileId = PterodactylProfile.normalizeId(profileId);
  final PterodactylSftpAccount? account =
      settings?.accounts[normalizedProfileId];
  return PterodactylTransferDrivePreparation(
    needsAccount: account == null || !account.enabled,
    inspectTarget: !accountOnly,
  );
}

final class PterodactylTransferDrivePreparation {
  const PterodactylTransferDrivePreparation({
    required this.needsAccount,
    required this.inspectTarget,
  });

  final bool needsAccount;
  final bool inspectTarget;
}

void _printTransferPlan(PterodactylTransferPlan plan) {
  for (final String line in pterodactylTransferPlanLines(plan)) {
    stdout.writeln(line);
  }
  for (final String warning in plan.warnings) {
    stdout.writeln('[WARN] ${_safe(warning)}');
  }
}

/// Stable, colorless transfer preflight emitted before any push mutation.
List<String> pterodactylTransferPlanLines(
  PterodactylTransferPlan plan,
) => <String>[
  'direction:    ${plan.direction.name}',
  'mode:         ${plan.mode.name}',
  'local:        ${_safe(plan.localInstanceName)}',
  'remote:       ${_safe(plan.profileId)}/'
      '${_safe(plan.targetExists ? plan.serverIdentifier : plan.remoteServerName)}',
  'add:          ${plan.addCount}',
  'update:       ${plan.updateCount}',
  'delete:       ${plan.deleteCount}',
  'transfer:     ${plan.transferBytes} bytes',
  'was running:  ${plan.targetWasRunning}',
];

void _printTransferResult(PterodactylTransferResult result) {
  final PterodactylTransferPlan plan = result.plan;
  stdout.writeln(
    '[OK] Pushed ${plan.changes.length} file change(s) to '
    '${_safe(plan.profileId)}/${_safe(plan.serverIdentifier)}.',
  );
  if (result.backupPath case final String backupPath) {
    stdout.writeln('backup:       ${_safe(backupPath)}');
  }
  if (result.recoveryManifestPath case final String recoveryPath) {
    stdout.writeln('recovery:     ${_safe(recoveryPath)}');
  }
  for (final String warning in result.warnings) {
    stdout.writeln('[WARN] ${_safe(warning)}');
  }
  stdout.writeln(
    result.linkPersisted
        ? 'link:         saved ${_safe(result.link.profileId)}/'
              '${_safe(result.link.serverIdentifier)}'
        : 'link:         one-time target; saved link unchanged',
  );
  final bool running =
      result.remoteRestarted || (plan.isNoop && plan.targetWasRunning);
  stdout.writeln('running:      ${running ? 'running' : 'stopped'}');
}

const Set<String> _pushNewOnlyOptions = <String>{
  'new',
  'template',
  'egg',
  'owner',
  'node',
  'image',
  'env',
  'memory',
  'swap',
  'disk',
  'io',
  'cpu',
  'databases',
  'allocations',
  'backups',
  'concurrency',
};

const Set<String> _pullUnsupportedOptions = <String>{
  'to',
  'mirror',
  'link',
  'start',
  'no-restart',
  'confirm',
  ..._pushNewOnlyOptions,
};

Future<PterodactylCreatePushPlan> _resolveRemoteCreation({
  required _RemoteArguments parsed,
  required String profileId,
  required String name,
  required String? template,
  required String? egg,
}) async {
  if (template != null) {
    _rejectEggOnlyCreationOptions(parsed);
    final PterodactylCreationCatalog catalog = await pterodactylService
        .creationCatalog(profileId, allowPartialEggInventory: true);
    final PterodactylApplicationServer source = _resolveCreationTemplate(
      catalog,
      template,
    );
    final PterodactylUser owner = _resolveCreationOwner(
      catalog,
      parsed.option('owner'),
    );
    final PterodactylNode node = _resolveCreationNode(
      catalog,
      '${source.nodeId}',
      requiredAllocations: 1,
    );
    final PterodactylTemplateCreatePlan plan =
        PterodactylTemplateCreatePlan.fromTemplate(
          template: source,
          name: name,
          ownerId: owner.id,
          memoryMiB: _integerInRange(parsed, 'memory', minimum: 0),
          diskMiB: _integerInRange(parsed, 'disk', minimum: 0),
          cpuPercent: _integerInRange(parsed, 'cpu', minimum: 0),
          startOnCompletion: false,
        );
    return PterodactylCreatePushPlan.template(
      plan: plan,
      ownerName: owner.username,
      nodeName: node.name,
    );
  }

  final PterodactylCreationCatalog catalog = await pterodactylService
      .creationCatalog(profileId);
  final PterodactylEgg source = _resolveCreationEgg(catalog, egg!);
  final PterodactylEggCreatePlan plan = _eggCreatePlan(
    parsed,
    catalog,
    eggSelector: egg,
    requiredAllocations: 1,
    startOnCompletion: false,
  );
  final PterodactylUser owner = catalog.users.firstWhere(
    (PterodactylUser user) => user.id == plan.ownerId,
  );
  final PterodactylNode node = catalog.nodes.firstWhere(
    (PterodactylNode item) => item.id == plan.nodeId,
  );
  return PterodactylCreatePushPlan.egg(
    name: name,
    source: source,
    plan: plan,
    ownerName: owner.username,
    nodeName: node.name,
  );
}

void _printResolvedRemoteCreation(
  PterodactylCreatePushPlan creation, {
  required bool startAfterTransfer,
  required PterodactylRemoteLink? existingLink,
  required bool persistNewLink,
}) {
  stdout.writeln(
    'source:       ${_safe(creation.sourceKind)} '
    '${_safe(creation.sourceName)} (${_safe(creation.sourceIdentity)})',
  );
  stdout.writeln(
    'owner:        ${creation.ownerId} (${_safe(creation.ownerName)})',
  );
  stdout.writeln(
    'node:         ${creation.nodeId} (${_safe(creation.nodeName)})',
  );
  stdout.writeln('egg:          ${creation.sourceEggId}');
  stdout.writeln('external id:  ${_safe(creation.externalId ?? '-')}');
  stdout.writeln('image:        ${_safe(creation.dockerImage)}');
  stdout.writeln('startup:      ${_safe(creation.startup)}');
  stdout.writeln(
    'environment:  ${pterodactylResolvedEnvironmentSummary(creation.environment)}',
  );
  stdout.writeln(
    'resources:    memory=${creation.memoryMiB} MiB, '
    'swap=${creation.swapMiB} MiB, disk=${creation.diskMiB} MiB, '
    'io=${creation.ioWeight}, cpu=${creation.cpuPercent}%, '
    'threads=${_safe(creation.threads ?? '-')}',
  );
  stdout.writeln(
    'features:     databases=${creation.databaseLimit ?? 'unlimited'}, '
    'allocations=${creation.allocationLimit ?? 'unlimited'}, '
    'backups=${creation.backupLimit ?? 'unlimited'}',
  );
  stdout.writeln(
    'create flags: oom_disabled=${creation.oomDisabled}, '
    'skip_scripts=${creation.skipScripts}, start_on_completion=false',
  );
  stdout.writeln(
    'final state:  ${startAfterTransfer ? 'running' : 'stopped'} '
    '(creation itself is always stopped for transfer)',
  );
  if (existingLink == null) {
    stdout.writeln('link action:  save the new server (Local is unlinked)');
  } else if (persistNewLink) {
    stdout.writeln(
      '[WARN] link action: replace saved '
      '${_safe(existingLink.profileId)}/'
      '${_safe(existingLink.serverIdentifier)} with the new server',
    );
  } else {
    stdout.writeln(
      'link action:  preserve saved ${_safe(existingLink.profileId)}/'
      '${_safe(existingLink.serverIdentifier)}; new server is one-time',
    );
  }
}

/// Lists every effective environment key without exposing its value.
String pterodactylResolvedEnvironmentSummary(Map<String, String> environment) {
  if (environment.isEmpty) return '<none>';
  final List<String> keys = environment.keys.toList(growable: false)..sort();
  return keys.map((String key) => '${_safe(key)}=<redacted>').join(', ');
}

Future<PterodactylApplicationServer> _createRemoteServer({
  required _RemoteArguments parsed,
  required String profileId,
  required String name,
  required String? template,
  required String? egg,
  required bool startOnCompletion,
}) async {
  if (template != null) {
    _rejectEggOnlyCreationOptions(parsed);
    final String? ownerSelector = parsed.option('owner');
    final int? ownerId = ownerSelector == null
        ? null
        : _resolveCreationOwner(
            await pterodactylService.creationCatalog(
              profileId,
              allowPartialEggInventory: true,
            ),
            ownerSelector,
          ).id;
    return pterodactylService.createFromTemplate(
      profileId: profileId,
      template: template,
      name: name,
      memoryMiB: _integerInRange(parsed, 'memory', minimum: 0),
      diskMiB: _integerInRange(parsed, 'disk', minimum: 0),
      cpuPercent: _integerInRange(parsed, 'cpu', minimum: 0),
      ownerId: ownerId,
      startOnCompletion: startOnCompletion,
    );
  }
  final PterodactylCreationCatalog catalog = await pterodactylService
      .creationCatalog(profileId);
  return pterodactylService.createFromEgg(
    profileId: profileId,
    name: name,
    plan: _eggCreatePlan(
      parsed,
      catalog,
      eggSelector: egg!,
      requiredAllocations: 1,
      startOnCompletion: startOnCompletion,
    ),
  );
}

Future<int> _bulk(_RemoteArguments parsed) async {
  const String usage =
      'Usage: remote bulk <start|stop|restart|kill|reinstall|delete> '
      '[servers...] [--all] [--state <running|offline>] '
      '[--concurrency <1-8>]';
  final String? rawAction = parsed.positionals.firstOrNull;
  final PterodactylBulkAction? action = rawAction == null
      ? null
      : PterodactylBulkAction.values
            .where(
              (PterodactylBulkAction item) =>
                  item.name == rawAction &&
                  item != PterodactylBulkAction.create,
            )
            .firstOrNull;
  if (action == null) {
    stderr.writeln(usage);
    return 2;
  }
  final PterodactylBulkServerState? state = switch (parsed
      .option('state')
      ?.trim()
      .toLowerCase()) {
    null => null,
    'running' => PterodactylBulkServerState.running,
    'offline' => PterodactylBulkServerState.offline,
    _ => throw ArgumentError('--state must be running or offline.'),
  };
  final String profileId = _profileId(parsed);
  final int concurrency =
      _integerInRange(parsed, 'concurrency', minimum: 1, maximum: 8) ?? 4;
  final List<PterodactylClientServer> targets = await pterodactylService
      .resolveBulkServers(
        profileId: profileId,
        selectors: parsed.positionals.skip(1),
        all: parsed.flag('all'),
        state: state,
      );
  final List<String> identifiers = targets
      .map((PterodactylClientServer server) => server.identifier)
      .toList(growable: false);
  if (action == PterodactylBulkAction.reinstall ||
      action == PterodactylBulkAction.delete) {
    final String token = PterodactylService.bulkConfirmationToken(
      action: action,
      profileId: profileId,
      serverIdentifiers: identifiers,
    );
    if (parsed.option('confirm') != token) {
      stderr.writeln(
        '${action == PterodactylBulkAction.delete ? 'Deletion is permanent' : 'Reinstall replaces server files'}. '
        'Repeat with --confirm ${_safe(token)}.',
      );
      return 2;
    }
  }

  final PterodactylBulkResult result = switch (action) {
    PterodactylBulkAction.start ||
    PterodactylBulkAction.stop ||
    PterodactylBulkAction.restart ||
    PterodactylBulkAction.kill => await pterodactylService.bulkPower(
      profileId: profileId,
      serverIdentifiers: identifiers,
      signal: PterodactylPowerSignal.values.byName(action.name),
      concurrency: concurrency,
    ),
    PterodactylBulkAction.reinstall => await pterodactylService.bulkReinstall(
      profileId: profileId,
      serverIdentifiers: identifiers,
      concurrency: concurrency,
    ),
    PterodactylBulkAction.delete => await pterodactylService.bulkDelete(
      profileId: profileId,
      serverIdentifiers: identifiers,
      force: parsed.flag('force'),
      concurrency: concurrency,
    ),
    PterodactylBulkAction.create => throw StateError('Unreachable action.'),
  };
  return _printBulkResult(result);
}

Future<int> _createMany(_RemoteArguments parsed) async {
  const String usage =
      'Usage: remote create-many '
      '(--template <server> | --egg <id|name>) '
      '(--names <a,b,c> | --prefix <name> --count <n>) '
      '[--owner <id|username|email>] [--node <id|name>] '
      '[--image <label|value>] [--env <KEY=VALUE,...>] '
      '[--memory <MiB>] [--swap <MiB>] [--disk <MiB>] '
      '[--io <10-1000>] [--cpu <percent>] [--databases <count>] '
      '[--allocations <count>] [--backups <count>] [--start] '
      '[--concurrency <1-8>]';
  final String? template = parsed.option('template');
  final String? egg = parsed.option('egg');
  final String? rawNames = parsed.option('names');
  final String? prefix = parsed.option('prefix');
  final int? count = _integerInRange(parsed, 'count', minimum: 1, maximum: 100);
  if ((template == null) == (egg == null) ||
      (rawNames == null) == (prefix == null) ||
      (prefix != null && count == null) ||
      (rawNames != null && count != null)) {
    stderr.writeln(usage);
    return 2;
  }
  _validateCreationOptionValues(parsed);
  final List<String> names = rawNames != null
      ? rawNames.split(',').map((String name) => name.trim()).toList()
      : List<String>.generate(
          count!,
          (int index) => '$prefix${index + 1}',
          growable: false,
        );
  final String profileId = _profileId(parsed);
  final int concurrency =
      _integerInRange(parsed, 'concurrency', minimum: 1, maximum: 8) ?? 1;
  final PterodactylBulkResult result;
  if (template != null) {
    _rejectEggOnlyCreationOptions(parsed);
    final String? ownerSelector = parsed.option('owner');
    final int? ownerId = ownerSelector == null
        ? null
        : _resolveCreationOwner(
            await pterodactylService.creationCatalog(
              profileId,
              allowPartialEggInventory: true,
            ),
            ownerSelector,
          ).id;
    result = await pterodactylService.bulkCreateFromTemplate(
      profileId: profileId,
      template: template,
      names: names,
      memoryMiB: _integerInRange(parsed, 'memory', minimum: 0),
      diskMiB: _integerInRange(parsed, 'disk', minimum: 0),
      cpuPercent: _integerInRange(parsed, 'cpu', minimum: 0),
      ownerId: ownerId,
      startOnCompletion: parsed.flag('start'),
      concurrency: concurrency,
    );
  } else {
    final PterodactylCreationCatalog catalog = await pterodactylService
        .creationCatalog(profileId);
    result = await pterodactylService.bulkCreateFromEgg(
      profileId: profileId,
      names: names,
      plan: _eggCreatePlan(
        parsed,
        catalog,
        eggSelector: egg!,
        requiredAllocations: names.length,
      ),
      concurrency: concurrency,
    );
  }
  return _printBulkResult(result);
}

Future<int> _printCreationCatalog(String profileId) async {
  final PterodactylCreationCatalog catalog = await pterodactylService
      .creationCatalog(profileId);
  for (final String line in pterodactylCreationCatalogLines(catalog)) {
    stdout.writeln(line);
  }
  return 0;
}

/// Stable, tab-separated creation inventory used by the headless CLI.
///
/// Egg children are emitted as separate rows so scripts and operators can
/// construct exact `--image` and `--env` arguments without first attempting
/// a server creation.
List<String> pterodactylCreationCatalogLines(
  PterodactylCreationCatalog catalog,
) {
  final List<String> lines = <String>[];
  for (final PterodactylUser user in catalog.users) {
    lines.add(
      'owner\t${user.id}\t${_safe(user.username)}\t${_safe(user.email)}'
      '${catalog.recommendedOwnerId == user.id ? '\trecommended' : ''}',
    );
  }
  for (final PterodactylNode node in catalog.nodes) {
    lines.add(
      'node\t${node.id}\t${_safe(node.name)}\t'
      '${catalog.freeAllocationCount(node.id)} free\t'
      '${node.maintenanceMode ? 'maintenance' : 'ready'}',
    );
  }
  final Map<int, String> nestNames = <int, String>{
    for (final PterodactylNest nest in catalog.nests) nest.id: nest.name,
  };
  for (final PterodactylEgg egg in catalog.eggs) {
    final bool hasStartup = egg.startup?.trim().isNotEmpty == true;
    final bool hasImage = egg.dockerImages.values.any(
      (String image) => image.trim().isNotEmpty,
    );
    final String readiness = !hasStartup
        ? 'no startup'
        : !hasImage
        ? 'no image'
        : 'ready';
    lines.add(
      'egg\t${egg.id}\t${_safe(nestNames[egg.nestId] ?? 'nest ${egg.nestId}')}\t'
      '${_safe(egg.name)}\t${egg.dockerImages.length} images\t'
      '${egg.variables.length} variables\t$readiness',
    );
    for (final MapEntry<String, String> image in egg.dockerImages.entries) {
      lines.add('image\t${egg.id}\t${_safe(image.key)}\t${_safe(image.value)}');
    }
    for (final PterodactylEggVariable variable in egg.variables) {
      final bool blankDefault = variable.defaultValue.trim().isEmpty;
      final String requirement = variable.isRequired
          ? (blankDefault ? 'required-blank' : 'required-default')
          : (blankDefault ? 'optional-blank' : 'optional-default');
      lines.add(
        'variable\t${egg.id}\t${_safe(variable.environmentVariable)}\t'
        '$requirement\t${variable.userEditable ? 'editable' : 'fixed'}\t'
        'default=${blankDefault ? '<blank>' : _safe(variable.defaultValue)}\t'
        'rules=${_safe(variable.rules)}',
      );
    }
  }
  for (final PterodactylApplicationServer template in catalog.templates) {
    lines.add(
      'template\t${template.id}\t${_safe(template.identifier)}\t'
      '${_safe(template.name)}',
    );
  }
  return List<String>.unmodifiable(lines);
}

const Set<String> _creationValueOptions = <String>{
  'owner',
  'node',
  'image',
  'env',
  'memory',
  'swap',
  'disk',
  'io',
  'cpu',
  'databases',
  'allocations',
  'backups',
  'concurrency',
};

const Set<String> _eggOnlyCreationOptions = <String>{
  'node',
  'image',
  'env',
  'swap',
  'io',
  'databases',
  'allocations',
  'backups',
};

void _validateCreationOptionValues(_RemoteArguments parsed) {
  final List<String> missing = _creationValueOptions
      .where(parsed.flag)
      .toList(growable: false);
  if (missing.isNotEmpty) {
    throw ArgumentError('--${missing.first} requires a value.');
  }
}

void _rejectEggOnlyCreationOptions(_RemoteArguments parsed) {
  final List<String> unsupported = _eggOnlyCreationOptions
      .where(parsed.has)
      .toList(growable: false);
  if (unsupported.isNotEmpty) {
    throw ArgumentError(
      '--${unsupported.first} applies only to creation with --egg.',
    );
  }
}

PterodactylEggCreatePlan _eggCreatePlan(
  _RemoteArguments parsed,
  PterodactylCreationCatalog catalog, {
  required String eggSelector,
  required int requiredAllocations,
  bool? startOnCompletion,
}) {
  final PterodactylUser owner = _resolveCreationOwner(
    catalog,
    parsed.option('owner'),
  );
  final PterodactylNode node = _resolveCreationNode(
    catalog,
    parsed.option('node'),
    requiredAllocations: requiredAllocations,
  );
  final PterodactylEgg egg = _resolveCreationEgg(catalog, eggSelector);
  final String startup = egg.startup?.trim() ?? '';
  if (startup.isEmpty) {
    throw StateError('The selected egg has no usable startup command.');
  }
  final String image = _resolveCreationImage(egg, parsed.option('image'));
  final Map<String, String> environment = _parseCreationEnvironment(
    parsed.option('env'),
    egg,
  );
  return PterodactylEggCreatePlan(
    ownerId: owner.id,
    nodeId: node.id,
    eggId: egg.id,
    eggUuid: egg.uuid,
    dockerImage: image,
    startup: startup,
    environment: environment,
    memoryMiB: _integerInRange(parsed, 'memory', minimum: 0) ?? 4096,
    swapMiB: _integerInRange(parsed, 'swap', minimum: -1) ?? 0,
    diskMiB: _integerInRange(parsed, 'disk', minimum: 0) ?? 0,
    ioWeight: _integerInRange(parsed, 'io', minimum: 10, maximum: 1000) ?? 500,
    cpuPercent: _integerInRange(parsed, 'cpu', minimum: 0) ?? 0,
    databaseLimit: _integerInRange(parsed, 'databases', minimum: 0) ?? 0,
    allocationLimit: _integerInRange(parsed, 'allocations', minimum: 0) ?? 0,
    backupLimit: _integerInRange(parsed, 'backups', minimum: 0) ?? 0,
    startOnCompletion: startOnCompletion ?? parsed.flag('start'),
  );
}

PterodactylUser _resolveCreationOwner(
  PterodactylCreationCatalog catalog,
  String? selector,
) {
  if (catalog.users.isEmpty) {
    throw StateError('The Panel has no user who can own the new server.');
  }
  if (selector == null) {
    final int? recommended = catalog.recommendedOwnerId;
    if (recommended != null) {
      return catalog.users.firstWhere(
        (PterodactylUser user) => user.id == recommended,
      );
    }
    if (catalog.users.length == 1) return catalog.users.single;
    throw StateError(
      'More than one Panel user exists; choose one with --owner <id|username|email>.',
    );
  }
  final String normalized = selector.trim().toLowerCase();
  final List<PterodactylUser> matches = catalog.users
      .where(
        (PterodactylUser user) =>
            '${user.id}' == normalized ||
            user.username.toLowerCase() == normalized ||
            user.email.toLowerCase() == normalized,
      )
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      matches.isEmpty
          ? 'No Panel owner matches: $selector'
          : 'Panel owner selector is ambiguous: $selector',
    );
  }
  return matches.single;
}

PterodactylNode _resolveCreationNode(
  PterodactylCreationCatalog catalog,
  String? selector, {
  required int requiredAllocations,
}) {
  final List<PterodactylNode> candidates = catalog.nodes
      .where(
        (PterodactylNode node) =>
            !node.maintenanceMode &&
            catalog.freeAllocationCount(node.id) >= requiredAllocations,
      )
      .toList(growable: false);
  if (selector == null) {
    if (candidates.length == 1) return candidates.single;
    if (candidates.isEmpty) {
      throw StateError(
        'No ready Panel node has $requiredAllocations free allocation(s).',
      );
    }
    throw StateError(
      'More than one node can host this request; choose one with --node <id|name>.',
    );
  }
  final String normalized = selector.trim().toLowerCase();
  final List<PterodactylNode> matches = catalog.nodes
      .where(
        (PterodactylNode node) =>
            '${node.id}' == normalized || node.name.toLowerCase() == normalized,
      )
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      matches.isEmpty
          ? 'No Panel node matches: $selector'
          : 'Panel node selector is ambiguous: $selector',
    );
  }
  final PterodactylNode node = matches.single;
  if (node.maintenanceMode) {
    throw StateError('The selected node is in maintenance mode.');
  }
  final int free = catalog.freeAllocationCount(node.id);
  if (free < requiredAllocations) {
    throw StateError(
      'The selected node has $free free allocation(s); '
      '$requiredAllocations are required.',
    );
  }
  return node;
}

PterodactylEgg _resolveCreationEgg(
  PterodactylCreationCatalog catalog,
  String selector,
) {
  final String normalized = selector.trim().toLowerCase();
  final List<PterodactylEgg> matches = catalog.eggs
      .where(
        (PterodactylEgg egg) =>
            '${egg.id}' == normalized || egg.name.toLowerCase() == normalized,
      )
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      matches.isEmpty
          ? 'No Panel egg matches: $selector. Run remote catalog.'
          : 'Egg name is ambiguous; use its numeric ID from remote catalog.',
    );
  }
  return matches.single;
}

PterodactylApplicationServer _resolveCreationTemplate(
  PterodactylCreationCatalog catalog,
  String selector,
) {
  final String normalized = selector.trim().toLowerCase();
  final List<PterodactylApplicationServer> matches = catalog.templates
      .where(
        (PterodactylApplicationServer server) =>
            server.identifier.toLowerCase() == normalized ||
            server.uuid.toLowerCase() == normalized ||
            server.name.toLowerCase() == normalized,
      )
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      matches.isEmpty
          ? 'No remote server template matches: $selector'
          : 'Remote server template name is ambiguous: $selector',
    );
  }
  return matches.single;
}

String _resolveCreationImage(PterodactylEgg egg, String? selector) {
  if (egg.dockerImages.isEmpty) {
    throw StateError('The selected egg has no allowed Docker image.');
  }
  if (selector == null) return egg.dockerImages.values.first;
  final String normalized = selector.trim().toLowerCase();
  final List<String> matches = egg.dockerImages.entries
      .where(
        (MapEntry<String, String> entry) =>
            entry.key.toLowerCase() == normalized ||
            entry.value.toLowerCase() == normalized,
      )
      .map((MapEntry<String, String> entry) => entry.value)
      .toSet()
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      matches.isEmpty
          ? 'That Docker image is not allowed by ${egg.name}.'
          : 'Docker image label is ambiguous; use its full image value.',
    );
  }
  return matches.single;
}

Map<String, String> _parseCreationEnvironment(String? raw, PterodactylEgg egg) {
  final Set<String> allowed = egg.variables
      .map((PterodactylEggVariable variable) => variable.environmentVariable)
      .toSet();
  final Map<String, String> result = <String, String>{
    for (final PterodactylEggVariable variable in egg.variables)
      variable.environmentVariable: variable.defaultValue,
  };
  if (raw != null && raw.trim().isNotEmpty) {
    final Set<String> assigned = <String>{};
    for (final String assignment in raw.split(',')) {
      final int separator = assignment.indexOf('=');
      if (separator < 1) {
        throw ArgumentError(
          '--env must contain comma-separated KEY=VALUE pairs.',
        );
      }
      final String key = assignment.substring(0, separator).trim();
      final String value = assignment.substring(separator + 1).trim();
      if (!allowed.contains(key)) {
        throw ArgumentError('The selected egg has no variable named $key.');
      }
      if (!assigned.add(key)) {
        throw ArgumentError('--env assigns $key more than once.');
      }
      result[key] = value;
    }
  }
  final List<String> missing = <String>[
    for (final PterodactylEggVariable variable in egg.variables)
      if (variable.isRequired &&
          (result[variable.environmentVariable]?.trim().isEmpty ?? true))
        variable.environmentVariable,
  ];
  if (missing.isNotEmpty) {
    throw ArgumentError(
      'Required egg variables need values: ${missing.join(', ')}.',
    );
  }
  return result;
}

int _printBulkResult(PterodactylBulkResult result) {
  for (final PterodactylBulkItemResult item in result.items) {
    final String identifier = item.identifier ?? '-';
    if (item.succeeded) {
      stdout.writeln('[OK]\t${_safe(identifier)}\t${_safe(item.name)}');
    } else {
      stdout.writeln(
        '[ERROR]\t${_safe(identifier)}\t${_safe(item.name)}\t'
        '${_safe(item.error ?? 'Unknown failure')}',
      );
    }
  }
  stdout.writeln(
    'summary: ${result.succeededCount}/${result.totalCount} succeeded; '
    '${result.failedCount} failed',
  );
  return result.isSuccess ? 0 : 1;
}

Future<int> _connect(_RemoteArguments parsed) async {
  final String? rawUrl = parsed.option('url');
  if (rawUrl == null || rawUrl.isEmpty) {
    stderr.writeln('Usage: remote connect --url <https://panel> [--id <id>]');
    return 2;
  }
  final String id = parsed.option('id') ?? 'remote';
  final PterodactylProfile candidate = PterodactylProfile(
    id: id,
    name: parsed.option('name') ?? id,
    panelUri: Uri.parse(rawUrl),
  );
  final PterodactylProfile? existing = pterodactylService.profile(id);
  final bool replace = parsed.flag('replace');
  final bool enrollApplication = parsed.flag('application');
  final bool hasClient = await pterodactylService.hasClientCredential(
    candidate,
  );
  final bool hasApplication = await pterodactylService.hasApplicationCredential(
    candidate,
  );
  final bool needsClientEnrollment = replace || !hasClient;
  final bool needsApplicationEnrollment =
      enrollApplication && (replace || !hasApplication);
  final Map<PterodactylCredentialRole, PterodactylCredential> rollback =
      <PterodactylCredentialRole, PterodactylCredential>{};
  if (replace && hasClient) {
    final PterodactylCredential? previous = await pterodactylService
        .credentialForRollback(candidate, PterodactylCredentialRole.client);
    if (previous != null) {
      rollback[PterodactylCredentialRole.client] = previous;
    }
  }
  if (replace && enrollApplication && hasApplication) {
    final PterodactylCredential? previous = await pterodactylService
        .credentialForRollback(
          candidate,
          PterodactylCredentialRole.application,
        );
    if (previous != null) {
      rollback[PterodactylCredentialRole.application] = previous;
    }
  }

  if ((needsClientEnrollment || needsApplicationEnrollment) &&
      !Ui.hasTerminal) {
    stderr.writeln(
      '[ERROR] API key enrollment requires an interactive terminal. The '
      'API key is never accepted as a command argument.',
    );
    return 2;
  }

  final List<PterodactylCredentialRole> newlyEnrolled =
      <PterodactylCredentialRole>[];
  bool profileCommitted = false;
  try {
    if (needsClientEnrollment) {
      stdout.writeln(
        'Create a Client API key at ${candidate.origin}/account/api.',
      );
      await _saveMaskedCredential(candidate, PterodactylCredentialRole.client);
      if (!hasClient) {
        newlyEnrolled.add(PterodactylCredentialRole.client);
      }
    }
    if (needsApplicationEnrollment) {
      stdout.writeln(
        'Create an Application API key at ${candidate.origin}/admin/api/new.',
      );
      stdout.writeln(
        'Grant Servers read/write plus Users, Nodes, Allocations, Nests, and '
        'Eggs read access.',
      );
      await _saveMaskedCredential(
        candidate,
        PterodactylCredentialRole.application,
      );
      if (!hasApplication) {
        newlyEnrolled.add(PterodactylCredentialRole.application);
      }
    }

    if (enrollApplication) {
      await pterodactylService.verifyCredential(
        candidate,
        PterodactylCredentialRole.application,
      );
    }
    final PterodactylVerification result = await pterodactylService
        .verifyProfile(candidate);
    pterodactylService.saveProfile(candidate);
    pterodactylService.selectProfile(candidate.id);
    profileCommitted = true;
    if (existing != null && existing.origin != candidate.origin) {
      for (final PterodactylCredentialRole role
          in PterodactylCredentialRole.values) {
        try {
          await pterodactylService.removeCredential(existing, role);
        } catch (_) {
          // The new profile and credential are already committed. Treat an
          // old-origin Keychain cleanup failure as non-fatal and identify the
          // exact non-secret account the operator may remove later.
          stderr.writeln(
            '[WARN] Connected, but the obsolete ${role.key} credential for '
            '${existing.origin} could not be removed from Keychain.',
          );
        }
      }
    }
    _printVerification(result);
  } catch (_) {
    if (profileCommitted) rethrow;
    for (final MapEntry<PterodactylCredentialRole, PterodactylCredential> entry
        in rollback.entries) {
      try {
        await pterodactylService.restoreCredential(
          candidate,
          entry.key,
          entry.value,
        );
      } catch (_) {
        // Preserve the original verification failure. The restore failure is
        // intentionally non-secret and the old value remains in session for
        // this process, but persistent Keychain repair may still be required.
      }
    }
    for (final PterodactylCredentialRole role in newlyEnrolled) {
      try {
        await pterodactylService.removeCredential(candidate, role);
      } catch (_) {
        // Preserve the original enrollment or verification failure.
      }
    }
    rethrow;
  }
  return 0;
}

Future<int> _account(_RemoteArguments parsed) async {
  final String action = parsed.positionals.firstOrNull ?? 'list';
  switch (action) {
    case 'list':
      return _listAccounts();
    case 'add':
      return _connect(parsed);
    case 'use':
      final String id = _accountId(parsed, position: 1);
      pterodactylService.selectProfile(id);
      stdout.writeln('[OK] Active remote account: $id');
      return 0;
    case 'rename':
      final String id = _accountId(parsed, position: 1);
      final PterodactylProfile? current = pterodactylService.profile(id);
      if (current == null) throw StateError('Unknown Pterodactyl profile: $id');
      final String name =
          parsed.option('name') ??
          (parsed.positionals.length > 2
              ? parsed.positionals.skip(2).join(' ')
              : '');
      if (name.trim().isEmpty) {
        stderr.writeln('Usage: remote account rename <id> <name>');
        return 2;
      }
      pterodactylService.saveProfile(
        PterodactylProfile(
          id: current.id,
          name: name,
          panelUri: current.panelUri,
          trustedCertificatePath: current.trustedCertificatePath,
        ),
      );
      stdout.writeln('[OK] Remote account renamed');
      return 0;
    case 'key':
      if (!Ui.hasTerminal) {
        stderr.writeln(
          '[ERROR] API key enrollment requires an interactive terminal.',
        );
        return 2;
      }
      final String id = parsed.positionals.length > 1
          ? parsed.positionals[1]
          : _profileId(parsed);
      final PterodactylProfile? profile = pterodactylService.profile(id);
      if (profile == null) {
        throw StateError('Unknown Pterodactyl profile: $id');
      }
      await _replaceAccountCredential(profile, parsed.option('role'));
      stdout.writeln('[OK] API key saved and verified for ${profile.id}');
      return 0;
    case 'remove':
      final String id = _accountId(parsed, position: 1);
      if (parsed.option('confirm') != id) {
        stderr.writeln(
          'Removing an account also removes its stored credentials. Repeat '
          'with --confirm $id.',
        );
        return 2;
      }
      await pterodactylService.removeProfile(id);
      stdout.writeln('[OK] Remote account removed');
      return 0;
    default:
      stderr.writeln('Usage: remote account <list|add|use|rename|key|remove>');
      return 2;
  }
}

Future<int> _listAccounts() async {
  final PterodactylProfile? active = pterodactylService.activeProfile();
  for (final PterodactylProfile profile in pterodactylService.listProfiles()) {
    final bool client = await pterodactylService.hasClientCredential(profile);
    final bool application = await pterodactylService.hasApplicationCredential(
      profile,
    );
    stdout.writeln(
      '${profile.id}\t${active?.id == profile.id ? 'active' : '-'}\t'
      '${profile.name}\t${profile.origin}\t'
      'client=${client ? 'saved' : 'missing'}\t'
      'application=${application ? 'saved' : 'optional'}',
    );
  }
  return 0;
}

Future<void> _replaceAccountCredential(
  PterodactylProfile profile,
  String? requestedRole,
) async {
  final String value = await Ui.secret('Pterodactyl API key');
  final PterodactylCredential credential = PterodactylCredential(value);
  final PterodactylCredentialRole? inferred = inferPterodactylCredentialRole(
    value,
  );
  final PterodactylCredentialRole role = requestedRole == null
      ? inferred ??
            PterodactylCredentialRole.values.byName(
              await Ui.pick(
                'API key type',
                PterodactylCredentialRole.values
                    .map((PterodactylCredentialRole item) => item.name)
                    .toList(growable: false),
              ),
            )
      : PterodactylCredentialRole.values.byName(
          requestedRole.trim().toLowerCase(),
        );
  if (inferred != null && inferred != role) {
    throw ArgumentError(
      'The ${inferred.name} API-key prefix does not match --role ${role.name}.',
    );
  }
  final PterodactylCredential? previous = await pterodactylService
      .credentialForRollback(profile, role);
  try {
    await pterodactylService.saveCredential(profile, role, credential);
    await pterodactylService.verifyCredential(profile, role);
    await pterodactylService.verifyProfile(profile);
  } catch (_) {
    if (previous != null) {
      await pterodactylService.restoreCredential(profile, role, previous);
    } else {
      await pterodactylService.removeCredential(profile, role);
    }
    rethrow;
  }
}

Future<void> _saveMaskedCredential(
  PterodactylProfile profile,
  PterodactylCredentialRole role,
) async {
  final String value = await Ui.secret('${role.name} API key');
  final PterodactylCredentialRole? inferred = inferPterodactylCredentialRole(
    value,
  );
  if (inferred != null && inferred != role) {
    throw FormatException(
      'Expected a ${role.name} API key, received a ${inferred.name} key.',
    );
  }
  await pterodactylService.saveCredential(
    profile,
    role,
    PterodactylCredential(value),
  );
}

String _accountId(_RemoteArguments parsed, {required int position}) {
  if (parsed.positionals.length <= position ||
      parsed.positionals[position].trim().isEmpty) {
    throw ArgumentError('A remote account ID is required.');
  }
  return PterodactylProfile.normalizeId(parsed.positionals[position]);
}

Future<int> _printHistory(_RemoteArguments parsed) async {
  final String profileId = _profileId(parsed);
  final String server = _server(parsed);
  final Duration window = parsePterodactylHistoryWindow(
    parsed.option('since') ?? '24h',
  );
  final int limit =
      _integerInRange(parsed, 'limit', minimum: 1, maximum: 10000) ?? 500;
  final List<MetricSample> stored = await pterodactylHistoryService.read(
    profileId,
    server,
    window: window,
  );
  final List<MetricSample> samples = stored.length <= limit
      ? stored
      : stored.sublist(stored.length - limit);
  if (parsed.flag('json')) {
    stdout.writeln(
      '[${samples.map((MetricSample item) => item.toJsonLine()).join(',')}]',
    );
    return 0;
  }
  for (final MetricSample sample in samples) {
    stdout.writeln(
      '${sample.ts.toUtc().toIso8601String()}\t${sample.state.name}\t'
      '${sample.cpuPercent ?? '-'}\t${sample.rssBytes ?? '-'}\t'
      '${sample.diskBytes ?? '-'}\t${sample.networkRxBytes ?? '-'}\t'
      '${sample.networkTxBytes ?? '-'}\t'
      '${sample.networkRxBytesPerSecond ?? '-'}\t'
      '${sample.networkTxBytesPerSecond ?? '-'}\t'
      '${sample.networkRxPacketsPerSecond ?? '-'}\t'
      '${sample.networkTxPacketsPerSecond ?? '-'}\t'
      '${sample.uptimeSeconds ?? '-'}',
    );
  }
  return 0;
}

Future<int> _drive(
  _RemoteArguments parsed, {
  required bool legacyNamespace,
}) async {
  final String requestedAction = parsed.positionals.firstOrNull ?? 'status';
  final String action = requestedAction == 'configure'
      ? 'install'
      : requestedAction;
  if (legacyNamespace) {
    stderr.writeln(
      '[WARN] remote files/smb is now remote drive; using the local Drive '
      'workflow.',
    );
  }
  switch (action) {
    case 'install':
    case 'add':
      final bool installing = action == 'install';
      if (installing && !Ui.hasTerminal) {
        stderr.writeln(
          '[ERROR] Drive installation requires an interactive terminal so '
          'SSH host fingerprints can be confirmed.',
        );
        return 2;
      }
      final bool allProfiles =
          parsed.flag('all-profiles') ||
          (installing && parsed.option('profile') == null);
      if (parsed.flag('all-profiles') && parsed.option('profile') != null) {
        throw ArgumentError('--profile and --all-profiles cannot be combined.');
      }
      if (allProfiles && parsed.option('username') != null) {
        throw ArgumentError(
          '--username can only be used while adding one profile.',
        );
      }
      final List<PterodactylProfile> profiles = allProfiles
          ? pterodactylService.listProfiles()
          : <PterodactylProfile>[
              pterodactylService.profile(_profileId(parsed)) ??
                  (throw StateError('The selected remote profile is missing.')),
            ];
      if (profiles.isEmpty) {
        throw StateError('No remote accounts are configured.');
      }
      final String? username = parsed.option('username');
      final Map<String, String> usernameOverrides = username == null
          ? const <String, String>{}
          : <String, String>{profiles.single.id: username};
      final Iterable<String> profileIds = profiles.map(
        (PterodactylProfile profile) => profile.id,
      );
      final PterodactylSmbSettings drive = installing
          ? await pterodactylSmbService.installDrive(
              profileIds: profileIds,
              panelUsernames: usernameOverrides,
              mountRoot: parsed.option('mount-root'),
              knownHostsFile: parsed.option('known-hosts'),
              provisionSshKeys: !parsed.flag('no-key'),
            )
          : await pterodactylSmbService.configureAccounts(
              profileIds: profileIds,
              panelUsernames: usernameOverrides,
              mountRoot: parsed.option('mount-root'),
              knownHostsFile: parsed.option('known-hosts'),
              provisionSshKeys: !parsed.flag('no-key'),
            );
      for (final PterodactylProfile profile in profiles) {
        stdout.writeln('[OK] Added Drive account ${profile.id}');
      }
      stdout.writeln('drive:       ${_safe(drive.mountRoot)}');
      if (!installing) {
        stdout.writeln('next:        remote drive trust');
        return 0;
      }
      if (!await _trustDriveHostKeys()) {
        stdout.writeln('[CANCELLED] Multiplexor Drive was not started.');
        return 0;
      }
      final PterodactylSmbStatus installed = await pterodactylSmbService
          .startDrive();
      _printDriveStatus(installed);
      if (!parsed.flag('no-open')) {
        final String opened = await pterodactylSmbService.openDrive();
        stdout.writeln('[OK] Opened ${_safe(opened)}');
      }
      return 0;
    case 'remove':
      final String profileId = parsed.positionals.length > 1
          ? PterodactylProfile.normalizeId(parsed.positionals[1])
          : _profileId(parsed);
      if (parsed.option('confirm') != profileId) {
        stderr.writeln(
          'Removing a Drive account also removes its saved password. Repeat '
          'with --confirm $profileId.',
        );
        return 2;
      }
      await pterodactylSmbService.removeAccount(profileId);
      stdout.writeln('[OK] Removed Drive account $profileId');
      return 0;
    case 'password':
      if (!Ui.hasTerminal) {
        stderr.writeln(
          '[ERROR] SFTP password enrollment requires an interactive terminal.',
        );
        return 2;
      }
      final String profileId = parsed.positionals.length > 1
          ? PterodactylProfile.normalizeId(parsed.positionals[1])
          : _profileId(parsed);
      await pterodactylSmbService.enrollPassword(profileId);
      stdout.writeln('[OK] Saved SFTP password for $profileId');
      return 0;
    case 'trust':
      if (!Ui.hasTerminal) {
        stderr.writeln(
          '[ERROR] SSH host-key trust requires an interactive terminal.',
        );
        return 2;
      }
      if (parsed.positionals.length > 2) {
        stderr.writeln('Usage: remote drive trust [server] [--profile <id>]');
        return 2;
      }
      final String? server = parsed.positionals.elementAtOrNull(1)?.trim();
      if (server == null || server.isEmpty) {
        await _trustDriveHostKeys();
      } else {
        final String profileId = _profileId(parsed);
        final List<PterodactylSshHostKeyCandidate> candidates =
            await pterodactylSmbService.scanServerHostKeys(
              profileId: profileId,
              serverIdentifier: server,
            );
        await _confirmDriveHostKeys(candidates);
      }
      return 0;
    case 'doctor':
      final PterodactylSmbDoctorReport report = await pterodactylSmbService
          .doctor();
      for (final PterodactylSmbCheck check in report.checks) {
        final String label = switch (check.level) {
          PterodactylSmbCheckLevel.ready => 'OK',
          PterodactylSmbCheckLevel.warning => 'WARN',
          PterodactylSmbCheckLevel.error => 'ERROR',
        };
        stdout.writeln(
          '[$label] ${_safe(check.name)}: ${_safe(check.message)}',
        );
      }
      return report.isReady ? 0 : 1;
    case 'authorize':
      stdout.writeln(
        '[OK] Multiplexor Drive is local and requires no administrator '
        'authorization.',
      );
      return 0;
    case 'start':
      final PterodactylSmbStatus started = await pterodactylSmbService
          .startDrive();
      _printDriveStatus(started);
      return started.running ? 0 : 1;
    case 'stop':
      final PterodactylSmbStatus stopped = await pterodactylSmbService
          .stopDrive();
      _printDriveStatus(stopped);
      return 0;
    case 'status':
      _printDriveStatus(await pterodactylSmbService.status());
      return 0;
    case 'open':
      final String? selector = parsed.positionals.length > 1
          ? parsed.positionals.skip(1).join(' ').trim()
          : null;
      final String opened;
      if (selector == null || selector.isEmpty) {
        opened = await pterodactylSmbService.openDrive();
      } else {
        final String profileId = _profileId(parsed);
        final PterodactylClientServerAccess access = await pterodactylService
            .serverAccess(profileId, selector);
        opened = await pterodactylSmbService.openServerFolder(
          profileId: profileId,
          serverIdentifier: access.server.identifier,
        );
      }
      stdout.writeln('[OK] Opened ${_safe(opened)}');
      return 0;
    default:
      stderr.writeln(
        'Usage: remote drive <install|add|remove|password|trust|doctor|start|status|open|stop>',
      );
      return 2;
  }
}

Future<bool> _trustDriveHostKeys() async {
  if (!Ui.hasTerminal) {
    stderr.writeln(
      '[ERROR] SSH host-key trust requires an interactive terminal.',
    );
    return false;
  }
  final List<PterodactylSshHostKeyCandidate> candidates =
      await pterodactylSmbService.scanHostKeys();
  return _confirmDriveHostKeys(candidates);
}

Future<bool> _confirmDriveHostKeys(
  List<PterodactylSshHostKeyCandidate> candidates,
) async {
  if (candidates.isEmpty) {
    stdout.writeln('[OK] SSH host keys are already trusted.');
    return true;
  }
  stdout.writeln('Verify these Wings SFTP fingerprints out-of-band:');
  for (final PterodactylSshHostKeyCandidate candidate in candidates) {
    stdout.writeln(
      '${_safe(candidate.endpoint)}\t${_safe(candidate.keyType)}\t'
      '${_safe(candidate.fingerprint)}',
    );
  }
  final bool confirmed = await Ui.confirm(
    'Trust exactly these ${candidates.length} SSH host keys?',
    defaultValue: false,
  );
  if (!confirmed) {
    stdout.writeln('[CANCELLED] No SSH host keys were changed.');
    return false;
  }
  await pterodactylSmbService.trustHostKeys(candidates);
  stdout.writeln('[OK] SSH host keys trusted');
  return true;
}

void _printDriveStatus(PterodactylSmbStatus status) {
  stdout.writeln('configured:  ${status.configured}');
  stdout.writeln(
    'drive:       ${_safe(status.mountRoot ?? pterodactylSmbService.drivePath)}',
  );
  stdout.writeln('running:     ${status.running}');
  stdout.writeln(
    'mounts:      ${status.runningMounts}/${status.mounts.length} running',
  );
  for (final PterodactylSmbMountStatus mount in status.mounts) {
    stdout.writeln(
      '${mount.running ? 'up' : 'down'}\t${_safe(mount.profileId)}\t'
      '${_safe(mount.serverIdentifier)}\t${_safe(mount.serverName)}\t'
      '${_safe(mount.mountPath)}',
    );
  }
}

Future<int> _printSettings(String profileId, String server) async {
  final PterodactylClientServerAccess access = await pterodactylService
      .serverAccess(profileId, server);
  final PterodactylClientServer current = access.server;
  stdout.writeln('name:        ${_safe(current.name)}');
  stdout.writeln('description: ${_safe(current.description)}');
  stdout.writeln('memory:      ${current.limits.memoryMiB} MiB');
  stdout.writeln('swap:        ${current.limits.swapMiB} MiB');
  stdout.writeln('disk:        ${current.limits.diskMiB} MiB');
  stdout.writeln('io:          ${current.limits.ioWeight}');
  stdout.writeln('cpu:         ${current.limits.cpuPercent}%');
  stdout.writeln('threads:     ${current.limits.threads ?? '-'}');
  stdout.writeln('oom disabled:${current.limits.oomDisabled}');
  stdout.writeln(
    'databases:   ${current.featureLimits.databases ?? 'unlimited'}',
  );
  stdout.writeln(
    'allocations: ${current.featureLimits.allocations ?? 'unlimited'}',
  );
  stdout.writeln(
    'backups:     ${current.featureLimits.backups ?? 'unlimited'}',
  );
  try {
    final PterodactylServerStartup startup = await pterodactylService.startup(
      profileId,
      server,
    );
    stdout.writeln('startup:     ${_safe(startup.rawStartupCommand)}');
    for (final PterodactylStartupVariable variable in startup.variables) {
      stdout.writeln(
        'variable:    ${_safe(variable.environmentVariable)}='
        '${_safe(variable.serverValue ?? '')}\t'
        '${variable.isEditable ? 'editable' : 'read-only'}',
      );
    }
  } on StateError {
    stdout.writeln('startup:     not granted');
  }
  return 0;
}

Future<int> _updateVariable(_RemoteArguments parsed) async {
  final String? key = parsed.option('key');
  final String? value = parsed.option('value');
  if (key == null || key.trim().isEmpty || value == null) {
    stderr.writeln(
      'Usage: remote variable <server> --key <variable> --value <value>',
    );
    return 2;
  }
  final PterodactylStartupVariable updated = await pterodactylService
      .updateStartupVariable(
        profileId: _profileId(parsed),
        server: _server(parsed),
        key: key,
        value: value,
      );
  stdout.writeln(
    '[OK] ${_safe(updated.environmentVariable)}='
    '${_safe(updated.serverValue ?? '')}',
  );
  return 0;
}

Future<int> _updateImage(_RemoteArguments parsed) async {
  final String? image = parsed.option('image');
  if (image == null || image.trim().isEmpty) {
    stderr.writeln('Usage: remote image <server> --image <docker-image>');
    return 2;
  }
  await pterodactylService.updateDockerImage(
    profileId: _profileId(parsed),
    server: _server(parsed),
    dockerImage: image,
  );
  stdout.writeln('[OK] Docker image updated');
  return 0;
}

Future<int> _updateLimits(_RemoteArguments parsed) async {
  final bool hasUpdate =
      <String>{
        'allocation',
        'memory',
        'swap',
        'disk',
        'io',
        'cpu',
        'threads',
        'databases',
        'allocations',
        'backups',
        'add-allocation',
        'remove-allocation',
      }.any(parsed.options.containsKey) ||
      parsed.flag('clear-threads') ||
      parsed.flag('oom-disabled') ||
      parsed.flag('oom-enabled');
  if (!hasUpdate ||
      (parsed.flag('oom-disabled') && parsed.flag('oom-enabled'))) {
    stderr.writeln(
      'Usage: remote limits <server> [--memory <MiB>] [--swap <MiB>] '
      '[--disk <MiB>] [--io <10-1000>] [--cpu <percent>] '
      '[--threads <set>|--clear-threads] '
      '[--databases <count>] [--allocations <count>] [--backups <count>] '
      '[--allocation <id>] [--add-allocation <id,...>] '
      '[--remove-allocation <id,...>] [--oom-disabled|--oom-enabled]',
    );
    return 2;
  }
  await pterodactylService.updateBuildSettings(
    profileId: _profileId(parsed),
    server: _server(parsed),
    allocationId: _nonNegativeInteger(parsed, 'allocation', minimum: 1),
    memoryMiB: _nonNegativeInteger(parsed, 'memory'),
    swapMiB: _nonNegativeInteger(parsed, 'swap', minimum: -1),
    diskMiB: _nonNegativeInteger(parsed, 'disk'),
    ioWeight: _integerInRange(parsed, 'io', minimum: 10, maximum: 1000),
    cpuPercent: _nonNegativeInteger(parsed, 'cpu'),
    threads: parsed.option('threads'),
    clearThreads: parsed.flag('clear-threads'),
    oomDisabled: parsed.flag('oom-disabled')
        ? true
        : parsed.flag('oom-enabled')
        ? false
        : null,
    databaseLimit: _nonNegativeInteger(parsed, 'databases'),
    allocationLimit: _nonNegativeInteger(parsed, 'allocations'),
    backupLimit: _nonNegativeInteger(parsed, 'backups'),
    addAllocationIds: _integerList(parsed, 'add-allocation'),
    removeAllocationIds: _integerList(parsed, 'remove-allocation'),
  );
  stdout.writeln('[OK] Server resource limits updated');
  return 0;
}

Future<int> _updateStartup(_RemoteArguments parsed) async {
  final String? command = parsed.option('command');
  if (command == null || command.trim().isEmpty) {
    stderr.writeln('Usage: remote startup <server> --command <command>');
    return 2;
  }
  await pterodactylService.updateStartupCommand(
    profileId: _profileId(parsed),
    server: _server(parsed),
    startup: command,
  );
  stdout.writeln('[OK] Startup command updated');
  return 0;
}

String _profileId(_RemoteArguments parsed) {
  final String? selected = parsed.option('profile');
  if (selected != null && selected.isNotEmpty) return selected;
  final PterodactylProfile? active = pterodactylService.activeProfile();
  if (active != null) return active.id;
  final List<PterodactylProfile> profiles = pterodactylService.listProfiles();
  if (profiles.isEmpty) {
    throw StateError('No Pterodactyl connection. Run remote connect.');
  }
  return profiles.single.id;
}

String _server(_RemoteArguments parsed) {
  final String? server =
      parsed.option('server') ?? parsed.positionals.firstOrNull;
  if (server == null || server.isEmpty) {
    throw ArgumentError('A remote server identifier is required.');
  }
  return server;
}

int? _nonNegativeInteger(
  _RemoteArguments parsed,
  String name, {
  int minimum = 0,
}) => _integerInRange(parsed, name, minimum: minimum);

int? _integerInRange(
  _RemoteArguments parsed,
  String name, {
  required int minimum,
  int? maximum,
}) {
  final String? raw = parsed.option(name);
  if (raw == null) return null;
  final int? value = int.tryParse(raw);
  if (value == null ||
      value < minimum ||
      (maximum != null && value > maximum)) {
    final String range = maximum == null ? '>=$minimum' : '$minimum-$maximum';
    throw ArgumentError('--$name must be an integer in $range.');
  }
  return value;
}

List<int> _integerList(_RemoteArguments parsed, String name) {
  final String? raw = parsed.option(name);
  if (raw == null || raw.trim().isEmpty) return const <int>[];
  final List<int> result = <int>[];
  for (final String item in raw.split(',')) {
    final int? value = int.tryParse(item.trim());
    if (value == null || value < 1) {
      throw ArgumentError('--$name must contain positive integer IDs.');
    }
    result.add(value);
  }
  return result;
}

bool _confirmed(_RemoteArguments parsed, String server) =>
    parsed.option('confirm') == server;

String _endpoint(String host, int port) =>
    '${_safe(host).contains(':') ? '[${_safe(host)}]' : _safe(host)}:$port';

String _safe(String value) => PterodactylConsoleSanitizer.text(
  value,
).replaceAll(RegExp(r'[\r\n\t]'), ' ');

void _printVerification(PterodactylVerification result) {
  stdout.writeln('[OK] Connected: ${result.profile.origin}');
  stdout.writeln('servers:      ${result.serverCount}');
  stdout.writeln('nodes:        ${result.nodeCount ?? 'not granted'}');
  stdout.writeln(
    'capabilities: ${result.capabilities.map((PterodactylCapability item) => item.name).join(', ')}',
  );
  for (final String warning in result.warnings) {
    stdout.writeln('[WARN] ${_safe(warning)}');
  }
}

Future<int> _printFleetStats(String profileId) async {
  final List<PterodactylFleetSample> fleet = await pterodactylService
      .captureFleet(profileId);
  int sampled = 0;
  double cpu = 0;
  int memory = 0;
  int disk = 0;
  int networkRx = 0;
  int networkTx = 0;
  for (final PterodactylFleetSample sample in fleet) {
    final PterodactylResourceUsage? usage = sample.resources;
    if (usage == null) continue;
    sampled += 1;
    cpu += usage.cpuAbsolute;
    memory += usage.memoryBytes;
    disk += usage.diskBytes;
    networkRx += usage.networkRxBytes;
    networkTx += usage.networkTxBytes;
  }
  stdout.writeln('sampled:     $sampled/${fleet.length}');
  stdout.writeln('cpu total:   ${cpu.toStringAsFixed(2)}%');
  stdout.writeln('memory:      $memory bytes');
  stdout.writeln('disk:        $disk bytes');
  stdout.writeln('network rx:  $networkRx bytes');
  stdout.writeln('network tx:  $networkTx bytes');
  for (final PterodactylFleetSample sample in fleet) {
    final PterodactylResourceUsage? usage = sample.resources;
    stdout.writeln(
      '${_safe(sample.server.identifier)}\t${_safe(sample.server.name)}\t'
      '${_safe(usage?.currentState ?? 'unavailable')}\t'
      '${usage == null ? '-' : '${usage.cpuAbsolute.toStringAsFixed(2)}%'}\t'
      '${usage?.memoryBytes ?? '-'}\t${usage?.diskBytes ?? '-'}',
    );
  }
  return 0;
}

Future<Map<String, List<String>>> _resolveAliases(
  List<PterodactylClientServer> servers,
) async {
  final Set<String> aliases = <String>{
    for (final PterodactylClientServer server in servers)
      for (final PterodactylAllocation allocation in server.allocations)
        if (allocation.alias?.trim() case final String alias)
          if (alias.isNotEmpty) alias,
  };
  final Map<String, List<String>> result = <String, List<String>>{};
  await Future.wait<void>(
    aliases.map((String alias) async {
      final InternetAddress? literal = InternetAddress.tryParse(alias);
      if (literal != null) {
        result[alias] = <String>[literal.address];
        return;
      }
      try {
        final List<InternetAddress> addresses = await InternetAddress.lookup(
          alias,
        ).timeout(const Duration(seconds: 3));
        result[alias] = <String>{
          for (final InternetAddress address in addresses) address.address,
        }.toList(growable: false);
      } on Object {
        result[alias] = const <String>[];
      }
    }),
  );
  return result;
}

String _advertisedEndpoints(
  PterodactylClientServer server,
  Map<String, List<String>> resolved,
) {
  final List<String> endpoints = <String>[];
  for (final PterodactylAllocation allocation in server.allocations) {
    final String? alias = allocation.alias?.trim();
    if (alias == null || alias.isEmpty) continue;
    final String configured = _endpoint(alias, allocation.port);
    final List<String> addresses = resolved[alias] ?? const <String>[];
    final List<String> resolvedEndpoints = <String>{
      for (final String address in addresses)
        if (address != alias) _endpoint(address, allocation.port),
    }.toList(growable: false);
    endpoints.add(
      resolvedEndpoints.isEmpty
          ? configured
          : '$configured -> ${resolvedEndpoints.join('|')}',
    );
  }
  return endpoints.isEmpty ? '-' : endpoints.toSet().join(', ');
}

String _bindEndpoints(PterodactylClientServer server) {
  final Set<String> endpoints = <String>{
    for (final PterodactylAllocation allocation in server.allocations)
      _endpoint(allocation.ip, allocation.port),
  };
  return endpoints.isEmpty ? '-' : endpoints.join(', ');
}

final class _RemoteArguments {
  _RemoteArguments(List<String> values) {
    for (int index = 0; index < values.length; index++) {
      final String value = values[index];
      if (!value.startsWith('--')) {
        positionals.add(value);
        continue;
      }
      final String key = value.substring(2);
      if (_booleanOptions.contains(key)) {
        flags.add(key);
      } else if (index + 1 < values.length &&
          !values[index + 1].startsWith('--')) {
        options[key] = values[++index];
      } else {
        flags.add(key);
      }
    }
  }

  final Map<String, String> options = <String, String>{};
  final Set<String> flags = <String>{};
  final List<String> positionals = <String>[];

  static const Set<String> _booleanOptions = <String>{
    'all',
    'all-profiles',
    'allow-unencrypted',
    'application',
    'clear-threads',
    'force',
    'json',
    'no-key',
    'no-open',
    'oom-disabled',
    'oom-enabled',
    'replace',
    'link',
    'mirror',
    'no-restart',
    'start',
  };

  String? option(String name) => options[name];
  bool flag(String name) => flags.contains(name);
  bool has(String name) => options.containsKey(name) || flags.contains(name);
  bool hasAny(Iterable<String> names) => names.any(has);
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
