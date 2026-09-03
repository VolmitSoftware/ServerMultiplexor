import '../terminal/term_events.dart';
import 'menu.dart';

/// Reads an editable line using the same Escape handling as menus. No cursor
/// position query is needed, so missing terminal replies cannot consume input.
String readPromptLine({
  required TermEvent Function() readEvent,
  required void Function(List<String> characters, int cursor) redraw,
  required Never Function() onInterrupt,
}) {
  final List<String> characters = <String>[];
  int cursor = 0;
  redraw(characters, cursor);
  while (true) {
    final TermEvent event = readEvent();
    switch (event.kind) {
      case TermEventKind.escape:
        throw const PromptBackNavigation();
      case TermEventKind.ctrlC:
        onInterrupt();
      case TermEventKind.enter:
        return characters.join();
      case TermEventKind.char:
        final List<String> inserted = event.char.runes
            .map(String.fromCharCode)
            .toList(growable: false);
        characters.insertAll(cursor, inserted);
        cursor += inserted.length;
      case TermEventKind.backspace:
        if (cursor > 0) characters.removeAt(--cursor);
      case TermEventKind.delete:
        if (cursor < characters.length) characters.removeAt(cursor);
      case TermEventKind.arrowLeft:
        if (cursor > 0) cursor--;
      case TermEventKind.arrowRight:
        if (cursor < characters.length) cursor++;
      case TermEventKind.home:
        cursor = 0;
      case TermEventKind.end:
        cursor = characters.length;
      default:
        continue;
    }
    redraw(characters, cursor);
  }
}
