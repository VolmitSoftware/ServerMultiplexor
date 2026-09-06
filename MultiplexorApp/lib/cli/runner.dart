import 'dart:io';

import '../services/app_context.dart';
import 'command_help.dart';
import 'local_command.dart';
import 'handlers/monitor_handler.dart';
import 'handlers/remote_handler.dart';
import 'handlers/wizard_handler.dart';

Future<int> runCli(List<String> args) async {
  try {
    if (isCliHelpRequest(args)) return printCliHelpForArgs(args);
    if (isCliVersionRequest(args)) {
      printCliVersion();
      return 0;
    }
    if (args.isEmpty || (args.length == 1 && args.first == 'wizard')) {
      await handleWizard();
      return 0;
    }
    if (args.first == 'remote' || args.first == 'ptero') {
      return await handleRemote(args.sublist(1));
    }
    final LocalCommand command = LocalCommand.parse(args);
    if (command.arguments.take(2).join(' ') == 'runtime watch') {
      return await handleRuntimeWatch(command.arguments.sublist(2));
    }
    return await passthroughService.run(command.arguments);
  } on FormatException catch (error) {
    stderr.writeln('[ERROR] ${error.message}');
    return 2;
  } on ProcessException catch (error) {
    stderr.writeln('[ERROR] ${error.message}');
    return error.errorCode == 0 ? 1 : error.errorCode;
  } catch (error) {
    stderr.writeln('[ERROR] $error');
    return 1;
  } finally {
    passthroughService.disposeRcon();
  }
}
