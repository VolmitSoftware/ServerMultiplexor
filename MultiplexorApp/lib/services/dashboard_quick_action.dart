/// Quick actions triggered by a single uppercase keypress against a highlighted
/// dashboard server row.
enum DashboardQuickAction { restart, stop, kill, console }

/// Maps a raw keypress to a dashboard quick action.
///
/// Returns null when the highlighted entry is not a server row, or when
/// [rawChar] is not one of the uppercase quick keys. Case is significant: only
/// uppercase R/S/X/O trigger actions, so the lowercase dashboard shortcuts
/// (`r` = refresh, `s` = start-all) are never affected.
DashboardQuickAction? dashboardQuickAction(
  String rawChar, {
  required bool onServerRow,
}) {
  if (!onServerRow) {
    return null;
  }
  switch (rawChar) {
    case 'R':
      return DashboardQuickAction.restart;
    case 'S':
      return DashboardQuickAction.stop;
    case 'X':
      return DashboardQuickAction.kill;
    case 'O':
      return DashboardQuickAction.console;
    default:
      return null;
  }
}
