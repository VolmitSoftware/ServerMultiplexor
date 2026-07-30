import 'package:multiplexor/utils/terminal/ansi.dart';
import 'package:multiplexor/utils/terminal/button.dart';
import 'package:multiplexor/utils/terminal/theme.dart';
import 'package:test/test.dart';

/// A theme resolved at truecolor depth, for tests that assert exact escape
/// sequences.
MonitorTheme _truecolor() => MonitorTheme.detect(
  env: <String, String>{'COLORTERM': 'truecolor'},
  isTty: true,
);

void main() {
  group('ButtonSpec', () {
    test('defaults danger to false and enabled to true', () {
      const ButtonSpec spec = ButtonSpec(id: 'a', label: 'OK');
      expect(spec.danger, isFalse);
      expect(spec.enabled, isTrue);
    });

    test('stores every field', () {
      const ButtonSpec spec = ButtonSpec(
        id: 'kill',
        label: 'KILL',
        danger: true,
        enabled: false,
      );
      expect(spec.id, 'kill');
      expect(spec.label, 'KILL');
      expect(spec.danger, isTrue);
      expect(spec.enabled, isFalse);
    });
  });

  group('ButtonSpan', () {
    test('stores id and column range', () {
      const ButtonSpan span = ButtonSpan(id: 'a', colStart: 1, colEnd: 5);
      expect(span.id, 'a');
      expect(span.colStart, 1);
      expect(span.colEnd, 5);
    });
  });

  group('renderButton', () {
    test('the stripped text is always "[ LABEL ]"', () {
      final MonitorTheme theme = _truecolor();
      for (final ButtonState state in ButtonState.values) {
        expect(
          Ansi.strip(renderButton(label: 'START', theme: theme, state: state)),
          '[ START ]',
          reason: state.name,
        );
      }
    });

    test('visible width equals label.length + 4 for every state', () {
      final MonitorTheme theme = _truecolor();
      for (final ButtonState state in ButtonState.values) {
        final String rendered = renderButton(
          label: 'RESTART',
          theme: theme,
          state: state,
        );
        expect(
          Ansi.visibleLength(rendered),
          'RESTART'.length + 4,
          reason: state.name,
        );
      }
    });

    test(
      'at MonitorTheme.plain every state renders identical plain text with zero escapes',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        for (final ButtonState state in ButtonState.values) {
          final String rendered = renderButton(
            label: 'STOP',
            theme: theme,
            state: state,
          );
          expect(rendered, '[ STOP ]', reason: state.name);
          expect(rendered.contains('\x1B'), isFalse, reason: state.name);
        }
      },
    );

    test('never emits a background SGR in any state or danger combination', () {
      final MonitorTheme theme = _truecolor();
      for (final ButtonState state in ButtonState.values) {
        for (final bool danger in <bool>[false, true]) {
          final String rendered = renderButton(
            label: 'GO',
            theme: theme,
            state: state,
            danger: danger,
          );
          expect(
            rendered.contains('[48;'),
            isFalse,
            reason: '${state.name} danger=$danger',
          );
        }
      }
    });

    group('normal state tones', () {
      test(
        'brackets are frame-toned and the label is text-toned when not danger',
        () {
          final MonitorTheme theme = _truecolor();
          final String rendered = renderButton(label: 'OK', theme: theme);
          expect(
            rendered,
            '${theme.paint('[ ', theme.frame)}'
            '${theme.paint('OK', theme.text)}'
            '${theme.paint(' ]', theme.frame)}',
          );
        },
      );

      test(
        'the label is danger-toned when danger is true, brackets stay frame-toned',
        () {
          final MonitorTheme theme = _truecolor();
          final String rendered = renderButton(
            label: 'KILL',
            theme: theme,
            danger: true,
          );
          expect(
            rendered,
            '${theme.paint('[ ', theme.frame)}'
            '${theme.paint('KILL', theme.danger)}'
            '${theme.paint(' ]', theme.frame)}',
          );
        },
      );
    });

    group('hover state tones', () {
      test('the whole chip is accent + bold when not danger', () {
        final MonitorTheme theme = _truecolor();
        final String rendered = renderButton(
          label: 'OK',
          theme: theme,
          state: ButtonState.hover,
        );
        expect(rendered, theme.paint('[ OK ]', '${theme.bold}${theme.accent}'));
      });

      test('the whole chip is danger + bold when danger is true', () {
        final MonitorTheme theme = _truecolor();
        final String rendered = renderButton(
          label: 'KILL',
          theme: theme,
          state: ButtonState.hover,
          danger: true,
        );
        expect(
          rendered,
          theme.paint('[ KILL ]', '${theme.bold}${theme.danger}'),
        );
      });
    });

    group('pressed state tones', () {
      test('the whole chip is textStrong + bold regardless of danger', () {
        final MonitorTheme theme = _truecolor();
        final String normalPressed = renderButton(
          label: 'OK',
          theme: theme,
          state: ButtonState.pressed,
        );
        final String dangerPressed = renderButton(
          label: 'KILL',
          theme: theme,
          state: ButtonState.pressed,
          danger: true,
        );
        expect(
          normalPressed,
          theme.paint('[ OK ]', '${theme.bold}${theme.textStrong}'),
        );
        expect(
          dangerPressed,
          theme.paint('[ KILL ]', '${theme.bold}${theme.textStrong}'),
        );
      });
    });

    group('disabled state tones', () {
      test('the whole chip is faint regardless of danger', () {
        final MonitorTheme theme = _truecolor();
        final String normalDisabled = renderButton(
          label: 'OK',
          theme: theme,
          state: ButtonState.disabled,
        );
        final String dangerDisabled = renderButton(
          label: 'KILL',
          theme: theme,
          state: ButtonState.disabled,
          danger: true,
        );
        expect(normalDisabled, theme.paint('[ OK ]', theme.faint));
        expect(dangerDisabled, theme.paint('[ KILL ]', theme.faint));
      });
    });
  });

  group('layoutButtonRow', () {
    test('row is exactly `width` visible columns', () {
      final MonitorTheme theme = _truecolor();
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: <ButtonSpec>[const ButtonSpec(id: 'a', label: 'OK')],
        width: 40,
        theme: theme,
      );
      expect(Ansi.visibleLength(rendered.row), 40);
    });

    test('an empty buttons list produces an all-spaces row with no spans', () {
      final MonitorTheme theme = _truecolor();
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: <ButtonSpec>[],
        width: 10,
        theme: theme,
      );
      expect(rendered.row, ' ' * 10);
      expect(rendered.spans, isEmpty);
    });

    test(
      'a width too small for the first chip yields an all-spaces row and zero spans',
      () {
        final MonitorTheme theme = _truecolor();
        final ButtonRowRender rendered = layoutButtonRow(
          buttons: <ButtonSpec>[const ButtonSpec(id: 'a', label: 'RESTART')],
          width: 5,
          theme: theme,
          indent: 0,
        );
        expect(rendered.row, ' ' * 5);
        expect(rendered.spans, isEmpty);
      },
    );

    test('spans exactly cover each rendered chip in the stripped row', () {
      final MonitorTheme theme = _truecolor();
      final List<ButtonSpec> buttons = <ButtonSpec>[
        const ButtonSpec(id: 'start', label: 'START'),
        const ButtonSpec(id: 'stop', label: 'STOP'),
        const ButtonSpec(id: 'kill', label: 'KILL', danger: true),
      ];
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: buttons,
        width: 60,
        theme: theme,
      );
      final String stripped = Ansi.strip(rendered.row);
      expect(rendered.spans.length, buttons.length);
      for (final ButtonSpan span in rendered.spans) {
        final ButtonSpec spec = buttons.firstWhere(
          (ButtonSpec b) => b.id == span.id,
        );
        final String expectedChip = '[ ${spec.label} ]';
        expect(
          stripped.substring(span.colStart, span.colEnd),
          expectedChip,
          reason: span.id,
        );
      }
    });

    test(
      'chips are separated by `gap` spaces and start after `indent` spaces',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        final ButtonRowRender rendered = layoutButtonRow(
          buttons: <ButtonSpec>[
            const ButtonSpec(id: 'a', label: 'A'),
            const ButtonSpec(id: 'b', label: 'B'),
          ],
          width: 30,
          theme: theme,
          indent: 2,
          gap: 3,
        );
        expect(rendered.row, '  [ A ]   [ B ]${' ' * (30 - 15)}');
        // ButtonSpan has no `==` override, so compare fields directly rather
        // than the objects themselves.
        expect(rendered.spans.length, 2);
        expect(rendered.spans[0].id, 'a');
        expect(rendered.spans[0].colStart, 2);
        expect(rendered.spans[0].colEnd, 7);
        expect(rendered.spans[1].id, 'b');
        expect(rendered.spans[1].colStart, 10);
        expect(rendered.spans[1].colEnd, 15);
      },
    );

    test('a disabled button is rendered but emits no span', () {
      final MonitorTheme theme = MonitorTheme.plain();
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: <ButtonSpec>[
          const ButtonSpec(id: 'a', label: 'A', enabled: false),
          const ButtonSpec(id: 'b', label: 'B'),
        ],
        width: 30,
        theme: theme,
      );
      expect(rendered.spans.length, 1);
      expect(rendered.spans.single.id, 'b');
      expect(rendered.row.contains('[ A ]'), isTrue);
    });

    test(
      'buttons that do not fully fit are dropped whole from the right, never clipped mid-chip',
      () {
        final MonitorTheme theme = MonitorTheme.plain();
        final ButtonRowRender rendered = layoutButtonRow(
          buttons: <ButtonSpec>[
            const ButtonSpec(id: 'a', label: 'AAAA'), // chip width 8
            const ButtonSpec(id: 'b', label: 'BBBB'), // chip width 8
          ],
          // indent(1) + 8 = 9 fits 'a'; +1 gap + 8 = 18 does not fit 'b'.
          width: 12,
          theme: theme,
        );
        expect(rendered.spans.length, 1);
        expect(rendered.spans.single.id, 'a');
        expect(rendered.row.contains('BBBB'), isFalse);
        expect(rendered.row, ' [ AAAA ]${' ' * (12 - 9)}');
      },
    );

    test('hoveredId selects the hover state for the matching chip only', () {
      final MonitorTheme theme = _truecolor();
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: <ButtonSpec>[
          const ButtonSpec(id: 'a', label: 'A'),
          const ButtonSpec(id: 'b', label: 'B'),
        ],
        width: 30,
        theme: theme,
        hoveredId: 'b',
      );
      final String expectedA = renderButton(label: 'A', theme: theme);
      final String expectedB = renderButton(
        label: 'B',
        theme: theme,
        state: ButtonState.hover,
      );
      expect(rendered.row.contains(expectedA), isTrue);
      expect(rendered.row.contains(expectedB), isTrue);
    });

    test('pressedId wins over hoveredId when both match the same button', () {
      final MonitorTheme theme = _truecolor();
      final ButtonRowRender rendered = layoutButtonRow(
        buttons: <ButtonSpec>[const ButtonSpec(id: 'a', label: 'A')],
        width: 30,
        theme: theme,
        hoveredId: 'a',
        pressedId: 'a',
      );
      final String expected = renderButton(
        label: 'A',
        theme: theme,
        state: ButtonState.pressed,
      );
      expect(rendered.row.contains(expected), isTrue);
    });

    test(
      'a disabled button ignores hoveredId/pressedId and renders disabled',
      () {
        final MonitorTheme theme = _truecolor();
        final ButtonRowRender rendered = layoutButtonRow(
          buttons: <ButtonSpec>[
            const ButtonSpec(id: 'a', label: 'A', enabled: false),
          ],
          width: 30,
          theme: theme,
          hoveredId: 'a',
          pressedId: 'a',
        );
        final String expected = renderButton(
          label: 'A',
          theme: theme,
          state: ButtonState.disabled,
        );
        expect(rendered.row.contains(expected), isTrue);
        expect(rendered.spans, isEmpty);
      },
    );
  });
}
