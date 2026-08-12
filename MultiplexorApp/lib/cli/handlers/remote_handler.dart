import 'dart:io';

import '../../services/app_context.dart';
import '../../services/pterodactyl/pterodactyl_console_protocol.dart';
import '../../services/pterodactyl/pterodactyl_console_session.dart';
import '../../services/pterodactyl/pterodactyl_console_terminal.dart';
import '../../services/pterodactyl/pterodactyl_credential.dart';
import '../../services/pterodactyl/pterodactyl_models.dart';
import '../../services/pterodactyl/pterodactyl_profile.dart';
import '../../services/pterodactyl/pterodactyl_service.dart';
import '../../utils/user_prompt.dart';

Future<int> handleRemote(List<String> args) async {
  final String subcommand = args.isEmpty ? 'list' : args.first;
  final List<String> rest = args.skip(1).toList(growable: false);
  final _RemoteArguments parsed = _RemoteArguments(rest);
  try {
    switch (subcommand) {
      case 'connect':
        return _connect(parsed);
      case 'profiles':
        for (final PterodactylProfile profile
            in pterodactylService.listProfiles()) {
          stdout.writeln('${profile.id}\t${profile.name}\t${profile.origin}');
        }
        return 0;
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
        if (name == null || name.trim().isEmpty || template == null) {
          stderr.writeln(
            'Usage: remote create <name> --template <server> [--memory <MiB>] [--disk <MiB>] [--cpu <percent>] [--start]',
          );
          return 2;
        }
        final PterodactylApplicationServer created = await pterodactylService
            .createFromTemplate(
              profileId: _profileId(parsed),
              template: template,
              name: name,
              memoryMiB: _integer(parsed, 'memory'),
              diskMiB: _integer(parsed, 'disk'),
              cpuPercent: _integer(parsed, 'cpu'),
              startOnCompletion: parsed.flag('start'),
            );
        stdout.writeln(
          '[OK] Created ${_safe(created.name)} (${_safe(created.identifier)})',
        );
        return 0;
      default:
        stderr.writeln(
          'Usage: remote <connect|profiles|verify|list|nodes|stats|start|stop|restart|kill|console|command|create>',
        );
        return 2;
    }
  } catch (error) {
    stderr.writeln('[ERROR] $error');
    return 1;
  }
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
      '[ERROR] Keychain enrollment requires an interactive terminal. The '
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
      stdout.writeln('Paste it into the secure macOS Keychain prompt.');
      await pterodactylService.enrollCredential(
        candidate,
        PterodactylCredentialRole.client,
      );
      if (!hasClient) {
        newlyEnrolled.add(PterodactylCredentialRole.client);
      }
    }
    if (needsApplicationEnrollment) {
      stdout.writeln(
        'Create an Application API key at ${candidate.origin}/admin/api/new.',
      );
      stdout.writeln(
        'Grant Servers read/write, Allocations read, and Nodes read.',
      );
      await pterodactylService.enrollCredential(
        candidate,
        PterodactylCredentialRole.application,
      );
      if (!hasApplication) {
        newlyEnrolled.add(PterodactylCredentialRole.application);
      }
    }

    final PterodactylVerification result = await pterodactylService
        .verifyProfile(candidate);
    pterodactylService.saveProfile(candidate);
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

String _profileId(_RemoteArguments parsed) {
  final String? selected = parsed.option('profile');
  if (selected != null && selected.isNotEmpty) return selected;
  final List<PterodactylProfile> profiles = pterodactylService.listProfiles();
  if (profiles.isEmpty) {
    throw StateError('No Pterodactyl connection. Run remote connect.');
  }
  if (profiles.length == 1) return profiles.single.id;
  throw StateError(
    'Multiple Pterodactyl connections exist; select one with --profile.',
  );
}

String _server(_RemoteArguments parsed) {
  final String? server =
      parsed.option('server') ?? parsed.positionals.firstOrNull;
  if (server == null || server.isEmpty) {
    throw ArgumentError('A remote server identifier is required.');
  }
  return server;
}

int? _integer(_RemoteArguments parsed, String name) {
  final String? raw = parsed.option(name);
  if (raw == null) return null;
  final int? value = int.tryParse(raw);
  if (value == null || value <= 0) {
    throw ArgumentError('--$name must be a positive integer.');
  }
  return value;
}

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
      if (key == 'start') {
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

  String? option(String name) => options[name];
  bool flag(String name) => flags.contains(name);
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
