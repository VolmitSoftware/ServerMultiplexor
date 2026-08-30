const Set<String> _paperConsoleServerTypes = <String>{
  'paper',
  'purpur',
  'folia',
  'canvas',
  'leaf',
};

/// Whether [serverType] provides Paper's JLine-backed terminal appender.
///
/// Keeping that appender active is what lets the server itself complete its
/// real Brigadier/plugin command tree and current player names.
bool usesPaperTerminalConsole(String serverType) =>
    _paperConsoleServerTypes.contains(serverType.trim().toLowerCase());

/// Builds Multiplexor's compact Log4j configuration for [serverType].
///
/// Paper-family servers retain their `TerminalConsole` appender so replacing
/// the log pattern does not silently disable JLine input and Tab completion.
/// Other server families keep the core Log4j console appender because they do
/// not all ship Paper's custom appender plugin.
String buildMinimalLog4jConfig(String serverType) {
  final String consoleAppender = usesPaperTerminalConsole(serverType)
      ? '''
        <TerminalConsole name="MinimalConsole">
            <PatternLayout>
                <Pattern>%msg%n%xEx</Pattern>
            </PatternLayout>
        </TerminalConsole>'''
      : '''
        <Console name="MinimalConsole" target="SYSTEM_OUT">
            <PatternLayout>
                <Pattern>%msg%n%xEx</Pattern>
            </PatternLayout>
        </Console>''';
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<Configuration status="WARN" monitorInterval="30">
    <Appenders>
$consoleAppender
        <RollingRandomAccessFile name="File"
                                 fileName="logs/latest.log"
                                 filePattern="logs/%d{yyyy-MM-dd}-%i.log.gz">
            <PatternLayout>
                <Pattern>[%d{HH:mm:ss}] [%t/%level]: [%logger] %msg%n</Pattern>
            </PatternLayout>
            <Policies>
                <TimeBasedTriggeringPolicy />
                <OnStartupTriggeringPolicy />
            </Policies>
        </RollingRandomAccessFile>
    </Appenders>
    <Loggers>
        <Root level="info">
            <RegexFilter regex="(?s).*RCON Client.*" useRawMsg="false" onMatch="DENY" onMismatch="NEUTRAL"/>
            <AppenderRef ref="MinimalConsole"/>
            <AppenderRef ref="File"/>
        </Root>
    </Loggers>
</Configuration>
''';
}
