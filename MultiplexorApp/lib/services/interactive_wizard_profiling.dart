part of 'interactive_wizard.dart';

extension _RemoteProfiling on InteractiveWizard {
  Future<void> _remoteProfile(String identifier) async {
    final PterodactylProfile profile = _requireRemoteProfile();
    while (true) {
      Ui.appHeader('REMOTE PROFILING', <String>[identifier, profile.name]);
      final int selected = await Ui.choose('JProfiler', <String>[
        'Check target',
        'Start a capture',
        'Capture status',
        'Fetch snapshots and logs',
        'Restore startup settings',
        'Open live tunnel',
        'Configure node SSH host',
        'Back',
      ]);
      if (selected == 7) return;
      final List<String>? arguments = switch (selected) {
        0 => <String>['check', identifier],
        1 => await _remoteProfileStartArguments(profile, identifier),
        2 => <String>['status', identifier],
        3 => <String>[
          'fetch',
          identifier,
          if (await Ui.confirm(
            'Open the downloaded snapshot in JProfiler?',
            defaultValue: false,
          ))
            '--open',
        ],
        4 => <String>['recover', identifier],
        5 => <String>['live', identifier],
        6 => await _remoteProfileHostArguments(identifier),
        _ => null,
      };
      if (arguments == null) continue;
      final int code = await handleRemoteProfile(<String>[
        ...arguments,
        '--profile',
        profile.id,
      ], waitForTunnel: _waitForRemoteProfileTunnel);
      if (selected != 5 || code != 0) await Ui.pause();
    }
  }

  Future<void> _waitForRemoteProfileTunnel(RemoteProfilerTunnel tunnel) async {
    final TermIo io = TermIo.instance;
    int? exitCode;
    Object? failure;
    tunnel.exitCode.then<void>(
      (int value) {
        exitCode = value;
      },
      onError: (Object error) {
        failure = error;
      },
    );
    Ui.note('Press Enter, Escape, or Ctrl-C to close this tunnel.');
    io.drainInput();
    io.setRawMode(true);
    io.hideCursor();
    try {
      while (exitCode == null && failure == null) {
        final TermEvent? event = io.readEventTimeout(
          const Duration(milliseconds: 100),
        );
        if (event?.kind == TermEventKind.enter ||
            event?.kind == TermEventKind.escape ||
            event?.kind == TermEventKind.ctrlC) {
          return;
        }
        await Future<void>.delayed(Duration.zero);
      }
      throw StateError(
        'Profiling SSH tunnel disconnected${exitCode == null ? ': $failure' : ' (exit $exitCode)'}.',
      );
    } finally {
      io.setRawMode(false);
      io.showCursor();
    }
  }

  Future<List<String>?> _remoteProfileStartArguments(
    PterodactylProfile profile,
    String identifier,
  ) async {
    final int targetMode = await Ui.choose('Capture target', <String>[
      'Server startup',
      'Attach to the running JVM',
    ]);
    final bool attach = targetMode == 1;
    final int mode = await Ui.choose('Recording mode', <String>[
      'Offline recording with automatic snapshot',
      'Live JProfiler connection',
    ]);
    final String duration = mode == 1
        ? '120s'
        : await Ui.input(
            'Recording duration',
            defaultValue: '120s',
            validator: (String value) {
              try {
                RemoteProfileCommand.parseDuration(value);
                return true;
              } on ArgumentError {
                return false;
              }
            },
            validationMessage: 'Use 1s through 24h, for example 120s or 5m',
          );
    final String agentDirectory = await Ui.input(
      'Local Linux agent directory (blank downloads JProfiler 16.2)',
    );
    final PterodactylResourceUsage resources = await pterodactyl.resources(
      profile.id,
      identifier,
    );
    if (attach && resources.currentState == 'offline') {
      Ui.warn('Attach requires an already-running JVM.');
      await Ui.pause();
      return null;
    }
    final bool restart = !attach && resources.currentState != 'offline';
    Ui.keyValue('target', identifier);
    Ui.keyValue('mode', mode == 0 ? 'offline' : 'live');
    if (mode == 0) Ui.keyValue('duration', duration);
    Ui.note(
      'Launch settings are restored after the profiling launch. The agent remains loaded until a normal restart.',
    );
    if (!await Ui.confirm(
      attach
          ? 'Attach JProfiler to this running server?'
          : restart
          ? 'Gracefully restart this server and profile its startup?'
          : 'Start this server with profiling enabled?',
      defaultValue: false,
    )) {
      return null;
    }
    return <String>[
      'start',
      identifier,
      attach ? '--attach' : '--startup',
      if (mode == 0) ...<String>['--duration', duration],
      if (agentDirectory.trim().isNotEmpty) ...<String>[
        '--agent-dir',
        agentDirectory.trim(),
      ],
      if (mode == 1) '--live',
      if (restart) '--restart',
    ];
  }

  Future<List<String>> _remoteProfileHostArguments(String identifier) async {
    final String target = await Ui.input(
      'Node SSH alias or user@host',
      validator: (String value) => value.trim().isNotEmpty,
      validationMessage: 'Enter the SSH target for the Docker host',
    );
    final String port = await Ui.input(
      'SSH port',
      defaultValue: '22',
      validator: (String value) {
        final int? port = int.tryParse(value);
        return port != null && port > 0 && port <= 65535;
      },
      validationMessage: 'Enter a port from 1 to 65535',
    );
    final String identity = await Ui.input(
      'SSH identity file (blank uses SSH defaults)',
    );
    final bool sudoDocker = await Ui.confirm(
      'Does Docker require passwordless sudo?',
      defaultValue: false,
    );
    return <String>[
      'host-set',
      identifier,
      '--ssh-target',
      target.trim(),
      '--ssh-port',
      port,
      if (identity.trim().isNotEmpty) ...<String>[
        '--identity-file',
        identity.trim(),
      ],
      if (sudoDocker) '--sudo-docker',
    ];
  }
}
