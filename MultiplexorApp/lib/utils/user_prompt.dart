/// Interactive UI facade for the wizard: styled output, prompts, and
/// shielded execution of background work.
library;

import 'dart:async';
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

  /// Compact one-line app header with a gradient brand block.
  static void appHeader(String brand, List<String> facts) {
    final String left = ' ${_gradientBlock(brand)}';
    final String right = facts
        .where((String fact) => fact.isNotEmpty)
        .map((String fact) => Ansi.style(fact, Ansi.gray))
        .join(Ansi.style('  ·  ', Ansi.gray));
    stdout.writeln('$left  $right');
    rule();
  }

  /// Renders [text] as a block with a cyan-to-blue background gradient.
  static String _gradientBlock(String text) {
    const List<int> ramp = <int>[51, 50, 45, 44, 39, 38, 33];
    final String padded = ' $text ';
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < padded.length; i++) {
      final int position = padded.length <= 1
          ? 0
          : (i * (ramp.length - 1)) ~/ (padded.length - 1);
      out.write(
        '\x1B[48;5;${ramp[position]}m\x1B[38;5;16m${Ansi.bold}${padded[i]}',
      );
    }
    out.write(Ansi.reset);
    return out.toString();
  }

  static void rule() {
    final int width = TermIo.instance.terminalColumns.clamp(20, 100);
    stdout.writeln(' ${Ansi.style('─' * (width - 2), Ansi.gray)}');
  }

  static void keyValue(String key, String value) {
    stdout.writeln('   ${Ansi.style(key.padRight(14), Ansi.gray)} $value');
  }

  static void blank() => stdout.writeln('');

  static void success(String message) {
    stdout.writeln(' ${Ansi.style('✔', Ansi.green)} $message');
  }

  static void info(String message) {
    stdout.writeln(' ${Ansi.style('•', Ansi.cyan)} $message');
  }

  static void warn(String message) {
    stdout.writeln(
      ' ${Ansi.style('!', '${Ansi.yellow}${Ansi.bold}')} $message',
    );
  }

  static void error(String message) {
    stdout.writeln(' ${Ansi.style('✖', '${Ansi.red}${Ansi.bold}')} $message');
  }

  static void note(String message) {
    stdout.writeln('   ${Ansi.style(message, Ansi.gray)}');
  }

  /// Announces a long-running step before streamed command output.
  static void doing(String message) {
    stdout.writeln(
      ' ${Ansi.style('▸', Ansi.cyan)} ${Ansi.style(message, Ansi.bold)}',
    );
  }

  /// Runs background work with keyboard echo off, then discards any
  /// keystrokes typed while it ran.
  static Future<T> shielded<T>(Future<T> Function() operation) {
    return TermIo.instance.shielded(operation);
  }

  static const List<String> _spinnerFrames = <String>[
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  /// Runs silent background work shielded while animating a spinner next to
  /// [message]. Only for operations that do not write to stdout themselves
  /// (captured commands); every frame is carriage-anchored and the line is
  /// erased before returning, so it is safe in raw and cooked mode alike.
  static Future<T> spin<T>(
    String message,
    Future<T> Function() operation,
  ) async {
    if (!hasTerminal) {
      return shielded(operation);
    }
    final TermIo io = TermIo.instance;
    io.hideCursor();
    int frame = 0;
    final Timer timer = Timer.periodic(const Duration(milliseconds: 80), (
      Timer _,
    ) {
      final String glyph = _spinnerFrames[frame % _spinnerFrames.length];
      frame++;
      stdout.write(
        '\r${Ansi.eraseLine} ${Ansi.style(glyph, Ansi.cyan)} '
        '${Ansi.style(message, Ansi.gray)}',
      );
    });
    try {
      return await shielded(operation);
    } finally {
      timer.cancel();
      stdout.write('\r${Ansi.eraseLine}');
      io.showCursor();
    }
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
      // Leave raw mode before the newline: with OPOST off, "\n" does not
      // return the carriage and the next line starts mid-column.
      io.setRawMode(false);
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

  static void _inputAccepted(
    String message,
    String value, {
    String color = Ansi.green,
  }) {
    stdout.writeln(
      '${Ansi.style('✔', Ansi.green)} ${Ansi.style(message, Ansi.bold)} '
      '${Ansi.style('·', Ansi.gray)} ${Ansi.style(value, color)}',
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

  /// Masked line input for secrets like PINs. Renders one '*' per character.
  /// Enter submits, Backspace deletes the last character, Escape backs out.
  static Future<String> secret(String prompt) async {
    if (!hasTerminal) {
      stdout.write('$prompt: ');
      try {
        return (stdin.readLineSync() ?? '').trim();
      } catch (_) {
        throw PromptInputUnavailable(
          'stdin is not readable while waiting for "$prompt"',
        );
      }
    }

    final TermIo io = TermIo.instance;
    io.drainInput();
    stdout.write(_inputPrompt(prompt));
    io.setRawMode(true);
    io.hideCursor();
    final StringBuffer buffer = StringBuffer();

    // Leave raw mode before printing anything ending in "\n": with OPOST
    // off, "\n" does not return the carriage and the next line starts
    // mid-column (the stair-step bug).
    void finishLine({required bool accepted}) {
      io.setRawMode(false);
      stdout.write('\r${Ansi.eraseLine}');
      if (accepted) {
        _inputAccepted(prompt, '•' * buffer.length);
      }
    }

    try {
      while (true) {
        final TermEvent event = io.readEvent();
        switch (event.kind) {
          case TermEventKind.enter:
            finishLine(accepted: true);
            return buffer.toString();
          case TermEventKind.escape:
            finishLine(accepted: false);
            throw const PromptBackNavigation();
          case TermEventKind.ctrlC:
            io.restoreTerminal();
            stdout.writeln();
            exit(130);
          case TermEventKind.backspace:
            if (buffer.isNotEmpty) {
              final String current = buffer.toString();
              buffer
                ..clear()
                ..write(current.substring(0, current.length - 1));
              stdout.write('\b \b');
            }
            break;
          case TermEventKind.char:
            buffer.write(event.char);
            stdout.write('*');
            break;
          default:
            break;
        }
      }
    } on TermInputUnavailable {
      throw PromptInputUnavailable(
        'stdin is not readable while waiting for "$prompt"',
      );
    } finally {
      io.showCursor();
      io.setRawMode(false);
    }
  }

  /// Single-key confirmation: y/n, Enter accepts the configured default,
  /// Esc backs out.
  static Future<bool> confirm(String prompt, {bool defaultValue = true}) async {
    final hint = defaultValue ? 'Y/n' : 'y/N';
    if (!hasTerminal) {
      stdout.write('$prompt [$hint]: ');
      final String value = (stdin.readLineSync() ?? '').trim().toLowerCase();
      if (value.isEmpty) {
        return defaultValue;
      }
      return value == 'y' || value == 'yes';
    }

    final TermIo io = TermIo.instance;
    io.drainInput();
    // Button-style chips: the default answer is a filled key, the other dim.
    final String chips = defaultValue
        ? '${Ansi.style(' Y ', '${Ansi.inverse}${Ansi.green}')} ${Ansi.style(' n ', Ansi.gray)}'
        : '${Ansi.style(' y ', Ansi.gray)} ${Ansi.style(' N ', '${Ansi.inverse}${Ansi.red}')}';
    stdout.write(
      '${Ansi.style('?', Ansi.yellow)} ${Ansi.style(prompt, Ansi.bold)} '
      '$chips ${Ansi.style('›', Ansi.gray)} ',
    );
    io.setRawMode(true);

    // Leave raw mode before echoing the answer: with OPOST off, "\n" does
    // not return the carriage and every following line starts mid-column
    // (the stair-step bug).
    bool finish(bool value) {
      io.setRawMode(false);
      stdout.write('\r${Ansi.eraseLine}');
      _inputAccepted(
        prompt,
        value ? 'yes' : 'no',
        color: value ? Ansi.green : Ansi.gray,
      );
      return value;
    }

    try {
      while (true) {
        final TermEvent event = io.readEvent();
        switch (event.kind) {
          case TermEventKind.enter:
            return finish(defaultValue);
          case TermEventKind.escape:
            io.setRawMode(false);
            stdout.write('\r${Ansi.eraseLine}');
            throw const PromptBackNavigation();
          case TermEventKind.ctrlC:
            io.restoreTerminal();
            stdout.writeln();
            exit(130);
          case TermEventKind.char:
            final String char = event.char.toLowerCase();
            if (char == 'y') {
              return finish(true);
            }
            if (char == 'n') {
              return finish(false);
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
