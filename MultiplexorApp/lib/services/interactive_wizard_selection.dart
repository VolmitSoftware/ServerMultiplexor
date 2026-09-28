part of 'interactive_wizard.dart';

/// The checked list is an explicit scope, never a shorthand for the fleet.
/// Missing identities abort before any operation; unavailable ones are skipped.
List<PterodactylFleetSample> remoteCheckedBulkTargets({
  required List<PterodactylFleetSample> fleet,
  required List<String> checkedIdentifiers,
  required RemoteBulkAction action,
}) {
  if (checkedIdentifiers.isEmpty) {
    throw ArgumentError('Select at least one server.');
  }
  final Map<String, PterodactylFleetSample> byId =
      <String, PterodactylFleetSample>{
        for (final PterodactylFleetSample sample in fleet)
          sample.server.identifier: sample,
      };
  final Set<String> checked = checkedIdentifiers.toSet();
  final List<String> missing = checked
      .where((String id) => !byId.containsKey(id))
      .toList();
  if (missing.isNotEmpty) {
    throw StateError(
      'Selected remote servers are no longer available: ${missing.join(', ')}. Refresh and select again.',
    );
  }
  return remoteBulkTargets(
        fleet: checked.map((String id) => byId[id]!),
        action: action,
        scope: RemoteBulkTargetScope.all,
      )
      .where(
        (PterodactylFleetSample sample) =>
            action != RemoteBulkAction.restart ||
            sample.resources?.currentState == 'running',
      )
      .toList(growable: false);
}

extension _SelectionWizard on InteractiveWizard {
  Future<void> _monitorSelectionAction(
    List<String> instances,
    InstanceBulkAction? requested,
    MonitorSnapshot snapshot, {
    PterodactylProfile? remoteProfile,
  }) async {
    // Freeze the scope before a picker or confirmation can yield to telemetry.
    final List<String> targets = List<String>.unmodifiable(instances.toSet());
    if (targets.isEmpty) return;
    InstanceBulkAction? action = requested;
    if (action == null) {
      final int choice = await Ui.choose(
        'Actions for ${targets.length} selected servers',
        const <String>[
          'Start selected',
          'Stop selected',
          'Restart selected',
          'Delete selected',
          'Back to dashboard',
        ],
      );
      if (choice >= InstanceBulkAction.values.length) return;
      action = InstanceBulkAction.values[choice];
    }
    if (snapshot.view == MonitorView.remote) {
      if (remoteProfile == null) {
        throw StateError('The selected remote profile is no longer available.');
      }
      final RemoteBulkAction remoteAction = switch (action) {
        InstanceBulkAction.start => RemoteBulkAction.start,
        InstanceBulkAction.stop => RemoteBulkAction.stop,
        InstanceBulkAction.restart => RemoteBulkAction.restart,
        InstanceBulkAction.delete => RemoteBulkAction.delete,
      };
      await _runRemoteBulkAction(
        remoteAction,
        null,
        checkedIdentifiers: targets,
        checkedProfile: remoteProfile,
      );
      return;
    }
    final Map<ConsumerProfile, List<String>> grouped =
        <ConsumerProfile, List<String>>{};
    for (final String identifier in targets) {
      if (!snapshot.instances.contains(identifier)) {
        throw StateError('A selected server is no longer available.');
      }
      final (ConsumerProfile, String)? target = localMonitorTarget(identifier);
      final ConsumerProfile profile =
          target?.$1 ?? snapshot.consumerFor(identifier);
      grouped
          .putIfAbsent(profile, () => <String>[])
          .add(target?.$2 ?? identifier);
    }
    final Map<ConsumerProfile, PassthroughService> sources =
        <ConsumerProfile, PassthroughService>{
          for (final ConsumerProfile profile in grouped.keys)
            profile: _commandsForConsumer(profile),
        };
    try {
      for (final ConsumerProfile profile in grouped.keys) {
        final Set<String> available = <String>{
          for (final _InstanceRow row in await _loadInstanceRows(
            source: sources[profile],
          ))
            row.name,
        };
        if (grouped[profile]!.any((String name) => !available.contains(name))) {
          throw StateError(
            'A selected ${profile.shortName} server is no longer available. Refresh and select again.',
          );
        }
      }
      for (final ConsumerProfile profile in grouped.keys) {
        await _runLocalSelectionAction(
          grouped[profile]!,
          action,
          profile,
          sources[profile]!,
        );
      }
    } finally {
      for (final PassthroughService source in sources.values) {
        source.disposeRcon();
      }
    }
  }

  Future<void> _runLocalSelectionAction(
    List<String> targets,
    InstanceBulkAction action,
    ConsumerProfile profile,
    PassthroughService scoped,
  ) async {
    final Map<String, _InstanceRow> rows = <String, _InstanceRow>{
      for (final _InstanceRow row in await Ui.spin(
        'Checking selected servers',
        () => _loadInstanceRows(source: scoped),
      ))
        row.name: row,
    };
    final List<String> missing = targets
        .where((String name) => !rows.containsKey(name))
        .toList();
    if (missing.isNotEmpty) {
      Ui.error(
        'Could not find every selected server: ${missing.join(', ')}. Refresh and select again.',
      );
      await Ui.pause();
      return;
    }
    Ui.appHeader('${action.name.toUpperCase()} SELECTED', <String>[
      profile.shortName,
      '${targets.length} servers',
    ]);
    final List<String> eligibleTargets = <String>[];
    for (final String name in targets) {
      final _InstanceRow row = rows[name]!;
      final String? reason = instanceBulkSkipReason(
        action,
        row.state,
        locked: row.locked,
      );
      if (reason == null) eligibleTargets.add(name);
      Ui.keyValue(name, reason == null ? row.state.name : 'skip: $reason');
    }
    if (eligibleTargets.isEmpty) {
      Ui.note('No selected servers can ${action.name} in their current state.');
      await Ui.pause();
      return;
    }
    if (action == InstanceBulkAction.delete &&
        !await Ui.confirm(
          'Permanently delete these ${eligibleTargets.length} selected servers and their data?',
          defaultValue: false,
        )) {
      return;
    }
    await Ui.shielded(
      () => scoped.run(<String>[
        'instance',
        'bulk',
        action.name,
        ...eligibleTargets,
        if (action == InstanceBulkAction.delete) ...<String>[
          '--confirm',
          instanceBulkDeleteToken(eligibleTargets),
        ],
      ]),
    );
    await Ui.pause();
  }
}
