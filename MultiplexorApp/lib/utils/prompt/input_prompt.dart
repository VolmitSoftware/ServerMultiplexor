import 'package:interact/interact.dart';

class InputPrompt {
  static Future<String> ask(
    String prompt, {
    String? defaultValue,
    bool Function(String)? validator,
    String? validationMessage,
  }) async {
    final value = Input(
      prompt: prompt,
      defaultValue: defaultValue ?? '',
      validator: validator == null
          ? null
          : (raw) {
              if (validator(raw)) {
                return true;
              }
              throw ValidationError(validationMessage ?? 'Invalid input');
            },
    ).interact();
    return value;
  }
}
