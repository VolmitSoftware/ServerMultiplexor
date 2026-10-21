import 'dart:math' as math;

import '../../utils/native_directory_picker.dart';
import '../../utils/terminal/ansi.dart';
import '../../utils/terminal/button.dart';
import '../../utils/terminal/frame_patch.dart';
import '../../utils/terminal/panel.dart';
import '../../utils/terminal/term_events.dart';
import '../../utils/terminal/term_io.dart';
import '../../utils/terminal/theme.dart';
import 'project_dashboard_model.dart';
import 'project_terminal.dart';

enum ProjectDestinationEditAction { save, remove, preview }

class ProjectDestinationEdit {
  const ProjectDestinationEdit({
    required this.action,
    this.arguments = const <String>[],
    this.destination,
  });

  final ProjectDestinationEditAction action;
  final List<String> arguments;
  final Map<String, Object?>? destination;
}

enum _DestinationField { location, name, kind, address, platform, minecraft }

enum _DestinationPending { back, remove, select }

typedef ProjectDirectoryPicker =
    Future<String?> Function({String? initialDirectory});

class ProjectDestinationEditor {
  ProjectDestinationEditor({
    required List<Map<String, Object?>> destinations,
    bool canPreview = false,
    bool newDestination = false,
    ProjectTerminal? terminal,
    MonitorTheme? theme,
    ProjectDirectoryPicker? directoryPicker,
  }) : _destinations = destinations
           .map(Map<String, Object?>.from)
           .toList(growable: false),
       _canPreview = canPreview,
       _terminal = terminal ?? const DartProjectTerminal(),
       _theme = theme ?? MonitorTheme.cached,
       _directoryPicker =
           directoryPicker ?? NativeDirectoryPicker().pickDirectory {
    _load(newDestination || destinations.isEmpty ? -1 : 0);
  }

  static const List<String> _kinds = <String>[
    'directory',
    'instance',
    'dropins',
  ];

  final List<Map<String, Object?>> _destinations;
  final bool _canPreview;
  final ProjectTerminal _terminal;
  final MonitorTheme _theme;
  final ProjectDirectoryPicker _directoryPicker;
  final Map<int, List<ButtonSpan>> _hits = <int, List<ButtonSpan>>{};
  int _selected = -1;
  String _name = '';
  String _kind = 'directory';
  String _path = '';
  String _instance = '';
  String _platform = 'any';
  String _minecraft = '';
  List<String> _baseline = <String>[];
  _DestinationField _focus = _DestinationField.name;
  _DestinationField? _editing;
  List<int> _editRunes = <int>[];
  int _cursor = 0;
  String _notice = '';
  _DestinationPending? _pending;
  int _pendingSelection = -1;
  String? _pressed;
  String? _previousFrame;
  int _lastWidth = 0;
  int _lastHeight = 0;
  bool _active = false;
  ProjectDestinationEdit? _result;

  List<String> get _values => <String>[
    _name,
    _kind,
    _path,
    _instance,
    _platform,
    _minecraft,
  ];

  bool get _dirty {
    List<String> values = _values;
    for (int index = 0; index < values.length; index++) {
      if (values[index] != _baseline[index]) return true;
    }
    return false;
  }

  List<String> get _platforms => <String>[
    if (_kind == 'directory') 'any',
    'plugin',
    'fabric',
    'forge',
    'neoforge',
    if (_kind != 'dropins') ...<String>['velocity', 'bungee'],
  ];

  List<_DestinationField> get _fields => <_DestinationField>[
    _DestinationField.location,
    if (_selected < 0) _DestinationField.name,
    _DestinationField.kind,
    if (_kind != 'dropins') _DestinationField.address,
    _DestinationField.platform,
    _DestinationField.minecraft,
  ];

  bool get _previewEnabled => _canPreview && _selected >= 0 && !_dirty;

  Future<ProjectDestinationEdit?> run() async {
    if (!_terminal.hasTerminal) {
      throw StateError('Destination editing requires a terminal.');
    }
    _active = true;
    _result = null;
    _pressed = null;
    _previousFrame = null;
    try {
      _terminal.activate();
      while (_active) {
        _render();
        TermEvent? event = _terminal.readEventTimeout(
          const Duration(milliseconds: 40),
        );
        if (event != null) await _handle(event);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    } on TermInputUnavailable {
      _active = false;
    } finally {
      _active = false;
      _terminal.restore();
    }
    return _result;
  }

  void _load(int index) {
    _selected = index;
    Map<String, Object?>? saved = index < 0 ? null : _destinations[index];
    _name = projectText(saved?['name']);
    _kind = projectText(saved?['kind'] ?? 'directory');
    _path = _kind == 'directory' ? projectText(saved?['path']) : '';
    _instance = projectText(saved?['instance']);
    _platform = projectText(saved?['platform'] ?? 'any');
    if (!_platforms.contains(_platform)) _platform = _platforms.first;
    _minecraft = projectText(saved?['minecraft']);
    _baseline = _values;
    _focus = index < 0 ? _DestinationField.name : _DestinationField.location;
    _editing = null;
    _pending = null;
    _notice = '';
  }

  String _value(_DestinationField field) => switch (field) {
    _DestinationField.name => _name,
    _DestinationField.address => _kind == 'instance' ? _instance : _path,
    _DestinationField.minecraft => _minecraft,
    _ => '',
  };

  void _setValue(_DestinationField field, String value) {
    switch (field) {
      case _DestinationField.name:
        _name = value;
      case _DestinationField.address:
        if (_kind == 'instance') {
          _instance = value;
        } else {
          _path = value;
        }
      case _DestinationField.minecraft:
        _minecraft = value;
      default:
        break;
    }
  }

  void _beginEdit(_DestinationField field) {
    if (!_fields.contains(field)) return;
    _focus = field;
    _editing = field;
    _editRunes = _value(field).runes.toList();
    _cursor = _editRunes.length;
    _notice = '';
  }

  void _commitEdit() {
    if (_editing == null) return;
    _setValue(_editing!, String.fromCharCodes(_editRunes));
    _editing = null;
    _notice = '';
  }

  void _moveFocus(int step) {
    _commitEdit();
    List<_DestinationField> fields = _fields;
    int index = fields.indexOf(_focus);
    _focus = fields[(index + step) % fields.length];
  }

  void _cycle(int step) {
    _notice = '';
    if (_focus == _DestinationField.location) {
      int count = _destinations.length + 1;
      _switchTo((_selected + 1 + step) % count - 1);
    } else if (_focus == _DestinationField.kind) {
      _kind = _kinds[(_kinds.indexOf(_kind) + step) % _kinds.length];
      if (!_platforms.contains(_platform)) _platform = _platforms.first;
    } else if (_focus == _DestinationField.platform) {
      List<String> platforms = _platforms;
      _platform =
          platforms[(platforms.indexOf(_platform) + step) % platforms.length];
    }
  }

  void _switchTo(int index) {
    if (index == _selected) return;
    if (_dirty) {
      _pending = _DestinationPending.select;
      _pendingSelection = index;
    } else {
      _load(index);
    }
  }

  void _back() {
    if (_dirty) {
      _pending = _DestinationPending.back;
    } else {
      _active = false;
    }
  }

  void _confirm() {
    _DestinationPending? pending = _pending;
    _pending = null;
    switch (pending) {
      case _DestinationPending.back:
        _active = false;
      case _DestinationPending.select:
        _load(_pendingSelection);
      case _DestinationPending.remove:
        _finish(
          ProjectDestinationEdit(
            action: ProjectDestinationEditAction.remove,
            arguments: <String>['destination', _name, '--remove'],
          ),
        );
      case null:
        break;
    }
  }

  void _save() {
    String name = _name.trim();
    String minecraft = _minecraft.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(name)) {
      _invalid(
        _DestinationField.name,
        'Name: use lowercase letters, digits, . _ -',
      );
      return;
    }
    if (_selected < 0 &&
        _destinations.any(
          (Map<String, Object?> destination) => destination['name'] == name,
        )) {
      _invalid(_DestinationField.name, 'Name: this location already exists.');
      return;
    }
    if (_kind == 'directory' && _path.trim().isEmpty) {
      _invalid(_DestinationField.address, 'Path: enter an export directory.');
      return;
    }
    if (_kind == 'instance' && _instance.trim().isEmpty) {
      _invalid(_DestinationField.address, 'Instance: enter an instance name.');
      return;
    }
    if ((_kind == 'dropins' || minecraft.isNotEmpty) &&
        !RegExp(r'^\d+(?:\.\d+)*$').hasMatch(minecraft)) {
      _invalid(
        _DestinationField.minecraft,
        'Minecraft version: enter an exact value, e.g. 26.3.',
      );
      return;
    }
    _finish(
      ProjectDestinationEdit(
        action: ProjectDestinationEditAction.save,
        arguments: <String>[
          'destination',
          name,
          if (_kind == 'directory') ...<String>['--path', _path.trim()],
          if (_kind == 'instance') ...<String>['--instance', _instance.trim()],
          if (_kind == 'dropins') '--dropins',
          if (_platform != 'any') ...<String>['--platform', _platform],
          if (minecraft.isNotEmpty) ...<String>['--mc', minecraft],
        ],
      ),
    );
  }

  void _invalid(_DestinationField field, String message) {
    _focus = field;
    _notice = message;
  }

  void _finish(ProjectDestinationEdit result) {
    _result = result;
    _active = false;
  }

  Future<void> _pickDirectory() async {
    if (_kind != 'directory') return;
    _focus = _DestinationField.address;
    _terminal.restore();
    try {
      String? selected = await _directoryPicker(initialDirectory: _path);
      if (selected != null) {
        _path = selected;
        _notice = '';
      }
    } on NativeDirectoryPickerException catch (error) {
      _notice = projectText(error);
    } finally {
      _terminal.activate();
      _previousFrame = null;
    }
  }

  Future<void> _activate(String id) async {
    _commitEdit();
    if (_pending != null) {
      if (id == 'confirm') _confirm();
      if (id == 'keep') _pending = null;
      return;
    }
    if (id.startsWith('saved:')) {
      _switchTo(int.parse(id.substring(6)));
      return;
    }
    if (id.startsWith('field:')) {
      _DestinationField field = _DestinationField.values.byName(
        id.substring(6),
      );
      if (!_fields.contains(field)) return;
      _focus = field;
      if (<_DestinationField>{
        _DestinationField.location,
        _DestinationField.kind,
        _DestinationField.platform,
      }.contains(field)) {
        _cycle(1);
      } else {
        _beginEdit(field);
      }
      return;
    }
    switch (id) {
      case 'back':
        _back();
      case 'new':
        _switchTo(-1);
      case 'save':
        _save();
      case 'browse':
        await _pickDirectory();
      case 'remove':
        if (_selected >= 0) _pending = _DestinationPending.remove;
      case 'preview':
        if (_previewEnabled) {
          _finish(
            ProjectDestinationEdit(
              action: ProjectDestinationEditAction.preview,
              destination: Map<String, Object?>.from(_destinations[_selected]),
            ),
          );
        } else {
          _notice = !_canPreview
              ? 'Select a build run before previewing deployment.'
              : 'Save this location before previewing deployment.';
        }
    }
  }

  String? _hit(TermEvent event) {
    for (ButtonSpan span in _hits[event.row - 1] ?? <ButtonSpan>[]) {
      if (event.col - 1 >= span.colStart && event.col - 1 < span.colEnd) {
        return span.id;
      }
    }
    return null;
  }

  Future<void> _handle(TermEvent event) async {
    if (event.kind == TermEventKind.mouseDown) {
      _pressed = event.button == 0 ? _hit(event) : null;
      return;
    }
    if (event.kind == TermEventKind.mouseUp) {
      String? pressed = _pressed;
      _pressed = null;
      if (event.button == 0 && pressed != null && pressed == _hit(event)) {
        await _activate(pressed);
      }
      return;
    }
    if (event.kind == TermEventKind.ctrlC) {
      _active = false;
      return;
    }
    if (_pending != null) {
      if (event.kind == TermEventKind.char && event.char == 'y') _confirm();
      if (event.kind == TermEventKind.escape ||
          (event.kind == TermEventKind.char && event.char == 'n')) {
        _pending = null;
      }
      return;
    }
    if (_editing != null) {
      _handleEdit(event);
      return;
    }
    switch (event.kind) {
      case TermEventKind.escape:
        _back();
      case TermEventKind.tab:
      case TermEventKind.arrowDown:
      case TermEventKind.wheelDown:
        _moveFocus(1);
      case TermEventKind.arrowUp:
      case TermEventKind.wheelUp:
        _moveFocus(-1);
      case TermEventKind.arrowLeft:
        _cycle(-1);
      case TermEventKind.arrowRight:
        _cycle(1);
      case TermEventKind.enter:
        await _activate('field:${_focus.name}');
      case TermEventKind.home:
        _focus = _fields.first;
      case TermEventKind.end:
        _focus = _fields.last;
      case TermEventKind.char:
        String? action = switch (event.char) {
          'a' => 'new',
          's' => 'save',
          'r' => 'remove',
          'p' => 'preview',
          'q' => 'back',
          'f' => 'browse',
          ' ' => 'field:${_focus.name}',
          _ => null,
        };
        if (action != null) await _activate(action);
      default:
        break;
    }
  }

  void _handleEdit(TermEvent event) {
    switch (event.kind) {
      case TermEventKind.escape:
        _editing = null;
      case TermEventKind.enter:
        _commitEdit();
      case TermEventKind.tab:
      case TermEventKind.arrowDown:
        _moveFocus(1);
      case TermEventKind.arrowUp:
        _moveFocus(-1);
      case TermEventKind.arrowLeft:
        _cursor = math.max(0, _cursor - 1);
      case TermEventKind.arrowRight:
        _cursor = math.min(_editRunes.length, _cursor + 1);
      case TermEventKind.home:
        _cursor = 0;
      case TermEventKind.end:
        _cursor = _editRunes.length;
      case TermEventKind.backspace:
        if (_cursor > 0) _editRunes.removeAt(--_cursor);
      case TermEventKind.delete:
        if (_cursor < _editRunes.length) _editRunes.removeAt(_cursor);
      case TermEventKind.char:
        List<int> added = projectText(event.char).runes.toList();
        _editRunes.insertAll(_cursor, added);
        _cursor += added.length;
      default:
        break;
    }
  }

  String _fit(String value, int width) => Ansi.padVisible(
    Ansi.clipVisible(value, math.max(0, width)),
    math.max(0, width),
  );

  String _editView(int width) {
    String before = projectText(String.fromCharCodes(_editRunes.take(_cursor)));
    int start = 0;
    while (before.length > width - 3 && start < _cursor) {
      start++;
      before = projectText(
        String.fromCharCodes(_editRunes.sublist(start, _cursor)),
      );
    }
    StringBuffer value = StringBuffer('${start > 0 ? '<' : ''}$before|');
    for (int rune in _editRunes.skip(_cursor)) {
      String character = projectText(String.fromCharCode(rune));
      if (value.length + character.length > width) break;
      value.write(character);
    }
    return _fit(value.toString(), width);
  }

  String _fieldLine(_DestinationField field, int width) {
    String label = switch (field) {
      _DestinationField.name => 'Name',
      _DestinationField.kind => 'Kind',
      _DestinationField.address =>
        _kind == 'instance'
            ? 'Instance'
            : _kind == 'dropins'
            ? 'Dropins'
            : 'Path',
      _DestinationField.platform => 'Platform',
      _DestinationField.minecraft => 'Minecraft version',
      _DestinationField.location => 'Location',
    };
    bool browse = field == _DestinationField.address && _kind == 'directory';
    int valueWidth = width - 21 - (browse ? 8 : 0);
    String value;
    if (_editing == field) {
      value = _editView(valueWidth);
    } else {
      value = switch (field) {
        _DestinationField.name => _name.isEmpty ? '(required)' : _name,
        _DestinationField.kind =>
          '< ${switch (_kind) {
            'instance' => 'Instance',
            'dropins' => 'Dropins',
            _ => 'Directory',
          }} >',
        _DestinationField.address =>
          _kind == 'dropins'
              ? 'Managed by Multiplexor'
              : _value(field).isEmpty
              ? '(required)'
              : _value(field),
        _DestinationField.platform => '< $_platform >',
        _DestinationField.minecraft =>
          _minecraft.isNotEmpty
              ? _minecraft
              : _kind == 'dropins'
              ? 'Required, e.g. 26.3'
              : _kind == 'instance'
              ? 'Use instance version'
              : 'Any version (optional)',
        _DestinationField.location => '',
      };
      if (field == _DestinationField.name && _selected >= 0) {
        value = '$value (fixed)';
      }
      value = _fit(projectText(value), valueWidth);
    }
    String line = '${_focus == field ? '>' : ' '} ${label.padRight(17)} $value';
    String styled = _focus == field
        ? _theme.paint(line, '${_theme.bold}${_theme.accent}')
        : line;
    return browse
        ? '$styled ${renderButton(label: '...', theme: _theme, state: _pressed == 'browse' ? ButtonState.pressed : ButtonState.normal)}'
        : styled;
  }

  void _render() {
    int width = math.max(1, _terminal.columns);
    int height = math.max(1, _terminal.lines);
    _hits.clear();
    List<String> lines = <String>[
      _theme.paint(
        'MULTIPLEXOR / DESTINATIONS',
        '${_theme.bold}${_theme.textStrong}',
      ),
    ];
    if (width < 48 || height < 14) {
      lines.add('Use a terminal at least 48 columns by 14 rows.');
      lines.add('q / Esc: Back');
    } else {
      bool lateral = width >= 96;
      String location = _selected < 0
          ? 'New location'
          : '${_selected + 1}/${_destinations.length}  $_name';
      lines.add(
        _theme.paint(
          '${_focus == _DestinationField.location ? '>' : ' '} Location  < $location >${_dirty ? '  unsaved' : ''}',
          _focus == _DestinationField.location ? _theme.accent : _theme.muted,
        ),
      );
      _hits[1] = <ButtonSpan>[
        ButtonSpan(id: 'field:location', colStart: 0, colEnd: width),
      ];
      int savedWidth = lateral ? math.min(32, (width * 0.28).floor()) : 0;
      int formOffset = lateral ? savedWidth + 1 : 0;
      int formWidth = width - formOffset;
      List<_DestinationField> formFields = <_DestinationField>[
        _DestinationField.name,
        _DestinationField.kind,
        _DestinationField.address,
        _DestinationField.platform,
        _DestinationField.minecraft,
      ];
      List<String> form = renderPanel(
        title: _selected < 0 ? 'NEW LOCATION' : 'EDIT LOCATION',
        badge: _dirty ? 'unsaved' : null,
        content: formFields
            .map((_DestinationField field) => _fieldLine(field, formWidth - 4))
            .toList(growable: false),
        width: formWidth,
        theme: _theme,
        emphasis: PanelEmphasis.active,
      );
      for (int index = 0; index < formFields.length; index++) {
        _DestinationField field = formFields[index];
        if (!_fields.contains(field)) continue;
        _hits[index + 3] = <ButtonSpan>[
          ButtonSpan(
            id: 'field:${field.name}',
            colStart: formOffset + 2,
            colEnd:
                width -
                (field == _DestinationField.address && _kind == 'directory'
                    ? 11
                    : 2),
          ),
          if (field == _DestinationField.address && _kind == 'directory')
            ButtonSpan(id: 'browse', colStart: width - 10, colEnd: width - 3),
        ];
      }
      if (lateral) {
        int capacity = math.min(
          math.max(5, height - 9),
          math.max(5, _destinations.length),
        );
        int start = math.max(0, _selected - capacity + 1);
        List<String> saved = <String>[];
        for (
          int index = start;
          index < math.min(_destinations.length, start + capacity);
          index++
        ) {
          String name = projectText(_destinations[index]['name']);
          saved.add(
            _theme.paint(
              '${index == _selected ? '>' : ' '} $name',
              index == _selected ? _theme.accent : _theme.text,
            ),
          );
          _hits
              .putIfAbsent(saved.length + 2, () => <ButtonSpan>[])
              .add(
                ButtonSpan(
                  id: 'saved:$index',
                  colStart: 2,
                  colEnd: savedWidth - 2,
                ),
              );
        }
        if (saved.isEmpty) saved.add('No saved locations.');
        while (saved.length < 5) {
          saved.add('');
        }
        List<String> savedPanel = renderPanel(
          title: 'SAVED / ${_destinations.length}',
          content: saved,
          width: savedWidth,
          theme: _theme,
        );
        for (
          int index = 0;
          index < math.max(savedPanel.length, form.length);
          index++
        ) {
          lines.add(
            '${index < savedPanel.length ? savedPanel[index] : ' ' * savedWidth} '
            '${index < form.length ? form[index] : ' ' * formWidth}',
          );
        }
      } else {
        lines.addAll(form);
      }
      String message = _pending == _DestinationPending.remove
          ? 'Remove $_name? Destination files stay unchanged. y/n'
          : _pending != null
          ? 'Discard unsaved changes? y discard / n keep editing'
          : _notice.isNotEmpty
          ? _notice
          : _focus == _DestinationField.minecraft
          ? switch (_kind) {
              'directory' => 'Delivery filter; blank allows any MC version.',
              'instance' => 'Blank = instance version; entered must match.',
              _ => 'Delivery filter; exact MC version is required.',
            }
          : _editing != null
          ? 'Enter accepts this field. Esc cancels this field.'
          : 'Minecraft version filters delivered artifacts.';
      lines.add(
        _theme.paint(
          message,
          _pending != null
              ? _theme.warn
              : _notice.isNotEmpty
              ? _theme.danger
              : _theme.muted,
        ),
      );
      List<ButtonSpec> buttons = _pending != null
          ? <ButtonSpec>[
              ButtonSpec(
                id: 'confirm',
                label: _pending == _DestinationPending.remove
                    ? 'REMOVE'
                    : 'DISCARD',
                shortcut: 'y',
                danger: true,
              ),
              const ButtonSpec(
                id: 'keep',
                label: 'KEEP EDITING',
                shortcut: 'n',
              ),
            ]
          : <ButtonSpec>[
              const ButtonSpec(id: 'back', label: 'BACK', shortcut: 'q'),
              const ButtonSpec(id: 'new', label: 'NEW', shortcut: 'a'),
              const ButtonSpec(id: 'save', label: 'SAVE', shortcut: 's'),
              ButtonSpec(
                id: 'remove',
                label: 'REMOVE',
                shortcut: 'r',
                enabled: _selected >= 0,
                danger: true,
              ),
              ButtonSpec(
                id: 'preview',
                label: 'PREVIEW',
                shortcut: 'p',
                enabled: _previewEnabled,
              ),
            ];
      ButtonRowRender actions = layoutButtonRow(
        buttons: buttons,
        width: width,
        theme: _theme,
        showShortcuts: width >= 64,
        pressedId: _pressed,
        indent: 0,
      );
      _hits[lines.length] = actions.spans;
      lines.add(actions.row);
      lines.add(
        _kind == 'directory'
            ? 'Tab field  Enter edit  f / [...]: choose folder'
            : 'Tab: field  Enter: edit  left/right: cycle',
      );
      lines.add('a New  s Save  r Remove  p Preview  q Back');
    }
    while (lines.length < height) {
      lines.add('');
    }
    String next = lines
        .take(height)
        .map((String line) => _fit(line, width))
        .join('\n');
    String patch = renderTerminalPatch(
      previous: _previousFrame,
      next: next,
      forceFull: width != _lastWidth || height != _lastHeight,
    );
    _terminal.write(synchronizeTerminalPatch(patch.replaceAll('\n', '\r\n')));
    _previousFrame = next;
    _lastWidth = width;
    _lastHeight = height;
  }
}
