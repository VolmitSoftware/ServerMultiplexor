import 'package:interact/interact.dart';

class SelectPrompt {
  static Future<int> showMenu(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) async {
    final choice = Select(
      prompt: title,
      options: options,
      initialIndex: initialIndex,
    ).interact();
    return choice;
  }

  static Future<String> pickValue(
    String title,
    List<String> options, {
    int initialIndex = 0,
  }) async {
    final idx = await showMenu(title, options, initialIndex: initialIndex);
    return options[idx];
  }
}
