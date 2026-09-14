part of 'interactive_wizard.dart';

extension _SessionWizard on InteractiveWizard {
  Future<String?> _sessionProfileWizard() async {
    final String selected =
        await menuSelect<String>('Session profile', const <MenuEntry<String>>[
          MenuEntry<String>(
            'Cooperative settlement',
            value: 'settlement.json',
            detail: 'One hour; create a settlement and share supplies',
          ),
          MenuEntry<String>(
            'Settlement construction goals',
            value: 'settlement-goals.json',
            detail: 'Four players build two shelters; one-hour deadline',
          ),
          MenuEntry<String>(
            'Dispersed established bases',
            value: 'dispersed-established.json',
            detail: 'Eight hours; requires two prepared bases',
          ),
          MenuEntry<String>(
            'Exploration frontier',
            value: 'frontier.json',
            detail: 'Four hours; requires a prepared starting base',
          ),
          MenuEntry<String>(
            'Velocity settlement',
            value: 'velocity-settlement.json',
            detail: 'One hour; requires lobby and survival backend aliases',
          ),
          MenuEntry<String>('Use a custom JSON profile', value: 'custom'),
          MenuEntry<String>('Back', value: 'back'),
        ]);
    if (selected == 'back') return null;
    if (selected == 'custom') {
      return Ui.input(
        'Session profile JSON path',
        validator: (String path) => File(path).existsSync(),
        validationMessage: 'Choose an existing profile JSON file.',
      );
    }
    final String path = p.join(
      passthrough.context.rootDir,
      'MultiplexorApp',
      'tool',
      'mineflayer',
      'session-profiles',
      selected,
    );
    if (!File(path).existsSync()) {
      Ui.error('Bundled session profile is missing: $path');
      await Ui.pause();
      return null;
    }
    return path;
  }

  void _sessionProfilePreview(Map<String, Object?> planned) {
    Ui.keyValue('Profile', '${planned['name']}');
    Ui.keyValue('Duration', '${planned['durationSeconds']} seconds');
    Ui.keyValue(
      'Completion',
      planned['completion'] == 'goals'
          ? 'Stop when goals pass, within the duration limit'
          : 'Run for the full duration and check goals',
    );
    final Object? population = planned['population'];
    if (population is Map<String, Object?>) {
      Ui.keyValue(
        'Population',
        '${population['identities']} identities; ${population['concurrent']} initially concurrent',
      );
      final Object? sessions = population['sessionSeconds'];
      if (sessions is List<Object?> && sessions.length == 2) {
        Ui.keyValue(
          'Session length',
          '${sessions[0]} to ${sessions[1]} seconds',
        );
      }
      final Object? offline = population['offlineSeconds'];
      if (offline is List<Object?> && offline.length == 2) {
        Ui.keyValue(
          'Time before returning',
          '${offline[0]} to ${offline[1]} seconds',
        );
      }
      final Object? stages = population['stages'];
      if (stages is List<Object?>) {
        for (final Map<String, Object?> stage
            in stages.whereType<Map<String, Object?>>()) {
          Ui.keyValue(
            'At ${stage['atSeconds']} seconds',
            '${stage['concurrent']} concurrent players',
          );
        }
      }
    }
    final Object? goals = planned['goals'];
    if (goals is Map<String, Object?> && goals.isNotEmpty) {
      for (final MapEntry<String, Object?> goal in goals.entries) {
        final String label = goal.key
            .replaceAllMapped(
              RegExp(r'([a-z])([A-Z])'),
              (Match match) => '${match[1]} ${match[2]}',
            )
            .toLowerCase();
        Ui.keyValue('Goal: $label', 'at least ${goal.value}');
      }
    }
    bool createsSettlement = false;
    bool usesExistingWorld = false;
    final Object? worlds = planned['worlds'];
    if (worlds is List<Object?>) {
      for (final Map<String, Object?> world
          in worlds.whereType<Map<String, Object?>>()) {
        Ui.keyValue(
          'World ${world['id']}',
          '${world['backend']} / ${world['dimension']}',
        );
        final Object? bounds = world['bounds'];
        if (bounds is Map<String, Object?> &&
            bounds['min'] is List<Object?> &&
            bounds['max'] is List<Object?>) {
          Ui.keyValue(
            'Bounds',
            '(${(bounds['min']! as List<Object?>).join(', ')}) → (${(bounds['max']! as List<Object?>).join(', ')})',
          );
        }
        final Object? setup = world['setup'];
        if (setup is Map<String, Object?>) {
          if (setup['kind'] == 'settlement') {
            createsSettlement = true;
            final Object? origin = setup['origin'];
            Ui.keyValue(
              'Setup',
              origin is List<Object?>
                  ? 'Create settlement at (${origin.join(', ')})'
                  : 'Create settlement',
            );
          } else if (setup['kind'] == 'existing') {
            usesExistingWorld = true;
            Ui.keyValue('Setup', 'Use existing world fixtures');
          }
        }
      }
    }
    if (createsSettlement) {
      Ui.note(
        'Settlement setup replaces blocks and provides starter supplies. World changes persist.',
      );
    }
    if (usesExistingWorld) {
      Ui.note(
        'Existing-world regions require the prepared fixtures and resources described in this profile.',
      );
    }
    Ui.note('The run continues when this menu closes.');
  }

  Future<void> _sessionRunsWizard({String? instance, String? network}) async {
    final String target = instance ?? network!;
    final String kind = instance != null ? 'instance' : 'network';
    while (true) {
      final CapturedResult capture = await passthrough.capture(const <String>[
        'gameplay',
        'sessions',
        'list',
        '--json',
      ]);
      if (capture.exitCode != 0) {
        Ui.error(capture.stderr.trim());
        await Ui.pause();
        return;
      }
      final Object? decoded = jsonDecode(capture.stdout);
      if (decoded is! List<Object?>) {
        Ui.error('Invalid session list response.');
        await Ui.pause();
        return;
      }
      final List<Map<String, Object?>> runs = <Map<String, Object?>>[
        for (final Object? value in decoded)
          if (value is Map<String, Object?> &&
              value['target'] is Map<String, Object?> &&
              (value['target']! as Map<String, Object?>)['kind'] == kind &&
              (value['target']! as Map<String, Object?>)['name'] == target)
            value,
      ];
      final String choice = await menuSelect<String>(
        'Player sessions for $target',
        <MenuEntry<String>>[
          const MenuEntry<String>('Start from a profile', value: 'start'),
          for (final Map<String, Object?> run in runs)
            MenuEntry<String>(
              '${run['runId']} · ${run['state']}',
              value: run['runId']! as String,
            ),
          const MenuEntry<String>('Refresh', value: 'refresh'),
          const MenuEntry<String>('Back', value: 'back'),
        ],
      );
      if (choice == 'back') return;
      if (choice == 'refresh') continue;
      if (choice == 'start') {
        final String? profile = await _sessionProfileWizard();
        if (profile == null) continue;
        bool prepare = false;
        if (instance != null) {
          final _InstanceRow? row = await _loadInstanceRow(instance);
          if (row == null) return;
          if (row.state == RuntimeState.stopped) {
            prepare = await Ui.confirm(
              'Prepare $instance for offline loopback sessions?',
              defaultValue: true,
            );
          }
        }
        final CapturedResult validation = await Ui.shielded(
          () => passthrough.capture(<String>[
            'gameplay',
            'sessions',
            'validate',
            profile,
            '--$kind',
            target,
            if (prepare) '--prepare',
            '--json',
          ]),
        );
        if (validation.exitCode != 0) {
          Ui.error(validation.stderr.trim());
          await Ui.pause();
          continue;
        }
        final Object? validated = jsonDecode(validation.stdout);
        if (validated is! Map<String, Object?> ||
            validated['profile'] is! Map<String, Object?>) {
          Ui.error('Invalid session profile response.');
          await Ui.pause();
          continue;
        }
        final Map<String, Object?> planned =
            validated['profile']! as Map<String, Object?>;
        _sessionProfilePreview(planned);
        if (!await Ui.confirm(
          'Start this profile on $target?',
          defaultValue: false,
        )) {
          continue;
        }
        await _shellRun(<String>[
          'gameplay',
          'sessions',
          'start',
          profile,
          '--$kind',
          target,
          if (prepare) '--prepare',
          '--start',
          '--stop-after',
        ]);
        await Ui.pause();
        continue;
      }
      final Map<String, Object?> run = runs.firstWhere(
        (Map<String, Object?> value) => value['runId'] == choice,
      );
      final String action =
          await menuSelect<String>(choice, <MenuEntry<String>>[
            const MenuEntry<String>('Show status', value: 'status'),
            if (run['active'] == true || run['state'] == 'interrupted')
              const MenuEntry<String>('Stop and save', value: 'stop'),
            if (run['active'] != true)
              const MenuEntry<String>('Resume saved session', value: 'resume'),
            const MenuEntry<String>('Show report', value: 'report'),
            const MenuEntry<String>('Back', value: 'back'),
          ]);
      if (action == 'back') continue;
      await _shellRun(<String>['gameplay', 'sessions', action, choice]);
      await Ui.pause();
    }
  }
}
