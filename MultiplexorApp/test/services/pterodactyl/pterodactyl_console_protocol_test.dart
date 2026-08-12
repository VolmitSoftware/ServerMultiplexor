import 'dart:convert';

import 'package:multiplexor/services/pterodactyl/pterodactyl_console_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('encodes every outbound console event as structured JSON', () {
    expect(jsonDecode(PterodactylConsoleFrames.authenticate('jwt-token')), {
      'event': 'auth',
      'args': <Object?>['jwt-token'],
    });
    expect(jsonDecode(PterodactylConsoleFrames.requestLogs()), {
      'event': 'send logs',
      'args': <Object?>[null],
    });
    expect(jsonDecode(PterodactylConsoleFrames.requestStats()), {
      'event': 'send stats',
      'args': <Object?>[null],
    });
    expect(jsonDecode(PterodactylConsoleFrames.sendCommand('say "hello"')), {
      'event': 'send command',
      'args': <Object?>['say "hello"'],
    });
    expect(
      () => PterodactylConsoleFrames.sendCommand('say one\nsay two'),
      throwsFormatException,
    );
  });

  test('removes ANSI, terminal controls, OSC links, and bidi overrides', () {
    const String hostile =
        'safe\x1b[2Jred\x1b[31m!\x1b[0m'
        '\x1b]8;;https://evil.invalid\x07link\x1b]8;;\x07'
        '\rnext\tcol\u202Etxt\x07';

    final String sanitized = PterodactylConsoleSanitizer.text(hostile);

    expect(sanitized, 'safered!link\nnext    coltxt');
    expect(sanitized.runes, everyElement(isNot(anyOf(0x1b, 0x07, 0x202e))));
  });

  test('parses sanitized output and typed statistics', () {
    final PterodactylConsoleEvent output = PterodactylConsoleEventParser.parse(
      jsonEncode(<String, Object?>{
        'event': 'console output',
        'args': <Object?>['hello\x1b[2J\nworld'],
      }),
    );
    expect(output, isA<PterodactylConsoleOutput>());
    expect((output as PterodactylConsoleOutput).lines, <String>[
      'hello',
      'world',
    ]);

    final PterodactylConsoleEvent stats = PterodactylConsoleEventParser.parse(
      jsonEncode(<String, Object?>{
        'event': 'stats',
        'args': <Object?>[
          jsonEncode(<String, Object?>{
            'state': 'running',
            'memory_bytes': 1048576,
            'memory_limit_bytes': 2097152,
            'cpu_absolute': 12.5,
            'disk_bytes': 42,
            'uptime': 5000,
            'network': <String, Object?>{'rx_bytes': 10, 'tx_bytes': 20},
          }),
        ],
      }),
    );
    expect(stats, isA<PterodactylConsoleStats>());
    final PterodactylConsoleStats typed = stats as PterodactylConsoleStats;
    expect(typed.state, 'running');
    expect(typed.memoryBytes, 1048576);
    expect(typed.cpuAbsolute, 12.5);
    expect(typed.networkTxBytes, 20);
  });

  test('malformed and oversized frames become safe warnings', () {
    expect(
      PterodactylConsoleEventParser.parse('{bad'),
      isA<PterodactylConsoleProtocolWarning>(),
    );
    expect(
      PterodactylConsoleEventParser.parse(
        'x' * (PterodactylConsoleEventParser.maximumFrameCharacters + 1),
      ),
      isA<PterodactylConsoleProtocolWarning>(),
    );
  });
}
