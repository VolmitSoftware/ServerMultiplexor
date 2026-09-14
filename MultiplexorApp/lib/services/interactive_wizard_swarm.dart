part of 'interactive_wizard.dart';

extension _SwarmWizard on InteractiveWizard {
  Future<void> _runSwarmWizard(String name) async {
    final _InstanceRow? instance = await _loadInstanceRow(name);
    if (instance == null || !instance.isolated) {
      Ui.note('Bot swarms require an isolated Local game server.');
      await Ui.pause();
      return;
    }
    final String? root = await passthrough.captureStdoutLine(<String>[
      'instance',
      'path',
      name,
    ]);
    if (root == null) return;
    final File metadata = File(p.join(root, '.server-source'));
    if (metadata.existsSync()) {
      final List<String> lines = metadata.readAsLinesSync();
      if (lines.any(
        (String line) =>
            line.trim() == 'type=velocity' || line.startsWith('network='),
      )) {
        Ui.note(
          'Bot swarms require a standalone game server outside a network.',
        );
        await Ui.pause();
        return;
      }
    }
    String selected =
        await menuSelect<String>('Swarm behavior', <MenuEntry<String>>[
          for (final String profile in GameplaySwarmSettings.profiles)
            MenuEntry<String>(profile, value: profile),
          const MenuEntry<String>('Use a JSON plan', value: 'plan'),
        ]);
    if (selected == 'plan') {
      selected = await Ui.input(
        'JSON plan path',
        validator: (String path) =>
            path.toLowerCase().endsWith('.json') && File(path).existsSync(),
        validationMessage: 'Choose an existing .json plan.',
      );
    }
    String? workload;
    if (selected == 'stress') {
      final String choice =
          await menuSelect<String>('Stress workload', const <MenuEntry<String>>[
            MenuEntry<String>('Use the default workload', value: 'default'),
            MenuEntry<String>('Use a JSON workload', value: 'file'),
          ]);
      if (choice == 'file') {
        workload = await Ui.input(
          'JSON workload path',
          validator: (String path) =>
              path.toLowerCase().endsWith('.json') && File(path).existsSync(),
          validationMessage: 'Choose an existing .json workload.',
        );
      }
    }
    final String bots = await _swarmNumber('Bots', 4, 1, 256);
    final String duration = await _swarmNumber(
      'Run duration in seconds',
      selected == 'stress' ? 3600 : 60,
      1,
      604800,
    );
    final String seed = await _swarmNumber('Random seed', 1, 0, 4294967295);
    final String radius = await _swarmNumber(
      'Activity radius in blocks',
      16,
      4,
      64,
    );
    final bool needsArena = selected == 'workshop' || selected == 'mixed';
    final String placement = needsArena
        ? 'arena'
        : await menuSelect<String>('Starting area', <MenuEntry<String>>[
            MenuEntry<String>('Use the existing world', value: 'world'),
            if (!selected.toLowerCase().endsWith('.json'))
              MenuEntry<String>(
                'Build a test arena',
                value: 'arena',
                detail: 'Replaces blocks in the chosen area',
              ),
            if (selected != 'stress')
              MenuEntry<String>(
                'Scatter across a grid',
                value: 'scatter',
                detail: 'Teleport workers to terrain around the origin',
              ),
          ]);
    String? scatter;
    if (placement == 'scatter') {
      scatter = await _swarmNumber('Scatter radius in blocks', 128, 8, 4096);
    }
    final String origin = await Ui.input(
      'Origin x,y,z',
      defaultValue: '0,80,0',
      validator: (String value) {
        try {
          GameplaySwarmSettings.parse(
            profile: selected,
            options: <String, String>{'origin': value, 'scatter': ?scatter},
            flags: <String>{if (placement == 'arena') 'build-arena'},
            generatedPrefix: 'SwPreview',
          );
          return true;
        } on FormatException {
          return false;
        }
      },
      validationMessage:
          'Use integer x,y,z; x/z plus any scatter radius within ±29999000 and y from -48 to 256.',
    );
    String? bounds;
    String? goals;
    String? completion;
    if (selected == 'stress') {
      final String area =
          await menuSelect<String>('Stress bounds', const <MenuEntry<String>>[
            MenuEntry<String>(
              'Use workload bounds or the starting area',
              value: 'default',
            ),
            MenuEntry<String>('Set a coordinate box', value: 'box'),
          ]);
      if (area == 'box') {
        bounds = await Ui.input(
          'Bounds minX,minY,minZ:maxX,maxY,maxZ',
          validator: (String value) {
            try {
              GameplaySwarmBounds.parse(value);
              return true;
            } on FormatException {
              return false;
            }
          },
          validationMessage: 'Enter ordered corners within the world limits.',
        );
      }
      final String goalChoice =
          await menuSelect<String>('Activity goals', const <MenuEntry<String>>[
            MenuEntry<String>('Use workload goals', value: 'default'),
            MenuEntry<String>('Set activity counts', value: 'counts'),
          ]);
      if (goalChoice == 'counts') {
        Ui.note(
          'Activities: ${GameplaySwarmSettings.stressActivities.join(', ')}.',
        );
        goals = await Ui.input(
          'Goals, for example mine=1000,build=1000',
          validator: (String value) {
            try {
              GameplaySwarmSettings.parseGoals(value);
              return true;
            } on FormatException {
              return false;
            }
          },
          validationMessage:
              'Use distinct activity=count pairs with positive counts.',
        );
      }
      final String stop =
          await menuSelect<String>('Completion rule', const <MenuEntry<String>>[
            MenuEntry<String>('Use the workload rule', value: 'default'),
            MenuEntry<String>('Run for the full duration', value: 'duration'),
            MenuEntry<String>(
              'Stop when all goals pass',
              value: 'goals',
              detail: 'The duration remains a hard deadline',
            ),
          ]);
      if (stop != 'default') completion = stop;
    }
    final bool chat = await Ui.confirm(
      'Send scripted progress messages in chat?',
      defaultValue: false,
    );
    final bool stopped = instance.state == RuntimeState.stopped;
    Ui.keyValue('target', name);
    Ui.keyValue('behavior', selected);
    Ui.keyValue('load', '$bots bots for ${duration}s, seed $seed');
    if (workload != null) Ui.keyValue('workload', workload);
    if (bounds != null) Ui.keyValue('bounds', bounds);
    if (goals != null) Ui.keyValue('goals', goals);
    if (completion != null) Ui.keyValue('completion', completion);
    if (placement == 'arena') {
      final int width = math.sqrt(int.parse(bots)).ceil() * 12;
      Ui.note(
        'Arena setup replaces blocks in a $width×$width area from $origin, '
        'with a floor and five cleared blocks above it. These world changes remain.',
      );
    }
    if (selected.toLowerCase().endsWith('.json')) {
      Ui.note(
        'The JSON plan uses the existing world. Its block changes remain after the run.',
      );
    }
    if (stopped) {
      Ui.note(
        'This run prepares offline loopback access, starts the server, then stops it afterward.',
      );
    } else {
      Ui.note(
        'The server must already use offline loopback access and will remain running.',
      );
    }
    if (!await Ui.confirm('Run this swarm?', defaultValue: false)) return;
    await _shellRun(<String>[
      'gameplay',
      'swarm',
      selected,
      name,
      '--bots',
      bots,
      '--duration',
      duration,
      '--seed',
      seed,
      '--radius',
      radius,
      '--origin',
      origin,
      if (placement == 'arena') '--build-arena',
      if (scatter != null) ...<String>['--scatter', scatter],
      if (workload != null) ...<String>['--workload', workload],
      if (bounds != null) ...<String>['--bounds', bounds],
      if (goals != null) ...<String>['--goals', goals],
      if (completion != null) ...<String>['--completion', completion],
      if (chat) '--chat',
      if (stopped) ...<String>['--prepare', '--start', '--stop-after'],
    ]);
    await Ui.pause();
  }

  Future<String> _swarmNumber(
    String label,
    int fallback,
    int minimum,
    int maximum,
  ) => Ui.input(
    label,
    defaultValue: '$fallback',
    validator: (String value) {
      final int? number = RegExp(r'^\d+$').hasMatch(value)
          ? int.tryParse(value)
          : null;
      return number != null && number >= minimum && number <= maximum;
    },
    validationMessage: 'Enter an integer from $minimum to $maximum.',
  );
}
