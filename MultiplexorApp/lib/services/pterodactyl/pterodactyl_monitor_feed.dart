import 'dart:io';

import '../runtime_state.dart';
import 'pterodactyl_console_protocol.dart';
import 'pterodactyl_models.dart';
import 'pterodactyl_service.dart';

typedef PterodactylFleetCapture =
    Future<List<PterodactylFleetSample>> Function(String profileId);
typedef PterodactylDnsLookup =
    Future<List<InternetAddress>> Function(String host);

const Duration _defaultDnsTimeout = Duration(seconds: 2);

Future<List<InternetAddress>> _systemDnsLookup(String host) =>
    InternetAddress.lookup(host);

/// Adapts Pterodactyl inventory/resources into the monitor's append-only TSV
/// contract while retaining provider metadata separately for display.
final class PterodactylMonitorFeed {
  PterodactylMonitorFeed({
    required PterodactylService service,
    required this.profileId,
    PterodactylDnsLookup dnsLookup = _systemDnsLookup,
    Duration dnsTimeout = _defaultDnsTimeout,
  }) : _captureFleet = service.captureFleet,
       _dnsLookup = dnsLookup,
       _dnsTimeout = dnsTimeout;

  PterodactylMonitorFeed.withCapture({
    required PterodactylFleetCapture captureFleet,
    required this.profileId,
    PterodactylDnsLookup dnsLookup = _systemDnsLookup,
    Duration dnsTimeout = _defaultDnsTimeout,
  }) : _captureFleet = captureFleet,
       _dnsLookup = dnsLookup,
       _dnsTimeout = dnsTimeout;

  final PterodactylFleetCapture _captureFleet;
  final PterodactylDnsLookup _dnsLookup;
  final Duration _dnsTimeout;
  final String profileId;
  final Map<String, Future<List<String>>> _dnsCache =
      <String, Future<List<String>>>{};

  List<String> _instances = const <String>[];
  Map<String, String> _displayNames = const <String, String>{};
  Map<String, String> _advertisedEndpoints = const <String, String>{};
  Map<String, String> _bindEndpoints = const <String, String>{};
  Map<String, String> _operationBlockReasons = const <String, String>{};
  bool _connectionFailed = false;

  List<String> get instances => _instances;
  Map<String, String> get displayNames => _displayNames;
  Map<String, String> get advertisedEndpoints => _advertisedEndpoints;
  Map<String, String> get bindEndpoints => _bindEndpoints;
  Map<String, String> get operationBlockReasons => _operationBlockReasons;
  bool get connectionFailed => _connectionFailed;

  Future<String> captureMetrics() async {
    final List<PterodactylFleetSample> fleet;
    try {
      fleet = await _captureFleet(profileId);
      _connectionFailed = false;
    } on Object {
      // MetricsSampler deliberately retains the last good snapshot when a
      // capture throws. Remember the failure separately so a first-run auth
      // or connectivity problem renders the Connection repair surface rather
      // than pretending the remote panel contains no servers.
      _connectionFailed = true;
      rethrow;
    }
    _instances = List<String>.unmodifiable(
      fleet.map((PterodactylFleetSample sample) => sample.server.identifier),
    );
    _operationBlockReasons = Map<String, String>.unmodifiable(<String, String>{
      for (final PterodactylFleetSample sample in fleet)
        if (_operationBlockReason(sample) case final String reason)
          sample.server.identifier: reason,
    });
    _displayNames = Map<String, String>.unmodifiable(<String, String>{
      for (final PterodactylFleetSample sample in fleet)
        sample.server.identifier: _safe(sample.server.name),
    });
    final List<MapEntry<String, String>?> advertisedEntries =
        await Future.wait(<Future<MapEntry<String, String>?>>[
          for (final PterodactylFleetSample sample in fleet)
            _advertisedEntry(sample.server),
        ]);
    _advertisedEndpoints = Map<String, String>.unmodifiable(<String, String>{
      for (final MapEntry<String, String>? entry in advertisedEntries)
        if (entry != null) entry.key: entry.value,
    });
    _bindEndpoints = Map<String, String>.unmodifiable(<String, String>{
      for (final PterodactylFleetSample sample in fleet)
        if (_bindEndpointsFor(sample.server) case final List<String> values
            when values.isNotEmpty)
          sample.server.identifier: values.join('\n'),
    });

    final List<String> rows = <String>[];
    for (final PterodactylFleetSample sample in fleet) {
      final PterodactylResourceUsage? resources = sample.resources;
      final RuntimeState? state = resources == null
          ? null
          : _state(resources.currentState);
      if (resources == null || state == null) {
        continue;
      }
      final PterodactylAllocation? allocation = sample.server.primaryAllocation;
      rows.add(
        <String>[
          sample.server.identifier,
          state.name,
          allocation == null ? '-' : '${allocation.port}',
          'unlocked',
          '-',
          '-',
          'Pterodactyl',
          '-',
          'shared',
          '${resources.uptime.inSeconds}',
          '${resources.cpuAbsolute}',
          '${resources.memoryBytes}',
          '-',
          '-',
          '${resources.diskBytes}',
          '${resources.networkRxBytes}',
          '${resources.networkTxBytes}',
          '${sample.server.limits.memoryMiB * 1024 * 1024}',
          '${sample.server.limits.diskMiB * 1024 * 1024}',
        ].join('\t'),
      );
    }
    return rows.join('\n');
  }

  static RuntimeState? _state(String value) =>
      switch (value.trim().toLowerCase()) {
        'offline' => RuntimeState.stopped,
        'starting' => RuntimeState.starting,
        'running' => RuntimeState.running,
        'stopping' => RuntimeState.stopping,
        _ => null,
      };

  static String? _operationBlockReason(PterodactylFleetSample sample) {
    final PterodactylResourceUsage? resources = sample.resources;
    if (sample.server.isNodeUnderMaintenance) {
      return 'node is under maintenance';
    }
    if (resources?.isSuspended == true) {
      return 'server is suspended';
    }
    final String? rawStatus = sample.server.status;
    if (rawStatus != null) {
      final String status = _safe(rawStatus).trim();
      if (status.isEmpty) {
        return 'server status is unknown';
      }
      return status.toLowerCase() == 'installing'
          ? 'server is installing'
          : 'server status: $status';
    }
    if (resources == null) {
      return 'resources unavailable';
    }
    if (_state(resources.currentState) == null) {
      final String currentState = _safe(resources.currentState).trim();
      return currentState.isEmpty
          ? 'runtime state is unknown'
          : 'unknown runtime state: $currentState';
    }
    return null;
  }

  Future<MapEntry<String, String>?> _advertisedEntry(
    PterodactylClientServer server,
  ) async {
    final List<String> values = await _advertisedEndpointsFor(server);
    return values.isEmpty
        ? null
        : MapEntry<String, String>(server.identifier, values.join('\n'));
  }

  Future<List<String>> _advertisedEndpointsFor(
    PterodactylClientServer server,
  ) async {
    final List<List<String>> groups = await Future.wait(<Future<List<String>>>[
      for (final PterodactylAllocation allocation in server.allocations)
        _advertisedAllocationEndpoints(allocation),
    ]);
    final Set<String> endpoints = <String>{};
    for (final List<String> group in groups) {
      endpoints.addAll(group);
    }
    return endpoints.toList(growable: false);
  }

  Future<List<String>> _advertisedAllocationEndpoints(
    PterodactylAllocation allocation,
  ) async {
    final String alias = _safe(allocation.alias ?? '').trim();
    if (alias.isEmpty) {
      return const <String>[];
    }
    final String lookupHost = _unbracket(alias);
    final InternetAddress? literal = InternetAddress.tryParse(lookupHost);
    if (literal != null) {
      return <String>[_endpoint(literal.address, allocation.port)];
    }

    final List<String> resolved = await _resolvedAddresses(lookupHost);
    if (resolved.isEmpty) {
      return <String>[_endpoint(alias, allocation.port)];
    }
    return <String>[
      for (final String address in resolved)
        '$alias ($address):${allocation.port}',
    ];
  }

  Future<List<String>> _resolvedAddresses(String host) {
    final String cacheKey = host.toLowerCase();
    return _dnsCache.putIfAbsent(cacheKey, () async {
      try {
        final List<InternetAddress> addresses = await _dnsLookup(
          host,
        ).timeout(_dnsTimeout);
        final Set<String> unique = <String>{
          for (final InternetAddress address in addresses) address.address,
        };
        return unique.toList(growable: false);
      } on Object {
        // DNS enriches display only. A failed or slow lookup must never hide
        // the configured alias or fail the metrics sweep.
        return const <String>[];
      }
    });
  }

  static List<String> _bindEndpointsFor(PterodactylClientServer server) {
    final Set<String> endpoints = <String>{};
    for (final PterodactylAllocation allocation in server.allocations) {
      endpoints.add(_endpoint(_safe(allocation.ip).trim(), allocation.port));
    }
    return endpoints.toList(growable: false);
  }

  static String _endpoint(String host, int port) {
    final String renderedHost = host.contains(':') ? '[$host]' : host;
    return '$renderedHost:$port';
  }

  static String _safe(String value) =>
      PterodactylConsoleSanitizer.text(value).replaceAll('\n', ' ');

  static String _unbracket(String host) =>
      host.length >= 2 && host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
}
