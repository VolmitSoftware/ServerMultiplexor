part of 'native_command_service.dart';

extension _NativeRecoveryCommands on NativeCommandService {
  Future<int> _dispatchInstanceUpdate(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    if (args.isEmpty) {
      throw _NativeCommandException(
        'Usage: instance update <name> [--mc <version>] [--jar <path>] [--auto-build]',
        2,
      );
    }
    final String name = _validateSimpleName(args.first, label: 'instance');
    final Map<String, String> options = _parseOptions(args.sublist(1));
    final _PreparedInstanceUpdate candidate = await _prepareInstanceUpdate(
      profile,
      name,
      options,
      io,
    );
    try {
      final bool wasRunning = await _recoveryIsRunning(profile, name);
      bool stopped = false;
      String? backupId;
      bool applied = false;
      try {
        if (wasRunning) {
          await _recoveryStop(profile, name, io);
          stopped = true;
        }
        backupId = await _backupCreate(
          profile,
          name,
          io,
          label: 'before-update',
          includeLogs: false,
          reason: 'update',
        );
        await _applyPreparedUpdate(profile, name, candidate, io);
        applied = true;
        if (wasRunning) {
          await _recoveryStart(profile, name, io);
          await _requireRecoveryReadiness(
            profile,
            name,
            const Duration(seconds: 90),
          );
          stopped = false;
        }
        io.write(
          '[OK] $name updated to ${candidate.type}${candidate.minecraft == null ? '' : ' mc=${candidate.minecraft}'}',
        );
        io.write('[INFO] Candidate SHA-256: ${candidate.sha256}');
        io.write('[INFO] Restore point: backup restore $name $backupId');
        return 0;
      } catch (_) {
        if (applied && backupId != null) {
          stopped = false;
          await _rollbackUpdate(profile, name, backupId, wasRunning, io);
        } else if (stopped) {
          stopped = false;
          await _recoveryStart(profile, name, io);
        }
        rethrow;
      }
    } finally {
      candidate.dispose();
    }
  }

  Future<int> _dispatchInstanceSafeUpdate(
    ConsumerProfile profile,
    List<String> args,
    _NativeIoBuffer io,
  ) async {
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args,
      booleanFlags: const <String>{
        'auto-build',
        'promote',
        'cleanup',
        'keep-staging',
      },
    );
    if (parsed.positionals.length != 1) {
      throw _NativeCommandException(
        'Usage: instance safe-update <name> [--mc <version>] [--jar <path>] [--auto-build] [--promote] [--cleanup] [--timeout <seconds>]',
        2,
      );
    }
    final String name = _validateSimpleName(
      parsed.positionals.single,
      label: 'instance',
    );
    final int? timeoutSeconds = int.tryParse(parsed.option('timeout') ?? '90');
    if (timeoutSeconds == null || timeoutSeconds < 5) {
      throw _NativeCommandException('--timeout must be at least 5 seconds', 2);
    }
    final Duration timeout = Duration(seconds: timeoutSeconds);
    final Map<String, String> options = <String, String>{
      ...parsed.options,
      if (parsed.flag('auto-build')) 'auto-build': 'true',
    };
    final _PreparedInstanceUpdate candidate = await _prepareInstanceUpdate(
      profile,
      name,
      options,
      io,
    );
    final bool promote = parsed.flag('promote');
    final bool cleanup =
        parsed.flag('cleanup') || (promote && !parsed.flag('keep-staging'));
    String? staging;
    String? backupId;
    bool needsOriginalResume = false;
    bool promotionApplied = false;
    bool wasRunning = false;
    try {
      wasRunning = await _recoveryIsRunning(profile, name);
      if (wasRunning) {
        await _recoveryStop(profile, name, io);
        needsOriginalResume = true;
      }
      backupId = await _backupCreate(
        profile,
        name,
        io,
        label: parsed.option('label') ?? 'safe-update',
        includeLogs: false,
        reason: 'safe-update',
      );
      staging = _uniqueInstanceName(
        profile,
        _sanitizeSimpleName('$name-safe-update-${_timestampId()}'),
      );
      final _BackupEntry backup = _findBackup(
        profile,
        backupId,
        instance: name,
      );
      _backupVerify(backup);
      final Directory stagingDirectory = Directory(
        _instanceDir(profile, staging),
      );
      RecoverySnapshot.copy(
        Directory(p.join(backup.path, 'snapshot')),
        stagingDirectory,
      );
      final Map<String, String> stagingSource = Map<String, String>.from(
        _serverSource(profile, staging),
      )..['isolated'] = 'true';
      _writeServerSource(stagingDirectory.path, fields: stagingSource);
      _instanceSetServerPort(
        profile,
        staging,
        await _findAvailableServerPort(
          profile,
          staging,
          avoidPorts: <int>{_instanceGetServerPort(profile, name)},
        ),
      );
      _setRecoveryProperty(stagingDirectory.path, 'server-ip', '127.0.0.1');
      _instanceEnsureRestartScript(profile, staging);
      io.write('[INFO] Staging clone: $staging (isolated, loopback only)');
      io.write('[INFO] Candidate SHA-256: ${candidate.sha256}');
      io.write('[INFO] Safety backup: $backupId');
      if (needsOriginalResume) {
        await _recoveryStart(profile, name, io);
        needsOriginalResume = false;
      }
      await _applyPreparedUpdate(profile, staging, candidate, io);
      await _recoveryStart(profile, staging, io);
      final MinecraftPingResult ping = await _requireRecoveryReadiness(
        profile,
        staging,
        timeout,
      );
      await _recoveryStop(profile, staging, io);
      io.write(
        '[OK] Staging answered Minecraft status: ${ping.versionName}. Plugin loading and gameplay were not tested.',
      );
      candidate.verify();
      if (promote) {
        if (await _recoveryIsRunning(profile, name)) {
          await _recoveryStop(profile, name, io);
          needsOriginalResume = wasRunning;
        }
        // The original may have accepted world changes during staging.
        backupId = await _backupCreate(
          profile,
          name,
          io,
          label: 'before-promotion',
          includeLogs: false,
          reason: 'safe-update-promotion',
        );
        await _applyPreparedUpdate(profile, name, candidate, io);
        promotionApplied = true;
        await _recoveryStart(profile, name, io);
        await _requireRecoveryReadiness(profile, name, timeout);
        if (!wasRunning) await _recoveryStop(profile, name, io);
        needsOriginalResume = false;
        io.write(
          '[OK] Promoted verified candidate to $name; Minecraft status answered.',
        );
        promotionApplied = false;
      } else {
        io.write(
          '[INFO] Original launch artifacts unchanged. Staging instance kept stopped: $staging',
        );
      }
      if (cleanup) {
        await _instanceDelete(profile, staging, io: io);
        io.write('[OK] Removed staging instance: $staging');
      }
      io.write('[INFO] Restore point: backup restore $name $backupId');
      return 0;
    } catch (error) {
      if (promotionApplied && backupId != null) {
        needsOriginalResume = false;
        await _rollbackUpdate(profile, name, backupId, wasRunning, io);
      } else if (needsOriginalResume) {
        needsOriginalResume = false;
        await _recoveryStart(profile, name, io);
      }
      if (staging != null) {
        io.error('[WARN] Staging kept for inspection: $staging');
      }
      if (backupId != null) {
        io.write('[INFO] Restore point: backup restore $name $backupId');
      }
      rethrow;
    } finally {
      // A failed candidate is kept on disk for inspection, but should not
      // continue using memory or running its plugins in the background.
      if (staging != null && await _recoveryIsRunning(profile, staging)) {
        try {
          await _recoveryStop(profile, staging, io);
        } catch (error) {
          io.error(
            '[WARN] Staging could not stop gracefully: $staging ($error)',
          );
        }
      }
      candidate.dispose();
    }
  }

  void _setRecoveryProperty(String directory, String key, String value) {
    final File properties = File(p.join(directory, 'server.properties'));
    final List<String> lines = properties.existsSync()
        ? properties.readAsLinesSync()
        : <String>[];
    lines.removeWhere((String line) => line.trimLeft().startsWith('$key='));
    lines.add('$key=$value');
    properties.writeAsStringSync('${lines.join('\n')}\n');
  }

  Future<_PreparedInstanceUpdate> _prepareInstanceUpdate(
    ConsumerProfile profile,
    String name,
    Map<String, String> options,
    _NativeIoBuffer io,
  ) async {
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    _ensureUnlocked(profile, name, action: 'updated');
    final Map<String, String> source = _serverSource(profile, name);
    final String type = (options['type'] ?? source['type'] ?? 'custom')
        .toLowerCase();
    _ensureConsumerOwnsServerType(profile, type, command: 'instance update');
    final String? explicit = options['jar'];
    String? minecraft = options['mc'];
    final String sourcePath;
    if (explicit != null && explicit.isNotEmpty) {
      if (!File(explicit).existsSync()) {
        throw _NativeCommandException('Jar not found: $explicit', 2);
      }
      sourcePath = File(explicit).resolveSymbolicLinksSync();
      minecraft = inferServerMinecraftVersion(
        serverType: type,
        minecraft: minecraft,
        jarPaths: <String>[sourcePath],
      );
    } else {
      minecraft ??= await _resolveLatestMcVersion(type);
      String? cached = _findCachedJar(
        profile,
        type: type,
        mc: minecraft,
        allowLatestFallback: false,
      );
      if (options['auto-build'] == 'true' || cached == null) {
        cached = await _buildTarget(
          profile,
          type,
          _serverCreateBuildOptions(options, minecraft),
          io,
        );
      }
      sourcePath = File(cached).resolveSymbolicLinksSync();
    }
    if (!sourcePath.toLowerCase().endsWith('.jar')) {
      throw _NativeCommandException('Update artifact must be a .jar file', 2);
    }
    final bool installer =
        (type == 'forge' || type == 'neoforge') &&
        (_looksLikeInstallerJar(sourcePath) || source['launch'] == 'argsfile');
    final String java = await _runtimeJavaPreflight(
      profile,
      name,
      minecraft: minecraft,
    );
    final Directory directory = Directory.systemTemp.createTempSync(
      'multiplexor-update-',
    );
    try {
      final Directory payload = Directory(p.join(directory.path, 'payload'))
        ..createSync();
      final File artifact = File(sourcePath).copySync(
        p.join(payload.path, installer ? 'installer.jar' : 'server.jar'),
      );
      final String artifactHash = await _sha256FileStreamed(artifact);
      String? argsFile;
      if (installer) {
        final CapturedResult result = await _processRunner.runCaptured(
          java,
          <String>['-jar', artifact.path, '--installServer', '.'],
          workingDirectory: payload.path,
        );
        if (result.exitCode != 0) {
          throw _NativeCommandException(
            'Update installer failed before changing $name: ${result.stderr}',
            1,
          );
        }
        argsFile = _findInstalledServerArgsFile(payload.path);
        if (argsFile == null || !_safeRecoveryRelativePath(argsFile)) {
          throw _NativeCommandException(
            'Update installer did not produce a local server argsfile',
            1,
          );
        }
      }
      final List<Map<String, Object>> entries = RecoverySnapshot.entries(
        payload,
      );
      final _PreparedInstanceUpdate candidate = _PreparedInstanceUpdate(
        directory: directory,
        payload: payload,
        type: type,
        minecraft: minecraft,
        sha256: artifactHash,
        argsFile: argsFile,
        entries: entries,
      );
      candidate.verify();
      io.write(
        '[INFO] Prepared ${installer ? 'installer' : 'jar'} update before stopping $name',
      );
      return candidate;
    } catch (_) {
      directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<void> _applyPreparedUpdate(
    ConsumerProfile profile,
    String name,
    _PreparedInstanceUpdate candidate,
    _NativeIoBuffer io,
  ) async {
    candidate.verify();
    if (await _recoveryIsRunning(profile, name)) {
      throw _NativeCommandException(
        'Update requires a stopped instance: $name',
        2,
      );
    }
    final Directory target = Directory(_instanceDir(profile, name));
    final Directory prepared = Directory(
      p.join('${target.parent.path}.recovery', '$name-update-${_newPinSalt()}'),
    );
    try {
      RecoverySnapshot.copy(target, prepared);
      final Map<String, String> source = Map<String, String>.from(
        _serverSource(profile, name),
      );
      final bool replaceInstallerArtifacts =
          candidate.argsFile != null || source['launch'] == 'argsfile';
      if (replaceInstallerArtifacts) {
        for (final String artifact in <String>[
          'libraries',
          'versions',
          'server.jar',
          'installer.jar',
          'run.sh',
          'run.bat',
          'user_jvm_args.txt',
        ]) {
          _deletePathEntity(p.join(prepared.path, artifact), recursive: true);
        }
        final String? oldArgs = source['args_file_rel'];
        if (oldArgs != null && _safeRecoveryRelativePath(oldArgs)) {
          _deletePathEntity(p.join(prepared.path, oldArgs), recursive: false);
        }
      }
      for (final String key in <String>[
        'jar',
        'jar_rel',
        'installer',
        'args_file_rel',
      ]) {
        source.remove(key);
      }
      source['type'] = candidate.type;
      source.remove('mc');
      if (candidate.minecraft != null) source['mc'] = candidate.minecraft!;
      source['artifact_sha256'] = candidate.sha256;
      if (candidate.argsFile != null) {
        _copyDirectory(candidate.payload, prepared);
        source['launch'] = 'argsfile';
        source['args_file_rel'] = candidate.argsFile!;
      } else {
        final String managed = await _importManagedLaunchJar(
          profile,
          p.join(candidate.payload.path, 'server.jar'),
        );
        _replaceWithSymlink(p.join(prepared.path, 'server.jar'), managed);
        source['launch'] = 'jar';
        source['jar'] = managed;
      }
      candidate.verify();
      _writeServerSource(prepared.path, fields: source);
      RecoverySnapshot.replace(
        prepared,
        target,
        afterInstall: () {
          _finishRecoveryInstall(profile, name, io);
        },
      );
      io.write('[INFO] Applied candidate SHA-256: ${candidate.sha256}');
    } finally {
      if (prepared.existsSync()) prepared.deleteSync(recursive: true);
    }
  }

  void _finishRecoveryInstall(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) {
    _instanceEnsureRestartScript(profile, instance);
    if (!_instanceIsolated(profile, instance)) {
      if (_isPluginConsumer(profile)) _irisPacksLinkInstance(profile, instance);
      _instanceEnsureSharedPluginOps(profile, instance, io: io);
    }
    if (_currentInstance(profile) == instance) {
      _instanceActivate(profile, instance);
    }
  }

  Future<void> _rollbackUpdate(
    ConsumerProfile profile,
    String name,
    String backupId,
    bool wasRunning,
    _NativeIoBuffer io,
  ) async {
    io.error('[WARN] Update failed; restoring $name from $backupId');
    if (await _recoveryIsRunning(profile, name)) {
      await _recoveryStop(profile, name, io);
    }
    await _backupRestore(profile, name, backupId, io);
    if (wasRunning) {
      await _recoveryStart(profile, name, io);
      await _requireRecoveryReadiness(
        profile,
        name,
        const Duration(seconds: 90),
      );
    }
    io.write('[OK] Restored previous instance state: $name');
  }

  Future<bool> _recoveryIsRunning(ConsumerProfile profile, String instance) =>
      _recoveryRuntimeOverride?.isRunning(profile, instance) ??
      _runtimeRunning(profile, instance);
  Future<void> _recoveryStop(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) =>
      _recoveryRuntimeOverride?.stopGracefully(profile, instance) ??
      _runtimeStop(profile, instance, io, requireGraceful: true);
  Future<void> _recoveryStart(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io,
  ) =>
      _recoveryRuntimeOverride?.start(profile, instance) ??
      _runtimeStart(profile, instance, io);
  Future<MinecraftPingResult> _requireRecoveryReadiness(
    ConsumerProfile profile,
    String instance,
    Duration timeout,
  ) async {
    final MinecraftPingResult? result =
        await (_recoveryRuntimeOverride?.waitUntilReady(
              profile,
              instance,
              timeout,
            ) ??
            _awaitMinecraftPing(profile, instance, timeout: timeout));
    if (result == null || !await _recoveryIsRunning(profile, instance)) {
      throw _NativeCommandException(
        '$instance did not become ready within ${timeout.inSeconds}s',
        1,
      );
    }
    return result;
  }

  Future<int> _dispatchBackup(List<String> args, _NativeIoBuffer io) async {
    final sub = args.isEmpty ? 'list' : args.first;
    final rest = args.isEmpty ? const <String>[] : args.sublist(1);
    final profile = _activeConsumer;

    switch (sub) {
      case 'create':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'include-logs'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: backup create [instance] [--label <label>] [--include-logs]',
            2,
          );
        }
        final instance = parsed.positionals.isNotEmpty
            ? parsed.positionals.first
            : _currentInstance(profile);
        if (instance == null || instance.isEmpty) {
          throw _NativeCommandException('No active instance set', 2);
        }
        final id = await _backupCreate(
          profile,
          instance,
          io,
          label: parsed.option('label'),
          includeLogs: parsed.flag('include-logs'),
          reason: 'manual',
        );
        io.write('[OK] Backup created: $id');
        return 0;
      case 'list':
        final parsed = _parseFlexibleArgs(
          rest,
          booleanFlags: const <String>{'all'},
        );
        if (parsed.positionals.length > 1) {
          throw _NativeCommandException(
            'Usage: backup list [instance|--all]',
            2,
          );
        }
        final target = parsed.flag('all')
            ? null
            : (parsed.positionals.isNotEmpty ? parsed.positionals.first : null);
        _backupList(profile, target, io);
        return 0;
      case 'restore':
        final parsed = _parseFlexibleArgs(rest);
        String? instance;
        String? id;
        if (parsed.positionals.length == 1) {
          id = parsed.positionals[0];
          instance = parsed.option('instance') ?? _currentInstance(profile);
        } else if (parsed.positionals.length == 2) {
          instance = parsed.positionals[0];
          id = parsed.positionals[1];
        }
        if (instance == null || id == null) {
          throw _NativeCommandException(
            'Usage: backup restore [instance] <backup-id>',
            2,
          );
        }
        await _backupRestore(profile, instance, id, io);
        io.write('[OK] Restored $instance from backup $id');
        return 0;
      case 'delete':
        final parsed = _parseFlexibleArgs(rest);
        final (instance, id) = _backupResolveInstanceAndId(parsed);
        final backup = _findBackup(profile, id, instance: instance);
        _deletePathEntity(backup.path, recursive: true);
        io.write('[OK] Deleted backup: ${backup.instance}/${backup.id}');
        return 0;
      case 'verify':
        final parsed = _parseFlexibleArgs(rest);
        final (instance, id) = _backupResolveInstanceAndId(parsed);
        final backup = _findBackup(profile, id, instance: instance);
        _backupVerify(backup);
        io.write('[OK] Backup verified: ${backup.instance}/${backup.id}');
        return 0;
      case 'prune':
        final parsed = _parseFlexibleArgs(rest);
        final keepRaw = parsed.option('keep') ?? '10';
        final keep = int.tryParse(keepRaw);
        if (keep == null || keep < 0) {
          throw _NativeCommandException(
            '--keep must be a non-negative integer',
            2,
          );
        }
        final instance = parsed.positionals.isEmpty
            ? null
            : parsed.positionals.first;
        final deleted = _backupPrune(profile, keep: keep, instance: instance);
        io.write('[OK] Pruned $deleted backup(s)');
        return 0;
      default:
        throw _NativeCommandException(
          'Usage: backup <create|list|restore|delete|prune|verify> ...',
          2,
        );
    }
  }

  String _backupsDir(ConsumerProfile profile) {
    return p.join(_consumerRoot(profile), 'backups');
  }

  Future<String> _backupCreate(
    ConsumerProfile profile,
    String instance,
    _NativeIoBuffer io, {
    String? label,
    required bool includeLogs,
    required String reason,
  }) async {
    _validateSimpleName(instance, label: 'instance');
    if (!_instanceExists(profile, instance)) {
      throw _NativeCommandException('Instance not found: $instance', 2);
    }
    if (await _recoveryIsRunning(profile, instance) ||
        _runtimeRestartPending(profile, instance)) {
      throw _NativeCommandException(
        'Backup requires a stopped instance. Stop $instance before creating its backup.',
        2,
      );
    }
    final String safeLabel = label == null || label.trim().isEmpty
        ? ''
        : '-${_sanitizeSimpleName(label, fallback: 'backup')}';
    final String id = '${_timestampId()}$safeLabel';
    final Directory completed = Directory(
      p.join(_backupsDir(profile), instance, id),
    );
    final Directory pending = Directory(
      '${completed.path}.partial-${_newPinSalt()}',
    );
    final Directory snapshot = Directory(p.join(pending.path, 'snapshot'));
    try {
      RecoverySnapshot.copy(
        Directory(_instanceDir(profile, instance)),
        snapshot,
        includeLogs: includeLogs,
      );
      _localizeRecoveryLaunch(profile, instance, snapshot);
      final Map<String, Object> manifest = <String, Object>{
        'version': RecoverySnapshot.version,
        'id': id,
        'consumer': profile.shortName,
        'instance': instance,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'label': label?.trim() ?? '',
        'reason': reason,
        'include_logs': includeLogs,
        'snapshot': 'snapshot',
        'entries': RecoverySnapshot.entries(snapshot),
      };
      File(p.join(pending.path, 'manifest.json')).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      );
      pending.renameSync(completed.path);
      io.write('[INFO] Backup path: ${completed.path}');
      return id;
    } finally {
      if (pending.existsSync()) pending.deleteSync(recursive: true);
    }
  }

  void _localizeRecoveryLaunch(
    ConsumerProfile profile,
    String instance,
    Directory snapshot,
  ) {
    final Map<String, String> source = Map<String, String>.from(
      _serverSource(profile, instance),
    );
    if (source['launch'] == 'jar') {
      final _LaunchTarget launch = _runtimeLaunchTarget(profile, instance);
      final File sourceJar = File(launch.path);
      if (!sourceJar.existsSync()) {
        throw _NativeCommandException(
          'Recovery launch dependency is missing: ${launch.path}',
          1,
        );
      }
      sourceJar.copySync(p.join(snapshot.path, 'server.jar'));
      source.remove('jar');
      source['jar_rel'] = 'server.jar';
    } else if (source['launch'] == 'argsfile') {
      final String relative = source['args_file_rel'] ?? '';
      if (!_safeRecoveryRelativePath(relative) ||
          !File(p.join(snapshot.path, relative)).existsSync()) {
        throw _NativeCommandException(
          'Recovery argsfile is missing or outside the instance',
          1,
        );
      }
    }
    source.remove('installer');
    if (source.isNotEmpty) _writeServerSource(snapshot.path, fields: source);
  }

  bool _safeRecoveryRelativePath(String value) =>
      value.isNotEmpty &&
      !p.isAbsolute(value) &&
      p.normalize(value) == value &&
      !p.split(value).contains('..');

  String _sha256File(File file) {
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  List<_BackupEntry> _backupEntries(
    ConsumerProfile profile, {
    String? instance,
  }) {
    if (instance != null) _validateSimpleName(instance, label: 'instance');
    final root = Directory(_backupsDir(profile));
    if (!root.existsSync()) {
      return const <_BackupEntry>[];
    }
    final entries = <_BackupEntry>[];
    final instanceDirs = instance != null
        ? <Directory>[Directory(p.join(root.path, instance))]
        : root.listSync(followLinks: false).whereType<Directory>().toList();
    for (final instanceDir in instanceDirs) {
      if (!instanceDir.existsSync()) {
        continue;
      }
      final instanceName = p.basename(instanceDir.path);
      for (final backupDir
          in instanceDir.listSync(followLinks: false).whereType<Directory>()) {
        if (p.basename(backupDir.path).contains('.partial-')) continue;
        entries.add(
          _BackupEntry(
            profile: profile,
            instance: instanceName,
            id: p.basename(backupDir.path),
            path: backupDir.path,
          ),
        );
      }
    }
    entries.sort((a, b) {
      final byInstance = a.instance.compareTo(b.instance);
      return byInstance != 0 ? byInstance : b.id.compareTo(a.id);
    });
    return entries;
  }

  void _backupList(
    ConsumerProfile profile,
    String? instance,
    _NativeIoBuffer io,
  ) {
    final entries = _backupEntries(profile, instance: instance);
    if (entries.isEmpty) {
      io.write('(none)');
      return;
    }
    for (final entry in entries) {
      final manifest = entry.manifest;
      final label = manifest['label']?.toString().trim() ?? '';
      final created = manifest['created_at']?.toString().trim() ?? entry.id;
      final suffix = label.isEmpty ? '' : ' label=$label';
      io.write('${entry.instance}/${entry.id}  $created$suffix');
    }
  }

  (String?, String) _backupResolveInstanceAndId(_FlexibleArgs parsed) {
    if (parsed.positionals.length == 1) {
      return (parsed.option('instance'), parsed.positionals.first);
    }
    if (parsed.positionals.length == 2) {
      return (parsed.positionals.first, parsed.positionals[1]);
    }
    throw _NativeCommandException(
      'Usage: backup <delete|verify> [instance] <backup-id>',
      2,
    );
  }

  _BackupEntry _findBackup(
    ConsumerProfile profile,
    String id, {
    String? instance,
  }) {
    if (id.contains('/') || id.contains('\\') || id.contains('..')) {
      throw _NativeCommandException('Invalid backup id: $id', 2);
    }
    final matches = _backupEntries(
      profile,
      instance: instance,
    ).where((entry) => entry.id == id).toList(growable: false);
    if (matches.isEmpty) {
      throw _NativeCommandException('Backup not found: $id', 2);
    }
    if (matches.length > 1) {
      throw _NativeCommandException(
        'Backup id $id exists for multiple instances. Use: backup <command> <instance> $id',
        2,
      );
    }
    return matches.single;
  }

  Future<void> _backupRestore(
    ConsumerProfile profile,
    String instance,
    String id,
    _NativeIoBuffer io,
  ) async {
    _validateSimpleName(instance, label: 'instance');
    final _BackupEntry backup = _findBackup(profile, id, instance: instance);
    _backupVerify(backup);
    if (_instanceExists(profile, instance)) {
      _ensureUnlocked(profile, instance, action: 'restored');
    }
    final Directory target = Directory(_instanceDir(profile, instance));
    final Directory prepared = Directory(
      p.join(
        '${target.parent.path}.recovery',
        '$instance-restore-${_newPinSalt()}',
      ),
    );
    bool resumeOnFailure = false;
    try {
      RecoverySnapshot.copy(
        Directory(p.join(backup.path, 'snapshot')),
        prepared,
      );
      RecoverySnapshot.verify(prepared, backup.manifest['entries']);
      if (await _recoveryIsRunning(profile, instance)) {
        await _recoveryStop(profile, instance, io);
        resumeOnFailure = true;
      }
      RecoverySnapshot.replace(
        prepared,
        target,
        afterInstall: () {
          _finishRecoveryInstall(profile, instance, io);
        },
      );
      resumeOnFailure = false;
    } catch (_) {
      if (resumeOnFailure && target.existsSync()) {
        await _recoveryStart(profile, instance, io);
      }
      rethrow;
    } finally {
      if (prepared.existsSync()) prepared.deleteSync(recursive: true);
    }
  }

  void _backupVerify(_BackupEntry backup) {
    final Map<String, dynamic> manifest = backup.manifest;
    if (manifest['version'] != RecoverySnapshot.version ||
        manifest['snapshot'] != 'snapshot' ||
        manifest['id'] != backup.id ||
        manifest['instance'] != backup.instance ||
        manifest['consumer'] != backup.profile.shortName) {
      throw _NativeCommandException(
        'Invalid backup manifest: ${backup.path}',
        1,
      );
    }
    final Directory snapshot = Directory(p.join(backup.path, 'snapshot'));
    try {
      RecoverySnapshot.verify(snapshot, manifest['entries']);
    } on FormatException catch (error) {
      throw _NativeCommandException(error.message, 1);
    }
    final File sourceFile = File(p.join(snapshot.path, '.server-source'));
    if (!sourceFile.existsSync()) return;
    final Map<String, String> source = <String, String>{};
    for (final String line in sourceFile.readAsLinesSync()) {
      final int split = line.indexOf('=');
      if (split > 0) {
        source[line.substring(0, split)] = line.substring(split + 1);
      }
    }
    if (source['launch'] == 'jar' || source['launch'] == 'argsfile') {
      final String relative =
          source[source['launch'] == 'jar' ? 'jar_rel' : 'args_file_rel'] ?? '';
      if (!_safeRecoveryRelativePath(relative) ||
          !File(p.join(snapshot.path, relative)).existsSync() ||
          source.containsKey('jar') ||
          source.containsKey('installer')) {
        throw _NativeCommandException(
          'Backup has an invalid launch dependency',
          1,
        );
      }
    }
  }

  int _backupPrune(
    ConsumerProfile profile, {
    required int keep,
    String? instance,
  }) {
    final byInstance = <String, List<_BackupEntry>>{};
    for (final entry in _backupEntries(profile, instance: instance)) {
      byInstance.putIfAbsent(entry.instance, () => <_BackupEntry>[]).add(entry);
    }
    var deleted = 0;
    for (final entries in byInstance.values) {
      entries.sort((a, b) => b.id.compareTo(a.id));
      for (final entry in entries.skip(keep)) {
        _deletePathEntity(entry.path, recursive: true);
        deleted++;
      }
    }
    return deleted;
  }
}

class _PreparedInstanceUpdate {
  const _PreparedInstanceUpdate({
    required this.directory,
    required this.payload,
    required this.type,
    required this.minecraft,
    required this.sha256,
    required this.argsFile,
    required this.entries,
  });
  final Directory directory;
  final Directory payload;
  final String type;
  final String? minecraft;
  final String sha256;
  final String? argsFile;
  final List<Map<String, Object>> entries;
  void verify() => RecoverySnapshot.verify(payload, entries);
  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
