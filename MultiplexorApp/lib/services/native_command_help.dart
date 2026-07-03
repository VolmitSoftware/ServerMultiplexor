part of 'native_command_service.dart';

void _printHelp(_NativeIoBuffer io) {
  writeGlobalHelp(io.write);
}

int _printHelpForArgs(List<String> args, _NativeIoBuffer io) {
  return printCliHelpForArgs(args, write: io.write, error: io.error);
}

void _printVersion(_NativeIoBuffer io) {
  printCliVersion(write: io.write);
}
