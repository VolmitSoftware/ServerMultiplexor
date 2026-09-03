import 'dart:collection';

import 'package:multiplexor/utils/prompt/line_input.dart';
import 'package:multiplexor/utils/prompt/menu.dart';
import 'package:multiplexor/utils/terminal/term_events.dart';
import 'package:test/test.dart';

String read(List<TermEvent> events) {
  final Queue<TermEvent> pending = Queue<TermEvent>.of(events);
  return readPromptLine(
    readEvent: pending.removeFirst,
    redraw: (List<String> _, int _) {},
    onInterrupt: () => throw StateError('interrupted'),
  );
}

List<TermEvent> text(String value) => <TermEvent>[
  for (final int rune in value.runes)
    TermEvent(TermEventKind.char, char: String.fromCharCode(rune)),
];

void main() {
  const TermEvent enter = TermEvent(TermEventKind.enter);
  const TermEvent escape = TermEvent(TermEventKind.escape);

  test('Escape cancels empty and partially completed required fields', () {
    for (final String value in <String>['', 'panel.example.test', 'secret']) {
      expect(
        () => read(<TermEvent>[...text(value), escape]),
        throwsA(isA<PromptBackNavigation>()),
      );
    }
  });

  test('a single Escape cancels without a cursor position response', () {
    final TermEventParser parser = TermEventParser();
    expect(parser.add(0x1b), isEmpty);
    expect(
      () => read(<TermEvent>[parser.timeout()!]),
      throwsA(isA<PromptBackNavigation>()),
    );
  });

  test('accepts blank defaults and full pasted values', () {
    expect(read(<TermEvent>[enter]), isEmpty);
    final String value = 'https://panel.example.test/${'a' * 500}';
    expect(read(<TermEvent>[...text(value), enter]), value);
  });

  test('supports edits, home/end and delete without submitting', () {
    expect(
      read(<TermEvent>[
        ...text('ab'),
        const TermEvent(TermEventKind.arrowLeft),
        ...text('X'),
        const TermEvent(TermEventKind.delete),
        const TermEvent(TermEventKind.home),
        const TermEvent(TermEventKind.delete),
        const TermEvent(TermEventKind.end),
        ...text('Z'),
        const TermEvent(TermEventKind.backspace),
        enter,
      ]),
      'X',
    );
  });

  test('deleting a Unicode character leaves valid text', () {
    expect(
      read(<TermEvent>[
        ...text('test𝒙'),
        const TermEvent(TermEventKind.backspace),
        enter,
      ]),
      'test',
    );
  });

  test('mouse and cursor reports do not contaminate input', () {
    expect(
      read(<TermEvent>[
        ...text('abc'),
        const TermEvent(TermEventKind.cursorReport, row: 1, col: 4),
        const TermEvent(TermEventKind.mouseDown),
        const TermEvent(TermEventKind.mouseUp),
        const TermEvent(TermEventKind.wheelDown),
        enter,
      ]),
      'abc',
    );
  });

  test('Ctrl-C invokes interrupt instead of accepting a value', () {
    expect(
      () => read(<TermEvent>[
        ...text('secret'),
        const TermEvent(TermEventKind.ctrlC),
      ]),
      throwsStateError,
    );
  });
}
