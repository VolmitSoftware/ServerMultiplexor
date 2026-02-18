library;

import 'dart:io';

export 'prompt/confirm_prompt.dart';
export 'prompt/display_prompt.dart';
export 'prompt/input_prompt.dart';
export 'prompt/select_prompt.dart';

import 'prompt/confirm_prompt.dart';
import 'prompt/display_prompt.dart';
import 'prompt/input_prompt.dart';
import 'prompt/select_prompt.dart';

class PromptInputUnavailable implements Exception {
  PromptInputUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class UserPrompt {
  static bool _lineModeEnabled =
      (Platform.environment['MULTIPLEXOR_FORCE_LINE_PROMPTS'] ?? '') == '1';
  static bool _lineModeNoticeShown = false;

  static void clearScreen() => DisplayPrompt.clearScreen();
  static void banner(String title, {String? subtitle}) =>
      DisplayPrompt.printBanner(title, subtitle: subtitle);
  static void row(String key, String value) => DisplayPrompt.row(key, value);
  static void success(String message) => DisplayPrompt.success(message);
  static void info(String message) => DisplayPrompt.info(message);
  static void warn(String message) => DisplayPrompt.warn(message);
  static void error(String message) => DisplayPrompt.error(message);
  static Future<void> pressEnter({String message = 'Press Enter to continue...'}) =>
      DisplayPrompt.pressEnter(message: message);

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
        return await SelectPrompt.showMenu(
          title,
          options,
          initialIndex: safeInitial,
        );
      } catch (error) {
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

  static Future<String> input(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    if (_canUseInteractivePrompts) {
      try {
        return await InputPrompt.ask(
          prompt,
          defaultValue: defaultValue,
          validator: validator,
          validationMessage: validationMessage,
        );
      } catch (error) {
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
      final value = _readLineOrThrow('confirmation for "$prompt"')
          .trim()
          .toLowerCase();
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

  static Future<bool> confirm(String prompt, {bool defaultValue = true}) async {
    if (_canUseInteractivePrompts) {
      try {
        return await ConfirmPrompt.ask(prompt, defaultValue: defaultValue);
      } catch (error) {
        if (!_isPromptIoFailure(error)) {
          rethrow;
        }
        _enableLineMode(error);
      }
    }
    return _confirmLineMode(prompt, defaultValue: defaultValue);
  }
}
