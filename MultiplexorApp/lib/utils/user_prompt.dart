/// Interactive UI facade for the wizard: styled output, prompts, and
/// shielded execution of background work.
library;

import 'dart:io';

import 'package:dart_console/dart_console.dart';

import 'prompt/menu.dart';
import 'terminal/ansi.dart';
import 'terminal/term_events.dart';
import 'terminal/term_io.dart';

export 'prompt/menu.dart';
export 'terminal/ansi.dart';
export 'terminal/term_io.dart';

class Ui {
  Ui._();

  static final Console _console = Console();

  static bool get hasTerminal => TermIo.instance.hasTerminal;

  static void clearScreen() {
    stdout.write('\x1B[2J\x1B[0;0H');
  }

  /// Compact one-line app header with a colored brand block.
  static void appHeader(String brand, List<String> facts) {
    final String left =
        ' ${Ansi.style(' $brand ', '${Ansi.inverse}${Ansi.bold}${Ansi.cyan}')}';
    final String right = facts
        .where((String fact) => fact.isNotEmpty)
        .map((String fact) => Ansi.style(fact, Ansi.gray))
        .join(Ansi.style('  ·  ', Ansi.gray));
    stdout.writeln('$left  $right');
    rule();
  }

  static void rule() {
    final int width = TermIo.instance.terminalColumns.clamp(20, 100);
    stdout.writeln(' ${Ansi.style('─' * (width - 2), Ansi.gray)}');
  }

  static void keyValue(String key, String value) {
    stdout.writeln(
      '   ${Ansi.style(key.padRight(14), Ansi.gray)} $value',
    );
  }

  static void blank() => stdout.writeln('');

  static void success(String message) {
    stdout.writeln(' ${Ansi.style('✔', Ansi.green)} $message');
  }

  static void info(String message) {
    stdout.writeln(' ${Ansi.style('•', Ansi.cyan)} $message');
  }

  static void warn(String message) {
    stdout.writeln(' ${Ansi.style('!', '${Ansi.yellow}${Ansi.bold}')} $message');
  }

  static void error(String message) {
    stdout.writeln(' ${Ansi.style('✖', '${Ansi.red}${Ansi.bold}')} $message');
  }

  static void note(String message) {
    stdout.writeln('   ${Ansi.style(message, Ansi.gray)}');
  }

  /// Announces a long-running step before streamed command output.
  static void doing(String message) {
    stdout.writeln(' ${Ansi.style('▸', Ansi.cyan)} ${Ansi.style(message, Ansi.bold)}');
  }

  /// Runs background work with keyboard echo off, then discards any
  /// keystrokes typed while it ran.
  static Future<T> shielded<T>(Future<T> Function() operation) {
    return TermIo.instance.shielded(operation);
  }

  /// Waits for any key (Enter/Space/click). Drains stale input first so a
  /// key pressed during preceding work cannot skip the pause.
  static Future<void> pause({String message = 'any key to continue'}) async {
    if (!hasTerminal) {
      return;
    }
    final TermIo io = TermIo.instance;
    io.drainInput();
    stdout.write('   ${Ansi.style(message, Ansi.gray)}');
    io.setRawMode(true);
    io.hideCursor();
    try {
      while (true) {
        final TermEvent event = io.readEvent();
        switch (event.kind) {
          case TermEventKind.ctrlC:
            io.restoreTerminal();
            stdout.writeln();
            exit(130);
          case TermEventKind.mouseDown:
          case TermEventKind.wheelUp:
          case TermEventKind.wheelDown:
          case TermEventKind.unknown:
          case TermEventKind.cursorReport:
            continue;
          default:
            stdout.write('\r${Ansi.eraseLine}');
            return;
        }
      }
    } on TermInputUnavailable {
      stdout.writeln();
    } finally {
      io.showCursor();
      io.setRawMode(false);
    }
  }

  /// Single-select menu over plain string options; returns the index.
  static Future<int> choose(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) {
    final List<MenuEntry<int>> entries = <MenuEntry<int>>[
      for (int i = 0; i < options.length; i++)
        MenuEntry<int>(options[i], value: i),
    ];
    return menuSelect<int>(title, entries, initialIndex: initialIndex);
  }

  /// Single-select menu over plain string options; returns the option.
  static Future<String> pick(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) async {
    final int index = await choose(title, options, initialIndex: initialIndex);
    return options[index];
  }

  static String _inputPrompt(String message, {String? hint}) {
    final String hintPart = hint == null || hint.isEmpty
        ? ''
        : ' ${Ansi.style('($hint)', Ansi.gray)}';
    return '${Ansi.style('?', Ansi.yellow)} ${Ansi.style(message, Ansi.bold)}'
        '$hintPart ${Ansi.style('›', Ansi.gray)} ';
  }

  static void _inputAccepted(String message, String value) {
    stdout.writeln(
      '${Ansi.style('✔', Ansi.green)} ${Ansi.style(message, Ansi.bold)} '
      '${Ansi.style('·', Ansi.gray)} ${Ansi.style(value, Ansi.green)}',
    );
  }

  /// Line input with optional default and validation. Escape goes back.
  static Future<String> input(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    while (true) {
      String? raw;
      if (hasTerminal) {
        TermIo.instance.drainInput();
        stdout.write(_inputPrompt(prompt, hint: defaultValue));
        try {
          raw = _console.readLine(cancelOnEscape: true);
        } on StdinException {
          throw PromptInputUnavailable(
            'stdin is not readable while waiting for input "$prompt"',
          );
        }
        if (raw == null) {
          stdout.writeln('');
          throw const PromptBackNavigation();
        }
      } else {
        stdout.write(
          defaultValue == null || defaultValue.isEmpty
              ? '$prompt: '
              : '$prompt [$defaultValue]: ',
        );
        try {
          raw = stdin.readLineSync();
        } catch (_) {
          raw = null;
        }
        if (raw == null) {
          throw PromptInputUnavailable(
            'stdin is not readable while waiting for input "$prompt"',
          );
        }
      }

      String value = raw.trim();
      if (value.isEmpty && defaultValue != null) {
        value = defaultValue;
      }
      if (validator == null || validator(value)) {
        if (hasTerminal) {
          _inputAccepted(prompt, value);
        }
        return value;
      }
      warn(validationMessage ?? 'Invalid input');
    }
  }

  /// Single-key confirmation: y/n, Enter accepts yes, Esc backs out.
  static Future<bool> confirm(String prompt) async {
    if (!hasTerminal) {
      stdout.write('$prompt [Y/n]: ');
      final String value = (stdin.readLineSync() ?? '').trim().toLowerCase();
      if (value.isEmpty) {
        return true;
      }
      return value == 'y' || value == 'yes';
    }

    final TermIo io = TermIo.instance;
    io.drainInput();
    stdout.write(_inputPrompt(prompt, hint: 'Y/n'));
    io.setRawMode(true);
    try {
      while (true) {
        final TermEvent event = io.readEvent();
        switch (event.kind) {
          case TermEventKind.enter:
            stdout.writeln('yes');
            return true;
          case TermEventKind.escape:
            stdout.writeln('');
            throw const PromptBackNavigation();
          case TermEventKind.ctrlC:
            io.restoreTerminal();
            stdout.writeln();
            exit(130);
          case TermEventKind.char:
            final String char = event.char.toLowerCase();
            if (char == 'y') {
              stdout.writeln('yes');
              return true;
            }
            if (char == 'n') {
              stdout.writeln('no');
              return false;
            }
            break;
          default:
            break;
        }
      }
    } on TermInputUnavailable {
      throw PromptInputUnavailable(
        'stdin is not readable while waiting for confirmation "$prompt"',
      );
    } finally {
      io.setRawMode(false);
    }
  }
}
