import 'package:multiplexor/services/minimal_log4j_config.dart';
import 'package:test/test.dart';

void main() {
  group('minimal Log4j console appender', () {
    test('retains Paper terminal input for every Paper-family server', () {
      for (final String type in <String>[
        'paper',
        'purpur',
        'folia',
        'canvas',
        'leaf',
      ]) {
        final String config = buildMinimalLog4jConfig(type);

        expect(usesPaperTerminalConsole(type), isTrue, reason: type);
        expect(config, contains('<TerminalConsole name="MinimalConsole">'));
        expect(config, isNot(contains('<Console name="MinimalConsole"')));
      }
    });

    test('keeps the portable appender for other server families', () {
      for (final String type in <String>[
        'forge',
        'mohist',
        'fabric',
        'neoforge',
        'custom',
      ]) {
        final String config = buildMinimalLog4jConfig(type);

        expect(usesPaperTerminalConsole(type), isFalse, reason: type);
        expect(
          config,
          contains('<Console name="MinimalConsole" target="SYSTEM_OUT">'),
        );
        expect(config, isNot(contains('<TerminalConsole')));
      }
    });

    test('normalizes source type and retains compact/full log patterns', () {
      final String config = buildMinimalLog4jConfig(' PurPur ');

      expect(usesPaperTerminalConsole(' PurPur '), isTrue);
      expect(config, contains('<Pattern>%msg%n%xEx</Pattern>'));
      expect(config, contains('[%d{HH:mm:ss}] [%t/%level]: [%logger] %msg%n'));
      expect(config, contains('RCON Client'));
    });
  });
}
