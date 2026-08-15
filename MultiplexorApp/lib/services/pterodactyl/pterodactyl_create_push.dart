import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pterodactyl_models.dart';
import 'pterodactyl_service.dart';
import 'pterodactyl_transfer_models.dart';

/// Exact, executable Remote creation inputs approved before Create & Push.
final class PterodactylCreatePushPlan {
  PterodactylCreatePushPlan.template({
    required PterodactylTemplateCreatePlan plan,
    required this.ownerName,
    required this.nodeName,
  }) : _templatePlan = plan,
       _eggPlan = null,
       _eggSource = null,
       name = plan.name,
       sourceKind = 'template',
       sourceName = plan.templateName,
       sourceIdentity = plan.templateUuid,
       sourceEggId = plan.eggId,
       _canonicalJson = plan.canonicalJson() {
    if (plan.startOnCompletion) {
      throw ArgumentError(
        'Create & Push creation plans must start with the server stopped.',
      );
    }
  }

  PterodactylCreatePushPlan.egg({
    required this.name,
    required PterodactylEgg source,
    required PterodactylEggCreatePlan plan,
    required this.ownerName,
    required this.nodeName,
  }) : _templatePlan = null,
       _eggPlan = plan,
       _eggSource = source,
       sourceKind = 'egg',
       sourceName = source.name,
       sourceIdentity = source.uuid,
       sourceEggId = source.id,
       _canonicalJson = <String, Object?>{
         'source_kind': 'egg',
         'source_uuid': source.uuid,
         'source_id': source.id,
         'source_name': source.name,
         'name': name,
         'description': 'Created by Multiplexor from Panel egg ${plan.eggId}.',
         'external_id': plan.externalId,
         'owner_id': plan.ownerId,
         'node_id': plan.nodeId,
         'egg_id': plan.eggId,
         'docker_image': plan.dockerImage,
         'startup': plan.startup,
         'environment': plan.environment,
         'limits': <String, Object?>{
           'memory': plan.memoryMiB,
           'swap': plan.swapMiB,
           'disk': plan.diskMiB,
           'io': plan.ioWeight,
           'cpu': plan.cpuPercent,
           'threads': null,
           'oom_disabled': true,
         },
         'feature_limits': <String, Object?>{
           'databases': plan.databaseLimit,
           'allocations': plan.allocationLimit,
           'backups': plan.backupLimit,
         },
         'start_on_completion': plan.startOnCompletion,
         'skip_scripts': false,
         'oom_disabled': true,
       } {
    if (plan.eggId != source.id || plan.eggUuid != source.uuid) {
      throw ArgumentError(
        'The resolved egg ID and UUID must match the creation source.',
      );
    }
    if (plan.startOnCompletion) {
      throw ArgumentError(
        'Create & Push creation plans must start with the server stopped.',
      );
    }
  }

  final PterodactylTemplateCreatePlan? _templatePlan;
  final PterodactylEggCreatePlan? _eggPlan;
  final PterodactylEgg? _eggSource;
  final String name;
  final String sourceKind;
  final String sourceName;
  final String sourceIdentity;
  final int sourceEggId;
  final String ownerName;
  final String nodeName;
  final JsonObject _canonicalJson;

  /// A detached canonical snapshot, safe for token generation and display.
  JsonObject get canonicalJson =>
      _canonicalJsonValue(_canonicalJson)! as JsonObject;

  int get ownerId => _templatePlan?.ownerId ?? _eggPlan!.ownerId;
  int get nodeId => _templatePlan?.nodeId ?? _eggPlan!.nodeId;
  String get dockerImage => _templatePlan?.dockerImage ?? _eggPlan!.dockerImage;
  String get startup => _templatePlan?.startup ?? _eggPlan!.startup;
  Map<String, String> get environment =>
      _templatePlan?.environment ?? _eggPlan!.environment;
  int get memoryMiB => _templatePlan?.limits.memoryMiB ?? _eggPlan!.memoryMiB;
  int get swapMiB => _templatePlan?.limits.swapMiB ?? _eggPlan!.swapMiB;
  int get diskMiB => _templatePlan?.limits.diskMiB ?? _eggPlan!.diskMiB;
  int get ioWeight => _templatePlan?.limits.ioWeight ?? _eggPlan!.ioWeight;
  int get cpuPercent =>
      _templatePlan?.limits.cpuPercent ?? _eggPlan!.cpuPercent;
  String? get threads => _templatePlan?.limits.threads;
  int? get databaseLimit =>
      _templatePlan?.featureLimits.databases ?? _eggPlan!.databaseLimit;
  int? get allocationLimit =>
      _templatePlan?.featureLimits.allocations ?? _eggPlan!.allocationLimit;
  int? get backupLimit =>
      _templatePlan?.featureLimits.backups ?? _eggPlan!.backupLimit;
  String? get externalId => _templatePlan?.externalId ?? _eggPlan?.externalId;
  bool get oomDisabled => _templatePlan?.oomDisabled ?? true;
  bool get skipScripts => _templatePlan?.skipScripts ?? false;

  PterodactylCreatePushPlan withExternalId(String value) {
    final PterodactylTemplateCreatePlan? templatePlan = _templatePlan;
    if (templatePlan != null) {
      return PterodactylCreatePushPlan.template(
        plan: templatePlan.copyWithExternalId(value),
        ownerName: ownerName,
        nodeName: nodeName,
      );
    }
    return PterodactylCreatePushPlan.egg(
      name: name,
      source: _eggSource!,
      plan: _eggPlan!.copyWithExternalId(value),
      ownerName: ownerName,
      nodeName: nodeName,
    );
  }

  Future<PterodactylApplicationServer> create({
    required PterodactylService service,
    required String profileId,
  }) {
    final PterodactylTemplateCreatePlan? templatePlan = _templatePlan;
    if (templatePlan != null) {
      return service.createFromTemplatePlan(
        profileId: profileId,
        plan: templatePlan,
      );
    }
    return service.createFromEgg(
      profileId: profileId,
      name: name,
      plan: _eggPlan!,
    );
  }
}

/// Returns the durable Panel external ID for one logical Create & Push target.
///
/// Local file contents are deliberately excluded: a changed Local snapshot
/// needs a fresh confirmation token but must reclaim the same created server.
String pterodactylCreatePushIntentId({
  required PterodactylTransferPlan transferPlan,
  required JsonObject canonicalCreation,
  required bool startAfterTransfer,
  required bool persistNewLink,
}) =>
    'multiplexor-push-${_createPushStableIdentityDigest(transferPlan: transferPlan, canonicalCreation: canonicalCreation, startAfterTransfer: startAfterTransfer, persistNewLink: persistNewLink).substring(0, 32)}';

String pterodactylCreatePushConfirmationToken({
  required String transferConfirmationToken,
  required JsonObject canonicalCreation,
  required bool startAfterTransfer,
  required bool persistNewLink,
}) =>
    'push-new:${_createPushDigest(transferConfirmationToken: transferConfirmationToken, canonicalCreation: canonicalCreation, startAfterTransfer: startAfterTransfer, persistNewLink: persistNewLink).substring(0, 24)}';

String _createPushDigest({
  required String transferConfirmationToken,
  required JsonObject canonicalCreation,
  required bool startAfterTransfer,
  required bool persistNewLink,
}) {
  final Object? canonical = _canonicalJsonValue(<String, Object?>{
    'version': 1,
    'transfer_confirmation': transferConfirmationToken,
    'creation': canonicalCreation,
    'start_after_transfer': startAfterTransfer,
    'persist_new_link': persistNewLink,
  });
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

String _createPushStableIdentityDigest({
  required PterodactylTransferPlan transferPlan,
  required JsonObject canonicalCreation,
  required bool startAfterTransfer,
  required bool persistNewLink,
}) {
  _requireNewPushIdentityPlan(transferPlan);
  final Object? canonical = _canonicalJsonValue(<String, Object?>{
    'version': 2,
    'local_instance_name': transferPlan.localInstanceName,
    'local_consumer': transferPlan.localConsumer,
    'local_instance_path': p.normalize(transferPlan.localInstancePath),
    'profile_id': transferPlan.profileId,
    'proposed_server_name': transferPlan.remoteServerName,
    'creation': _creationWithoutExternalId(canonicalCreation),
    'start_after_transfer': startAfterTransfer,
    'persist_new_link': persistNewLink,
  });
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

String _createPushCreationDigest(JsonObject canonicalCreation) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonicalJsonValue(_creationWithoutExternalId(canonicalCreation)),
        ),
      ),
    )
    .toString();

JsonObject _creationWithoutExternalId(JsonObject canonicalCreation) {
  final JsonObject detached =
      _canonicalJsonValue(canonicalCreation)! as JsonObject;
  detached['external_id'] = null;
  return detached;
}

void _requireNewPushIdentityPlan(PterodactylTransferPlan plan) {
  if (plan.direction != PterodactylTransferDirection.push ||
      plan.mode != PterodactylTransferMode.update ||
      plan.targetExists ||
      plan.localInstanceName.trim().isEmpty ||
      plan.localConsumer.trim().isEmpty ||
      plan.localInstancePath.trim().isEmpty ||
      plan.profileId.trim().isEmpty ||
      plan.remoteServerName.trim().isEmpty) {
    throw ArgumentError(
      'A stable Create & Push identity requires a fully resolved new-target '
      'transfer plan.',
    );
  }
}

Object? _canonicalJsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List<Object?>) {
    return value.map<Object?>(_canonicalJsonValue).toList(growable: false);
  }
  if (value is Map<Object?, Object?>) {
    final List<String> keys =
        value.keys
            .map<String>((Object? key) {
              if (key is! String) {
                throw ArgumentError(
                  'Canonical creation maps require string keys.',
                );
              }
              return key;
            })
            .toList(growable: false)
          ..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonicalJsonValue(value[key]),
    };
  }
  throw ArgumentError(
    'Unsupported canonical creation value: ${value.runtimeType}.',
  );
}

/// Holds an exclusive operation claim for one durable Create & Push intent.
final class PterodactylCreatePushIntentClaim {
  PterodactylCreatePushIntentClaim._({
    required PterodactylCreatePushIntentStore store,
    required RandomAccessFile lock,
    required JsonObject base,
    required PterodactylCreatePushPlan creation,
    required bool startAfterTransfer,
    required bool persistNewLink,
    required String transferConfirmationToken,
    required bool sourceChangedSinceCommit,
    required this.server,
    required this.shouldCreate,
    required this.alreadyCompleted,
  }) : _store = store,
       _lock = lock,
       _base = base,
       _creation = creation,
       _startAfterTransfer = startAfterTransfer,
       _persistNewLink = persistNewLink,
       _transferConfirmationToken = transferConfirmationToken,
       _sourceChangedSinceCommit = sourceChangedSinceCommit;

  final PterodactylCreatePushIntentStore _store;
  final RandomAccessFile _lock;
  final JsonObject _base;
  final PterodactylCreatePushPlan _creation;
  final bool _startAfterTransfer;
  final bool _persistNewLink;
  final String _transferConfirmationToken;
  final bool _sourceChangedSinceCommit;
  PterodactylApplicationServer? server;
  final bool shouldCreate;
  final bool alreadyCompleted;
  bool _closed = false;

  String get path => _store.file.path;
  String get id => _base['intent_id']! as String;
  String get status => _base['status']! as String;
  bool get sourceChangedSinceCommit => _sourceChangedSinceCommit;
  bool get needsPostconditionRepair =>
      status == 'postconditions-failed' && !_sourceChangedSinceCommit;

  void record({
    required String state,
    PterodactylApplicationServer? created,
    PterodactylTransferResult? result,
    String? failure,
  }) {
    if (state == 'completed') {
      throw ArgumentError('Use complete() to validate Create & Push results.');
    }
    _record(state: state, created: created, result: result, failure: failure);
  }

  /// Records completion only after every confirmed postcondition is proven.
  ///
  /// Set [filesTransferred] to false only for the repair-only engine path; a
  /// normal or no-op Push synchronizes the approved snapshot and keeps the
  /// default true.
  void complete({
    required PterodactylApplicationServer created,
    required PterodactylTransferResult result,
    bool filesTransferred = true,
  }) {
    final List<String> missing = <String>[
      if (_persistNewLink && !result.linkPersisted) 'durable Remote link',
      if (_startAfterTransfer && !result.remoteRestarted)
        'requested running state',
    ];
    if (missing.isNotEmpty) {
      final String failure =
          'Confirmed postconditions were not met: ${missing.join(', ')}.';
      _record(
        state: 'postconditions-failed',
        created: created,
        result: result,
        failure: failure,
        committedTransferConfirmationToken: filesTransferred
            ? _transferConfirmationToken
            : null,
      );
      throw StateError(
        '$failure Repeat the exact confirmed command to repair them without '
        'creating another server. Intent: $path',
      );
    }
    _record(
      state: 'completed',
      created: created,
      result: result,
      committedTransferConfirmationToken: filesTransferred
          ? _transferConfirmationToken
          : null,
    );
  }

  void _record({
    required String state,
    PterodactylApplicationServer? created,
    PterodactylTransferResult? result,
    String? failure,
    String? committedTransferConfirmationToken,
  }) {
    if (_closed) throw StateError('Create & Push intent claim is closed.');
    if (created != null) {
      _requireCreatedServerMatchesPlan(created, _creation, path);
      _requireRecordedServerIdentity(_base, created, path);
    }
    server = created ?? server;
    final PterodactylApplicationServer? known = server;
    final JsonObject next = <String, Object?>{
      ..._base,
      'status': state,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      if (known != null) ...<String, Object?>{
        'server_id': known.id,
        'server_identifier': known.identifier,
        'server_uuid': known.uuid,
        'server_name': known.name,
      },
      if (result != null) ...<String, Object?>{
        'link_persisted': result.linkPersisted,
        'backup_path': result.backupPath,
        'recovery_manifest_path': result.recoveryManifestPath,
        'remote_restarted': result.remoteRestarted,
      },
      if (failure != null) 'failure': _safeFailure(failure),
    };
    if (committedTransferConfirmationToken != null) {
      next['committed_transfer_confirmation_token'] =
          committedTransferConfirmationToken;
    }
    if (failure == null) next.remove('failure');
    _base
      ..clear()
      ..addAll(next);
    _store.write(_base);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _lock.unlockSync();
    } finally {
      _lock.closeSync();
    }
  }
}

/// Durable, locked, idempotent Create & Push intent coordination.
final class PterodactylCreatePushIntentCoordinator {
  PterodactylCreatePushIntentCoordinator({
    required String metadataDirectoryPath,
    required PterodactylService service,
  }) : _metadataDirectoryPath = metadataDirectoryPath,
       _service = service;

  final String _metadataDirectoryPath;
  final PterodactylService _service;

  Future<PterodactylCreatePushIntentClaim> claim({
    required String id,
    required String confirmationToken,
    required PterodactylTransferPlan transferPlan,
    required PterodactylCreatePushPlan creation,
    required bool startAfterTransfer,
    required bool persistNewLink,
  }) async {
    final String expectedId = pterodactylCreatePushIntentId(
      transferPlan: transferPlan,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: startAfterTransfer,
      persistNewLink: persistNewLink,
    );
    final String stableIdentityHash = _createPushStableIdentityDigest(
      transferPlan: transferPlan,
      canonicalCreation: creation.canonicalJson,
      startAfterTransfer: startAfterTransfer,
      persistNewLink: persistNewLink,
    );
    final String expectedConfirmationToken =
        pterodactylCreatePushConfirmationToken(
          transferConfirmationToken: transferPlan.confirmationToken,
          canonicalCreation: creation.canonicalJson,
          startAfterTransfer: startAfterTransfer,
          persistNewLink: persistNewLink,
        );
    if (id != expectedId || creation.externalId != id) {
      throw ArgumentError(
        'The Create & Push intent ID does not match the canonical plan.',
      );
    }
    if (confirmationToken != expectedConfirmationToken) {
      throw ArgumentError(
        'The Create & Push confirmation token does not match the canonical '
        'plan.',
      );
    }
    final PterodactylCreatePushIntentStore store =
        PterodactylCreatePushIntentStore(
          metadataDirectoryPath: _metadataDirectoryPath,
          intentId: id,
        );
    final RandomAccessFile lock = store.acquireLock();
    try {
      final JsonObject expected = <String, Object?>{
        'schema_version': 2,
        'intent_id': id,
        'panel_external_id': id,
        'stable_identity_hash': stableIdentityHash,
        'creation_configuration_hash': _createPushCreationDigest(
          creation.canonicalJson,
        ),
        'status': 'confirmed',
        'profile_id': transferPlan.profileId,
        'local_instance_name': transferPlan.localInstanceName,
        'local_consumer': transferPlan.localConsumer,
        'local_instance_path': transferPlan.localInstancePath,
        'proposed_server_name': transferPlan.remoteServerName,
        'creation_source_kind': creation.sourceKind,
        'creation_source_identity': creation.sourceIdentity,
        'confirmation_token': confirmationToken,
        'transfer_confirmation_token': transferPlan.confirmationToken,
        'source_fingerprint': transferPlan.sourceFingerprint,
        'committed_transfer_confirmation_token': null,
        'start_after_transfer': startAfterTransfer,
        'persist_new_link': persistNewLink,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      _requireUniqueStableIntentJournal(
        selected: store.file,
        stableIdentityHash: stableIdentityHash,
      );
      final JsonObject? loaded = store.load();
      final JsonObject existing;
      if (loaded == null) {
        store.write(expected);
        existing = expected;
      } else {
        _requireMatchingIntent(loaded, expected, store.file.path);
        existing = loaded;
      }
      final String status = _requiredString(existing, 'status');
      final String? committedTransferConfirmationToken = _optionalString(
        existing,
        'committed_transfer_confirmation_token',
      );
      if (status == 'postconditions-failed' &&
          committedTransferConfirmationToken == null) {
        throw StateError(
          'Create & Push intent $id cannot prove which Local snapshot was '
          'committed. Inspect ${store.file.path}; no automatic recovery is '
          'safe.',
        );
      }
      final bool sourceChangedSinceCommit =
          committedTransferConfirmationToken != null &&
          committedTransferConfirmationToken != transferPlan.confirmationToken;
      final List<PterodactylApplicationServer> matches = await _service
          .findApplicationServersByExternalId(
            profileId: transferPlan.profileId,
            externalId: id,
          );
      if (matches.length > 1) {
        throw StateError(
          'Create & Push intent $id matches multiple Panel servers. No '
          'automatic recovery is safe; inspect ${store.file.path}.',
        );
      }
      if (matches.isEmpty) {
        const Set<String> safePreCreate = <String>{
          'confirmed',
          'creating',
          'create-unknown',
        };
        if (!safePreCreate.contains(status)) {
          throw StateError(
            'Create & Push intent $id is $status, but no Panel server has '
            'external ID $id. Inspect ${store.file.path}; no server was '
            'created automatically.',
          );
        }
        _rebindIntentApproval(
          existing,
          confirmationToken: confirmationToken,
          transferPlan: transferPlan,
        );
        existing['status'] = 'confirmed';
        store.write(existing);
        return PterodactylCreatePushIntentClaim._(
          store: store,
          lock: lock,
          base: existing,
          creation: creation,
          startAfterTransfer: startAfterTransfer,
          persistNewLink: persistNewLink,
          transferConfirmationToken: transferPlan.confirmationToken,
          sourceChangedSinceCommit: sourceChangedSinceCommit,
          server: null,
          shouldCreate: true,
          alreadyCompleted: false,
        );
      }
      final PterodactylApplicationServer server = matches.single;
      _requireRecordedServerIdentity(existing, server, store.file.path);
      _requireCreatedServerMatchesPlan(server, creation, store.file.path);
      if (status == 'completed' && sourceChangedSinceCommit) {
        throw StateError(
          'Create & Push intent $id already completed for an earlier Local '
          'snapshot. Use normal Push to update ${server.identifier}; no new '
          'server was created.',
        );
      }
      _rebindIntentApproval(
        existing,
        confirmationToken: confirmationToken,
        transferPlan: transferPlan,
      );
      existing
        ..['server_id'] = server.id
        ..['server_identifier'] = server.identifier
        ..['server_uuid'] = server.uuid
        ..['server_name'] = server.name;
      store.write(existing);
      return PterodactylCreatePushIntentClaim._(
        store: store,
        lock: lock,
        base: existing,
        creation: creation,
        startAfterTransfer: startAfterTransfer,
        persistNewLink: persistNewLink,
        transferConfirmationToken: transferPlan.confirmationToken,
        sourceChangedSinceCommit: sourceChangedSinceCommit,
        server: server,
        shouldCreate: false,
        alreadyCompleted: status == 'completed',
      );
    } catch (_) {
      try {
        lock.unlockSync();
      } finally {
        lock.closeSync();
      }
      rethrow;
    }
  }
}

final class PterodactylCreatePushIntentStore {
  PterodactylCreatePushIntentStore({
    required String metadataDirectoryPath,
    required String intentId,
  }) : file = _intentFile(metadataDirectoryPath, intentId);

  final File file;

  JsonObject? load() {
    _recoverAtomicState(file);
    final FileSystemEntityType type = _safeFileType(
      file,
      noun: 'Create & Push intent',
    );
    if (type == FileSystemEntityType.notFound) return null;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<Object?, Object?>) throw const FormatException();
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in decoded.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      };
    } catch (error) {
      throw StateError(
        'Create & Push intent is unreadable at ${file.path}: $error',
      );
    }
  }

  RandomAccessFile acquireLock() {
    final File lockFile = File('${file.path}.lock');
    _safeFileType(lockFile, noun: 'Create & Push intent lock');
    final RandomAccessFile lock = lockFile.openSync(mode: FileMode.append);
    try {
      if (_safeFileType(lockFile, noun: 'Create & Push intent lock') !=
          FileSystemEntityType.file) {
        throw StateError('Create & Push intent lock was not created safely.');
      }
      lock.lockSync(FileLock.exclusive);
      return lock;
    } catch (error) {
      lock.closeSync();
      throw StateError(
        'Create & Push intent is active in another process: ${file.path} '
        '($error)',
      );
    }
  }

  void write(JsonObject json) {
    _recoverAtomicState(file);
    final File temporary = File('${file.path}.tmp');
    _safeFileType(temporary, noun: 'Create & Push intent temporary file');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      flush: true,
    );
    if (_safeFileType(temporary, noun: 'Create & Push intent temporary file') !=
        FileSystemEntityType.file) {
      throw StateError('Create & Push intent temporary file is unsafe.');
    }
    _replaceAtomically(temporary, file);
  }
}

File _intentFile(String metadataDirectoryPath, String intentId) {
  if (!RegExp(r'^multiplexor-push-[a-f0-9]{32}$').hasMatch(intentId)) {
    throw ArgumentError.value(intentId, 'intentId', 'is not canonical');
  }
  final Directory metadata = Directory(p.normalize(metadataDirectoryPath));
  if (!metadata.existsSync()) metadata.createSync(recursive: true);
  _requireRealDirectory(metadata, noun: 'Multiplexor metadata directory');
  final Directory transfers = Directory(
    p.join(metadata.path, 'pterodactyl-transfers'),
  );
  _createRealChildDirectory(transfers, noun: 'transfer metadata directory');
  final Directory intents = Directory(p.join(transfers.path, 'intents'));
  _createRealChildDirectory(intents, noun: 'transfer intent directory');
  return File(p.join(intents.path, '$intentId.json'));
}

void _recoverAtomicState(File destination) {
  final File temporary = File('${destination.path}.tmp');
  final File previous = File('${destination.path}.previous');
  final FileSystemEntityType destinationType = _safeFileType(
    destination,
    noun: 'Create & Push intent',
  );
  final FileSystemEntityType temporaryType = _safeFileType(
    temporary,
    noun: 'Create & Push intent temporary file',
  );
  final FileSystemEntityType previousType = _safeFileType(
    previous,
    noun: 'Create & Push intent recovery file',
  );
  if (destinationType == FileSystemEntityType.file &&
      _isJsonObject(destination)) {
    if (temporaryType == FileSystemEntityType.file) temporary.deleteSync();
    if (previousType == FileSystemEntityType.file) previous.deleteSync();
    return;
  }
  if (temporaryType == FileSystemEntityType.file && _isJsonObject(temporary)) {
    if (destinationType == FileSystemEntityType.file) destination.deleteSync();
    temporary.renameSync(destination.path);
    if (previousType == FileSystemEntityType.file) previous.deleteSync();
    return;
  }
  if (previousType == FileSystemEntityType.file && _isJsonObject(previous)) {
    if (destinationType == FileSystemEntityType.file) destination.deleteSync();
    previous.renameSync(destination.path);
    if (temporaryType == FileSystemEntityType.file) temporary.deleteSync();
    return;
  }
  if (destinationType == FileSystemEntityType.file ||
      temporaryType == FileSystemEntityType.file ||
      previousType == FileSystemEntityType.file) {
    throw StateError(
      'Create & Push intent atomic-write state is corrupt at '
      '${destination.path}.',
    );
  }
}

void _requireRealDirectory(Directory directory, {required String noun}) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    directory.path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.directory) {
    throw StateError('$noun must be a real directory: ${directory.path}');
  }
}

void _createRealChildDirectory(Directory directory, {required String noun}) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    directory.path,
    followLinks: false,
  );
  if (type == FileSystemEntityType.notFound) directory.createSync();
  _requireRealDirectory(directory, noun: noun);
}

FileSystemEntityType _safeFileType(File file, {required String noun}) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    file.path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw StateError('$noun must be a regular file: ${file.path}');
  }
  return type;
}

bool _isJsonObject(File file) {
  try {
    return jsonDecode(file.readAsStringSync()) is Map<Object?, Object?>;
  } catch (_) {
    return false;
  }
}

void _requireUniqueStableIntentJournal({
  required File selected,
  required String stableIdentityHash,
}) {
  final Directory directory = selected.parent;
  final String selectedPath = p.normalize(selected.path);
  final List<String> matches = <String>[];
  for (final FileSystemEntity entity in directory.listSync(
    followLinks: false,
  )) {
    final String basename = p.basename(entity.path);
    if (!RegExp(r'^multiplexor-push-[a-f0-9]{32}\.json$').hasMatch(basename)) {
      continue;
    }
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    try {
      final Object? decoded = jsonDecode(File(entity.path).readAsStringSync());
      if (decoded is Map<Object?, Object?> &&
          decoded['stable_identity_hash'] == stableIdentityHash) {
        matches.add(p.normalize(entity.path));
      }
    } catch (_) {
      // The selected journal is validated by its store. An unrelated corrupt
      // journal cannot claim this stable identity without its full digest.
    }
  }
  final List<String> conflicting = matches
      .where((String path) => path != selectedPath)
      .toList(growable: false);
  if (conflicting.isNotEmpty) {
    throw StateError(
      'Multiple durable Create & Push intents claim the same stable identity. '
      'No automatic recovery is safe; inspect ${<String>[selectedPath, ...conflicting].join(', ')}.',
    );
  }
}

void _rebindIntentApproval(
  JsonObject intent, {
  required String confirmationToken,
  required PterodactylTransferPlan transferPlan,
}) {
  intent
    ..['confirmation_token'] = confirmationToken
    ..['transfer_confirmation_token'] = transferPlan.confirmationToken
    ..['source_fingerprint'] = transferPlan.sourceFingerprint
    ..['updated_at'] = DateTime.now().toUtc().toIso8601String();
}

const List<String> _intentIdentityFields = <String>[
  'schema_version',
  'intent_id',
  'panel_external_id',
  'stable_identity_hash',
  'creation_configuration_hash',
  'profile_id',
  'local_instance_name',
  'local_consumer',
  'local_instance_path',
  'proposed_server_name',
  'creation_source_kind',
  'creation_source_identity',
  'start_after_transfer',
  'persist_new_link',
];

void _requireMatchingIntent(
  JsonObject actual,
  JsonObject expected,
  String path,
) {
  for (final String key in _intentIdentityFields) {
    if (actual[key] != expected[key]) {
      throw StateError(
        'Create & Push intent identity mismatch for $key at $path. No Panel '
        'mutation was attempted.',
      );
    }
  }
  _requiredString(actual, 'status');
}

void _requireRecordedServerIdentity(
  JsonObject record,
  PterodactylApplicationServer server,
  String path,
) {
  final Object? recordedUuid = record['server_uuid'];
  final Object? recordedId = record['server_id'];
  if (recordedUuid != null && recordedUuid != server.uuid ||
      recordedId != null && recordedId != server.id) {
    throw StateError(
      'Create & Push intent server identity does not match Panel external ID '
      '${server.externalId} at $path. No transfer was attempted.',
    );
  }
}

void _requireCreatedServerMatchesPlan(
  PterodactylApplicationServer server,
  PterodactylCreatePushPlan creation,
  String path,
) {
  final bool matches =
      server.externalId == creation.externalId &&
      server.name == creation.name &&
      server.ownerId == creation.ownerId &&
      server.nodeId == creation.nodeId &&
      server.eggId == creation.sourceEggId &&
      server.image == creation.dockerImage &&
      server.startup == creation.startup &&
      _mapsEqual(
        _effectiveEnvironment(server.environment),
        creation.environment,
      ) &&
      server.limits.memoryMiB == creation.memoryMiB &&
      server.limits.swapMiB == creation.swapMiB &&
      server.limits.diskMiB == creation.diskMiB &&
      server.limits.ioWeight == creation.ioWeight &&
      server.limits.cpuPercent == creation.cpuPercent &&
      server.limits.threads == creation.threads &&
      server.limits.oomDisabled == creation.oomDisabled &&
      server.featureLimits.databases == creation.databaseLimit &&
      server.featureLimits.allocations == creation.allocationLimit &&
      server.featureLimits.backups == creation.backupLimit &&
      server.skipScripts == creation.skipScripts;
  if (!matches) {
    throw StateError(
      'Panel server ${server.identifier} has external ID ${server.externalId}, '
      'but its immutable creation settings do not match the confirmed Create '
      '& Push plan. Inspect $path; no transfer was attempted.',
    );
  }
}

bool _mapsEqual(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final MapEntry<String, String> entry in left.entries) {
    if (right[entry.key] != entry.value || !right.containsKey(entry.key)) {
      return false;
    }
  }
  return true;
}

Map<String, String> _effectiveEnvironment(Map<String, String> environment) =>
    <String, String>{
      for (final MapEntry<String, String> entry in environment.entries)
        if (!entry.key.startsWith('P_SERVER_') && entry.key != 'STARTUP')
          entry.key: entry.value,
    };

String _requiredString(JsonObject json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw StateError('Create & Push intent field $key is invalid.');
  }
  return value;
}

String? _optionalString(JsonObject json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw StateError('Create & Push intent field $key is invalid.');
  }
  return value;
}

String _safeFailure(String value) {
  final String safe = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return safe.length <= 2000 ? safe : '${safe.substring(0, 2000)}...';
}

void _replaceAtomically(File temporary, File destination) {
  final File previous = File('${destination.path}.previous');
  final FileSystemEntityType temporaryType = _safeFileType(
    temporary,
    noun: 'Create & Push intent temporary file',
  );
  final FileSystemEntityType destinationType = _safeFileType(
    destination,
    noun: 'Create & Push intent',
  );
  final FileSystemEntityType previousType = _safeFileType(
    previous,
    noun: 'Create & Push intent recovery file',
  );
  if (previousType == FileSystemEntityType.file) {
    if (temporaryType == FileSystemEntityType.file) temporary.deleteSync();
    throw StateError('Create & Push intent recovery file already exists.');
  }
  bool movedPrevious = false;
  bool installedNew = false;
  try {
    if (destinationType == FileSystemEntityType.file) {
      destination.renameSync(previous.path);
      movedPrevious = true;
    }
    temporary.renameSync(destination.path);
    installedNew = true;
    if (movedPrevious &&
        _safeFileType(previous, noun: 'Create & Push intent recovery file') ==
            FileSystemEntityType.file) {
      previous.deleteSync();
    }
  } catch (_) {
    if (installedNew &&
        _safeFileType(destination, noun: 'Create & Push intent') ==
            FileSystemEntityType.file) {
      destination.deleteSync();
    }
    if (movedPrevious &&
        _safeFileType(previous, noun: 'Create & Push intent recovery file') ==
            FileSystemEntityType.file) {
      previous.renameSync(destination.path);
    }
    rethrow;
  } finally {
    if (_safeFileType(temporary, noun: 'Create & Push intent temporary file') ==
        FileSystemEntityType.file) {
      temporary.deleteSync();
    }
  }
}
