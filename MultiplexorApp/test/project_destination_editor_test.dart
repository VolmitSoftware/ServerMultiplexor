import 'dart:collection';

import 'package:multiplexor/services/projects/project_destination_editor.dart';
import 'package:multiplexor/services/projects/project_terminal.dart';
import 'package:multiplexor/utils/native_directory_picker.dart';
import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

void main() {
  test('folder picker selection stays a draft until Save', () async {
    List<String?> initial = <String?>[];
    _Outcome outcome = await _run(
      <TermEvent>[_char('f'), _char('s')],
      directoryPicker: ({String? initialDirectory}) async {
        initial.add(initialDirectory);
        return '/tmp/Plugin Outputs';
      },
    );
    expect(initial, <String>['/tmp/example-exports']);
    expect(outcome.result!.arguments, contains('/tmp/Plugin Outputs'));
    expect(outcome.terminal.activations, 2);
    expect(outcome.terminal.restores, 2);
  });

  test('cancelling the native folder picker retains the path', () async {
    _Outcome outcome = await _run(<TermEvent>[
      _char('f'),
      _char('s'),
    ], directoryPicker: ({String? initialDirectory}) async => null);
    expect(outcome.result!.arguments, _savedArguments);
    expect(outcome.terminal.activations, 2);
    expect(outcome.terminal.restores, 2);
  });

  test(
    'picker paths preserve filesystem characters without terminal controls',
    () async {
      const String selected = '/tmp/exports\x1b[31m';
      _Outcome outcome = await _run(<TermEvent>[
        _char('f'),
        _enter,
        _escape,
        _char('s'),
      ], directoryPicker: ({String? initialDirectory}) async => selected);
      expect(outcome.result!.arguments, contains(selected));
      expect(outcome.terminal.frames.join(), isNot(contains('\x1b[31m')));
    },
  );

  test('folder-picker errors leave the form usable for manual entry', () async {
    _Outcome outcome = await _run(
      <TermEvent>[
        _char('f'),
        ..._edit('/tmp/manual', previous: '/tmp/example-exports'),
        _char('s'),
      ],
      directoryPicker: ({String? initialDirectory}) async {
        throw const NativeDirectoryPickerException(
          'Picker unavailable; type the path.',
        );
      },
    );
    expect(outcome.result!.arguments, contains('/tmp/manual'));
    expect(
      outcome.terminal.output,
      contains('Picker unavailable; type the path.'),
    );
    expect(outcome.terminal.activations, 2);
    expect(outcome.terminal.restores, 2);
  });

  test(
    'Path browse button requires matching mouse press and release',
    () async {
      int opened = 0;
      for (int width in <int>[48, 80, 140]) {
        _Outcome rejected = await _run(
          <TermEvent>[
            TermEvent(TermEventKind.mouseDown, row: 6, col: width - 6),
            const TermEvent(TermEventKind.mouseUp, row: 6, col: 3),
            _escape,
          ],
          columns: width,
          lines: 14,
          directoryPicker: ({String? initialDirectory}) async {
            opened++;
            return null;
          },
        );
        expect(rejected.result, isNull);
        expect(opened, 0);
      }
      for (int width in <int>[48, 80, 140]) {
        _Outcome selected = await _run(
          <TermEvent>[
            TermEvent(TermEventKind.mouseDown, row: 6, col: width - 6),
            TermEvent(TermEventKind.mouseUp, row: 6, col: width - 6),
            _char('s'),
          ],
          columns: width,
          lines: 14,
          directoryPicker: ({String? initialDirectory}) async {
            opened++;
            return '/tmp/chosen';
          },
        );
        expect(selected.result!.arguments, contains('/tmp/chosen'));
        expect(
          Ansi.strip(selected.terminal.frames.first).split('\r\n')[5],
          contains('[ ... ]'),
        );
      }
      expect(opened, 3);
    },
  );

  test('non-directory destinations do not open the folder picker', () async {
    int opened = 0;
    for (String kind in <String>['instance', 'dropins']) {
      _Outcome outcome = await _run(
        <TermEvent>[_char('f'), _escape],
        destinations: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'target',
            'kind': kind,
            'instance': 'sample',
            'platform': 'plugin',
            'minecraft': '26.3',
          },
        ],
        directoryPicker: ({String? initialDirectory}) async {
          opened++;
          return '/tmp/chosen';
        },
      );
      expect(outcome.result, isNull);
      expect(outcome.terminal.output, isNot(contains('[ ... ]')));
    }
    expect(opened, 0);
  });

  test(
    'version field explains its delivery meaning for every destination kind',
    () async {
      for (String kind in <String>['directory', 'instance', 'dropins']) {
        _Outcome outcome = await _run(
          <TermEvent>[const TermEvent(TermEventKind.end), _escape],
          destinations: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'target',
              'kind': kind,
              'path': '/tmp/target',
              'instance': 'sample',
              'platform': 'plugin',
            },
          ],
          columns: 48,
          lines: 14,
        );
        expect(outcome.terminal.output, contains('Minecraft version'));
        expect(
          outcome.terminal.output,
          contains(switch (kind) {
            'directory' => 'Any version (optional)',
            'instance' => 'Use instance version',
            _ => 'Required, e.g. 26.3',
          }),
        );
        expect(
          outcome.terminal.output,
          contains(switch (kind) {
            'directory' => 'Delivery filter; blank allows any MC version.',
            'instance' => 'Blank = instance version; entered must match.',
            _ => 'Delivery filter; exact MC version is required.',
          }),
        );
      }
    },
  );

  test(
    'creates a directory destination by editing fields on one screen',
    () async {
      _Outcome outcome = await _run(
        <TermEvent>[
          ..._edit('exports'),
          _tab,
          _tab,
          ..._edit('/tmp/project-exports'),
          _tab,
          _right,
          _tab,
          ..._edit('26.3'),
          _char('s'),
        ],
        destinations: <Map<String, Object?>>[],
        newDestination: true,
      );
      expect(outcome.result!.action, ProjectDestinationEditAction.save);
      expect(outcome.result!.arguments, <String>[
        'destination',
        'exports',
        '--path',
        '/tmp/project-exports',
        '--platform',
        'plugin',
        '--mc',
        '26.3',
      ]);
      expect(outcome.terminal.activations, 1);
      expect(outcome.terminal.restores, 1);
    },
  );

  test(
    'saving an existing destination preserves its name and defaults',
    () async {
      _Outcome outcome = await _run(<TermEvent>[_char('s')]);
      expect(outcome.result!.action, ProjectDestinationEditAction.save);
      expect(outcome.result!.arguments, _savedArguments);
      expect(_exports['name'], 'exports');
      expect(_exports['path'], '/tmp/example-exports');
      expect(outcome.terminal.output, contains('exports'));
    },
  );

  test('platform and Minecraft filters can both be cleared', () async {
    _Outcome outcome = await _run(<TermEvent>[
      _tab,
      _tab,
      _tab,
      _left,
      _tab,
      ..._edit('', previous: '26.3'),
      _char('s'),
    ]);
    expect(outcome.result!.arguments, <String>[
      'destination',
      'exports',
      '--path',
      '/tmp/example-exports',
    ]);
  });

  test(
    'save focuses invalid names, duplicate names, and missing paths for correction',
    () async {
      _Outcome outcome = await _run(<TermEvent>[
        ..._edit('Bad Name'),
        _char('s'),
        ..._edit('exports', previous: 'Bad Name'),
        _char('s'),
        ..._edit('fresh', previous: 'exports'),
        _char('s'),
        ..._edit('/tmp/fresh'),
        _char('s'),
      ], newDestination: true);
      expect(outcome.result!.arguments, <String>[
        'destination',
        'fresh',
        '--path',
        '/tmp/fresh',
      ]);
      expect(outcome.terminal.output, contains('Name: use lowercase'));
      expect(
        outcome.terminal.output,
        contains('Name: this location already exists.'),
      );
      expect(
        outcome.terminal.output,
        contains('Path: enter an export directory.'),
      );
    },
  );

  test(
    'drop-ins use a supported consumer and require an exact version',
    () async {
      _Outcome outcome = await _run(
        <TermEvent>[
          _char('s'),
          ..._edit('26.*'),
          _char('s'),
          ..._edit('26.3', previous: '26.*'),
          _char('s'),
        ],
        destinations: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'test-dropins',
            'kind': 'dropins',
            'platform': 'velocity',
          },
        ],
      );
      expect(outcome.result!.arguments, <String>[
        'destination',
        'test-dropins',
        '--dropins',
        '--platform',
        'plugin',
        '--mc',
        '26.3',
      ]);
      expect(outcome.terminal.output.toLowerCase(), contains('platform'));
      expect(outcome.terminal.output.toLowerCase(), contains('exact'));
    },
  );

  test(
    'instance destinations require a name and return an instance argument',
    () async {
      _Outcome outcome = await _run(
        <TermEvent>[_char('s'), ..._edit('build-test'), _char('s')],
        destinations: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'test-instance',
            'kind': 'instance',
            'platform': 'plugin',
          },
        ],
      );
      expect(outcome.result!.arguments, <String>[
        'destination',
        'test-instance',
        '--instance',
        'build-test',
        '--platform',
        'plugin',
      ]);
      expect(outcome.terminal.output.toLowerCase(), contains('instance'));
    },
  );

  test('q is literal text during inline editing', () async {
    _Outcome outcome = await _run(<TermEvent>[
      ..._edit('queue-exports'),
      _tab,
      _tab,
      ..._edit('/tmp/queue-exports'),
      _char('s'),
    ], newDestination: true);
    expect(outcome.result!.arguments, <String>[
      'destination',
      'queue-exports',
      '--path',
      '/tmp/queue-exports',
    ]);
  });

  test('Escape cancels only the active field edit', () async {
    _Outcome outcome = await _run(<TermEvent>[
      _tab,
      _tab,
      _enter,
      ..._text('/discarded'),
      _escape,
      _char('s'),
    ]);
    expect(outcome.result!.arguments, _savedArguments);
  });

  test('dirty Back can keep changes or discard without a command', () async {
    for (TermEvent keep in <TermEvent>[_char('n'), _escape]) {
      _Outcome outcome = await _run(<TermEvent>[
        _tab,
        _tab,
        ..._edit('/tmp/changed', previous: '/tmp/example-exports'),
        _escape,
        keep,
        _char('s'),
      ]);
      expect(outcome.result!.arguments, <String>[
        'destination',
        'exports',
        '--path',
        '/tmp/changed',
        '--platform',
        'plugin',
        '--mc',
        '26.3',
      ]);
    }
    _Outcome discarded = await _run(<TermEvent>[
      _tab,
      _tab,
      ..._edit('/tmp/changed', previous: '/tmp/example-exports'),
      _char('q'),
      _char('y'),
    ]);
    expect(discarded.result, isNull);
  });

  test('removal needs confirmation and only removes configuration', () async {
    for (TermEvent cancel in <TermEvent>[_char('n'), _escape]) {
      _Outcome outcome = await _run(<TermEvent>[
        _char('r'),
        cancel,
        _char('s'),
      ]);
      expect(outcome.result!.action, ProjectDestinationEditAction.save);
      expect(outcome.result!.arguments, _savedArguments);
    }
    _Outcome removed = await _run(<TermEvent>[_char('r'), _char('y')]);
    expect(removed.result!.action, ProjectDestinationEditAction.remove);
    expect(removed.result!.arguments, <String>[
      'destination',
      'exports',
      '--remove',
    ]);
    expect(removed.terminal.output.toLowerCase(), contains('files'));
  });

  test(
    'preview returns the clean saved destination only when available',
    () async {
      _Outcome available = await _run(<TermEvent>[
        _char('p'),
      ], canPreview: true);
      expect(available.result!.action, ProjectDestinationEditAction.preview);
      expect(available.result!.destination, _exports);
      expect(available.result!.arguments, isEmpty);
      _Outcome unavailable = await _run(<TermEvent>[_char('p'), _char('q')]);
      expect(unavailable.result, isNull);
      _Outcome unsaved = await _run(
        <TermEvent>[_char('p'), _char('q')],
        newDestination: true,
        canPreview: true,
      );
      expect(unsaved.result, isNull);
      _Outcome dirty = await _run(<TermEvent>[
        _tab,
        _tab,
        ..._edit('/tmp/changed', previous: '/tmp/example-exports'),
        _char('p'),
        _char('s'),
      ], canPreview: true);
      expect(dirty.result!.action, ProjectDestinationEditAction.save);
      expect(dirty.result!.arguments, contains('/tmp/changed'));
    },
  );

  test(
    'mouse Save requires a matching left-button press and release',
    () async {
      for (List<TermEvent> gesture in <List<TermEvent>>[
        <TermEvent>[const TermEvent(TermEventKind.mouseDown, row: 11, col: 20)],
        <TermEvent>[const TermEvent(TermEventKind.mouseUp, row: 11, col: 20)],
        <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 11, col: 20, button: 2),
          const TermEvent(TermEventKind.mouseUp, row: 11, col: 20, button: 2),
        ],
        <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 11, col: 20),
          const TermEvent(TermEventKind.mouseUp, row: 11, col: 3),
        ],
        <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 11, col: 20),
          const TermEvent(TermEventKind.mouseUp, row: 10, col: 20),
        ],
      ]) {
        _Outcome rejected = await _run(
          <TermEvent>[...gesture, _escape],
          columns: 48,
          lines: 14,
        );
        expect(rejected.result, isNull);
        expect(rejected.terminal.restores, 1);
      }
      _Outcome saved = await _run(
        <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 11, col: 20),
          const TermEvent(TermEventKind.mouseUp, row: 11, col: 20),
        ],
        columns: 48,
        lines: 14,
      );
      expect(saved.result!.action, ProjectDestinationEditAction.save);
      expect(saved.result!.arguments, _savedArguments);
    },
  );

  test(
    'clicking a text field edits it in place and preserves the fixed name',
    () async {
      _Outcome outcome = await _run(
        <TermEvent>[
          const TermEvent(TermEventKind.mouseDown, row: 6, col: 20),
          const TermEvent(TermEventKind.mouseUp, row: 6, col: 20),
          ..._text('/queue'),
          _enter,
          _char('s'),
        ],
        columns: 48,
        lines: 14,
      );
      expect(outcome.result!.arguments, <String>[
        'destination',
        'exports',
        '--path',
        '/tmp/example-exports/queue',
        '--platform',
        'plugin',
        '--mc',
        '26.3',
      ]);
      expect(outcome.terminal.output, contains('exports (fixed)'));
    },
  );

  test('all editable fields fit together at 48 columns and 14 rows', () async {
    for (bool newDestination in <bool>[false, true]) {
      _Outcome outcome = await _run(
        <TermEvent>[_escape],
        newDestination: newDestination,
        canPreview: true,
        columns: 48,
        lines: 14,
      );
      List<String> lines = Ansi.strip(
        outcome.terminal.frames.first,
      ).split('\r\n');
      expect(lines, hasLength(14));
      expect(lines.every((String line) => line.length <= 48), isTrue);
      for (String label in <String>[
        'Name',
        'Kind',
        'Path',
        'Platform',
        'Minecraft',
      ]) {
        expect(
          lines.sublist(3, 8).any((String line) => line.contains(label)),
          isTrue,
          reason: '$label must remain visible with the other fields',
        );
      }
      for (String label in <String>[
        'BACK',
        'NEW',
        'SAVE',
        'REMOVE',
        'PREVIEW',
      ]) {
        expect(lines[10], contains(label));
      }
      expect(outcome.result, isNull);
    }
  });
}

const TermEvent _tab = TermEvent(TermEventKind.tab);
const TermEvent _enter = TermEvent(TermEventKind.enter);
const TermEvent _escape = TermEvent(TermEventKind.escape);
const TermEvent _left = TermEvent(TermEventKind.arrowLeft);
const TermEvent _right = TermEvent(TermEventKind.arrowRight);

TermEvent _char(String value) => TermEvent(TermEventKind.char, char: value);

List<TermEvent> _text(String value) => <TermEvent>[
  for (int rune in value.runes) _char(String.fromCharCode(rune)),
];

List<TermEvent> _edit(String value, {String previous = ''}) => <TermEvent>[
  _enter,
  const TermEvent(TermEventKind.end),
  for (int index = 0; index < previous.length; index++)
    const TermEvent(TermEventKind.backspace),
  ..._text(value),
  _enter,
];

const Map<String, Object?> _exports = <String, Object?>{
  'name': 'exports',
  'kind': 'directory',
  'path': '/tmp/example-exports',
  'platform': 'plugin',
  'minecraft': '26.3',
};

const List<String> _savedArguments = <String>[
  'destination',
  'exports',
  '--path',
  '/tmp/example-exports',
  '--platform',
  'plugin',
  '--mc',
  '26.3',
];

Future<_Outcome> _run(
  List<TermEvent> events, {
  List<Map<String, Object?>> destinations = const <Map<String, Object?>>[
    _exports,
  ],
  bool newDestination = false,
  bool canPreview = false,
  int columns = 80,
  int lines = 24,
  ProjectDirectoryPicker? directoryPicker,
}) async {
  _Terminal terminal = _Terminal(columns: columns, lines: lines)
    ..input.addAll(events);
  Future<ProjectDestinationEdit?> running = ProjectDestinationEditor(
    destinations: destinations,
    newDestination: newDestination,
    canPreview: canPreview,
    terminal: terminal,
    theme: MonitorTheme.plainAscii(),
    directoryPicker: directoryPicker,
  ).run();
  try {
    return _Outcome(
      await running.timeout(const Duration(seconds: 5)),
      terminal,
    );
  } finally {
    terminal.input.add(const TermEvent(TermEventKind.ctrlC));
    await running;
  }
}

class _Outcome {
  const _Outcome(this.result, this.terminal);

  final ProjectDestinationEdit? result;
  final _Terminal terminal;
}

class _Terminal implements ProjectTerminal {
  _Terminal({required this.columns, required this.lines});

  final Queue<TermEvent> input = Queue<TermEvent>();
  final List<String> frames = <String>[];
  int activations = 0;
  int restores = 0;

  String get output => frames.map(Ansi.strip).join();

  @override
  bool get hasTerminal => true;
  @override
  final int columns;
  @override
  final int lines;
  @override
  void activate() => activations++;
  @override
  TermEvent? readEventTimeout(Duration timeout) =>
      input.isEmpty ? null : input.removeFirst();
  @override
  void write(String text) => frames.add(text);
  @override
  void restore() => restores++;
}
