part of 'native_command_service.dart';

extension _NativeAddonCommands on NativeCommandService {
  Future<int> _dispatchAddons(List<String> args, _NativeIoBuffer io) async {
    final String command = args.isEmpty ? 'list' : args.first;
    final _FlexibleArgs parsed = _parseFlexibleArgs(
      args.isEmpty ? const <String>[] : args.sublist(1),
      booleanFlags: const <String>{'json', 'none'},
    );
    final Set<String> options = switch (command) {
      'catalog' => <String>{},
      'list' || 'update' => <String>{'mc'},
      'set' => <String>{'mc', 'select'},
      _ => throw _NativeCommandException(
        'Usage: addons <catalog|list|set|update>',
        2,
      ),
    };
    final Set<String> flags = switch (command) {
      'catalog' || 'list' => <String>{'json'},
      'set' => <String>{'none'},
      _ => <String>{},
    };
    if (parsed.options.keys.any((String key) => !options.contains(key)) ||
        parsed.flags.keys.any((String key) => !flags.contains(key)) ||
        parsed.positionals.length > (command == 'catalog' ? 0 : 1)) {
      throw _NativeCommandException(
        'Invalid addons arguments. Run help addons.',
        2,
      );
    }
    final AddonCatalog catalog = AddonCatalog.load(context.rootDir);
    if (command == 'catalog') {
      final List<Map<String, Object?>> entries = catalog.entries.values
          .map((AddonDefinition addon) => addon.toJson())
          .toList();
      if (parsed.flag('json')) {
        io.write(jsonEncode(<String, Object?>{'entries': entries}));
      } else {
        for (final AddonDefinition addon in catalog.entries.values) {
          io.write('${addon.id}\t${addon.name}\t${addon.description}');
        }
        io.write(
          '[INFO] Custom catalog: ${p.join(context.metadataDir, 'addons.json')}',
        );
      }
      return 0;
    }
    final ConsumerProfile profile = _activeConsumer;
    final String? target =
        parsed.positionals.firstOrNull ?? _currentInstance(profile);
    if (target == null) {
      throw _NativeCommandException(
        'No active instance. Supply an instance name.',
        2,
      );
    }
    final String name = _validateSimpleName(target, label: 'instance');
    if (!_instanceExists(profile, name)) {
      throw _NativeCommandException('Instance not found: $name', 2);
    }
    final Map<String, String> metadata = _serverSource(profile, name);
    final String serverType = metadata['type'] ?? 'custom';
    final String minecraft =
        parsed.option('mc')?.trim() ?? metadata['mc']?.trim() ?? '';
    final String instancePath = _instanceDir(profile, name);
    final AddonInstaller installer = AddonInstaller(
      workspace: context.rootDir,
      instancePath: instancePath,
      serverType: serverType,
      minecraft: minecraft,
      catalog: catalog,
    );
    if (command == 'list') {
      final Map<String, Object?> result = installer.list(name);
      if (parsed.flag('json')) {
        io.write(jsonEncode(result));
      } else {
        for (final Object? raw in result['entries']! as List<Object?>) {
          final Map<String, Object?> addon = addonObject(raw);
          io.write(
            '${addon['selected'] == true ? '[x]' : '[ ]'} ${addon['id']}  ${addon['name']}${addon['available'] == true ? '' : '  (${addon['reason']})'}',
          );
        }
      }
      return 0;
    }
    Future<void> requireStopped() async {
      if (await _runtimeStateOf(profile, name) != RuntimeState.stopped) {
        throw _NativeCommandException(
          'Stop $name before changing addons: runtime stop $name',
          2,
        );
      }
      if (jsonEncode(_serverSource(profile, name)) != jsonEncode(metadata)) {
        throw _NativeCommandException(
          'Server metadata changed during addon installation. Retry.',
          2,
        );
      }
    }

    await requireStopped();
    final Set<String> selection;
    if (command == 'update') {
      selection = AddonState.read(instancePath).entries.keys.toSet();
    } else {
      final String? selected = parsed.option('select');
      if ((selected == null) == !parsed.flag('none') ||
          selected != null && selected.trim().isEmpty) {
        throw _NativeCommandException(
          'Usage: addons set [instance] (--select <id,id,...>|--none) [--mc <version>]',
          2,
        );
      }
      selection = selected == null
          ? <String>{}
          : selected.split(',').map((String id) => id.trim()).toSet();
    }
    final Set<String> installed = await installer.apply(
      selection,
      report: io.write,
      beforeCommit: requireStopped,
      commit: (void Function() operation) =>
          _withDropinSyncLock(profile, name, operation),
      update: command == 'update',
    );
    io.write(
      '[OK] Addons for $name: ${installed.isEmpty ? 'none' : installed.join(', ')}',
    );
    return 0;
  }
}
