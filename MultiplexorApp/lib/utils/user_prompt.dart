library;

import 'dart:io';

import 'package:dart_console/dart_console.dart';

export 'prompt/confirm_prompt.dart';
export 'prompt/display_prompt.dart';
export 'prompt/input_prompt.dart';
export 'prompt/select_prompt.dart';

import 'prompt/display_prompt.dart';

class PromptInputUnavailable implements Exception {
  PromptInputUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class PromptBackNavigation implements Exception {
  const PromptBackNavigation();

  @override
  String toString() => 'Prompt cancelled with Escape';
}

class UserPrompt {
  static bool _lineModeEnabled =
      (Platform.environment['MULTIPLEXOR_FORCE_LINE_PROMPTS'] ?? '') == '1';
  static bool _lineModeNoticeShown = false;
  static final Console _console = Console();
  static const String _reset = '\x1B[0m';
  static const String _bold = '\x1B[1m';
  static const String _yellow = '\x1B[33m';
  static const String _green = '\x1B[32m';
  static const String _cyan = '\x1B[36m';
  static const String _gray = '\x1B[90m';

  static void clearScreen() => DisplayPrompt.clearScreen();
  static void banner(String title, {String? subtitle}) =>
      DisplayPrompt.printBanner(title, subtitle: subtitle);
  static void row(String key, String value) => DisplayPrompt.row(key, value);
  static void success(String message) => DisplayPrompt.success(message);
  static void info(String message) => DisplayPrompt.info(message);
  static void warn(String message) => DisplayPrompt.warn(message);
  static void error(String message) => DisplayPrompt.error(message);
  static Future<void> pressEnter({
    String message = 'Press Enter to continue...',
  }) => DisplayPrompt.pressEnter(message: message);

  static bool get _canUseInteractivePrompts =>
      !_lineModeEnabled && stdin.hasTerminal && stdout.hasTerminal;

  static bool _isPromptIoFailure(Object error) {
    if (error is StdinException || error is OSError) {
      return true;
    }
    final text = '$error'.toLowerCase();
    return text.contains('bad file descriptor') ||
        text.contains('stdinexception') ||
        text.contains('stdin');
  }

  static void _enableLineMode(Object error) {
    _lineModeEnabled = true;
    if (_lineModeNoticeShown) {
      return;
    }
    _lineModeNoticeShown = true;
    DisplayPrompt.warn(
      'Interactive key mode unavailable; using line-input prompts.',
    );
    DisplayPrompt.info('Reason: $error');
  }

  static int _clampInitialIndex(int initialIndex, int optionsLength) {
    if (optionsLength <= 0) {
      return 0;
    }
    if (initialIndex < 0) {
      return 0;
    }
    if (initialIndex >= optionsLength) {
      return optionsLength - 1;
    }
    return initialIndex;
  }

  static String? _readLineSafe() {
    try {
      return stdin.readLineSync();
    } on StdinException {
      return null;
    } on OSError {
      return null;
    }
  }

  static String _readLineOrThrow(String context) {
    final line = _readLineSafe();
    if (line == null) {
      throw PromptInputUnavailable(
        'stdin is not readable while waiting for $context',
      );
    }
    return line;
  }

  static bool _isBackToken(String raw) {
    final normalized = raw.trim().toLowerCase();
    return normalized == '\x1b' ||
        normalized == 'esc' ||
        normalized == 'escape';
  }

  static String _styledInputPrompt(String message, {String? hint}) {
    final hintPart = hint == null || hint.isEmpty
        ? ''
        : ' $_gray($hint)$_reset';
    return '$_yellow? $_reset$_bold$message$_reset$hintPart $_gray›$_reset ';
  }

  static String _styledSuccessPrompt(String message, String value) {
    return '$_green✔ $_reset$_bold$message$_reset $_gray·$_reset '
        '$_green$value$_reset';
  }

  static String _readConsoleLineOrBack(String context) {
    try {
      final line = _console.readLine(cancelOnEscape: true);
      if (line == null) {
        stdout.writeln('');
        throw const PromptBackNavigation();
      }
      return line;
    } on PromptBackNavigation {
      rethrow;
    } on StdinException {
      throw PromptInputUnavailable(
        'stdin is not readable while waiting for $context',
      );
    } on OSError {
      throw PromptInputUnavailable(
        'stdin is not readable while waiting for $context',
      );
    }
  }

  static Future<int> _menuInteractiveInput(
    String title,
    List<String> options, {
    required int initialIndex,
  }) async {
    if (options.isEmpty) {
      throw StateError('Menu "$title" requires at least one option.');
    }

    var selected = _clampInitialIndex(initialIndex, options.length);
    stdout.writeln(_styledInputPrompt(title));

    void redraw({required bool wipe}) {
      if (wipe) {
        for (var i = 0; i < options.length; i++) {
          _console.cursorUp();
          _console.eraseLine();
        }
      }
      for (var i = 0; i < options.length; i++) {
        if (i == selected) {
          stdout.writeln(' $_green❯$_reset $_cyan${options[i]}$_reset');
        } else {
          stdout.writeln('   ${options[i]}');
        }
      }
    }

    redraw(wipe: false);
    _console.hideCursor();
    try {
      while (true) {
        final key = _console.readKey();
        if (key.isControl) {
          switch (key.controlChar) {
            case ControlCharacter.arrowUp:
              selected = (selected - 1 + options.length) % options.length;
              redraw(wipe: true);
              continue;
            case ControlCharacter.arrowDown:
              selected = (selected + 1) % options.length;
              redraw(wipe: true);
              continue;
            case ControlCharacter.enter:
              for (var i = 0; i < options.length; i++) {
                _console.cursorUp();
                _console.eraseLine();
              }
              stdout.writeln(_styledSuccessPrompt(title, options[selected]));
              return selected;
            case ControlCharacter.escape:
              for (var i = 0; i < options.length; i++) {
                _console.cursorUp();
                _console.eraseLine();
              }
              throw const PromptBackNavigation();
            default:
              continue;
          }
        }

        final numeric = int.tryParse(key.char);
        if (numeric != null && numeric >= 1 && numeric <= options.length) {
          selected = numeric - 1;
          redraw(wipe: true);
        }
      }
    } finally {
      _console.showCursor();
    }
  }

  static Future<int> _menuLineInput(
    String title,
    List<String> options, {
    required int initialIndex,
  }) async {
    if (options.isEmpty) {
      throw StateError('Menu "$title" requires at least one option.');
    }
    final fallbackIndex = _clampInitialIndex(initialIndex, options.length);
    stdout.writeln('? $title');
    for (var i = 0; i < options.length; i++) {
      final marker = i == fallbackIndex ? '*' : ' ';
      stdout.writeln(' $marker ${i + 1}) ${options[i]}');
    }
    stdout.write('Select [${fallbackIndex + 1}]: ');
    final raw = _readLineOrThrow('menu selection for "$title"').trim();
    if (_isBackToken(raw)) {
      throw const PromptBackNavigation();
    }
    if (raw.isEmpty) {
      return fallbackIndex;
    }

    final numeric = int.tryParse(raw);
    if (numeric != null && numeric >= 1 && numeric <= options.length) {
      return numeric - 1;
    }

    final byLabel = options.indexWhere(
      (option) => option.toLowerCase() == raw.toLowerCase(),
    );
    if (byLabel >= 0) {
      return byLabel;
    }

    return fallbackIndex;
  }

  static Future<int> menu(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) async {
    final safeInitial = _clampInitialIndex(initialIndex, options.length);
    if (_canUseInteractivePrompts) {
      try {
        return await _menuInteractiveInput(
          title,
          options,
          initialIndex: safeInitial,
        );
      } catch (error) {
        if (error is PromptBackNavigation) {
          rethrow;
        }
        if (!_isPromptIoFailure(error)) {
          rethrow;
        }
        _enableLineMode(error);
      }
    }
    return _menuLineInput(title, options, initialIndex: safeInitial);
  }

  static Future<String> pick(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) async {
    final idx = await menu(title, options, initialIndex: initialIndex);
    return options[idx];
  }

  static Future<String> _inputLineMode(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    while (true) {
      if (defaultValue != null && defaultValue.isNotEmpty) {
        stdout.write('$prompt [$defaultValue]: ');
      } else {
        stdout.write('$prompt: ');
      }
      final raw = _readLineOrThrow('input for "$prompt"');
      if (_isBackToken(raw)) {
        throw const PromptBackNavigation();
      }
      var value = raw.trim();
      if (value.isEmpty && defaultValue != null) {
        value = defaultValue;
      }

      if (validator == null || validator(value)) {
        return value;
      }

      DisplayPrompt.warn(validationMessage ?? 'Invalid input');
    }
  }

  static Future<String> _inputInteractive(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    while (true) {
      stdout.write(_styledInputPrompt(prompt, hint: defaultValue));
      final raw = _readConsoleLineOrBack('input for "$prompt"');
      var value = raw.trim();
      if (value.isEmpty && defaultValue != null) {
        value = defaultValue;
      }

      if (validator == null || validator(value)) {
        stdout.writeln(_styledSuccessPrompt(prompt, value));
        return value;
      }

      DisplayPrompt.warn(validationMessage ?? 'Invalid input');
    }
  }

  static Future<String> input(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    if (_canUseInteractivePrompts) {
      try {
        return await _inputInteractive(
          prompt,
          defaultValue: defaultValue,
          validator: validator,
          validationMessage: validationMessage,
        );
      } catch (error) {
        if (error is PromptBackNavigation) {
          rethrow;
        }
        if (!_isPromptIoFailure(error)) {
          rethrow;
        }
        _enableLineMode(error);
      }
    }
    return _inputLineMode(
      prompt,
      defaultValue: defaultValue,
      validator: validator,
      validationMessage: validationMessage,
    );
  }

  static Future<bool> _confirmLineMode(
    String prompt, {
    required bool defaultValue,
  }) async {
    final suffix = defaultValue ? ' [Y/n]: ' : ' [y/N]: ';
    while (true) {
      stdout.write('$prompt$suffix');
      final value = _readLineOrThrow(
        'confirmation for "$prompt"',
      ).trim().toLowerCase();
      if (_isBackToken(value)) {
        throw const PromptBackNavigation();
      }
      if (value.isEmpty) {
        return defaultValue;
      }
      if (value == 'y' || value == 'yes') {
        return true;
      }
      if (value == 'n' || value == 'no') {
        return false;
      }
    }
  }

  static Future<bool> _confirmInteractive(
    String prompt, {
    required bool defaultValue,
  }) async {
    final hint = defaultValue ? 'Y/n' : 'y/N';
    while (true) {
      stdout.write(_styledInputPrompt(prompt, hint: hint));
      final value = _readConsoleLineOrBack(
        'confirmation for "$prompt"',
      ).trim().toLowerCase();
      if (value == '\x1b') {
        throw const PromptBackNavigation();
      }
      if (value.isEmpty) {
        stdout.writeln(
          _styledSuccessPrompt(prompt, defaultValue ? 'yes' : 'no'),
        );
        return defaultValue;
      }
      if (value == 'y' || value == 'yes') {
        stdout.writeln(_styledSuccessPrompt(prompt, 'yes'));
        return true;
      }
      if (value == 'n' || value == 'no') {
        stdout.writeln(_styledSuccessPrompt(prompt, 'no'));
        return false;
      }
    }
  }

  static Future<bool> confirm(String prompt, {bool defaultValue = true}) async {
    if (_canUseInteractivePrompts) {
      try {
        return await _confirmInteractive(prompt, defaultValue: defaultValue);
      } catch (error) {
        if (error is PromptBackNavigation) {
          rethrow;
        }
        if (!_isPromptIoFailure(error)) {
          rethrow;
        }
        _enableLineMode(error);
      }
    }
    return _confirmLineMode(prompt, defaultValue: defaultValue);
  }
}
