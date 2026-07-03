# Dashboard quick-action keys

Date: 2026-07-03
Status: Approved (design)

## Problem

When the CLI opens with no arguments it goes straight to the interactive wizard's
dashboard — the main server list. Today the only way to act on a specific server
is to highlight its row and press Enter, which drills into a per-server submenu.
The user wants single-keypress actions that operate on the **currently highlighted
server row** directly from the dashboard (press a key to restart/stop/kill/console
the highlighted server).

## Behavior

When a **server row** is highlighted in the dashboard list, these keys act on that
server immediately — no submenu, no confirmation:

| Key | Action | Running server | Stopped server |
|-----|--------|----------------|----------------|
| **R** | Restart | restart in background, stay on the list | start in background, stay on the list |
| **S** | Stop (graceful) | send `stop` to the MC console, wait for a clean world-save exit | no-op (brief note) |
| **X** | Kill (force) | kill the tmux session immediately (today's `runtime stop`) | no-op (brief note) |
| **O** | Console | attach console (Esc detaches, server keeps running) | start **with** console attached |

### Rules

- **Uppercase only.** Keys are Shift+letter. Lowercase `r` (Refresh) and `s`
  (Start-all) keep their current dashboard meanings — no collisions.
- **Server rows only.** If the highlight is on a non-server entry (New instance,
  Build & tuning, Switch consumer, Refresh, Quit, etc.), the quick keys do nothing.
- **Stay on the list.** `R`/`S`/`X` run in the background and return to the
  dashboard, which already live-refreshes ~1s so the state badge updates on its own.
  `O` is the only quick key that takes over the screen (that is its purpose).
- **No confirmation.** A mis-key is recoverable by simply restarting.
- **Footer hint** on the dashboard becomes:
  `↑↓ move · enter open · R restart · S stop · X kill · O console · esc back`

## Implementation

Three code areas, plus docs and tests.

### 1. `lib/utils/prompt/menu.dart` — generic action-key hook

Add an optional named parameter to `menuSelect`:

```dart
T? Function(String rawChar, MenuEntry<T> highlighted)? onActionKey,
```

- In the `case TermEventKind.char:` branch, **before** the existing
  `event.char.toLowerCase()` digit/shortcut matching, call `onActionKey` with the
  **raw** (case-preserving) `event.char` and the highlighted entry
  (`entries[selected]`). If it returns a non-null value, finish and return it.
- Refactor the existing `finish(int index)` into a `finishWith(T value, String label)`
  helper so the action path can return a value that is not the highlighted entry's
  own `value`. `finish(index)` delegates to `finishWith(entries[index].value, entries[index].label)`.
- Case preservation is essential: uppercase must be checked before the lowercase
  fold so `S` is not swallowed by the lowercase `s` = Start-all shortcut.

This is an optional parameter, so existing `menuSelect` callers are unaffected
(zero blast radius).

### 2. `lib/services/interactive_wizard.dart` — dashboard wiring

- Extend `_Act` with `instanceRestart`, `instanceStop`, `instanceKill`,
  `instanceConsole`. `_DashChoice` is unchanged — it already carries `instance`.
- Extract a **pure** mapping helper, e.g.
  `_DashChoice? dashboardQuickAction(String rawChar, _DashChoice? highlighted)`:
  returns the matching quick-action `_DashChoice` only when `rawChar` is one of
  `R/S/X/O` **and** `highlighted?.kind == _Act.instance` with a non-null instance;
  otherwise `null`. (Pure and unit-testable.)
- In `_dashboardMenu`, pass `onActionKey: (raw, entry) => dashboardQuickAction(raw, entry.value)`
  and the new `hint`.
- Handle the four new acts in `_dispatch`. Each reloads the current row to decide
  running-vs-stopped, shows `Ui.doing(...)`, and `_shellRun`s the right command:
  - `instanceRestart`: running → `runtime restart <name> --no-console`;
    stopped → `runtime start <name> --no-console`.
  - `instanceStop`: running → `runtime stop <name> --graceful`; stopped → note.
  - `instanceKill`: running → `runtime stop <name>`; stopped → note.
  - `instanceConsole`: running → `runtime console <name>`;
    stopped → `runtime start <name>` (attaches console).

### 3. `lib/services/native_command_service.dart` — graceful stop

- Add a `--graceful` flag to the `runtime stop` subcommand. Parse it out of the
  args in `_dispatchRuntime`; the remaining token is the instance.
- New `_runtimeGracefulStop(profile, instance, io)`:
  1. If the tmux session exists, `tmux send-keys -t <session> stop Enter`.
  2. Poll for session death (server exits after saving) up to a timeout (~60s).
  3. On timeout, fall back to the existing hard `_runtimeStop` path.
  4. Clean up pid files; report `[OK] Runtime stopped (graceful): <instance>`.
- Update the `_dispatchRuntime` usage/error string to mention `--graceful`.

### 4. Docs — `README.md` + `lib/services/native_command_help.dart`

Per the project's README-sync rule:
- Document `runtime stop [instance] --graceful` in the runtime command table and
  the runtime help text.
- Add a short note describing the dashboard quick keys (R/S/X/O on the highlighted
  server).

### 5. Tests

- Unit-test the pure `dashboardQuickAction` helper: `R/S/X/O` on a server row map to
  the right acts; a non-server highlighted entry returns `null`; lowercase and other
  chars return `null`.
- Add a `term_events` test asserting uppercase letters pass through case-preserved
  (`TermEvent.char == 'R'`, not `'r'`).
- Validation path: `dart analyze` -> `dart test` -> `./start.sh` smoke test
  (including `./start.sh runtime stop <instance> --graceful` against a
  stopped/nonexistent instance to confirm no crash).

## Out of scope

- Confirmation prompts for destructive keys (explicitly declined).
- Quick keys inside the per-server submenu or other lists (the submenu already has
  its own shortcuts).
- Reworking the existing lowercase dashboard shortcuts.
