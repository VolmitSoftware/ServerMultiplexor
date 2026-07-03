# Dashboard Quick-Action Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add uppercase single-key shortcuts (R/S/X/O) to the interactive wizard's first-open dashboard that act on the currently highlighted server row without opening its submenu.

**Architecture:** A new generic `onActionKey` hook on the `menuSelect` TUI component reports an uppercase keypress against the highlighted entry; the wizard maps R/S/X/O to per-instance actions via a pure, unit-tested helper and dispatches them. A new `runtime stop --graceful` command backs the S key with a real clean shutdown (send `stop` to the console, wait, fall back to force-stop).

**Tech Stack:** Dart 3.10, `package:test`, tmux-backed runtime, `dart analyze` / `dart test`.

## Global Constraints

- **NEVER run git commands** (`add`, `commit`, `push`, etc.). The user handles all git operations. Where this plan would normally commit, run the validation checkpoint instead and stop.
- **Strongly type everything.** Explicit type annotations; no `var`/`dynamic` where a type can be written (project rule).
- **No backwards-compatibility shims.** Change call sites directly.
- **No emojis** in code, comments, or output. (The existing `✔`/`▸` glyphs in `menu.dart` are pre-existing UI and stay.)
- **README is user-facing truth:** any CLI flag change updates `README.md` and `lib/cli/command_help.dart` in the same change.
- All commands run from `MultiplexorApp/`. Package name is `multiplexor`; test imports use `package:multiplexor/...`.
- Validation path for every task: `dart analyze` -> `dart test`.
- Uppercase-only keys: R/S/X/O. Lowercase `r` (Refresh) and `s` (Start-all) keep their current meanings and must not regress.

## File Structure

- **Create** `lib/services/dashboard_quick_action.dart` — public `DashboardQuickAction` enum + pure `dashboardQuickAction()` mapping function. Single responsibility: map a raw keypress + "is this a server row?" to an action. Pure, no I/O, unit-testable.
- **Create** `test/dashboard_quick_action_test.dart` — unit tests for the helper.
- **Modify** `lib/utils/prompt/menu.dart` — add optional `onActionKey` param to `menuSelect`; refactor `finish` into `finishWith`.
- **Modify** `test/term_events_test.dart` — add a guard test that uppercase letters are case-preserved.
- **Modify** `lib/services/native_command_service.dart` — `--graceful` flag on `runtime stop` + new `_runtimeGracefulStop`.
- **Modify** `lib/services/interactive_wizard.dart` — new `_Act` values, `onActionKey` wiring in `_dashboardMenu`, dispatch handlers, footer hint.
- **Modify** `README.md` and `lib/cli/command_help.dart` — document `--graceful` and the dashboard quick keys.

---

### Task 1: Pure quick-action mapping helper

**Files:**
- Create: `lib/services/dashboard_quick_action.dart`
- Test: `test/dashboard_quick_action_test.dart`

**Interfaces:**
- Produces: `enum DashboardQuickAction { restart, stop, kill, console }` and `DashboardQuickAction? dashboardQuickAction(String rawChar, {required bool onServerRow})`. Task 5 (wizard) consumes both.

- [ ] **Step 1: Write the failing test**

Create `test/dashboard_quick_action_test.dart`:

```dart
import 'package:multiplexor/services/dashboard_quick_action.dart';
import 'package:test/test.dart';

void main() {
  group('dashboardQuickAction', () {
    test('maps uppercase keys on a server row', () {
      expect(
        dashboardQuickAction('R', onServerRow: true),
        DashboardQuickAction.restart,
      );
      expect(
        dashboardQuickAction('S', onServerRow: true),
        DashboardQuickAction.stop,
      );
      expect(
        dashboardQuickAction('X', onServerRow: true),
        DashboardQuickAction.kill,
      );
      expect(
        dashboardQuickAction('O', onServerRow: true),
        DashboardQuickAction.console,
      );
    });

    test('returns null when the highlight is not a server row', () {
      expect(dashboardQuickAction('R', onServerRow: false), isNull);
      expect(dashboardQuickAction('X', onServerRow: false), isNull);
    });

    test('ignores lowercase and unrelated characters', () {
      expect(dashboardQuickAction('r', onServerRow: true), isNull);
      expect(dashboardQuickAction('s', onServerRow: true), isNull);
      expect(dashboardQuickAction('q', onServerRow: true), isNull);
      expect(dashboardQuickAction('1', onServerRow: true), isNull);
      expect(dashboardQuickAction('', onServerRow: true), isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/dashboard_quick_action_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'multiplexor' ... dashboard_quick_action.dart` / URI does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/services/dashboard_quick_action.dart`:

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/dashboard_quick_action_test.dart`
Expected: PASS — all 3 tests green.

- [ ] **Step 5: Checkpoint**

Run: `dart analyze` (expected: `No issues found!`). Do NOT run git — stop here for review.

---

### Task 2: Guard test for uppercase case preservation

The feature relies on `TermEventParser` passing uppercase letters through unchanged (so `S` is not seen as lowercase `s`). The parser already does this; this test locks the invariant in.

**Files:**
- Modify: `test/term_events_test.dart` (add one test inside the existing `group('TermEventParser keys', ...)`)

- [ ] **Step 1: Add the guard test**

Inside `main()`'s `group('TermEventParser keys', () {` block in `test/term_events_test.dart`, add after the `'parses printable characters'` test:

```dart
    test('preserves case for uppercase letters', () {
      final TermEventParser parser = TermEventParser();
      final List<TermEvent> events = feed(parser, 'R');
      expect(events, hasLength(1));
      expect(events.single.kind, TermEventKind.char);
      expect(events.single.char, 'R');
    });
```

- [ ] **Step 2: Run the test (guard — expected to pass immediately)**

Run: `dart test test/term_events_test.dart`
Expected: PASS. If it FAILS, the parser is lowercasing input — stop and investigate before continuing, because the whole feature depends on this.

- [ ] **Step 3: Checkpoint**

Run: `dart analyze` (expected: `No issues found!`). Do NOT run git.

---

### Task 3: `menuSelect` action-key hook

**Files:**
- Modify: `lib/utils/prompt/menu.dart`

**Interfaces:**
- Produces: new optional named param on `menuSelect`: `T? Function(String rawChar, MenuEntry<T> highlighted)? onActionKey`. When it returns non-null for the highlighted entry, the menu finishes and returns that value. Task 5 consumes it.
- Note: `menuSelect` is an interactive TTY component with no existing unit tests; verification for this task is compile-clean + the downstream smoke test in Task 7. Do not add a TTY test.

- [ ] **Step 1: Add the `onActionKey` parameter**

In `lib/utils/prompt/menu.dart`, change the `menuSelect` signature (currently ends with `Duration tickInterval = const Duration(seconds: 1),`) to add the new param:

```dart
Future<T> menuSelect<T>(
  String title,
  List<MenuEntry<T>> entries, {
  int initialIndex = 0,
  String? hint,
  Future<List<MenuEntry<T>>> Function()? onTick,
  Duration tickInterval = const Duration(seconds: 1),
  T? Function(String rawChar, MenuEntry<T> highlighted)? onActionKey,
}) async {
```

- [ ] **Step 2: Refactor `finish` into `finishWith`**

Replace the existing `finish` closure (the block starting `T finish(int index) {` and ending with its closing `}`) with:

```dart
    T finishWith(T value, String label) {
      clear();
      io.disableMouse();
      io.showCursor();
      // Leave raw mode before printing: with OPOST off, "\n" does not
      // return the carriage and the next line starts mid-column.
      io.setRawMode(false);
      stdout.writeln(
        '${Ansi.style('✔', Ansi.green)} ${Ansi.style(title, Ansi.bold)} '
        '${Ansi.style('·', Ansi.gray)} ${Ansi.style(label, Ansi.green)}',
      );
      return value;
    }

    T finish(int index) =>
        finishWith(entries[index].value as T, entries[index].label);
```

- [ ] **Step 3: Handle action keys in the char branch**

In the `case TermEventKind.char:` branch, insert the action-key check as the first lines — before `final String char = event.char.toLowerCase();`. The branch becomes:

```dart
        case TermEventKind.char:
          if (onActionKey != null) {
            final T? actionValue = onActionKey(event.char, entries[selected]);
            if (actionValue != null) {
              return finishWith(actionValue, entries[selected].label);
            }
          }
          final String char = event.char.toLowerCase();
          final int digit = int.tryParse(char) ?? -1;
          if (digit >= 1 && digit <= selectable.length) {
            selected = selectable[digit - 1];
            draw(repaint: true);
            break;
          }
          for (final int i in selectable) {
            if (entries[i].shortcut?.toLowerCase() == char) {
              return finish(i);
            }
          }
          break;
```

(The raw `event.char` is checked first so uppercase keys are handled before the lowercase fold that drives digit/shortcut matching. `selected` is always a selectable index, so `entries[selected]` is never a separator.)

- [ ] **Step 4: Verify it compiles**

Run: `dart analyze`
Expected: `No issues found!`

- [ ] **Step 5: Run the full test suite (no regressions)**

Run: `dart test`
Expected: all existing tests pass (Tasks 1 and 2 included).

- [ ] **Step 6: Checkpoint**

Do NOT run git — stop for review.

---

### Task 4: `runtime stop --graceful` command

**Files:**
- Modify: `lib/services/native_command_service.dart` (the `'stop'` case in `_dispatchRuntime`; the default-case usage string; add `_runtimeGracefulStop` immediately after `_runtimeStop`)

**Interfaces:**
- Consumes: existing helpers `_currentInstance`, `_tmuxSessionName`, `_tmuxSessionExists`, `_runProcess`, `_readPid`, `_runtimeServerPidFile`, `_runtimeConsolePidFile`, `_pidRunning`, `_runtimeStop`, `deleteSyncSafe`, `_NativeCommandException`.
- Produces: `runtime stop [instance] --graceful` behavior. Task 5's `_quickStop` shells out to it.

- [ ] **Step 1: Parse `--graceful` in the stop case**

In `_dispatchRuntime`, replace the existing `case 'stop':` block:

```dart
      case 'stop':
        await _runtimeStop(profile, rest.isNotEmpty ? rest.first : null, io);
        return 0;
```

with:

```dart
      case 'stop':
        final bool graceful = rest.contains('--graceful');
        final List<String> stopPositional = rest
            .where((String a) => a != '--graceful')
            .toList(growable: false);
        final String? stopTarget =
            stopPositional.isNotEmpty ? stopPositional.first : null;
        if (graceful) {
          await _runtimeGracefulStop(profile, stopTarget, io);
        } else {
          await _runtimeStop(profile, stopTarget, io);
        }
        return 0;
```

- [ ] **Step 2: Update the usage string**

In the same method's `default:` case, replace the usage message string with (adds `; stop supports --graceful`):

```dart
        throw _NativeCommandException(
          'Usage: runtime <console|consoles|consoles-lateral|start|stop|restart|status|stats|states|metrics|list|settings> [instance|args] (start/restart support --instance/--no-console; stop supports --graceful)',
          2,
        );
```

- [ ] **Step 3: Add `_runtimeGracefulStop`**

Immediately after the closing brace of `_runtimeStop` (the method that ends with the `[OK]/[WARN] Runtime stopped` writes), add:

```dart
  Future<void> _runtimeGracefulStop(
    ConsumerProfile profile,
    String? inputInstance,
    _NativeIoBuffer io,
  ) async {
    final instance = inputInstance?.trim().isNotEmpty == true
        ? inputInstance!.trim()
        : _currentInstance(profile);

    if (instance == null || instance.isEmpty) {
      throw _NativeCommandException('No active instance set', 2);
    }

    final tmuxSession = _tmuxSessionName(profile, instance);
    if (!await _tmuxSessionExists(tmuxSession)) {
      // No live console to talk to; defer to the hard path so pid files are
      // cleaned up and the result is reported once.
      await _runtimeStop(profile, instance, io);
      return;
    }

    // Ask the server to shut down cleanly (flushes and saves worlds).
    await _runProcess('tmux', <String>[
      'send-keys',
      '-t',
      tmuxSession,
      'stop',
      'Enter',
    ]);

    final serverPid = _readPid(_runtimeServerPidFile(profile, instance));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var exited = false;
    while (DateTime.now().isBefore(deadline)) {
      final sessionAlive = await _tmuxSessionExists(tmuxSession);
      final pidAlive = serverPid != null && await _pidRunning(serverPid);
      if (!sessionAlive && !pidAlive) {
        exited = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (!exited) {
      io.write('[WARN] Graceful stop timed out; forcing: $instance');
      await _runtimeStop(profile, instance, io);
      return;
    }

    File(_runtimeServerPidFile(profile, instance)).deleteSyncSafe();
    File(_runtimeConsolePidFile(profile, instance)).deleteSyncSafe();
    io.write('[OK] Runtime stopped (graceful): $instance');
  }
```

- [ ] **Step 4: Verify it compiles**

Run: `dart analyze`
Expected: `No issues found!`

- [ ] **Step 5: Smoke the flag parsing (no running server needed)**

Run: `./start.sh runtime stop __no_such_instance__ --graceful`
Expected: it treats the argument as an instance name and does not crash on the flag. Because there is no live tmux session it defers to the hard path, which prints a `[OK]`/`[WARN] Runtime stopped: __no_such_instance__` line (matches how `runtime stop <unknown>` already behaves). Confirm no Dart exception/stack trace and a clean exit.

- [ ] **Step 6: Run the full test suite**

Run: `dart test`
Expected: all tests pass.

- [ ] **Step 7: Checkpoint**

Do NOT run git — stop for review.

---

### Task 5: Wizard wiring (quick keys on the dashboard)

**Files:**
- Modify: `lib/services/interactive_wizard.dart` (add import; extend `_Act`; `_dashboardMenu`; `_dispatch`; add four `_quick*` handlers)

**Interfaces:**
- Consumes: `dashboardQuickAction` + `DashboardQuickAction` (Task 1); `menuSelect`'s `onActionKey` param (Task 3); `runtime stop --graceful` (Task 4).

- [ ] **Step 1: Import the helper**

At the top of `lib/services/interactive_wizard.dart`, add the import alongside the other `package:multiplexor/...` (or relative) service imports:

```dart
import 'dashboard_quick_action.dart';
```

(Match the existing import style in the file — if neighboring service imports are relative like `'consumer_service.dart'`, use `'dashboard_quick_action.dart'`; if they are `package:multiplexor/services/...`, use that form.)

- [ ] **Step 2: Extend the `_Act` enum**

In the `enum _Act { ... }` declaration, add four values (place them after `instance,`):

```dart
enum _Act {
  instance,
  instanceRestart,
  instanceStop,
  instanceKill,
  instanceConsole,
  create,
  createMany,
  startAll,
  stopAll,
  wipeEverything,
  consolesGrid,
  consolesLateral,
  buildMenu,
  consumer,
  refresh,
  quit,
}
```

- [ ] **Step 3: Wire `onActionKey` and the hint into `_dashboardMenu`**

Replace the `_dashboardMenu` method body's `menuSelect` call so it passes `hint` and `onActionKey`:

```dart
  Future<_DashChoice> _dashboardMenu(_DashboardData data) async {
    return menuSelect<_DashChoice>(
      'Dashboard',
      _buildDashEntries(data.rows, data.active),
      initialIndex: data.rows.isEmpty ? 0 : 1,
      hint:
          '↑↓ move · enter open · R restart · S stop · X kill · O console · esc back',
      onActionKey: (String raw, MenuEntry<_DashChoice> entry) {
        final _DashChoice? value = entry.value;
        final bool onServerRow = value != null &&
            value.kind == _Act.instance &&
            value.instance != null;
        final DashboardQuickAction? action =
            dashboardQuickAction(raw, onServerRow: onServerRow);
        if (action == null) {
          return null;
        }
        final String name = value!.instance!;
        switch (action) {
          case DashboardQuickAction.restart:
            return _DashChoice(_Act.instanceRestart, instance: name);
          case DashboardQuickAction.stop:
            return _DashChoice(_Act.instanceStop, instance: name);
          case DashboardQuickAction.kill:
            return _DashChoice(_Act.instanceKill, instance: name);
          case DashboardQuickAction.console:
            return _DashChoice(_Act.instanceConsole, instance: name);
        }
      },
      // Live refresh: re-poll players/TPS/version and redraw in place ~1s.
      onTick: () async {
        final List<_InstanceRow> rows = await _loadInstanceMetricRows();
        final String? active = await _activeInstance();
        return _buildDashEntries(rows, active);
      },
    );
  }
```

- [ ] **Step 4: Handle the new acts in `_dispatch`**

In the `_dispatch` `switch (choice.kind)`, add four cases (place them right after the `case _Act.instance:` block):

```dart
      case _Act.instanceRestart:
        await _quickRestart(choice.instance!);
        return;
      case _Act.instanceStop:
        await _quickStop(choice.instance!);
        return;
      case _Act.instanceKill:
        await _quickKill(choice.instance!);
        return;
      case _Act.instanceConsole:
        await _quickConsole(choice.instance!);
        return;
```

- [ ] **Step 5: Add the four quick-action handlers**

Add these methods next to `_instanceMenu` (anywhere in the class):

```dart
  Future<void> _quickRestart(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    final bool running = row != null && row.state != RuntimeState.stopped;
    Ui.doing(running ? 'Restarting $name' : 'Starting $name');
    final int code = running
        ? await _shellRun(<String>['runtime', 'restart', name, '--no-console'])
        : await _shellRun(<String>['runtime', 'start', name, '--no-console']);
    if (code != 0) {
      await Ui.pause();
    }
  }

  Future<void> _quickStop(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    if (row == null || row.state == RuntimeState.stopped) {
      return;
    }
    Ui.doing('Stopping $name (graceful)');
    await _shellRun(<String>['runtime', 'stop', name, '--graceful']);
  }

  Future<void> _quickKill(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    if (row == null || row.state == RuntimeState.stopped) {
      return;
    }
    Ui.doing('Killing $name');
    await _shellRun(<String>['runtime', 'stop', name]);
  }

  Future<void> _quickConsole(String name) async {
    final _InstanceRow? row = await Ui.shielded(() => _loadInstanceRow(name));
    final bool running = row != null && row.state != RuntimeState.stopped;
    if (running) {
      await _shellRun(<String>['runtime', 'console', name]);
    } else {
      await _shellRun(<String>['runtime', 'start', name]);
    }
  }
```

(S/X on an already-stopped server return silently — the dashboard clears and redraws immediately, so a message would only flash. This matches the "no-op" behavior in the spec.)

- [ ] **Step 6: Verify it compiles (exhaustive switch)**

Run: `dart analyze`
Expected: `No issues found!` In particular, no "missing case" warning on `_dispatch`'s switch over `_Act`.

- [ ] **Step 7: Run the full test suite**

Run: `dart test`
Expected: all tests pass.

- [ ] **Step 8: Checkpoint**

Do NOT run git — stop for review.

---

### Task 6: Documentation (README + command help)

**Files:**
- Modify: `README.md` (runtime table row for `stop`; dashboard shortcuts section)
- Modify: `lib/cli/command_help.dart` (runtime group `stop` form)

- [ ] **Step 1: Fix and extend the README `runtime stop` row**

In `README.md`, replace the `runtime stop` table row (currently `| `runtime stop [instance]` | Send a graceful stop. |`) with:

```markdown
| `runtime stop [instance] [--graceful]` | Force-stop the instance immediately (kills the tmux session, then SIGTERM/SIGKILL any tracked pids). With `--graceful`, sends `stop` to the server console and waits up to 60s for a clean world-save shutdown, falling back to a force-stop on timeout. |
```

- [ ] **Step 2: Document the dashboard quick keys**

In `README.md`, immediately after the existing `Dashboard shortcuts:` line, add a new paragraph:

```markdown
Highlighted-server quick keys (act on the selected server without opening its menu): `R` restart, `S` stop (graceful), `X` kill (force), `O` console. These are uppercase (Shift), so they never clash with the lowercase shortcuts above; they do nothing when a non-server row (New, Build, etc.) is highlighted.
```

- [ ] **Step 3: Update the CLI help form**

In `lib/cli/command_help.dart`, inside the `CommandHelpGroup('runtime', <String>[ ... ])`, change the `'stop [instance]',` line to:

```dart
    'stop [instance] [--graceful]',
```

- [ ] **Step 4: Verify docs/tests still pass**

Run: `dart analyze` then `dart test`
Expected: `No issues found!` and all tests pass (including `command_help_test.dart`).

- [ ] **Step 5: Checkpoint**

Do NOT run git — stop for review.

---

### Task 7: Final end-to-end validation

**Files:** none (verification only)

- [ ] **Step 1: Clean analyze + full suite**

Run: `dart analyze` (expected `No issues found!`) then `dart test` (expected all pass).

- [ ] **Step 2: CLI smoke**

Run: `./start.sh help runtime`
Expected: the runtime help lists `stop [instance] [--graceful]`.

- [ ] **Step 3: Interactive dashboard verification (manual, needs a TTY)**

Because the wizard requires a real terminal, verify by hand:
1. Run `./start.sh` to open the dashboard.
2. With at least one instance present, highlight a **stopped** server and press `R`. Expected: `Starting <name>` appears, the server starts in the background, and the dashboard's state badge updates to running within ~1s. Press `O` to attach the console, then Esc to detach.
3. Highlight a **running** server, press `S`. Expected: `Stopping <name> (graceful)`; the server saves and stops; badge returns to stopped.
4. Highlight a running server, press `X`. Expected: immediate kill; badge returns to stopped.
5. Highlight a non-server row (e.g. "New instance") and press `R`/`S`/`X`. Expected: nothing happens.
6. Confirm lowercase `r` still refreshes and lowercase `s` still starts all stopped (no regression).

- [ ] **Step 4: Report results**

Summarize what was run and observed (analyze/test output counts, help output, dashboard behavior). Do NOT run git — the user commits.

---

## Self-Review

**Spec coverage:**
- Uppercase R/S/X/O on highlighted server row -> Tasks 3 (hook), 1 (mapping), 5 (wiring). Covered.
- Server-rows-only / non-server no-op -> `onServerRow` gate in Task 1 + `_dispatch` guards. Covered.
- R stay-on-list restart/start; O attach console -> Task 5 `_quickRestart`/`_quickConsole`. Covered.
- S graceful vs X force -> Task 4 (`--graceful` + `_runtimeGracefulStop`) + Task 5 mapping. Covered.
- No confirmation -> handlers act directly; no `Ui.confirm`. Covered.
- Uppercase does not clash with lowercase r/s -> raw-char check before lowercase fold (Task 3) + guard test (Task 2). Covered.
- Footer hint -> Task 5 Step 3. Covered.
- README + help sync -> Task 6. Covered.
- Tests: pure mapping (Task 1), case preservation (Task 2). Covered.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command shows expected output. Clean.

**Type consistency:** `DashboardQuickAction` enum values (`restart`/`stop`/`kill`/`console`) and `dashboardQuickAction(String, {required bool onServerRow})` are identical across Tasks 1 and 5. `_Act` values (`instanceRestart`/`instanceStop`/`instanceKill`/`instanceConsole`) match between Tasks 5 Step 2, Step 3, and Step 4. `onActionKey` signature `T? Function(String, MenuEntry<T>)` matches between Task 3 (definition) and Task 5 (use). `_runtimeGracefulStop(ConsumerProfile, String?, _NativeIoBuffer)` matches between definition (Task 4 Step 3) and call site (Task 4 Step 1). Consistent.
