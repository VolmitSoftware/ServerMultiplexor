import 'dart:convert';

import 'package:multiplexor/services/interactive_wizard.dart';
import 'package:test/test.dart';

Map<String, Object?> entry(
  String id, {
  String? name,
  String description = '',
  bool selected = false,
  bool available = true,
  String? reason,
}) => <String, Object?>{
  'id': id,
  'name': name ?? id,
  'description': description,
  'selected': selected,
  'available': available,
  'reason': reason,
};

WizardAddonChecklist checklist(
  List<Map<String, Object?>> entries, {
  String minecraft = '1.21.11',
  bool versionRequired = false,
}) => WizardAddonChecklist.parse(
  jsonEncode(<String, Object?>{
    'instance': 'demo',
    'type': 'paper',
    'minecraft': minecraft,
    'versionRequired': versionRequired,
    'entries': entries,
  }),
);

void main() {
  group('Wizard addon checklist', () {
    test('retains selected unavailable addons so they can be removed', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('essentialsx', available: false, reason: 'Requires Paper.'),
        entry(
          'fawe',
          selected: true,
          available: false,
          reason: 'Requires Paper.',
        ),
        entry('viaversion', selected: true),
        entry('viabackwards'),
      ]);

      expect(
        model.options.map((WizardAddonOption option) => option.id),
        <String>['fawe', 'viaversion', 'viabackwards'],
      );
      expect(model.initiallySelected, <int>{0, 1});
      expect(model.labels.first, 'fawe (unavailable; uncheck to remove)');
      expect(model.unavailableNotes, <String>[
        'essentialsx: Requires Paper.',
        'fawe: Requires Paper.',
      ]);
      expect(model.commandFor('demo', <int>{1}), <String>[
        'addons',
        'set',
        'demo',
        '--select',
        'viaversion',
        '--mc',
        '1.21.11',
      ]);
    });

    test(
      'preserves engine names and descriptions including development status',
      () {
        final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
          entry(
            'protocollib',
            name: 'ProtocolLib',
            description: 'Development build for this Minecraft version',
          ),
        ]);
        expect(
          model.labels.single,
          'ProtocolLib · Development build for this Minecraft version',
        );
      },
    );

    test('does not apply an unchanged selection regardless of set order', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('viaversion', selected: true),
        entry('viabackwards', selected: true),
      ]);
      expect(model.commandFor('demo', <int>{1, 0}), isNull);
    });

    test('renders new catalog entries without addon-specific UI changes', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('custom-addon', name: 'Custom addon'),
        entry('viaversion'),
        entry('viabackwards'),
      ]);
      expect(model.labels.first, 'Custom addon');
      expect(model.commandFor('demo', <int>{2, 0}), <String>[
        'addons',
        'set',
        'demo',
        '--select',
        'custom-addon,viabackwards',
        '--mc',
        '1.21.11',
      ]);
    });

    test('uses explicit none to remove every managed addon', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('viaversion', selected: true),
      ]);
      expect(model.commandFor('demo', <int>{}), <String>[
        'addons',
        'set',
        'demo',
        '--none',
        '--mc',
        '1.21.11',
      ]);
    });

    test(
      'applies the resolved catalog version alongside changed selection',
      () {
        final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
          entry('viaversion'),
        ], minecraft: ' 26.1.2 ');

        expect(model.minecraft, '26.1.2');
        expect(model.versionRequired, isFalse);
        expect(model.commandFor('demo', <int>{0}), <String>[
          'addons',
          'set',
          'demo',
          '--select',
          'viaversion',
          '--mc',
          '26.1.2',
        ]);
      },
    );

    test('requests version input when the engine marks it required', () {
      final WizardAddonChecklist model = checklist(
        <Map<String, Object?>>[
          entry('fawe', available: false, reason: 'Minecraft version unknown.'),
        ],
        minecraft: '',
        versionRequired: true,
      );

      expect(model.minecraft, isEmpty);
      expect(model.versionRequired, isTrue);
      expect(model.options, isEmpty);
    });

    test(
      'unknown version alone does not require input on unsupported platforms',
      () {
        final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
          entry('fawe', available: false, reason: 'Requires Paper.'),
        ], minecraft: '');

        expect(model.versionRequired, isFalse);
        expect(model.options, isEmpty);
      },
    );

    test('omits an unresolved version when removing an unsupported addon', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('viaversion', selected: true, available: false),
      ], minecraft: '');

      expect(model.commandFor('demo', <int>{}), <String>[
        'addons',
        'set',
        'demo',
        '--none',
      ]);
    });

    test('has no selectable rows for a platform without eligible addons', () {
      final WizardAddonChecklist model = checklist(<Map<String, Object?>>[
        entry('essentialsx', available: false),
      ]);
      expect(model.options, isEmpty);
      expect(model.unavailableNotes, <String>[
        'essentialsx: Unavailable for this server.',
      ]);
      expect(model.commandFor('demo', <int>{}), isNull);
    });

    test(
      'rejects a malformed catalog instead of presenting an empty selection',
      () {
        for (final String source in <String>[
          '{}',
          '{"minecraft":"1.21.11","versionRequired":false,"entries":[{"id":"fawe"}]}',
          '{"minecraft":12111,"versionRequired":false,"entries":[]}',
          '{"minecraft":"","versionRequired":"true","entries":[]}',
          '{"minecraft":"","entries":[]}',
          'not JSON',
        ]) {
          expect(
            () => WizardAddonChecklist.parse(source),
            throwsFormatException,
          );
        }
      },
    );
  });
}
