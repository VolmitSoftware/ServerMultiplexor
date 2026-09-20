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
      await Ui.pause();
    }
  }
}
