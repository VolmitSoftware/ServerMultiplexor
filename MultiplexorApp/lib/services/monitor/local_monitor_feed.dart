import '../../models/consumer_profile.dart';
import 'metric_sample.dart';
import 'metrics_sampler.dart';
import 'monitor_frame_util.dart';
import 'monitor_network_tree.dart';
import 'trend_store.dart';

class LocalMonitorFeed implements MonitorMetricsSource {
  LocalMonitorFeed({
    required Future<String> Function(ConsumerProfile) captureMetrics,
    required Future<String?> Function(ConsumerProfile) capturePrimary,
    Map<ConsumerProfile, TrendStore> stores =
        const <ConsumerProfile, TrendStore>{},
    int ringCapacity = 900,
    DateTime Function()? clock,
  }) : _capturePrimary = capturePrimary,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    for (final ConsumerProfile profile in profiles) {
      _samplers[profile] = MetricsSampler(
        captureMetrics: () async {
          final String raw = await captureMetrics(profile);
          _flags[profile] = metricsTsvFlagsByInstance(raw);
          return raw;
        },
        store: stores[profile],
        ringCapacity: ringCapacity,
        clock: () => _sampleTime,
      );
    }
  }

  static const List<ConsumerProfile> profiles = <ConsumerProfile>[
    ConsumerProfile.plugin,
    ConsumerProfile.fabric,
    ConsumerProfile.forge,
    ConsumerProfile.neoforge,
  ];

  final Future<String?> Function(ConsumerProfile) _capturePrimary;
  final DateTime Function() _clock;
  final Map<ConsumerProfile, MetricsSampler> _samplers =
      <ConsumerProfile, MetricsSampler>{};
  final Map<ConsumerProfile, Map<String, InstanceFlags>> _flags =
      <ConsumerProfile, Map<String, InstanceFlags>>{};
  final Map<ConsumerProfile, String?> _primary = <ConsumerProfile, String?>{};
  final Map<ConsumerProfile, String> _primaryErrors =
      <ConsumerProfile, String>{};
  bool _sweeping = false;
  late DateTime _sampleTime;

  static String identifier(ConsumerProfile profile, String name) =>
      '${profile.shortName}/$name';

  Future<void> initialize({required Duration window}) async {
    await sweep();
    await Future.wait<void>(<Future<void>>[
      for (final MetricsSampler sampler in _samplers.values)
        _initializeStore(sampler, window),
    ]);
  }

  @override
  Future<void> sweep() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      _sampleTime = _clock();
      await Future.wait<void>(<Future<void>>[
        for (final ConsumerProfile profile in profiles) _sweepProfile(profile),
      ]);
    } finally {
      _sweeping = false;
    }
  }

  @override
  List<MetricSample> history(String instance) {
    final (ConsumerProfile, String)? target = _target(instance);
    return target == null
        ? const <MetricSample>[]
        : _samplers[target.$1]!.history(target.$2);
  }

  @override
  MetricSample? latest(String instance) {
    final (ConsumerProfile, String)? target = _target(instance);
    return target == null ? null : _samplers[target.$1]!.latest(target.$2);
  }

  MonitorSnapshot snapshot({
    List<MonitorNetworkGroup> networks = const <MonitorNetworkGroup>[],
    Map<String, String> advertisedEndpoints = const <String, String>{},
    bool networkTopologyStale = false,
  }) {
    final MonitorNetworkTree pluginTree = MonitorNetworkTree.project(
      _samplers[ConsumerProfile.plugin]!.instances,
      networks,
    );
    final List<String> instances = <String>[];
    final Map<String, String> displayNames = <String, String>{};
    final Map<String, ConsumerProfile> instanceConsumers =
        <String, ConsumerProfile>{};
    final Map<String, InstanceFlags> flags = <String, InstanceFlags>{};
    final Set<String> primaryInstances = <String>{};
    final List<String> errors = <String>[];
    DateTime? lastSuccessfulCapture;
    bool everyProfileCaptured = true;
    for (final ConsumerProfile profile in profiles) {
      final MetricsSampler sampler = _samplers[profile]!;
      final DateTime? lastCapture = sampler.lastSuccessfulSweep;
      if (lastCapture == null) {
        everyProfileCaptured = false;
      } else if (lastSuccessfulCapture == null ||
          lastCapture.isBefore(lastSuccessfulCapture)) {
        lastSuccessfulCapture = lastCapture;
      }
      final String? error = sampler.lastError;
      if (error != null) errors.add('${profile.shortName}: $error');
      final String? primaryError = _primaryErrors[profile];
      if (primaryError != null) {
        errors.add('${profile.shortName} primary: $primaryError');
      }
      final List<String> names = profile == ConsumerProfile.plugin
          ? pluginTree.instances
          : sampler.instances;
      for (final String name in names) {
        final String id = identifier(profile, name);
        instances.add(id);
        displayNames[id] = name;
        instanceConsumers[id] = profile;
        final InstanceFlags? instanceFlags = _flags[profile]?[name];
        if (instanceFlags != null) flags[id] = instanceFlags;
        if (_primary[profile] == name) primaryInstances.add(id);
      }
    }
    return MonitorSnapshot(
      instances: instances,
      history: <String, List<MetricSample>>{
        for (final String instance in instances) instance: history(instance),
      },
      consumerName: 'local',
      displayNames: displayNames,
      instanceConsumers: instanceConsumers,
      primaryInstances: primaryInstances,
      groupedLocal: true,
      flags: flags,
      captureError: errors.isEmpty ? null : errors.join('; '),
      lastSuccessfulCapture: everyProfileCaptured
          ? lastSuccessfulCapture
          : null,
      networkTopologyStale: networkTopologyStale,
      networkRows: <String, MonitorNetworkRow>{
        for (final MapEntry<String, MonitorNetworkRow> entry
            in pluginTree.rows.entries)
          identifier(ConsumerProfile.plugin, entry.key): MonitorNetworkRow(
            network: entry.value.network,
            proxy: identifier(ConsumerProfile.plugin, entry.value.proxy),
            port: entry.value.port,
            alias: entry.value.alias,
            lastChild: entry.value.lastChild,
          ),
      },
      advertisedEndpoints: <String, String>{
        for (final MapEntry<String, String> entry
            in advertisedEndpoints.entries)
          identifier(ConsumerProfile.plugin, entry.key): entry.value,
      },
    );
  }

  Future<void> _initializeStore(MetricsSampler sampler, Duration window) async {
    await sampler.compactStore(sampler.instances);
    await sampler.seedFromStore(sampler.instances, window: window);
  }

  Future<void> _sweepProfile(ConsumerProfile profile) async {
    await Future.wait<void>(<Future<void>>[
      _samplers[profile]!.sweep(),
      _loadPrimary(profile),
    ]);
  }

  Future<void> _loadPrimary(ConsumerProfile profile) async {
    try {
      final String? name = await _capturePrimary(profile);
      _primary[profile] = name == null || name.trim().isEmpty
          ? null
          : name.trim();
      _primaryErrors.remove(profile);
    } catch (error) {
      _primaryErrors[profile] = error.toString();
    }
  }

  (ConsumerProfile, String)? _target(String instance) {
    final int separator = instance.indexOf('/');
    if (separator <= 0 || separator == instance.length - 1) return null;
    final ConsumerProfile? profile = ConsumerProfile.parse(
      instance.substring(0, separator),
    );
    if (profile == null) return null;
    return (profile, instance.substring(separator + 1));
  }
}
