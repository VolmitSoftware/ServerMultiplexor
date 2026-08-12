import 'dart:convert';

/// Pure encoding helpers for the Wings console WebSocket protocol.
final class PterodactylConsoleFrames {
  PterodactylConsoleFrames._();

  static String authenticate(String token) {
    if (token.isEmpty || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(token)) {
      throw const FormatException('Invalid Pterodactyl WebSocket token.');
    }
    return _frame('auth', <Object?>[token]);
  }

  static String requestLogs() => _frame('send logs', const <Object?>[null]);

  static String requestStats() => _frame('send stats', const <Object?>[null]);

  static String sendCommand(String command) {
    if (command.isEmpty ||
        command.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(command)) {
      throw const FormatException(
        'Console commands must contain 1-4096 printable characters.',
      );
    }
    return _frame('send command', <Object?>[command]);
  }

  static String _frame(String event, List<Object?> arguments) =>
      jsonEncode(<String, Object?>{'event': event, 'args': arguments});
}

/// Removes terminal control sequences and display-spoofing format characters.
///
/// Remote output is never allowed to contribute terminal control bytes. ANSI
/// CSI sequences, OSC titles/links, DCS-like strings, C0/C1 controls, bidi
/// overrides, and zero-width format marks are removed before rendering.
final class PterodactylConsoleSanitizer {
  PterodactylConsoleSanitizer._();

  static const int maximumCharacters = 64 * 1024;

  static String text(String input) {
    final String stripped = _stripAnsi(
      input,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final StringBuffer output = StringBuffer();
    int characters = 0;
    for (final int rune in stripped.runes) {
      if (characters >= maximumCharacters) {
        output.write(' [truncated]');
        break;
      }
      if (rune == 0x0a) {
        output.write('\n');
        characters++;
        continue;
      }
      if (rune == 0x09) {
        output.write('    ');
        characters += 4;
        continue;
      }
      if (_isControl(rune) || _isDisplayFormat(rune)) {
        continue;
      }
      output.writeCharCode(rune);
      characters++;
    }
    return output.toString();
  }

  static bool _isControl(int rune) =>
      rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f);

  static bool _isDisplayFormat(int rune) =>
      (rune >= 0x200b && rune <= 0x200f) ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2060 && rune <= 0x206f) ||
      rune == 0xfeff;

  static String _stripAnsi(String input) {
    final StringBuffer output = StringBuffer();
    int index = 0;
    while (index < input.length) {
      final int unit = input.codeUnitAt(index);
      if (unit == 0x1b) {
        index = _skipEscape(input, index + 1);
        continue;
      }
      if (unit == 0x9b) {
        index = _skipCsi(input, index + 1);
        continue;
      }
      if (unit == 0x90 ||
          unit == 0x98 ||
          unit == 0x9d ||
          unit == 0x9e ||
          unit == 0x9f) {
        index = _skipControlString(input, index + 1);
        continue;
      }
      output.writeCharCode(unit);
      index++;
    }
    return output.toString();
  }

  static int _skipEscape(String input, int index) {
    if (index >= input.length) return index;
    final int introducer = input.codeUnitAt(index);
    if (introducer == 0x5b) return _skipCsi(input, index + 1);
    if (introducer == 0x50 ||
        introducer == 0x58 ||
        introducer == 0x5d ||
        introducer == 0x5e ||
        introducer == 0x5f) {
      return _skipControlString(input, index + 1);
    }
    return index + 1;
  }

  static int _skipCsi(String input, int index) {
    while (index < input.length) {
      final int unit = input.codeUnitAt(index++);
      if (unit >= 0x40 && unit <= 0x7e) return index;
    }
    return index;
  }

  static int _skipControlString(String input, int index) {
    while (index < input.length) {
      final int unit = input.codeUnitAt(index++);
      if (unit == 0x07 || unit == 0x9c) return index;
      if (unit == 0x1b &&
          index < input.length &&
          input.codeUnitAt(index) == 0x5c) {
        return index + 1;
      }
    }
    return index;
  }
}

sealed class PterodactylConsoleEvent {
  const PterodactylConsoleEvent();
}

enum PterodactylConsoleConnectionState {
  connecting,
  connected,
  refreshing,
  disconnected,
  error,
}

final class PterodactylConsoleConnectionEvent extends PterodactylConsoleEvent {
  const PterodactylConsoleConnectionEvent(this.state, {this.message});

  final PterodactylConsoleConnectionState state;
  final String? message;
}

final class PterodactylConsoleAuthenticated extends PterodactylConsoleEvent {
  const PterodactylConsoleAuthenticated();
}

final class PterodactylConsoleOutput extends PterodactylConsoleEvent {
  const PterodactylConsoleOutput(this.lines);

  final List<String> lines;
}

final class PterodactylConsoleInstallOutput extends PterodactylConsoleEvent {
  const PterodactylConsoleInstallOutput(this.lines);

  final List<String> lines;
}

final class PterodactylConsoleStatus extends PterodactylConsoleEvent {
  const PterodactylConsoleStatus(this.status);

  final String status;
}

final class PterodactylConsoleStats extends PterodactylConsoleEvent {
  const PterodactylConsoleStats({
    this.state,
    this.memoryBytes,
    this.memoryLimitBytes,
    this.cpuAbsolute,
    this.diskBytes,
    this.networkRxBytes,
    this.networkTxBytes,
    this.uptimeMilliseconds,
  });

  final String? state;
  final int? memoryBytes;
  final int? memoryLimitBytes;
  final double? cpuAbsolute;
  final int? diskBytes;
  final int? networkRxBytes;
  final int? networkTxBytes;
  final int? uptimeMilliseconds;
}

final class PterodactylConsoleTokenExpiring extends PterodactylConsoleEvent {
  const PterodactylConsoleTokenExpiring();
}

final class PterodactylConsoleTokenExpired extends PterodactylConsoleEvent {
  const PterodactylConsoleTokenExpired();
}

final class PterodactylConsoleDaemonMessage extends PterodactylConsoleEvent {
  const PterodactylConsoleDaemonMessage(this.message, {this.isError = false});

  final String message;
  final bool isError;
}

final class PterodactylConsoleUnknownEvent extends PterodactylConsoleEvent {
  const PterodactylConsoleUnknownEvent(this.name);

  final String name;
}

final class PterodactylConsoleProtocolWarning extends PterodactylConsoleEvent {
  const PterodactylConsoleProtocolWarning(this.message);

  final String message;
}

/// Parses untrusted Wings frames into terminal-safe typed events.
final class PterodactylConsoleEventParser {
  PterodactylConsoleEventParser._();

  static const int maximumFrameCharacters = 1024 * 1024;

  static PterodactylConsoleEvent parse(String frame) {
    if (frame.length > maximumFrameCharacters) {
      return const PterodactylConsoleProtocolWarning(
        'Ignored an oversized console event.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      return const PterodactylConsoleProtocolWarning(
        'Ignored a malformed console event.',
      );
    }
    if (decoded is! Map<Object?, Object?> || decoded['event'] is! String) {
      return const PterodactylConsoleProtocolWarning(
        'Ignored an invalid console event.',
      );
    }
    final String event = decoded['event'] as String;
    final Object? rawArguments = decoded['args'];
    final List<Object?> arguments = rawArguments is List<Object?>
        ? rawArguments
        : const <Object?>[];
    return switch (event) {
      'auth success' => const PterodactylConsoleAuthenticated(),
      'console output' => PterodactylConsoleOutput(_safeLines(arguments)),
      'install output' => PterodactylConsoleInstallOutput(
        _safeLines(arguments),
      ),
      'status' => PterodactylConsoleStatus(_firstSafeString(arguments)),
      'stats' => _stats(arguments),
      'token expiring' => const PterodactylConsoleTokenExpiring(),
      'token expired' => const PterodactylConsoleTokenExpired(),
      'daemon error' || 'jwt error' => PterodactylConsoleDaemonMessage(
        _safeLines(arguments).join(' '),
        isError: true,
      ),
      'daemon message' => PterodactylConsoleDaemonMessage(
        _safeLines(arguments).join(' '),
      ),
      _ => PterodactylConsoleUnknownEvent(
        PterodactylConsoleSanitizer.text(event),
      ),
    };
  }

  static List<String> _safeLines(List<Object?> arguments) {
    final List<String> result = <String>[];
    for (final Object? argument in arguments) {
      if (argument is! String) continue;
      result.addAll(PterodactylConsoleSanitizer.text(argument).split('\n'));
    }
    return List<String>.unmodifiable(result);
  }

  static String _firstSafeString(List<Object?> arguments) {
    for (final Object? argument in arguments) {
      if (argument is String) {
        return PterodactylConsoleSanitizer.text(argument);
      }
    }
    return 'unknown';
  }

  static PterodactylConsoleStats _stats(List<Object?> arguments) {
    if (arguments.isEmpty) return const PterodactylConsoleStats();
    Object? raw = arguments.first;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        return const PterodactylConsoleStats();
      }
    }
    if (raw is! Map<Object?, Object?>) {
      return const PterodactylConsoleStats();
    }
    final Object? rawNetwork = raw['network'];
    final Map<Object?, Object?> network = rawNetwork is Map<Object?, Object?>
        ? rawNetwork
        : const <Object?, Object?>{};
    return PterodactylConsoleStats(
      state: raw['state'] is String
          ? PterodactylConsoleSanitizer.text(raw['state'] as String)
          : null,
      memoryBytes: _nonNegativeInt(raw['memory_bytes']),
      memoryLimitBytes: _nonNegativeInt(raw['memory_limit_bytes']),
      cpuAbsolute: _nonNegativeDouble(raw['cpu_absolute']),
      diskBytes: _nonNegativeInt(raw['disk_bytes']),
      networkRxBytes: _nonNegativeInt(network['rx_bytes']),
      networkTxBytes: _nonNegativeInt(network['tx_bytes']),
      uptimeMilliseconds: _nonNegativeInt(raw['uptime']),
    );
  }

  static int? _nonNegativeInt(Object? value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    return value.toInt();
  }

  static double? _nonNegativeDouble(Object? value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    return value.toDouble();
  }
}
