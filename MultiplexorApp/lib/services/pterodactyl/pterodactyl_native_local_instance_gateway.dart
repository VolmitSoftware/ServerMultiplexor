import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../models/consumer_profile.dart';
import '../../utils/process_runner.dart';
import '../passthrough_service.dart';
import 'pterodactyl_transfer_models.dart';

typedef PterodactylTransferConsumerLoader = ConsumerProfile Function();

/// Adapts the native Local instance engine to the Remote transfer engine.
///
/// Every operation is routed through the same commands used by the Local TUI,
/// so external instance storage, bracketed workspace paths, runtime state, and
/// instance-name validation keep one source of truth.
final class PterodactylNativeLocalInstanceGateway
    implements PterodactylLocalInstanceGateway {
  PterodactylNativeLocalInstanceGateway({
    required PassthroughService passthrough,
    required PterodactylTransferConsumerLoader loadConsumer,
  }) : _passthrough = passthrough,
       _loadConsumer = loadConsumer;

  final PassthroughService _passthrough;
  final PterodactylTransferConsumerLoader _loadConsumer;

  @override
  Future<String> currentConsumer() async => _loadConsumer().shortName;

  @override
  Future<PterodactylLocalInstance> createStopped(
    String name, {
    String? consumer,
  }) async {
    final ConsumerProfile selected = _selectedConsumer(consumer);
    _requireSafeInstanceName(name);
    final String candidatePath = p.join(_instanceStoreRoot(selected), name);
    if (FileSystemEntity.typeSync(candidatePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'Local instance path already exists and was not changed: $name.',
      );
    }
    final String creationToken = _creationToken();
    bool created = false;
    try {
      _passthrough.setConsumerOverride(selected);
      final CapturedResult result = await _passthrough
          .createIsolatedTransferInstance(name, creationToken: creationToken);
      _requireSuccess(result, operation: 'create isolated Local instance');
      created = true;
      final PterodactylLocalInstance instance = await _resolveFor(
        selected,
        name,
      );
      if (await isRunning(instance)) {
        throw StateError(
          'The newly created Local instance unexpectedly started: $name.',
        );
      }
      return instance;
    } catch (error, stackTrace) {
      if (!created) {
        final bool cleaned = _passthrough.cleanupPartialTransferInstance(
          name,
          creationToken: creationToken,
        );
        if (!cleaned &&
            FileSystemEntity.typeSync(candidatePath, followLinks: false) !=
                FileSystemEntityType.notFound) {
          throw StateError(
            'Local creation failed and an unverified filesystem entity now '
            'occupies $candidatePath. It was preserved for manual review. '
            'Original failure: $error',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      try {
        await _run(selected, <String>['instance', 'delete', name]);
      } catch (cleanupError) {
        throw StateError(
          'Local creation failed after instance $name was allocated: $error. '
          'Automatic cleanup also failed: $cleanupError',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<PterodactylLocalInstance> resolve(String name, {String? consumer}) =>
      _resolveFor(_selectedConsumer(consumer), name);

  Future<PterodactylLocalInstance> _resolveFor(
    ConsumerProfile consumer,
    String name,
  ) async {
    final CapturedResult result = await _capture(consumer, <String>[
      'instance',
      'path',
      name,
    ]);
    _requireSuccess(result, operation: 'resolve Local instance $name');
    final List<String> lines = result.stdout
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      throw StateError('Local instance $name did not report a path.');
    }
    final String consumerRoot = _passthrough.consumerService.rootFor(consumer);
    final String instancePath = _validatedInstancePath(
      consumer: consumer,
      name: name,
      reportedPath: lines.last,
    );
    final List<String> safeSymlinkRoots = <String>[
      _requireManagedDirectory(consumerRoot, p.join(consumerRoot, 'builds')),
      _requireManagedDirectory(consumerRoot, p.join(consumerRoot, 'dropins')),
      if (consumer == ConsumerProfile.plugin)
        ?_optionalManagedDirectory(
          consumerRoot,
          p.join(consumerRoot, 'shared-plugin-data', 'ops'),
        ),
      if (consumer == ConsumerProfile.plugin)
        ?_optionalManagedDirectory(
          consumerRoot,
          p.join(consumerRoot, 'shared-plugin-data', 'iris', 'packs'),
        ),
    ];
    _requireManagedLaunchLinks(
      instanceName: name,
      instancePath: instancePath,
      safeRoots: safeSymlinkRoots,
    );
    return PterodactylLocalInstance(
      name: name,
      consumer: consumer.shortName,
      path: instancePath,
      safeSymlinkRoots: safeSymlinkRoots,
    );
  }

  void _requireSafeInstanceName(String name) {
    if (name.trim().isEmpty ||
        p.basename(name) != name ||
        p.windows.basename(name) != name ||
        name == '.' ||
        name == '..') {
      throw StateError('Local instance name is unsafe: $name.');
    }
  }

  String _creationToken() {
    final Random random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _validatedInstancePath({
    required ConsumerProfile consumer,
    required String name,
    required String reportedPath,
  }) {
    final String normalized = p.normalize(p.absolute(reportedPath));
    if (FileSystemEntity.typeSync(normalized, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Local instance paths must be real directories.');
    }
    final String expectedRoot = _instanceStoreRoot(consumer);
    final String canonicalRoot = _requireManagedDirectory(
      _instanceStoreManagedBase(consumer),
      expectedRoot,
    );
    final String canonicalInstance = Directory(
      normalized,
    ).resolveSymbolicLinksSync();
    if (!p.equals(p.dirname(canonicalInstance), canonicalRoot) ||
        p.basename(canonicalInstance) != name) {
      throw StateError(
        'Local instance $name escaped its managed consumer instance store.',
      );
    }
    return normalized;
  }

  String _instanceStoreRoot(ConsumerProfile consumer) {
    final String consumerRoot = _passthrough.consumerService.rootFor(consumer);
    final String workspaceRoot = _passthrough.context.rootDir;
    if (consumer == ConsumerProfile.plugin ||
        !workspaceRoot.contains('[') && !workspaceRoot.contains(']')) {
      return p.join(consumerRoot, 'instances');
    }
    final String home = (Platform.environment['HOME'] ?? '').trim();
    final String externalRoot = home.isNotEmpty
        ? p.join(home, '.multiplexor')
        : p.join(Directory.systemTemp.path, 'multiplexor');
    return p.join(
      externalRoot,
      'instance-store',
      _stablePathHash(workspaceRoot),
      consumer.shortName,
    );
  }

  String _instanceStoreManagedBase(ConsumerProfile consumer) {
    final String workspaceRoot = _passthrough.context.rootDir;
    if (consumer == ConsumerProfile.plugin ||
        !workspaceRoot.contains('[') && !workspaceRoot.contains(']')) {
      return _passthrough.consumerService.rootFor(consumer);
    }
    final String home = (Platform.environment['HOME'] ?? '').trim();
    return home.isNotEmpty
        ? p.join(home, '.multiplexor')
        : p.join(Directory.systemTemp.path, 'multiplexor');
  }

  String _requireManagedDirectory(String managedRoot, String candidate) {
    final String root = p.normalize(p.absolute(managedRoot));
    final String target = p.normalize(p.absolute(candidate));
    if (!p.equals(root, target) && !p.isWithin(root, target)) {
      throw StateError('A Local managed content root escaped its consumer.');
    }
    String current = root;
    if (FileSystemEntity.typeSync(current, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('A Local managed content root is not a real directory.');
    }
    for (final String part in p.split(p.relative(target, from: root))) {
      if (part == '.' || part.isEmpty) continue;
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError(
          'Local managed content directories cannot contain symlinks.',
        );
      }
    }
    final String canonicalRoot = Directory(root).resolveSymbolicLinksSync();
    final String canonicalTarget = Directory(target).resolveSymbolicLinksSync();
    if (!p.equals(canonicalRoot, canonicalTarget) &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      throw StateError('A Local managed content root escaped its consumer.');
    }
    return canonicalTarget;
  }

  String? _optionalManagedDirectory(String managedRoot, String candidate) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      candidate,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    return _requireManagedDirectory(managedRoot, candidate);
  }

  String _stablePathHash(String input) {
    const int offset = 0x811C9DC5;
    const int prime = 0x01000193;
    int hash = offset;
    for (final int codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * prime) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  void _requireManagedLaunchLinks({
    required String instanceName,
    required String instancePath,
    required List<String> safeRoots,
  }) {
    final String canonicalInstance = Directory(
      instancePath,
    ).resolveSymbolicLinksSync();
    for (final String fileName in const <String>[
      'server.jar',
      'installer.jar',
    ]) {
      final String path = p.join(instancePath, fileName);
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.link) {
        continue;
      }
      final String target;
      try {
        target = File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        throw StateError(
          'Local instance $instanceName has a broken $fileName link.',
        );
      }
      final bool managed =
          p.equals(canonicalInstance, target) ||
          p.isWithin(canonicalInstance, target) ||
          safeRoots.any(
            (String root) => p.equals(root, target) || p.isWithin(root, target),
          );
      if (!managed) {
        throw StateError(
          'Local instance $instanceName uses an unmanaged external '
          '$fileName. Re-import jar-launch servers with `instance update '
          '$instanceName --jar <path>`; recreate installer-based servers '
          'with `server create --jar <path>` before Remote transfer.',
        );
      }
    }
  }

  @override
  Future<bool> isRunning(PterodactylLocalInstance instance) async {
    final ConsumerProfile consumer = _consumer(instance);
    final CapturedResult result = await _capture(consumer, const <String>[
      'runtime',
      'states',
    ]);
    _requireSuccess(
      result,
      operation: 'read Local runtime state for ${instance.name}',
    );
    for (final String line in result.stdout.split('\n')) {
      final List<String> fields = line.trim().split('\t');
      if (fields.length >= 2 && fields.first == instance.name) {
        return fields[1].trim().toLowerCase() != 'stopped';
      }
    }
    throw StateError(
      'Local instance ${instance.name} disappeared while reading its state.',
    );
  }

  @override
  Future<void> stop(PterodactylLocalInstance instance) =>
      _run(_consumer(instance), <String>['runtime', 'stop', instance.name]);

  @override
  Future<void> start(PterodactylLocalInstance instance) => _run(
    _consumer(instance),
    <String>['runtime', 'start', instance.name, '--no-console'],
  );

  @override
  Future<void> delete(PterodactylLocalInstance instance) =>
      _run(_consumer(instance), <String>['instance', 'delete', instance.name]);

  ConsumerProfile _consumer(PterodactylLocalInstance instance) {
    final ConsumerProfile? consumer = ConsumerProfile.parse(instance.consumer);
    if (consumer == null) {
      throw StateError(
        'Unknown Local consumer recorded for ${instance.name}: '
        '${instance.consumer}',
      );
    }
    return consumer;
  }

  ConsumerProfile _selectedConsumer(String? value) {
    if (value == null || value.trim().isEmpty) return _loadConsumer();
    final ConsumerProfile? consumer = ConsumerProfile.parse(value);
    if (consumer == null) {
      throw StateError('Unknown Local consumer: $value');
    }
    return consumer;
  }

  Future<void> _run(ConsumerProfile consumer, List<String> command) async {
    final CapturedResult result = await _capture(consumer, command);
    _requireSuccess(result, operation: command.join(' '));
  }

  Future<CapturedResult> _capture(
    ConsumerProfile consumer,
    List<String> command,
  ) {
    _passthrough.setConsumerOverride(consumer);
    return _passthrough.capture(command);
  }

  static void _requireSuccess(
    CapturedResult result, {
    required String operation,
  }) {
    if (result.success) return;
    final String detail = result.stderr
        .split('\n')
        .map((String line) => line.trim())
        .firstWhere(
          (String line) => line.isNotEmpty,
          orElse: () => 'exit ${result.exitCode}',
        );
    throw StateError('Could not $operation: $detail');
  }
}
