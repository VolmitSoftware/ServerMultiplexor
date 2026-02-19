import 'dart:io';

import 'package:dart_console/dart_console.dart';

class DisplayPrompt {
  static const String _reset = '\x1B[0m';
  static const String _bold = '\x1B[1m';
  static const String _cyan = '\x1B[36m';
  static const String _green = '\x1B[32m';
  static const String _yellow = '\x1B[33m';
  static const String _red = '\x1B[31m';

  static void clearScreen() {
    stdout.write('\x1B[2J\x1B[0;0H');
  }

  static void printBanner(String title, {String? subtitle}) {
    final lines = <String>[title];
    if (subtitle != null) {
      lines.add(subtitle);
    }
    final width =
        lines.map((line) => line.length).fold(0, (a, b) => a > b ? a : b) + 6;
    final top = '╔${'═' * width}╗';
    final bottom = '╚${'═' * width}╝';

    stdout.writeln('$_cyan$top$_reset');
    for (final line in lines) {
      final padded = line.padRight(width - 2, ' ');
      stdout.writeln('$_cyan║$_reset $_bold$padded$_reset $_cyan║$_reset');
    }
    stdout.writeln('$_cyan$bottom$_reset');
  }

  static void row(String key, String value) {
    stdout.writeln('$_bold${key.padRight(16)}$_reset $value');
  }

  static void success(String message) {
    stdout.writeln('$_green[OK]$_reset $message');
  }

  static void info(String message) {
    stdout.writeln('$_cyan[INFO]$_reset $message');
  }

  static void warn(String message) {
    stdout.writeln('$_yellow[WARN]$_reset $message');
  }

  static void error(String message) {
    stdout.writeln('$_red[ERROR]$_reset $message');
  }

  static Future<void> pressEnter({
    String message = 'Press Enter to continue...',
  }) async {
    stdout.write(message);
    if (stdin.hasTerminal && stdout.hasTerminal) {
      try {
        final console = Console();
        console.readLine(cancelOnEscape: true);
        return;
      } on StdinException {
        // Fall through to stdin.readLineSync fallback.
      } on OSError {
        // Fall through to stdin.readLineSync fallback.
      }
    }
    try {
      stdin.readLineSync();
    } on StdinException {
      // Ignore when stdin is not readable; caller can continue.
    } on OSError {
      // Ignore when stdin is detached/invalid.
    }
  }
}
