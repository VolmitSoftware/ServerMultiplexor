part of 'interactive_wizard.dart';

class WizardNetwork {
  const WizardNetwork({
    required this.name,
    required this.proxy,
    required this.bind,
    required this.port,
    required this.onlineMode,
    required this.defaultServer,
    required this.fallbackServers,
    required this.members,
  });

  factory WizardNetwork.fromJson(Object? value) {
    if (value case {
      'name': final String name,
      'proxy': final String proxy,
      'bind': final String bind,
      'port': final int port,
      'onlineMode': final bool onlineMode,
      'defaultServer': final String defaultServer,
      'fallbackServers': final List<Object?> fallbacks,
      'members': final List<Object?> members,
    }) {
      return WizardNetwork(
        name: name,
        proxy: proxy,
        bind: bind,
        port: port,
        onlineMode: onlineMode,
        defaultServer: defaultServer,
        fallbackServers: <String>[
          for (final Object? fallback in fallbacks)
            if (fallback is String)
              fallback
            else
              throw const FormatException('Invalid network fallback.'),
        ],
        members: <WizardNetworkMember>[
          for (final Object? member in members)
            WizardNetworkMember.fromJson(member),
        ],
      );
    }
    throw const FormatException('Invalid network response.');
  }

  final String name;
  final String proxy;
  final String bind;
  final int port;
  final bool onlineMode;
  final String defaultServer;
  final List<String> fallbackServers;
  final List<WizardNetworkMember> members;

  String get address => '${bind == '0.0.0.0' ? 'LAN address' : bind}:$port';

  MonitorNetworkGroup get monitorGroup => MonitorNetworkGroup(
    name: name,
    proxy: proxy,
    port: port,
    members: <MonitorNetworkMember>[
      for (final WizardNetworkMember member in members)
        MonitorNetworkMember(
          instance: member.instance,
          alias: member.alias,
          port: member.port,
        ),
    ],
  );

  static List<WizardNetwork> parseList(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! List<Object?>) {
      throw const FormatException('Invalid network list.');
    }
    return decoded.map(WizardNetwork.fromJson).toList(growable: false);
  }
}

class WizardNetworkMember {
  const WizardNetworkMember({
    required this.instance,
    required this.alias,
    required this.port,
  });

  factory WizardNetworkMember.fromJson(Object? value) {
    if (value case {
      'instance': final String instance,
      'alias': final String alias,
      'port': final int port,
    }) {
      return WizardNetworkMember(instance: instance, alias: alias, port: port);
    }
    throw const FormatException('Invalid network member.');
  }

  final String instance;
  final String alias;
  final int port;
}

class WizardNetworkStatus {
  const WizardNetworkStatus({
    required this.network,
    required this.state,
    required this.allStopped,
    required this.anyStopped,
    required this.proxyRunning,
    required this.proxyStopped,
    required this.issues,
    this.playersOnline,
  });

  factory WizardNetworkStatus.parse(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded case {
      'network': final Object? network,
      'state': final String state,
      'instances': final List<Object?> instances,
      'issues': final List<Object?> issues,
    }) {
      final WizardNetwork definition = WizardNetwork.fromJson(network);
      final int? playersOnline = switch (decoded['playersOnline']) {
        final int count when count >= 0 => count,
        _ => null,
      };
      if (!const <String>{'running', 'degraded', 'stopped'}.contains(state) ||
          instances.length != definition.members.length + 1) {
        throw const FormatException('Invalid network runtime response.');
      }
      bool allStopped = true;
      bool anyStopped = false;
      bool proxyRunning = false;
      bool proxyStopped = false;
      final Set<String> expectedNames = <String>{
        definition.proxy,
        ...definition.members.map(
          (WizardNetworkMember member) => member.instance,
        ),
      };
      for (final Object? instance in instances) {
        if (instance case {
          'name': final String name,
          'state': final String state,
        }) {
          if (!expectedNames.remove(name)) {
            throw const FormatException('Unexpected network instance.');
          }
          if (!RuntimeState.values.any((RuntimeState s) => s.name == state)) {
            throw const FormatException('Unknown network instance state.');
          }
          allStopped = allStopped && state == 'stopped';
          anyStopped = anyStopped || state == 'stopped';
          if (name == definition.proxy) {
            proxyRunning = state == 'running' || state == 'starting';
            proxyStopped = state == 'stopped';
          }
        } else {
          throw const FormatException('Invalid network instance response.');
        }
      }
      return WizardNetworkStatus(
        network: definition,
        state: state,
        allStopped: allStopped,
        anyStopped: anyStopped,
        proxyRunning: proxyRunning,
        proxyStopped: proxyStopped,
        playersOnline: playersOnline,
        issues: <String>[
          for (final Object? issue in issues)
            if (issue is String)
              issue
            else
              throw const FormatException('Invalid network issue.'),
        ],
      );
    }
    throw const FormatException('Invalid network status.');
  }

  final WizardNetwork network;
  final String state;
  final bool allStopped;
  final bool anyStopped;
  final bool proxyRunning;
  final bool proxyStopped;
  final List<String> issues;
  final int? playersOnline;

  String get playerCountLabel => playersOnline == null
      ? 'players unavailable'
      : '$playersOnline ${playersOnline == 1 ? 'player' : 'players'}';

  String get menuTitle =>
      '${network.name} · $state · ${network.address} · $playerCountLabel';

  List<String> get actions => <String>[
    if (anyStopped) 'start',
    if (!allStopped) ...<String>['stop', 'restart'],
    if (proxyRunning) 'console',
    'status',
    'check',
    'remove',
    'delete',
    if (proxyStopped) 'plugins-sync',
    if (allStopped) ...<String>['repair', 'add', 'configure'],
    'back',
  ];
}

class WizardNetworkCandidate {
  const WizardNetworkCandidate({
    required this.instance,
    required this.type,
    required this.minecraft,
    required this.port,
  });

  final String instance;
  final String type;
  final String minecraft;
  final int port;

  String get label => '$instance ($type $minecraft, port $port)';

  static List<WizardNetworkCandidate> parseList(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! List<Object?>) {
      throw const FormatException('Invalid network candidate list.');
    }
    return <WizardNetworkCandidate>[
      for (final Object? candidate in decoded)
        if (candidate case {
          'instance': final String instance,
          'type': final String type,
          'minecraft': final String minecraft,
          'port': final int port,
        })
          WizardNetworkCandidate(
            instance: instance,
            type: type,
            minecraft: minecraft,
            port: port,
          )
        else
          throw const FormatException('Invalid network candidate.'),
    ];
  }
}

extension _NetworkWizard on InteractiveWizard {
  Future<void> _networkMenu() async {
    if (!_isPluginConsumer()) {
      Ui.note('Networks are available in the Local plugin consumer.');
      await Ui.pause();
      return;
    }
    while (true) {
      final String? raw = await _networkCapture(<String>[
        'network',
        'list',
        '--json',
      ]);
      if (raw == null) {
        final String action = await menuSelect<String>(
          'Network information unavailable',
          const <MenuEntry<String>>[
            MenuEntry<String>('Retry', value: 'retry'),
            MenuEntry<String>(
              'Recover interrupted operation',
              value: 'recover',
              detail: 'Requires affected instances to be stopped',
            ),
            MenuEntry<String>('Back to dashboard', value: 'back'),
          ],
        );
        if (action == 'back') return;
        if (action == 'recover') {
          await _shellRun(<String>['network', 'recover']);
          await Ui.pause();
        }
        continue;
      }
      final List<WizardNetwork> networks;
      try {
        networks = WizardNetwork.parseList(raw);
      } on FormatException catch (error) {
        Ui.error(error.message);
        await Ui.pause();
        return;
      }
      final String choice = await menuSelect<String>(
        'Velocity networks',
        <MenuEntry<String>>[
          const MenuEntry<String>('Create network', value: ''),
          for (final WizardNetwork network in networks)
            MenuEntry<String>(
              network.name,
              value: 'network:${network.name}',
              detail: '${network.address} · ${network.members.length} servers',
            ),
          const MenuEntry<String>('Back to dashboard', value: 'back'),
        ],
      );
      if (choice == 'back') return;
      if (choice.isEmpty) {
        await _createNetwork();
      } else {
        await _networkActions(choice.substring('network:'.length));
      }
    }
  }

  Future<String?> _networkCapture(List<String> command) async {
    final CapturedResult result = await Ui.shielded(
      () => passthrough.capture(command),
    );
    if (result.success || result.stdout.trimLeft().startsWith('{')) {
      return result.stdout;
    }
    Ui.error('Could not load network information.');
    if (result.stderr.trim().isNotEmpty) Ui.note(result.stderr.trim());
    await Ui.pause();
    return null;
  }

  Future<List<WizardNetworkCandidate>> _networkCandidates() async {
    final String? raw = await _networkCapture(<String>[
      'network',
      'candidates',
      '--json',
    ]);
    if (raw == null) return const <WizardNetworkCandidate>[];
    try {
      return WizardNetworkCandidate.parseList(raw);
    } on FormatException catch (error) {
      Ui.error(error.message);
      await Ui.pause();
      return const <WizardNetworkCandidate>[];
    }
  }

  Future<String> _networkPort({String defaultValue = '25565'}) => Ui.input(
    'Proxy port',
    defaultValue: defaultValue,
    validator: (String value) {
      final int? port = int.tryParse(value);
      return port != null && port >= 1 && port <= 65535;
    },
    validationMessage: 'Enter a port from 1 to 65535.',
  );

  Future<String> _networkBind({String current = '127.0.0.1'}) =>
      menuSelect<String>('Who can connect?', const <MenuEntry<String>>[
        MenuEntry<String>('This computer', value: '127.0.0.1'),
        MenuEntry<String>('LAN / all interfaces', value: '0.0.0.0'),
      ], initialIndex: current == '0.0.0.0' ? 1 : 0);

  Future<String> _networkDefault(List<String> aliases, {String? current}) =>
      menuSelect<String>('Entry server', <MenuEntry<String>>[
        for (final String alias in aliases)
          MenuEntry<String>(alias, value: alias),
      ], initialIndex: current == null ? 0 : aliases.indexOf(current));

  Future<void> _createNetwork() async {
    final List<WizardNetworkCandidate> candidates = await _networkCandidates();
    if (candidates.isEmpty) {
      Ui.note(
        'Create and stop a Paper-compatible server first. Networks need '
        'Minecraft 1.19 or newer and servers outside existing networks.',
      );
      await Ui.pause();
      return;
    }
    final String name = await Ui.input(
      'Network name',
      validator: (String value) =>
          NetworkDefinition.validName(value) &&
          NetworkDefinition.validName('$value-proxy'),
      validationMessage:
          'Use 1–58 letters, numbers, _, or -, beginning with a letter or number.',
    );
    final Set<int> selected = await Ui.checklist('Backend servers', <String>[
      for (final WizardNetworkCandidate candidate in candidates)
        candidate.label,
    ]);
    if (selected.isEmpty) return;
    final List<String> members = <String>[
      for (int index = 0; index < candidates.length; index++)
        if (selected.contains(index)) candidates[index].instance,
    ];
    final String entry = await _networkDefault(members);
    final String port = await _networkPort();
    final String bind = await _networkBind();
    final String source =
        await menuSelect<String>('Velocity jar', const <MenuEntry<String>>[
          MenuEntry<String>('Download Velocity', value: 'download'),
          MenuEntry<String>('Use a local jar', value: 'jar'),
        ]);
    String? jar;
    String? version;
    if (source == 'jar') {
      jar = await Ui.input(
        'Velocity jar path',
        validator: (String path) =>
            path.toLowerCase().endsWith('.jar') && File(path).existsSync(),
        validationMessage: 'Enter the path to an existing Velocity .jar file.',
      );
    } else {
      version = await Ui.input('Velocity version (blank for latest available)');
    }
    Ui.keyValue('proxy', '$name-proxy');
    Ui.keyValue('listen', '$bind:$port');
    Ui.keyValue('entry server', entry);
    Ui.keyValue('backends', members.join(', '));
    Ui.note(
      'Players authenticate through Velocity. Backend ports become local-only.',
    );
    if (!await Ui.confirm('Create this network?', defaultValue: false)) return;
    final int code = await _shellRun(<String>[
      'network',
      'create',
      name,
      '--members',
      members.join(','),
      '--default',
      entry,
      '--port',
      port,
      '--bind',
      bind,
      if (jar != null) ...<String>['--jar', jar],
      if (version != null && version.isNotEmpty) ...<String>[
        '--proxy-version',
        version,
      ],
    ]);
    await Ui.pause();
    if (code == 0) await _networkActions(name);
  }

  Future<void> _networkActions(String name) async {
    const Map<String, String> labels = <String, String>{
      'start': 'Start network',
      'stop': 'Stop network',
      'restart': 'Restart network',
      'console': 'Proxy console',
      'status': 'Show status',
      'check': 'Check configuration',
      'repair': 'Repair configuration',
      'add': 'Add backend',
      'remove': 'Remove backend',
      'configure': 'Configure routing and port',
      'plugins-sync': 'Sync Velocity plugins',
      'delete': 'Delete network',
      'back': 'Back to networks',
    };
    while (true) {
      final String? raw = await _networkCapture(<String>[
        'network',
        'status',
        name,
        '--json',
      ]);
      if (raw == null) return;
      final WizardNetworkStatus status;
      try {
        status = WizardNetworkStatus.parse(raw);
      } on FormatException catch (error) {
        Ui.error(error.message);
        await Ui.pause();
        return;
      }
      final String action = await menuSelect<String>(
        status.menuTitle,
        <MenuEntry<String>>[
          if (!status.network.onlineMode)
            const MenuEntry<String>(
              'Persistent player sessions',
              value: 'sessions',
              detail: 'Run and manage sessions through the proxy',
            ),
          for (final String action in status.actions)
            MenuEntry<String>(
              labels[action]!,
              value: action,
              labelColor: action == 'delete' ? Ui.theme.danger : null,
              detail: action == 'check' && status.issues.isNotEmpty
                  ? '${status.issues.length} issues'
                  : action == 'delete'
                  ? 'Restore backend settings; retain server and proxy files'
                  : action == 'repair'
                  ? 'Reapply managed settings; preserve unrelated configuration'
                  : null,
            ),
        ],
      );
      switch (action) {
        case 'sessions':
          await _sessionRunsWizard(network: name);
        case 'back':
          return;
        case 'add':
          await _networkAdd(name);
        case 'remove':
          if (await _networkRemove(status.network)) return;
        case 'configure':
          await _networkConfigure(status.network);
        case 'delete':
          Ui.note(
            'Backend settings will be restored. Server and proxy files remain.',
          );
          final String confirmation = await Ui.input(
            'Type $name to delete the network',
          );
          if (confirmation != name) continue;
          final int code = await _shellRun(<String>[
            'network',
            'delete',
            name,
            '--confirm',
            confirmation,
          ]);
          await Ui.pause();
          if (code == 0) return;
        default:
          await _shellRun(<String>['network', action, name]);
          if (action != 'console') await Ui.pause();
      }
    }
  }

  Future<void> _networkAdd(String name) async {
    final List<WizardNetworkCandidate> candidates = await _networkCandidates();
    if (candidates.isEmpty) {
      Ui.note(
        'No stopped, compatible servers outside a network are available.',
      );
      await Ui.pause();
      return;
    }
    final WizardNetworkCandidate candidate =
        await menuSelect<WizardNetworkCandidate>(
          'Add backend to $name',
          <MenuEntry<WizardNetworkCandidate>>[
            for (final WizardNetworkCandidate candidate in candidates)
              MenuEntry<WizardNetworkCandidate>(
                candidate.label,
                value: candidate,
              ),
          ],
        );
    final String alias = await Ui.input(
      'Routing name',
      defaultValue: candidate.instance,
      validator: (String value) =>
          NetworkDefinition.validName(value) && value.toLowerCase() != 'try',
      validationMessage:
          'Use letters, numbers, _, or -. The name try is reserved.',
    );
    await _shellRun(<String>[
      'network',
      'add',
      name,
      candidate.instance,
      '--alias',
      alias,
    ]);
    await Ui.pause();
  }

  Future<bool> _networkRemove(WizardNetwork network) async {
    final String alias = await menuSelect<String>(
      'Remove backend from ${network.name}',
      <MenuEntry<String>>[
        for (final WizardNetworkMember member in network.members)
          MenuEntry<String>(
            member.alias,
            value: member.alias,
            detail: member.instance,
          ),
      ],
    );
    if (!await Ui.confirm(
      'Restore $alias to standalone settings?',
      defaultValue: false,
    )) {
      return false;
    }
    final int code = await _shellRun(<String>[
      'network',
      'remove',
      network.name,
      alias,
    ]);
    await Ui.pause();
    return code == 0 && network.members.length == 1;
  }

  Future<void> _networkConfigure(WizardNetwork network) async {
    final List<String> aliases = <String>[
      for (final WizardNetworkMember member in network.members) member.alias,
    ];
    final String entry = await _networkDefault(
      aliases,
      current: network.defaultServer,
    );
    final List<String> previousFallbacks = network.fallbackServers
        .where((String alias) => alias != entry)
        .toList(growable: false);
    final String fallbacks = await Ui.input(
      'Fallback order (comma-separated server names, or none)',
      defaultValue: previousFallbacks.isEmpty
          ? 'none'
          : previousFallbacks.join(','),
      validator: (String value) {
        if (value.trim() == 'none') return true;
        final List<String> requested = value
            .split(',')
            .map((String alias) => alias.trim())
            .toList(growable: false);
        return requested.toSet().length == requested.length &&
            requested.every(
              (String alias) => aliases.contains(alias) && alias != entry,
            );
      },
      validationMessage:
          'Use none or unique routing names other than the entry server.',
    );
    final String port = await _networkPort(
      defaultValue: network.port.toString(),
    );
    final String bind = network.onlineMode
        ? await _networkBind(current: network.bind)
        : '127.0.0.1';
    await _shellRun(<String>[
      'network',
      'configure',
      network.name,
      '--default',
      entry,
      '--fallback',
      fallbacks,
      '--port',
      port,
      '--bind',
      bind,
    ]);
    await Ui.pause();
  }
}
