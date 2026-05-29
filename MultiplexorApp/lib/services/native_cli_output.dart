part of 'native_command_service.dart';

class _NativeIoBuffer {
  _NativeIoBuffer({required this.stream});

  static const String _reset = '\x1B[0m';
  static const String _bold = '\x1B[1m';
  static const String _cyan = '\x1B[36m';
  static const String _green = '\x1B[32m';
  static const String _yellow = '\x1B[33m';
  static const String _red = '\x1B[31m';
  static const String _gray = '\x1B[90m';

  final bool stream;
  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();

  void write(String line) {
    _stdout.writeln(line);
    if (stream) {
      stdout.writeln(_styleLine(line, error: false));
    }
  }

  void error(String line) {
    _stderr.writeln(line);
    if (stream) {
      stderr.writeln(_styleLine(line, error: true));
    }
  }

  CapturedResult result(int exitCode) {
    return CapturedResult(
      exitCode: exitCode,
      stdout: _stdout.toString(),
      stderr: _stderr.toString(),
    );
  }

  bool _useAnsi({required bool error}) {
    if (!stream) {
      return false;
    }
    if (Platform.environment.containsKey('NO_COLOR')) {
      return false;
    }
    return error ? stderr.hasTerminal : stdout.hasTerminal;
  }

  String _styleLine(String line, {required bool error}) {
    if (!_useAnsi(error: error) || line.isEmpty) {
      return line;
    }

    if (error) {
      return _styleStatus(line);
    }

    if (line == 'Multiplexor') {
      return '$_bold$_cyan$line$_reset';
    }
    if (line.endsWith(':') && !line.startsWith('  ')) {
      return '$_bold$line$_reset';
    }
    if (line.startsWith('  ./start.sh')) {
      return _styleCommandLine(line);
    }
    if (line.startsWith('  --')) {
      return _styleCommandLine(line);
    }
    if (line.startsWith('  ') && !line.startsWith('      ')) {
      return '$_cyan$line$_reset';
    }
    return _styleStatus(line);
  }

  String _styleCommandLine(String line) {
    final trimmed = line.trimLeft();
    final indent = line.substring(0, line.length - trimmed.length);
    final detailStart = line.indexOf(RegExp(r'\s{2,}\S'), indent.length);
    if (detailStart <= indent.length) {
      return '$indent$_cyan$trimmed$_reset';
    }
    final command = line.substring(indent.length, detailStart).trimRight();
    final detail = line.substring(detailStart);
    return '$indent$_cyan$command$_reset$_gray$detail$_reset';
  }

  String _styleStatus(String line) {
    if (line.startsWith('[OK]')) {
      return line.replaceFirst('[OK]', '$_green[OK]$_reset');
    }
    if (line.startsWith('[INFO]')) {
      return line.replaceFirst('[INFO]', '$_cyan[INFO]$_reset');
    }
    if (line.startsWith('[WARN]')) {
      return line.replaceFirst('[WARN]', '$_yellow[WARN]$_reset');
    }
    if (line.startsWith('[ERROR]')) {
      return line.replaceFirst('[ERROR]', '$_red[ERROR]$_reset');
    }
    if (line.startsWith('[SYNC]')) {
      return line.replaceFirst('[SYNC]', '$_cyan[SYNC]$_reset');
    }
    return line;
  }
}
