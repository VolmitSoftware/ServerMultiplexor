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
    final InstanceBulkAction action =
        requested ??
        await menuSelect<InstanceBulkAction>(
          'Actions for ${targets.length} selected servers',
          <MenuEntry<InstanceBulkAction>>[
            const MenuEntry<InstanceBulkAction>(
              'Start selected',
              value: InstanceBulkAction.start,
              shortcut: 's',
            ),
            const MenuEntry<InstanceBulkAction>(
              'Stop selected',
              value: InstanceBulkAction.stop,
              shortcut: 't',
            ),
            const MenuEntry<InstanceBulkAction>(
              'Restart selected',
              value: InstanceBulkAction.restart,
              shortcut: 'r',
            ),
            MenuEntry<InstanceBulkAction>(
              'Delete selected',
              value: InstanceBulkAction.delete,
              shortcut: 'd',
              labelColor: Ansi.red,
            ),
          ],
        );
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
      await _runLocalSelectionAction(grouped, action, sources);
    } finally {
      for (final PassthroughService source in sources.values) {
        source.disposeRcon();
      }
    }
  }

  /// One plan across every platform the selection spans: a single
  /// confirmation for deletes, then each platform's bulk command. Success
  /// returns straight to the dashboard; a failure keeps its output up.
  Future<void> _runLocalSelectionAction(
    Map<ConsumerProfile, List<String>> grouped,
    InstanceBulkAction action,
    Map<ConsumerProfile, PassthroughService> sources,
  ) async {
    final Map<ConsumerProfile, Map<String, _InstanceRow>> rows = await Ui.spin(
      'Checking selected servers',
      () async => <ConsumerProfile, Map<String, _InstanceRow>>{
        for (final ConsumerProfile profile in grouped.keys)
          profile: <String, _InstanceRow>{
            for (final _InstanceRow row in await _loadInstanceRows(
              source: sources[profile],
            ))
              row.name: row,
          },
      },
    );
    final Map<ConsumerProfile, List<String>> eligible =
        <ConsumerProfile, List<String>>{};
    final List<String> skipped = <String>[];
    for (final ConsumerProfile profile in grouped.keys) {
      for (final String name in grouped[profile]!) {
        final _InstanceRow? row = rows[profile]![name];
        if (row == null) {
          throw StateError(
            '${profile.shortName}/$name is no longer available. Refresh and select again.',
          );
        }
        final String? reason = instanceBulkSkipReason(
          action,
          row.state,
          locked: row.locked,
        );
        if (reason == null) {
          eligible.putIfAbsent(profile, () => <String>[]).add(name);
        } else {
          skipped.add('${profile.shortName}/$name: $reason');
        }
      }
    }
    final int count = eligible.values.fold(
      0,
      (int total, List<String> names) => total + names.length,
    );
    if (count == 0) {
      Ui.report(instanceBulkOutcome(action, 0, skipped: skipped.length));
      return;
    }
    if (action == InstanceBulkAction.delete) {
      Ui.appHeader('DELETE SELECTED', <String>[
        for (final ConsumerProfile profile in eligible.keys)
          '${profile.shortName} ${eligible[profile]!.length}',
      ]);
      for (final ConsumerProfile profile in eligible.keys) {
        for (final String name in eligible[profile]!) {
          Ui.keyValue(
            name,
            '${profile.shortName} · ${rows[profile]![name]!.state.name}',
          );
        }
      }
      for (final String line in skipped) {
        Ui.note('skip $line');
      }
      if (!await Ui.confirm(
        'Delete $count ${count == 1 ? 'server' : 'servers'} and their data?',
        destructive: true,
      )) {
        return;
      }
    } else {
      Ui.doing('Bulk ${action.name}: $count servers');
    }
    bool failed = false;
    for (final ConsumerProfile profile in eligible.keys) {
      final List<String> names = eligible[profile]!;
      final int code = await Ui.shielded(
        () => sources[profile]!.run(<String>[
          'instance',
          'bulk',
          action.name,
          ...names,
          if (action == InstanceBulkAction.delete) ...<String>[
            '--confirm',
            instanceBulkDeleteToken(names),
          ],
        ]),
      );
      failed = failed || code != 0;
    }
    if (failed) {
      await Ui.pause();
      return;
    }
    Ui.report(instanceBulkOutcome(action, count, skipped: skipped.length));
  }
}
