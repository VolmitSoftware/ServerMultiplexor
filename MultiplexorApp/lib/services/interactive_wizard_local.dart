part of 'interactive_wizard.dart';

extension _LocalWizard on InteractiveWizard {
  Future<void> _instanceBackups(String name) async {
    while (true) {
      final List<BackupSummary> backups = passthrough.listBackups(name);
      final String choice =
          await menuSelect<String>('Backups for $name', <MenuEntry<String>>[
            const MenuEntry<String>(
              'Create backup',
              value: '',
              detail: 'Requires a stopped server',
            ),
            for (final BackupSummary backup in backups)
              MenuEntry<String>(
                backup.id,
                value: backup.id,
                detail: backup.label.isEmpty
                    ? backup.createdAt.toLocal().toString()
                    : backup.label,
              ),
            const MenuEntry<String>('Back to dashboard', value: 'back'),
          ]);
      if (choice == 'back') return;
      if (choice.isEmpty) {
        final String label = await Ui.input('Backup label (optional)');
        await _shellRun(<String>[
          'backup',
          'create',
          name,
          if (label.isNotEmpty) ...<String>['--label', label],
        ]);
        await Ui.pause();
        continue;
      }
      final String action =
          await menuSelect<String>(choice, const <MenuEntry<String>>[
            MenuEntry<String>('Verify backup', value: 'verify'),
            MenuEntry<String>(
              'Restore backup',
              value: 'restore',
              detail: 'Replaces current instance data',
            ),
            MenuEntry<String>('Back to backups', value: 'back'),
          ]);
      if (action == 'back') continue;
      if (action == 'restore' &&
          !await Ui.confirm(
            'Restore $name from $choice? Current worlds and settings will be replaced.',
            defaultValue: false,
          )) {
        continue;
      }
      await _shellRun(<String>['backup', action, name, choice]);
      await Ui.pause();
    }
  }

  Future<void> _createFromTemplate() async {
    final ConsumerProfile profile = _activeConsumer();
    final List<TemplateSummary> templates = passthrough.listTemplates().where((
      TemplateSummary template,
    ) {
      final ConsumerProfile? owner = switch (template.type) {
        'forge' || 'mohist' => ConsumerProfile.forge,
        'fabric' => ConsumerProfile.fabric,
        'neoforge' => ConsumerProfile.neoforge,
        'custom' => null,
        _ => ConsumerProfile.plugin,
      };
      return owner == null || owner == profile;
    }).toList();
    if (templates.isEmpty) {
      Ui.note(
        'No templates for ${profile.shortName}. Export a stopped instance from its Runtime menu, or use template init.',
      );
      await Ui.pause();
      return;
    }
    while (true) {
      final String
      selected = await menuSelect<String>('Templates', <MenuEntry<String>>[
        for (final TemplateSummary template in templates)
          MenuEntry<String>(
            template.name,
            value: template.name,
            detail: template.description.isNotEmpty
                ? template.description
                : '${template.type} ${template.minecraft ?? 'version not set'}',
          ),
        const MenuEntry<String>('Back to dashboard', value: ''),
      ]);
      if (selected.isEmpty) return;
      final TemplateSummary template = templates.firstWhere(
        (TemplateSummary candidate) => candidate.name == selected,
      );
      if (await _useTemplate(template)) return;
    }
  }

  Future<bool> _useTemplate(TemplateSummary template) async {
    final bool network = template.kind == 'network';
    while (true) {
      Ui.keyValue('Template', template.name);
      Ui.keyValue(
        'Source',
        template.bundled ? 'Bundled example' : 'Saved YAML',
      );
      if (template.description.isNotEmpty) Ui.note(template.description);
      Ui.keyValue(
        'Creates',
        network
            ? '${template.backendCount} backend servers and a Velocity proxy'
            : 'One ${template.type} server',
      );
      if (template.minecraft != null) {
        Ui.keyValue('Minecraft', template.minecraft!);
      }
      Ui.note('Created servers stay stopped until you start them.');
      final String action =
          await menuSelect<String>(template.name, <MenuEntry<String>>[
            MenuEntry<String>(
              network
                  ? 'Create network from template'
                  : 'Create server from template',
              value: 'create',
            ),
            const MenuEntry<String>('Inspect template YAML', value: 'show'),
            const MenuEntry<String>('Back to templates', value: 'back'),
          ]);
      if (action == 'back') return false;
      if (action == 'create') break;
      await _shellRun(<String>['template', 'show', template.name]);
      await Ui.pause();
    }
    final String name = await Ui.input(
      network ? 'New network name' : 'New instance name',
      validator: network
          ? (String value) =>
                value.length <= 55 && NetworkDefinition.validName(value)
          : _isValidInstanceName,
      validationMessage: network
          ? 'Use 1–55 letters, numbers, _, or -, beginning with a letter or number.'
          : 'Use letters, numbers, ., _, or - with no spaces.',
    );
    final List<String> buildTypes =
        (template.buildTypes.isNotEmpty
                ? template.buildTypes
                : <String>[template.type])
            .where((String type) => type != 'custom')
            .toList(growable: false);
    bool hasCachedBuilds = buildTypes.isNotEmpty;
    for (final String type in buildTypes) {
      final List<BuildCacheEntry> cached = await _cachedBuilds(type);
      hasCachedBuilds =
          hasCachedBuilds &&
          newestCachedAge(cached, version: template.minecraft) != null;
    }
    final bool download;
    if (hasCachedBuilds) {
      download = await menuSelect<bool>('Server jars', const <MenuEntry<bool>>[
        MenuEntry<bool>('Use cached builds', value: false),
        MenuEntry<bool>('Download fresh builds', value: true),
      ]);
    } else {
      download = buildTypes.isNotEmpty;
    }
    Ui.keyValue(network ? 'Network' : 'Instance', name);
    Ui.keyValue(
      'Builds',
      download ? 'Download required builds' : 'Use existing jars',
    );
    if (network) {
      Ui.note('Velocity is resolved separately during network creation.');
    }
    if (!await Ui.confirm(
      'Create $name from ${template.name}?',
      defaultValue: false,
    )) {
      return true;
    }
    final int code = await _shellRun(<String>[
      'template',
      'apply',
      template.name,
      name,
      if (download) '--auto-build',
    ]);
    if (code == 0) {
      Ui.success(
        network
            ? '$name created and stopped. Open NETWORKS to start it.'
            : '$name created and stopped. Review its runtime and addons before starting.',
      );
    }
    await Ui.pause();
    if (code == 0 && network) await _networkActions(name);
    return true;
  }

  Future<void> _instanceRuntimeSettings(String name) async {
    while (true) {
      final _InstanceRow? instance = await _loadInstanceRow(name);
      final String action = await menuSelect<String>(
        'Runtime for $name',
        <MenuEntry<String>>[
          MenuEntry<String>('Show effective settings', value: 'show'),
          MenuEntry<String>('Check Java compatibility', value: 'check'),
          MenuEntry<String>('Select Java executable', value: 'set-java'),
          MenuEntry<String>('Set heap', value: 'set-heap'),
          MenuEntry<String>('Set JVM preset', value: 'set-preset'),
          MenuEntry<String>('Use consumer defaults', value: 'reset'),
          MenuEntry<String>('Export as template', value: 'template'),
          if (instance?.isolated == true)
            MenuEntry<String>('Run bot swarm', value: 'swarm'),
          if (instance?.isolated == true)
            MenuEntry<String>('Persistent player sessions', value: 'sessions'),
          MenuEntry<String>('Back to dashboard', value: 'back'),
        ],
      );
      if (action == 'back') return;
      if (action == 'swarm') {
        await _runSwarmWizard(name);
        continue;
      }
      if (action == 'sessions') {
        await _sessionRunsWizard(instance: name);
        continue;
      }
      if (action == 'template') {
        final String template = await Ui.input(
          'Template name',
          validator: _isValidInstanceName,
        );
        await _shellRun(<String>['template', 'export', name, template]);
      } else {
        String? value;
        if (action == 'set-java') {
          value = await Ui.input(
            'Java executable path',
            validator: (String value) => value.trim().isNotEmpty,
          );
        }
        if (action == 'set-heap') {
          value = await Ui.input(
            'Heap size',
            validator: (String value) => RegExp(
              r'^[1-9][0-9]*[MG]$',
              caseSensitive: false,
            ).hasMatch(value),
            validationMessage: 'Use a size such as 4G or 512M.',
          );
        }
        if (action == 'set-preset') {
          value = await Ui.pick('JVM preset', const <String>[
            'aikar',
            'vanilla',
            'conservative',
          ]);
        }
        if (action == 'reset' &&
            !await Ui.confirm(
              'Remove runtime overrides for $name?',
              defaultValue: false,
            )) {
          continue;
        }
        await _shellRun(<String>[
          'runtime',
          'settings',
          action,
          ?value,
          '--instance',
          name,
        ]);
      }
      await Ui.pause();
    }
  }
}
