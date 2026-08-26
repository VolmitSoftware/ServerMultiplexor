/// Button-chip rendering for the interactive monitor dashboard: a single
/// `[ LABEL ]` chip in any of its interaction states, and a row layout that
/// packs chips left to right and reports where each one landed.
///
/// Everything in this library is pure: no clock reads, no IO, no mutation.
library;

import 'ansi.dart';
import 'theme.dart';

/// The interaction state of a single button chip.
enum ButtonState { normal, hover, pressed, disabled }

/// A button's identity and behavior, independent of layout or interaction
/// state: what it is, not where it sits or how it currently looks.
class ButtonSpec {
  const ButtonSpec({
    required this.id,
    required this.label,
    this.shortcut,
    this.danger = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final String? shortcut;
  final bool danger;
  final bool enabled;

  String get displayLabel =>
      shortcut == null ? label : '${shortcut!.toUpperCase()} $label';

  String labelFor({required bool showShortcut}) =>
      showShortcut ? displayLabel : label;
}

/// Renders [label] as a `[ LABEL ]` chip in [state], with zero background
/// SGR codes at any color depth and identical plain text at
/// [ColorDepth.none]. Visible width is always `label.length + 4`.
///
/// Tone composition:
/// - [ButtonState.normal]: the brackets are painted [MonitorTheme.frame]
///   and the label is painted [MonitorTheme.text] (or [MonitorTheme.danger]
///   when [danger] is true).
/// - [ButtonState.hover]: the whole chip is painted [MonitorTheme.accent]
///   (or [MonitorTheme.danger] when [danger] is true) plus
///   [MonitorTheme.bold].
/// - [ButtonState.pressed]: the whole chip is painted
///   [MonitorTheme.textStrong] plus [MonitorTheme.bold], regardless of
///   [danger] — the press flash is uniform.
/// - [ButtonState.disabled]: the whole chip is painted [MonitorTheme.faint],
///   regardless of [danger].
String renderButton({
  required String label,
  required MonitorTheme theme,
  ButtonState state = ButtonState.normal,
  bool danger = false,
}) {
  const String open = '[ ';
  const String close = ' ]';
  switch (state) {
    case ButtonState.normal:
      final String labelTone = danger ? theme.danger : theme.text;
      return '${theme.paint(open, theme.frame)}'
          '${theme.paint(label, labelTone)}'
          '${theme.paint(close, theme.frame)}';
    case ButtonState.hover:
      final String chipTone =
          '${theme.bold}${danger ? theme.danger : theme.accent}';
      return theme.paint('$open$label$close', chipTone);
    case ButtonState.pressed:
      return theme.paint(
        '$open$label$close',
        '${theme.bold}${theme.textStrong}',
      );
    case ButtonState.disabled:
      return theme.paint('$open$label$close', theme.faint);
  }
}

/// Where one placed chip landed within a [ButtonRowRender.row]: half-open
/// column range `[colStart, colEnd)`, 0-based within the row.
class ButtonSpan {
  const ButtonSpan({
    required this.id,
    required this.colStart,
    required this.colEnd,
  });

  final String id;
  final int colStart;
  final int colEnd;
}

/// The result of [layoutButtonRow]: the rendered [row] text and a [ButtonSpan]
/// for every clickable chip placed within it.
class ButtonRowRender {
  const ButtonRowRender({required this.row, required this.spans});

  final String row;
  final List<ButtonSpan> spans;
}

/// The interaction state [button] renders in, given the currently hovered
/// and pressed ids. A disabled button is always disabled, regardless of
/// [hoveredId]/[pressedId]; otherwise a press wins over a hover on the same
/// id.
ButtonState _stateFor(ButtonSpec button, String? hoveredId, String? pressedId) {
  if (!button.enabled) {
    return ButtonState.disabled;
  }
  if (pressedId == button.id) {
    return ButtonState.pressed;
  }
  if (hoveredId == button.id) {
    return ButtonState.hover;
  }
  return ButtonState.normal;
}

/// Lays [buttons] out left to right into a single row exactly [width]
/// visible columns wide: `[indent]` leading spaces, each chip from
/// [renderButton], and `[gap]` spaces between consecutive chips.
///
/// A button whose chip would not fully fit within [width] is dropped whole
/// — never clipped mid-chip — along with every button after it, since a
/// left-to-right pack only ever runs out of room on the right. A disabled
/// button is still rendered (in its faint state) but never gets a
/// [ButtonSpan], since it is not clickable. [hoveredId] and [pressedId]
/// select the rendered state of the chip whose id matches; a press wins over
/// a hover on the same id.
ButtonRowRender layoutButtonRow({
  required List<ButtonSpec> buttons,
  required int width,
  required MonitorTheme theme,
  String? hoveredId,
  String? pressedId,
  bool showShortcuts = true,
  int gap = 1,
  int indent = 1,
}) {
  final int safeWidth = width < 0 ? 0 : width;
  final int safeIndent = indent < 0 ? 0 : indent;
  final int safeGap = gap < 0 ? 0 : gap;

  final StringBuffer buffer = StringBuffer(' ' * safeIndent);
  final List<ButtonSpan> spans = <ButtonSpan>[];
  int cursor = safeIndent;
  bool first = true;

  for (final ButtonSpec button in buttons) {
    final String label = button.labelFor(showShortcut: showShortcuts);
    final int chipWidth = label.length + 4;
    final int gapBefore = first ? 0 : safeGap;
    final int start = cursor + gapBefore;
    final int end = start + chipWidth;
    if (end > safeWidth) {
      break;
    }

    if (gapBefore > 0) {
      buffer.write(' ' * gapBefore);
    }
    final ButtonState state = _stateFor(button, hoveredId, pressedId);
    buffer.write(
      renderButton(
        label: label,
        theme: theme,
        state: state,
        danger: button.danger,
      ),
    );
    if (state != ButtonState.disabled) {
      spans.add(ButtonSpan(id: button.id, colStart: start, colEnd: end));
    }

    cursor = end;
    first = false;
  }

  final String row = Ansi.padVisible(
    Ansi.clipVisible(buffer.toString(), safeWidth),
    safeWidth,
  );
  return ButtonRowRender(row: row, spans: spans);
}
