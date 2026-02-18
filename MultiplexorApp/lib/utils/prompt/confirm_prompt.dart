import 'package:interact/interact.dart';

class ConfirmPrompt {
  static Future<bool> ask(
    String prompt, {
    bool defaultValue = true,
  }) async {
    final result = Confirm(
      prompt: prompt,
      defaultValue: defaultValue,
      waitForNewLine: true,
    ).interact();
    return result;
  }
}
