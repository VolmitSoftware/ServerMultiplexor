import 'package:multiplexor/utils/terminal/frame_patch.dart';
import 'package:test/test.dart';

void main() {
  group('terminalFullFrameCheckpointDue', () {
    test('uses a one-million-character default budget', () {
      expect(terminalFullFrameCheckpointCharacters, 1_000_000);
    });

    test('keeps incremental output below the checkpoint budget', () {
      expect(
        terminalFullFrameCheckpointDue(
          charactersSinceFullFrame: 900_000,
          nextPatchCharacters: 99_999,
        ),
        isFalse,
      );
    });

    test('requests a checkpoint when the next patch reaches the budget', () {
      expect(
        terminalFullFrameCheckpointDue(
          charactersSinceFullFrame: 900_000,
          nextPatchCharacters: 100_000,
        ),
        isTrue,
      );
    });

    test('does not checkpoint an empty idle update', () {
      expect(
        terminalFullFrameCheckpointDue(
          charactersSinceFullFrame: terminalFullFrameCheckpointCharacters,
          nextPatchCharacters: 0,
        ),
        isFalse,
      );
    });
  });

  group('renderTerminalPatch', () {
    test('renders a full clear and the frame content on the first render', () {
      const String next = 'line one\nline two';
      final String patch = renderTerminalPatch(previous: null, next: next);

      expect(patch, '\x1B[H\x1B[2J$next\x1B[0m\x1B[H\x1B[?25l');
    });

    test('returns an empty string when previous and next are identical', () {
      const String frame = 'line one\nline two\nline three';

      final String patch = renderTerminalPatch(previous: frame, next: frame);

      expect(patch, '');
    });

    test(
      'addresses only the row of a single changed middle line and no others',
      () {
        const String previous = 'top\nmiddle\nbottom';
        const String next = 'top\nCHANGED\nbottom';

        final String patch = renderTerminalPatch(
          previous: previous,
          next: next,
        );

        expect(patch, '\x1B[2;1HCHANGED\x1B[K\x1B[0m\x1B[H\x1B[?25l');
        expect('\x1B[1;1H'.allMatches(patch).length, 0);
        expect('\x1B[3;1H'.allMatches(patch).length, 0);
        expect('\x1B[2;1H'.allMatches(patch).length, 1);
      },
    );

    test('clears trailing rows removed when the next frame is shorter', () {
      const String previous = 'top\nmiddle\nbottom';
      const String next = 'top';

      final String patch = renderTerminalPatch(previous: previous, next: next);

      expect(patch, '\x1B[2;1H\x1B[K\x1B[3;1H\x1B[K\x1B[0m\x1B[H\x1B[?25l');
    });

    test('writes new trailing rows appended when the next frame is longer', () {
      const String previous = 'top';
      const String next = 'top\nmiddle\nbottom';

      final String patch = renderTerminalPatch(previous: previous, next: next);

      expect(
        patch,
        '\x1B[2;1Hmiddle\x1B[K\x1B[3;1Hbottom\x1B[K\x1B[0m\x1B[H\x1B[?25l',
      );
    });

    test(
      'bypasses the diff and forces a full render when forceFull is true',
      () {
        const String frame = 'unchanged\nframe';

        final String patch = renderTerminalPatch(
          previous: frame,
          next: frame,
          forceFull: true,
        );

        expect(patch, '\x1B[H\x1B[2J$frame\x1B[0m\x1B[H\x1B[?25l');
      },
    );

    test('patches multiple non-contiguous changed lines independently', () {
      const String previous = 'a\nb\nc\nd\ne';
      const String next = 'a\nX\nc\nY\ne';

      final String patch = renderTerminalPatch(previous: previous, next: next);

      expect(patch, '\x1B[2;1HX\x1B[K\x1B[4;1HY\x1B[K\x1B[0m\x1B[H\x1B[?25l');
    });

    test(
      'treats a null previous the same as the first render even with an empty next frame',
      () {
        final String patch = renderTerminalPatch(previous: null, next: '');

        expect(patch, '\x1B[H\x1B[2J\x1B[0m\x1B[H\x1B[?25l');
      },
    );

    test('parks and hides the caret after every non-empty update', () {
      const String trailer = '\x1B[0m\x1B[H\x1B[?25l';
      final List<String> patches = <String>[
        renderTerminalPatch(previous: null, next: 'first frame'),
        renderTerminalPatch(previous: 'old', next: 'new'),
        renderTerminalPatch(previous: 'same', next: 'same', forceFull: true),
      ];

      expect(patches, everyElement(endsWith(trailer)));
      expect(renderTerminalPatch(previous: 'same', next: 'same'), isEmpty);
    });
  });

  group('synchronizeTerminalPatch', () {
    test('wraps a visible patch in one synchronized update', () {
      expect(synchronizeTerminalPatch('patch'), '\x1B[?2026hpatch\x1B[?2026l');
    });

    test('keeps an idle no-op completely silent', () {
      expect(synchronizeTerminalPatch(''), isEmpty);
    });
  });
}
