/// The one-line outcome a finished flow leaves for the screen it returns to,
/// shown there instead of holding the flow open on a key press.
class FlowNotice {
  const FlowNotice(this.message);

  final String message;

  static FlowNotice? _pending;

  /// Replaces any notice that has not been shown yet.
  static void post(String message) => _pending = FlowNotice(message);

  /// The notice waiting to be shown, cleared as it is handed over.
  static FlowNotice? take() {
    final FlowNotice? notice = _pending;
    _pending = null;
    return notice;
  }
}
