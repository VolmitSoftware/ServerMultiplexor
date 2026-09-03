part of 'interactive_wizard.dart';

/// Presentation of the engine's addon catalog for a single instance.
/// Compatibility, dependency resolution, and installation stay in the engine.
class WizardAddonChecklist {
  WizardAddonChecklist._({
    required this.minecraft,
    required this.versionRequired,
    required this.options,
    required this.unavailableNotes,
  });

  factory WizardAddonChecklist.parse(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded case {
      'minecraft': final String minecraft,
      'versionRequired': final bool versionRequired,
      'entries': final List<Object?> entries,
    }) {
      final List<WizardAddonOption> options = <WizardAddonOption>[];
      final List<String> unavailableNotes = <String>[];
      for (final Object? entry in entries) {
        if (entry case {
          'id': final String id,
          'name': final String name,
          'description': final String description,
          'selected': final bool selected,
          'available': final bool available,
        }) {
          final Object? reason = (entry as Map<String, Object?>)['reason'];
          if (!available) {
            unavailableNotes.add(
              '$name: ${reason is String && reason.isNotEmpty ? reason : 'Unavailable for this server.'}',
            );
          }
          if (available || selected) {
            options.add(
              WizardAddonOption(
                id: id,
                name: name,
                description: description,
                selected: selected,
                available: available,
              ),
            );
          }
        } else {
          throw const FormatException('Invalid addon catalog entry.');
        }
      }
      return WizardAddonChecklist._(
        minecraft: minecraft.trim(),
        versionRequired: versionRequired,
        options: List<WizardAddonOption>.unmodifiable(options),
        unavailableNotes: List<String>.unmodifiable(unavailableNotes),
      );
    }
    throw const FormatException('Invalid addon catalog response.');
  }

  final String minecraft;
  final bool versionRequired;
  final List<WizardAddonOption> options;
  final List<String> unavailableNotes;

  Set<int> get initiallySelected => <int>{
    for (int index = 0; index < options.length; index++)
      if (options[index].selected) index,
  };

  List<String> get labels => <String>[
    for (final WizardAddonOption option in options) option.label,
  ];

  /// No command means the user retained the current selection.
  List<String>? commandFor(String instance, Set<int> selection) {
    for (final int index in selection) {
      RangeError.checkValidIndex(index, options, 'selection');
    }
    final Set<int> previous = initiallySelected;
    if (selection.length == previous.length &&
        selection.containsAll(previous)) {
      return null;
    }
    return <String>[
      'addons',
      'set',
      instance,
      if (selection.isEmpty)
        '--none'
      else ...<String>[
        '--select',
        <String>[
          for (int index = 0; index < options.length; index++)
            if (selection.contains(index)) options[index].id,
        ].join(','),
      ],
      if (minecraft.isNotEmpty) ...<String>['--mc', minecraft],
    ];
  }
}

class WizardAddonOption {
  const WizardAddonOption({
    required this.id,
    required this.name,
    required this.description,
    required this.selected,
    required this.available,
  });

  final String id;
  final String name;
  final String description;
  final bool selected;
  final bool available;

  String get label => !available
      ? '$name (unavailable; uncheck to remove)'
      : description.isEmpty
      ? name
      : '$name · $description';
}

extension _AddonWizard on InteractiveWizard {
  /// Returns false on a command failure so setup cannot reach its first start.
  /// Escape propagates to the dashboard's existing back-navigation handler.
  Future<bool> _configureInstanceAddons(
    String name, {
    bool duringSetup = false,
  }) async {
    String? requestedMinecraft;
    late WizardAddonChecklist checklist;
    while (true) {
      final CapturedResult result = await Ui.shielded(
        () => passthrough.capture(<String>[
          'addons',
          'list',
          name,
          '--json',
          if (requestedMinecraft != null) ...<String>[
            '--mc',
            requestedMinecraft,
          ],
        ]),
      );
      if (!result.success) {
        Ui.error('Could not load addons for $name.');
        if (result.stderr.trim().isNotEmpty) Ui.note(result.stderr.trim());
        if (duringSetup) Ui.note('$name remains stopped.');
        await Ui.pause();
        return false;
      }

      checklist = WizardAddonChecklist.parse(result.stdout);
      if (!checklist.versionRequired) break;
      Ui.note(
        'Enter this server\'s Minecraft version to choose compatible addons.',
      );
      requestedMinecraft = await Ui.input(
        'Minecraft version for $name',
        validator: _looksLikeMinecraftVersion,
        validationMessage: 'Use a version like 1.21.11 or 26.1.2.',
      );
    }
    for (final String note in checklist.unavailableNotes) {
      Ui.note(note);
    }
    if (checklist.options.isEmpty) {
      Ui.note('No compatible addons are available for this server.');
      if (!duringSetup) await Ui.pause();
      return true;
    }

    Ui.note('Check addons to install; uncheck managed addons to remove them.');
    Ui.note('ViaBackwards automatically includes ViaVersion.');
    final Set<int> selection = await Ui.checklist(
      'Addons for $name',
      checklist.labels,
      initiallySelected: checklist.initiallySelected,
    );
    final List<String>? command = checklist.commandFor(name, selection);
    if (command == null) {
      if (!duringSetup) {
        Ui.note('Addon selection unchanged.');
        await Ui.pause();
      }
      return true;
    }

    Ui.doing('Applying addons for $name');
    final int code = await _shellRun(command);
    if (code != 0) {
      if (duringSetup) Ui.note('$name remains stopped.');
      await Ui.pause();
      return false;
    }
    if (!duringSetup) await Ui.pause();
    return true;
  }
}
