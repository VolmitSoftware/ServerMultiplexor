# Multiplexor

A Dart-native Minecraft server workspace manager. One workspace holds many server instances across four isolated **consumer profiles** (plugin, forge, fabric, neoforge), each with its own build cache, dropin folder, and instance store.

Everything is driven through `./start.sh` — either the interactive wizard (no args) or a direct CLI command. There is no separate build step: `start.sh` compiles `MultiplexorApp/` to the `multiplexor` binary whenever a `.dart` source, `pubspec.yaml`, or `pubspec.lock` is newer than the binary, then execs it. Unchanged sources skip straight to the binary. A failed compile leaves the previous binary in place and exits non-zero rather than running stale-but-working code silently. Set `MULTIPLEXOR_REBUILD=1` to force a recompile; everything `start.sh` itself prints goes to stderr, so stdout stays parseable.

On Windows, use `.\start.ps1` from PowerShell with the same arguments. Both launchers build `multiplexor.exe` on Windows, resolve Dart dependencies before compiling, and use Flutter's cached Dart SDK directly when it is installed. The build tool invokes that same SDK for compilation. PowerShell does not require WSL, Git Bash, or tmux. The launcher preserves quoted command arguments on Windows PowerShell 5.1 and PowerShell 7.

Every successful branch push assigns the build a monotonically increasing semantic patch version, embeds that version in the CLI, uploads versioned Apple Silicon macOS, Intel macOS, and Windows archives as GitHub Actions artifacts retained for 30 days, and publishes the same archives in a GitHub Release tagged at the exact pushed commit. The newest default-branch push becomes the latest release; other branches and default-branch builds superseded while CI was running publish as prereleases. The checked-in version remains the release baseline, so CI never adds surprise commits to a branch. Explicit tag pushes matching `v*` must match that baseline and publish at that existing tag.

Compiled releases update themselves from the latest stable [GitHub Release](https://github.com/VolmitSoftware/ServerMultiplexor/releases/latest). On an interactive dashboard launch (no arguments, `wizard`, or `runtime watch`), Multiplexor checks at most once every six hours, compares the embedded semantic version, and downloads the matching macOS Apple Silicon, macOS Intel, or Windows x64 archive. It never downgrades or selects a prerelease. Release publication includes `SHA256SUMS`; downloads must pass the checksum, archive, and executable-version checks before installation.

An automatic update replaces the executable and reopens the dashboard with the same arguments and working directory. Windows uses a temporary helper to finish after the running executable exits. Preparation failures keep the existing executable; failed replacement restores it. Network failures leave the dashboard usable and retry on a later launch after fifteen minutes. Server instances, worlds, credentials, and workspace files are not part of the executable update.

`multiplexor update` installs an update immediately; `multiplexor update check` only checks. Use `multiplexor update auto off` to disable automatic updates, `multiplexor update auto on` to enable them, or `multiplexor update status` to inspect the current build and settings. Preferences and check times are stored per executable under `~/.multiplexor/self-update` (`%USERPROFILE%\.multiplexor\self-update` on Windows). `MULTIPLEXOR_NO_UPDATE=1` skips the automatic check for one launch. Help, version, noninteractive commands, and background server/watch processes do not auto-update.

Only release builds made with `tool/build_exe.dart --version <semver>` enable self-installation. Source runs and ordinary `./start.sh` development builds continue to compile local source. Existing downloads need one manual replacement with an updater-enabled release before they can update themselves. A writable executable directory is required; the updater does not request elevation.

## Requirements

- `dart` 3.10+ (`./start.sh` compiles `MultiplexorApp/` on demand)
- `java` 17+ (or whatever your target server requires)
- `git`; `tmux` is required for interactive runtime consoles on macOS/Linux
- Node.js 22+ and npm (required for Mineflayer gameplay tests)
- macOS Keychain for persistent Pterodactyl credentials (origin-bound
  environment credentials are available for CI/non-macOS sessions)
- `rclone` and OpenSSH for Multiplexor Drive; macOS mounts each remote server
  into the local `~/Multiplexor Drive` folder through rclone's loopback NFS

## Quick Start

```bash
./start.sh                                          # interactive wizard
./start.sh consumer use plugin                      # pick a consumer profile
./start.sh server create demo --type purpur --auto-build
./start.sh runtime start demo                       # starts and attaches console
./start.sh runtime watch                            # live monitoring dashboard
./start.sh remote verify                            # verify the saved Pterodactyl panel
./start.sh remote list                              # remote fleet + every advertised/bind endpoint
```

## Live monitor

A failed Local capture preserves the last successful server list and readings and displays **METRICS STALE** while retrying. A first-capture failure displays **METRICS UNAVAILABLE**. A successful empty capture clears the list. `runtime watch --once` exits nonzero on capture failure instead of printing an empty fleet as if the read succeeded.

`./start.sh runtime watch` opens the full-screen monitor; `./start.sh` with no args lands on the same screen. `Tab` switches between the Local workspace and the saved Pterodactyl Remote fleet. Local sweeps `runtime metrics` every two seconds. On macOS it reads real per-Java-process packet and byte counters from `nettop`; platforms without trustworthy zero-dependency per-process counters leave Local network telemetry unavailable. Remote uses Pterodactyl's resource API at a rate-aware interval of at least 20 seconds and automatically slows down for large panels. Pterodactyl exposes byte counters rather than packet counters, so Remote correctly reports RX/TX bytes per second instead of estimating packets. The first sample after opening the monitor reads `n/a`; later samples derive rates from the measured counter delta and interval, rejecting counter resets and server restarts. Both views keep per-server history seeded from their own trend stores so charts survive a restart. History is kept at full resolution for 24 hours, rolled up into five-minute means for a week, and dropped after that.

The landing view is a `MULTIPLEXOR` header, a KPI strip (`FLEET` servers-up and players, a fleet `TPS` sparkline, a `HOST` memory and CPU card), a full-width `SERVERS` table (state, players, TPS, a trend sparkline, memory, CPU and uptime per row — narrow terminals drop the rightmost readings whole), and a compact card for the selected server. The card is sized by the selection's own state: a running server expands into small side-by-side charts (TPS, CPU, memory as width allows), a facts line, and a dedicated bottom RX/TX network monitor with comparable sparklines. It labels true macOS packet telemetry as `PPS` and Pterodactyl throughput as `B/s`. A stopped server collapses to a single line and leaves the rows to the table. Under them sit two action bars — the selected server's, then the workspace's — over the key hint footer.

Everything on those bars is a button. Pressing lights a chip in the accent tone; a click activates on release, so a press that drifts onto another chip before it lifts does nothing. Chips that cannot apply — `RESTART` on a stopped server, `DELETE` on a locked one — are drawn faint and are not clickable at all. `START`, on the bar or on the card, is a background start: the dashboard stays up and watches the server come alive, and `CONSOLE` is one click away once it is running. The range badge on the selected panel (`running · 15m`) is a button too, and cycles the chart window.

Clicking a row in `SERVERS` selects it; clicking the selected row again opens its **card**, as do `enter` and `[ MORE ]`. `[ MORE ]` on the workspace bar, or `w`, opens the workspace card instead: build & tuning, pull builds, create many, start all, stop all, wipe. A card is modal: buttons print their single-letter hotkeys when space permits, all four arrow keys move keyboard focus through the button grid, and `enter` runs the focused action. Clicking a button still runs it; clicking elsewhere on the card does nothing, while clicking outside it or pressing `esc` dismisses it. Disabled actions cannot receive focus or fire by hotkey, and nothing behind a card is clickable or keyboard-active while it is up.

Every server row has a checkbox on its left in both Local and Remote views. Click the checkbox or press **Space** on the focused row to select it for a batch. The **ALL** checkbox or `a` selects every server in the current fleet, including rows scrolled offscreen; repeating it clears the selection. `x` or **CLEAR** clears the checked boxes. While any servers are checked, the action bar shows **N SELECTED** with **START**, **STOP**, **RESTART**, **DELETE**, and **CLEAR**. Press `b` for the same selected-actions menu. Opening a server card or detail view does not change the checked set, and single-server card actions still affect only that card's server.

Checks stay attached to server identities across refreshes and scrolling. Disappeared servers are removed from the selection; newly discovered servers are never checked automatically. Switching provider or consumer starts a fresh selection. Start applies to stopped servers, stop to active servers, restart to running servers, and Local deletion skips locked instances. Commands recheck each exact target, report skips/failures, and never widen an empty selection to the whole fleet. Delete lists the targets and requires confirmation; Remote deletion retains its typed confirmation and permission checks.

Mouse support needs a terminal that reports SGR mouse events, which every current one does (Terminal.app, iTerm2, kitty, WezTerm, tmux, the VS Code terminal). The monitor uses click-only reporting (`?1000` with `?1006` SGR coordinates), so passive pointer movement does not repaint the screen. Reporting is turned off again on exit, so the terminal is left as it was found.

| Key | What it does |
|-----|--------------|
| `tab` | Switch between Local and Pterodactyl Remote fleets. |
| `↑` `↓`, wheel | Move the server selection. Inside a modal card, arrows and the wheel move button focus instead. |
| `←` `→` | Move horizontally between buttons in an open modal card. |
| `enter`, click | Open the selected server's card; inside a card, run the focused button. A second click on the selected row, or `[ MORE ]`, also opens the card. |
| `Space`, checkbox click | Toggle the focused/clicked server's batch checkbox on the main dashboard. |
| `a`, **ALL** | Select every server in the current fleet, including offscreen rows; clear if all are already checked. |
| `x`, **CLEAR** | Clear the checked selection. |
| button letter | Run that button directly while its modal card is open; the hotkey is printed at the start of each button when space permits. |
| `d` | Detail screen for the selected server. |
| `S` `X` `O` | Stop, kill (force), open console on the selected server. Restart is available on its action bar and server card. |
| `Shift+R` | Clear and repaint the entire screen, preserving selection, chart range, and any open card. |
| `g`, `G` | Open all running Local consoles: a native terminal grid on Windows, a tmux grid on macOS/Linux. |
| `n` | Create a new instance. Mohist creation offers a persistent Mods/Plugins source checklist; other isolated servers offer per-artifact one-time copies. |
| `b` | With checked rows, open actions for those exact servers. Otherwise open Remote bulk actions or Local Build & tuning. |
| `w` | Open the workspace card, also available through **WORKSPACES** beside the top Local/Remote control or `[ MORE ]` on the workspace bar. Landing view only. |
| `c` | Switch consumer profile (rebuilds the dashboard against the new one). |
| `r` | Cycle the chart window: `15m` → `1h` → `6h` → `24h` → `7d`. |
| `q`, `ctrl-c` | Quit. |

The detail screen (`d`) gives one server the whole frame: `TPS`, `CPU %`, `MEM MiB`, `PLAYERS`, and dual-series RX/TX `NETWORK` charts over the same window, plus a live `LOG` tail of its runtime log. On wide terminals the network chart spans the bottom of the chart grid immediately above the log. `esc` returns to the landing view; `esc` on the landing view quits. Below 80×24 the frame is replaced by a resize prompt rather than a squeezed layout.

`./start.sh runtime watch --once` prints a single frame to stdout and exits — colorless, zero escape bytes, no TTY required — so it is safe to pipe, log, or diff from a script.

## Interactive Wizard

The bottom-right **CHECK FOR UPDATE** button (`u`) checks for a newer Multiplexor release while the Local or Remote dashboard remains usable. It shows checking, up-to-date, available-version, or retry status. Select **UPDATE** to confirm installation and restart in the same workspace and consumer through the verified executable updater. A failed check exposes its error before retrying; development builds show **DEVELOPMENT BUILD** and explain how to rebuild local source. The shortcut is inactive while a card or detail view is open.

Local instance cards include **BACKUPS** for creating, verifying, and restoring snapshots, and **RUNTIME** for per-instance Java, heap, presets, and compatibility checks. **New** opens the single-server creator directly, with platform and Minecraft version selection. **WORKSPACES → CREATE MANY** opens bulk creation with an optional shared Minecraft version. **WORKSPACES** in the top bar opens the workspace card without changing the selected Local/Remote view. The Local card includes **DIAGNOSTICS** and, for the plugin consumer, **NETWORKS**.

An isolated Local instance's **RUNTIME → Run bot swarm** action selects idle, wander, redstone, workshop, mixed, stress, or a custom JSON recipe. Choose the bot count, duration, seed, activity radius, placement, origin, and scripted chat. Stress also offers a JSON workload, coordinate bounds, activity goals, and duration or goal completion. The wizard shows persistent arena changes before starting. A stopped target is prepared for offline loopback access, started for the run, and stopped afterward; an already running target stays running.

**RUNTIME → Persistent player sessions** offers the five bundled profiles or a custom JSON path and lists previous runs. Before starting, review identities, concurrency, session lengths, goals, world bounds, and required fixture setup. Select a run to view player activity, stop and save, resume, or read its report. Offline Velocity networks expose the same action in their network menu. Session runs continue when the wizard closes. The wizard starts stopped targets and stops only those targets when the run ends.

Velocity networks appear as trees in the Local dashboard. A `Velocity / <network>` parent shows the proxy port, followed by `├─` and `└─` backend rows with their ports. Each row keeps its own state and metrics. Select a parent or child to open its instance actions. The selected panel identifies the network and route. An asterisk marks an active network instance. ASCII terminals use `|-` and `` `- `` branches. Standalone servers keep their ordinary rows. Keyboard focus and checked instances stay attached to their instance identities when the tree changes.

The Local plugin workspace card also includes **NETWORKS** (`v` while the card is open). Create a Velocity network from a checklist of compatible stopped servers, choose its entry server, port, and local or LAN access, then download Velocity or select a local jar. A network menu shows its join address, state, and connected player count from the proxy, with start, stop, restart, proxy console, status, and configuration checks. An unavailable player count is shown separately from zero players. Backend removal and network deletion stop the network automatically. Any backend can be removed, including the entry server or a fallback; routing updates automatically. Stop the whole network to add backends, edit routing, change the proxy bind/port, or repair configuration. Velocity plugin sync only requires the proxy to be stopped. Deleting the network restores backend settings and retains server and proxy files.

**UPDATE** prepares a candidate, backs up the instance, starts an isolated loopback staging copy, and promotes the exact tested artifact after a Minecraft status response. Jar and Forge/NeoForge installer updates use this flow. Custom servers accept a replacement jar and an explicit Minecraft version. Promotion checks the original server too, restores the prior running/stopped state, and rolls back on startup failure. Status checks do not prove plugin loading or gameplay behavior.

The port picker includes custom entry across 1–65535, an available-port choice, and labels for ports configured on other instances across consumers.

`Shift+R` also repaints wizard menus without activating an action or changing the selection.

The Local and Remote dashboards automatically repaint the full screen every 30 seconds, including open cards and detail views. This restores the display and mouse tracking while preserving selection and chart range. Normal updates redraw only changed rows between these repaints.

`./start.sh` with no args lands on the live monitor above. Everything the monitor does not do itself it hands back to the wizard, on a suspended terminal, returning to the dashboard when the flow finishes or when you press Esc. Local keeps the existing state-aware server and workspace actions. Remote exposes permission-aware power, console, history, account, lifecycle, settings, creation, transfer, and Multiplexor Drive workflows. **Pull to Local** copies a Remote server into a new, stopped Local instance and links the pair. **Push to Remote** shows a file diff before it can update the linked server, another existing server, or a newly created stopped server. Remote creation can clone an existing configuration or build directly from a Panel egg, so a completely empty panel can create its first server. Its workspace card includes Create many and Bulk actions; `b` opens the bulk selector directly, with all/selected/running/stopped presets, per-server toggles, bounded execution, progress, and an outcome for every target. Suspended, installing, maintenance, unavailable, and otherwise non-runnable servers retain their rows but have mutating actions disabled. Mirror push, kill, reinstall, and delete default to no and require typed confirmation.

Press `Esc` from any wizard menu, text field, masked key/PIN field, confirmation, checklist, or result pause to return to the dashboard. Required fields and validation errors never trap navigation; cancelling a setup form leaves unsubmitted settings unchanged.

Create many runs up to four independent server creations at once, including Local build downloads and installer work. Local batches reserve distinct ports before dispatch. Remote batches reserve distinct allocations and default to four concurrent requests; the CLI accepts `--concurrency 1-8`.

The Remote console has a persistent server/resource header, severity colors, safe Minecraft `§` formatting, prefix and routine-noise trimming, and batched history rendering. `Tab` completes common commands, commands already used in the session, selectors, and player names learned from recent/live join, leave, login, and `list` output; press it again to cycle ambiguous matches. `Esc`, `Ctrl-C`, or `:exit` immediately restores the dashboard without stopping the server.

The Remote server menu's Open folder action repairs or starts Multiplexor Drive when needed, then opens that server's exact local folder in Finder.

The Remote connection card is the guided account surface. It can add, select, rename, repair, rotate, and remove multiple panel accounts. Multiplexor asks for the panel HTTPS origin once, accepts the key through masked terminal input, saves it in macOS Keychain, and verifies it before selecting the account. It never accepts an API key on the command line or writes one into profile state. Standard `ptlc_` and `ptla_` prefixes select the Client or Application role automatically. A root-admin Client key provides the one-key experience on current Pterodactyl releases; a separate Application key is only needed when the Client key cannot reach administrative routes. First-server/egg creation needs Servers read/write plus Users, Nodes, Allocations, Nests, and Eggs read access.

Remote cards show every configured advertised allocation and every bind allocation. DNS A/AAAA results are shown beside configured aliases when resolution succeeds. These are intentionally separate: Pterodactyl does not know an upstream NAT port mapping, so Multiplexor never guesses that a private bind address, node FQDN, and public game endpoint are interchangeable.

The workspace card (`[ MORE ]` on the workspace bar) holds the actions that are not per-instance: Build & tuning, Pull latest builds, Create many, Start all stopped, Stop all running, and Wipe everything. An isolated server's instance card includes **Copy drop-ins**, which opens the same per-artifact checklist for one-time local plugin or mod copies without subscribing the server to future syncs. Destructive prompts (wipe, delete, factory reset) default to no and show that default in red. In Build & tuning, JVM controls include heap, flag preset, console line wrap, and console log format.

When upstream version metadata is unavailable, the picker offers known cached versions, manual entry, and Retry. Cached choices remain usable without a refresh, and no fallback is labeled latest.

Platform and version pickers show when each build was last fetched (`updated 2h ago`, `cached 3d ago`), and a `builds` status footer on the platform picker and Build & tuning menus shows per-platform freshness at a glance. Ordinary creates and updates reuse a cached build when it is under 24 hours old and fetch a fresh one otherwise (or when nothing is cached). Spigot is the exception to age-based refresh: an existing BuildTools jar is reused no matter its age, since rebuilds take many minutes. Force one with `build spigot --force`.

Pull latest builds refreshes the newest build of every platform the active consumer owns, spigot included. Spigot only runs BuildTools when its upstream Jenkins build is newer than the cached jar, so the bulk pull normally stays fast; any platform that fails is named in the summary line.

Local server setup includes an **Addons** checklist before the first launch. To change an existing server, stop it and open its card → **Addons**. Use Space, Enter, or a click to toggle entries, then Done to download and apply. The checked selection is saved per instance. Minecraft versions are detected from server metadata or recognized jar filenames, including existing Leaf instances. If a custom jar has no discoverable version, the wizard asks for it inline before showing the checklist. ViaBackwards includes ViaVersion automatically. Cancelling or a failed install leaves the new server stopped.

For batches, use the main dashboard's left-hand checkboxes and selected action bar. Batch starts stay headless, so they do not attach a console for each server. Local operations use the same `instance bulk` command available to scripts; Remote operations reuse the fleet engine with only the checked IDs. Both run up to four servers concurrently by default; headless bulk commands accept `--concurrency 1-8`. Restart still stops each server before starting that server again. Workspace Start all and Stop all use the same parallel engines, with consoles opened after the start batch finishes.

Independent builds, repository syncs, addon preparation, Remote fleet polling, Drive checks, and transfer-file hashes also use rolling pools of up to four workers. Completed work immediately frees a slot. Port allocation and shared watcher startup are coordinated, and addon/transfer commit and rollback steps keep their required order. Every started operation finishes before failure cleanup runs.

## Concepts

- **Consumer profile** — one of `plugin`, `forge`, `fabric`, `neoforge`. Each profile has its own instances, dropin sources, and build cache. The active profile is set with `consumer use`. Mohist is the explicit hybrid exception: it is Forge-owned and can subscribe to plugin-consumer dropins.
- **Instance** — one server install inside a consumer. Lives at `consumers/<profile>/instances/<name>` (or under `~/.multiplexor/instance-store/...` if the workspace path contains `[` or `]`). Metadata is in `.server-source` (type, launch mode, jar path, isolation, Mohist dropin sources, and lock state + hashed PIN).
- **Active instance** — the default target when an instance name is omitted. Set with `instance activate`.
- **Network** — one local Velocity proxy and a group of plugin-consumer backends. Players join the proxy address and switch routing names with `/server`. Each backend belongs to at most one network; unrelated standalone servers and multiple networks can coexist.
- **Dropins** — plugin or mod jars under `consumers/<profile>/dropins/plugins` or `consumers/<profile>/dropins/mods`. On `runtime start` and via the watcher, these jars are copied into subscribed instances. Mohist records whether it tracks Forge mods, plugin-consumer plugins, or both, placing them in separate `mods/` and `plugins/` folders. Automatic sync tracks the last synchronized SHA-256 per instance: it updates untouched jars but preserves and warns about unknown or locally modified jars. An explicit `plugins sync` or `mods sync` remains authoritative and replaces them.
- **Isolated instance** — opts out of all shared state: no dropin sync, no Iris pack symlink, no shared `ops.json` merge. Created with `server create --isolated` or toggled later with `instance isolated <name> true`.
- **Shared plugin data** — `consumers/plugin-consumers/shared-plugin-data/` holds Iris packs and a merged `ops.json` for non-isolated plugin instances.
- **Build cache** — `consumers/<profile>/builds/<type>/` holds versioned server jars. `server create --type ...` resolves jars from here; `--auto-build` refreshes from upstream first.
- **Content lockfile** — `consumers/<profile>/state/content-lock.yaml` tracks jars installed by `content install` so they can be updated, removed, and re-synced through the existing dropin pipeline.
- **Backup** — `consumers/<profile>/backups/<instance>/<backup-id>/` stores a restorable snapshot with checksums and a manifest. Backups are used manually and by `instance safe-update`.
- **Gameplay test** — a Mineflayer scenario run against an actual instance. Built-ins cover connection, command responses, and status effects; custom `.mjs` scenarios can assert any protocol-visible player behavior. Reports stay under ignored per-consumer state.
- **Remote profile** — non-secret Pterodactyl panel metadata in `.multiplexor/pterodactyl-profiles.yaml`. Client/Application bearer keys live in macOS Keychain under an exact profile+HTTPS-origin identity, never in the YAML file.
- **Remote link** — `.multiplexor-remote.json` inside a pulled, initially paired, or explicitly relinked Local instance records the exact remote account, immutable server identity, display name, Local consumer, and transfer timestamps. `remote push <local>` uses this identity instead of guessing from names.
- **Multiplexor Drive** — the local `~/Multiplexor Drive` folder containing one live folder for every accessible Pterodactyl server, grouped by remote account. Selecting Open folder for a remote server opens its folder here in Finder.

## CLI Reference

Local commands share argument validation with wizard operations. Unknown options, missing option values, repeated single-value options, and extra positional arguments are rejected before execution. Boolean options accept `--flag`, `--flag=true`, or `--flag=false`.

Every command is `./start.sh <namespace> <action> [args]`. Global flags: `--consumer <profile>` for a one-shot profile override, `--root <path>` for a different workspace, `--verbose` for arg-normalization debug output. Use `./start.sh help <command>` or `<command> --help` for focused command help.

### update — compiled Multiplexor releases

These commands also work directly on the downloaded executable, without a Dart SDK or workspace. `update` runs before workspace initialization.

| Command | What it does |
|---------|--------------|
| `update [install]` | Download, verify, and install a newer stable compiled release. Requires a release build. |
| `update check` | Check for a newer stable version without downloading the executable or changing settings. |
| `update status` | Show the embedded version, executable path, automatic-update setting, and last check time. |
| `update auto [on\|off]` | Read or change automatic updates for this installed executable. |

### remote — Pterodactyl fleet

| Command | What it does |
|---------|--------------|
| `remote connect --url <https://panel> [--id <id>] [--name <name>] [--application] [--replace]` | Add or repair an account through masked API-key input, verify it, and make it active. `remote account add` accepts the same flags. |
| `remote account list` | List accounts, the active account, panel origin, and Client/Application credential status. `accounts` and `profiles` are aliases. |
| `remote account use <id>` | Persist the account used when `--profile` is omitted. |
| `remote account rename <id> <name>` | Rename the local account label without changing its panel origin or credential identity. |
| `remote account key [id] [--role <client\|application>]` | Replace a key through masked input, infer standard key prefixes, verify it, and roll back on failure. |
| `remote account remove <id> --confirm <id>` | Remove an account and its stored credentials with an exact-ID confirmation. |
| `remote verify [--profile <id>]` | Verify credentials, whole-panel visibility, node access, creation capability, and configuration warnings. |
| `remote list [--profile <id>]` | List every remote server with all advertised/DNS-resolved and bind IP:port allocations. |
| `remote nodes [--profile <id>]` | Show each node's FQDN, configured/allocated memory and disk, daemon port, and SFTP port. |
| `remote catalog [--profile <id>]` | List the Panel owners, nodes/free allocations, nests/eggs, allowed Docker image label/value pairs, egg environment keys/default requirements, and existing templates available for Remote creation. |
| `remote stats <server> [--profile <id>]` | Show current state, CPU, memory, disk, network, and uptime for one server. |
| `remote stats --all [--profile <id>]` | Show aggregate and per-server resource statistics for the panel fleet. |
| `remote history <server> [--since <15m\|6h\|7d>] [--limit <n>] [--json] [--profile <id>]` | Read persisted monitor samples, including derived RX/TX rates, without polling the panel. History keeps raw samples for 24 hours and five-minute rollups for seven days. |
| `remote drive install [--profile <id>\|--all-profiles] [--username <name>] [--mount-root <path>] [--known-hosts <path>] [--no-key] [--no-open]` | Set up the local Multiplexor Drive, defaulting to every saved account and `~/Multiplexor Drive`; verify SSH host fingerprints, mount every accessible server, and open the drive in Finder. By default it generates a per-profile Ed25519 key and registers only its public half through the Client API. |
| `remote drive add [--profile <id>] [--username <name>] [--no-key]` | Add or refresh one remote account in Multiplexor Drive. Stop the drive first when changing its accounts. |
| `remote drive remove [profile] --confirm <profile>` | Remove one account and its saved SFTP password from Multiplexor Drive with exact confirmation. |
| `remote drive password [profile]` | Enroll the Panel password through secure interactive input as an SSH-key fallback. |
| `remote drive trust [server] [--profile <id>]` | Scan Wings SFTP host keys, display every SHA256 fingerprint, and persist them only after an explicit default-no confirmation. Supplying a server scans only that selected target; omitting it retains the all-configured-Drive workflow. |
| `remote drive doctor` | Check rclone, the local mount provider, SFTP authentication, SSH host trust, and safe Drive-folder ownership. |
| `remote drive start\|status\|stop` | Mount all configured servers locally, inspect their current paths and health, or stop the mounts safely. No SMB server or administrator authorization is involved. |
| `remote drive open [server] [--profile <id>]` | Open `~/Multiplexor Drive` in Finder, or open the exact local folder for a server. The drive starts or repairs itself first when necessary. |
| `remote files <...>` / `remote smb <...>` | Compatibility aliases for `remote drive`; new workflows should use the Drive name. |
| `remote permissions <server> [--profile <id>]` | Show ownership and the exact Client permissions used to gate server actions. |
| `remote activity <server> [--page <n>] [--per-page <1-100>] [--profile <id>]` | Read the panel's historical server activity/audit feed. |
| `remote settings <server> [--profile <id>]` | Show limits, feature limits, startup command, and accessible startup variables. |
| `remote start\|stop\|restart\|kill <server> [--profile <id>]` | Send a Pterodactyl power signal. Stop allows five seconds for shutdown, then sends kill if the server remains online. |
| `remote bulk <start\|stop\|restart\|kill\|reinstall\|delete> [servers...] [--all] [--state running\|offline] [--concurrency <1-8>] [--confirm <token>] [--force] [--profile <id>]` | Safely operate on an explicit remote fleet. Every selector is resolved before mutation; state filters use live resource state (`running` includes transitional non-offline states), work is bounded, and every server receives an outcome. Reinstall/delete print the exact token required by `--confirm`. |
| `remote console <server> [--profile <id>]` | Attach to a severity-colored, prefix/noise-trimmed live console with server resource chrome, safe Minecraft `§` formatting, and `Tab` completion for common/session commands, selectors, and observed online player names. Repeated `Tab` cycles ambiguous matches; Esc, Ctrl-C, or `:exit` restores the caller without stopping the server. |
| `remote command <server> <command> [--profile <id>]` | Send one console command. |
| `remote pull <server> --as <local> [--profile <id>] [--consumer <profile>]` | Copy the transferable files of a stopped Remote server into a new, stopped Local instance and record its exact remote account/server link. Pull never changes the Remote, refuses a running Remote, and refuses to overwrite an existing Local instance. |
| `remote push <local> [--to <server>] [--mirror] [--link] [--start\|--no-restart] [--confirm <token>] [--profile <id>] [--consumer <profile>]` | Diff a stopped Local instance against its linked Remote, or the existing server selected by `--to`, then push changed/new files. Without `--confirm`, prints the exact token and exits without mutation. The default preserves remote-only files; `--mirror` deletes them and requires the stronger destructive token. A previously running target is stopped for the transfer and restarted after success unless `--no-restart`; `--start` starts a previously stopped target. `--link` records the selected target as the Local instance's new link. After committing files, an unverified explicit `--link` or `--start` outcome returns nonzero so the same idempotent workflow can repair it. |
| `remote push <local> --new <name> (--template <server>\|--egg <id\|name>) [creation flags] [--link] [--start] [--confirm <token>] [--profile <id>] [--consumer <profile>]` | Resolve and show the exact source UUID/egg ID, owner, node, image, startup, environment variable names (values are redacted), resources, features, final power state, and link action before creating anything. The composite confirmation token still binds every exact environment value, the complete creation plan, and the current Local snapshot. The durable intent identity does not change when Local files later change, so a freshly previewed and confirmed retry resumes the same created server instead of allocating another one. The server is created stopped, receives and validates Local files before its first start, then starts only with `--start`. An unlinked Local records the new pairing automatically; an already-linked Local preserves its existing target unless `--link` explicitly replaces it. A failed transfer leaves the new server stopped and prints the exact existing-target retry command. |
| `remote create <name> (--template <server>\|--egg <id\|name>) [--owner <id\|username\|email>] [--node <id\|name>] [--image <label\|value>] [--env <KEY=VALUE,...>] [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--databases <count>] [--allocations <count>] [--backups <count>] [--start] [--profile <id>]` | Create from an existing Application-visible configuration or directly from a Panel egg. Egg creation works on an empty panel, defaults to the connected owner and sole viable node, sends every egg-variable default, and requires explicit values for required blank variables. `--node`, `--image`, `--env`, `--swap`, `--io`, and feature-limit flags apply only to egg creation. |
| `remote create-many (--template <server>\|--egg <id\|name>) (--names <a,b,c>\|--prefix <name> --count <1-100>) [--owner <id\|username\|email>] [--node <id\|name>] [--image <label\|value>] [--env <KEY=VALUE,...>] [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--databases <count>] [--allocations <count>] [--backups <count>] [--start] [--concurrency <1-8>] [--profile <id>]` | Create several servers from one template or egg. Multiplexor validates the full plan and reserves distinct allocations before the first create request, runs up to four creates in parallel by default, and reports every result. The same egg-only flag restriction as `remote create` applies. |
| `remote rename <server> <name> [--description <text>] [--profile <id>]` | Rename or describe a server using Client permission first and Application fallback when enrolled. |
| `remote reinstall <server> --confirm <server> [--profile <id>]` | Request a reinstall through the least-privileged permitted route. The exact server value is required as confirmation. |
| `remote delete <server> --confirm <server> [--force] [--profile <id>]` | Permanently delete a server through the Application route with exact confirmation. |
| `remote variable <server> --key <variable> --value <value> [--profile <id>]` | Change an editable startup variable. |
| `remote image <server> --image <docker-image> [--profile <id>]` | Select an allowed Docker image when `startup.docker-image` is granted. |
| `remote limits <server> [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--threads <set>\|--clear-threads] [--databases <count>] [--allocations <count>] [--backups <count>] [--allocation <id>] [--add-allocation <id,...>] [--remove-allocation <id,...>] [--oom-disabled\|--oom-enabled] [--profile <id>]` | Modify resource, feature, and allocation limits through the Application API while preserving unspecified values. |
| `remote startup <server> --command <command> [--profile <id>]` | Modify the administrative startup command while preserving the current egg, image, variables, and install-script policy. |

The active account is used when `--profile` is omitted; `--profile` remains available as a one-command override. `ptero` is an alias for `remote`.

Pull records a file baseline for the exact Local instance and Remote UUID. Subsequent Update pushes upload only changed and new files from the preview. Files changed or deleted only on Remote stay untouched; a file edited differently on both sides blocks the push and identifies the conflict. Local deletions also preserve Remote files in Update mode. Mirror still makes the transferable Remote tree match Local and requires its destructive confirmation. A target without a recorded baseline uses the current Local/Remote comparison shown in its preview. Baselines live under `.multiplexor/pterodactyl-transfer-baselines/` and advance after verified transfers, including across app restarts.

Transfers carry worlds, server jars, plugins/mods, and normal configuration while excluding runtime-only `logs/`, `crash-reports/`, `session.lock`, and Multiplexor's own metadata. They reuse Multiplexor Drive account credentials but connect directly to only the selected server over SFTP; they never start or require the cached browsing mount or unrelated profiles. An interactive terminal can add a missing account and approve that target's displayed host fingerprint, while headless use exits with exact `remote drive install --profile ... --no-open` and target-scoped `remote drive trust <server> --profile ...` recovery commands. Push confirmation tokens bind the exact Local snapshot and every planned add, overwrite, and delete operation; Create & Push additionally binds every resolved creation field, desired final state, and link decision. A changed input requires a fresh preview. Remote contents are re-read after the server stops, then every non-empty push snapshots the complete Remote tree under `.multiplexor/pterodactyl-transfers/backups/` before applying files, writes a recovery manifest, and rolls back automatically if the upload fails. Create & Push also writes a durable intent under `.multiplexor/pterodactyl-transfers/intents/` and assigns its unique ID as the Panel `external_id`. That stable identity binds the Local consumer and canonical instance path, profile, proposed server name, immutable creation configuration, and requested start/link postconditions, but not the changing file fingerprint. A newly confirmed current snapshot can therefore discover and resume the same committed server after an ambiguous create response, Local edits, or transfer failure. If only its requested durable link or final running state failed and Local is unchanged, the exact retry repairs those postconditions without uploading files again; changed Local files resume the normal diff and transfer against the same server. Ambiguous, duplicated, or mismatched identities stop without another Panel mutation. The CLI prints the relevant intent, backup, and recovery paths.

Multiplexor Drive never treats an API key as an SFTP password. It creates a dedicated local Ed25519 identity per remote profile, registers only the public key with the account, and requires explicit Wings host-key trust. API keys, private-key contents, and cleartext Panel passwords are never written to Drive settings or runtime state. The mounted files remain live remote server files: normal Finder edits, moves, and deletions affect the server immediately.

The drive remains mounted until `remote drive stop` or the computer reboots. After a reboot, `remote drive start` restores every configured mount; `remote drive open` also starts or repairs it on demand before opening Finder. If Finder leaves `.DS_Store` metadata in a detached mount folder or its VFS write cache, Multiplexor preserves it in a `.multiplexor-local-recovery` or `finder-metadata-recovery` folder before remounting. Any other local file, directory, or symlink remains untouched and blocks the mount with its exact path instead of being hidden.

For CI/non-macOS sessions, set both an origin-bound key and its companion origin, for example `MULTIPLEXOR_PTERODACTYL_DEV_CLIENT_API_KEY` plus `MULTIPLEXOR_PTERODACTYL_DEV_ORIGIN=https://panel.example.com`. Environment credentials are session-only and should not be used for long-running child-process workflows.

### consumer — pick which profile is active

| Command | What it does |
|---------|--------------|
| `consumer list` | List the four profiles. |
| `consumer show` | Print the active profile (alias: `current`). |
| `consumer use <profile>` | Set the active profile. |
| `consumer path` | Print the active profile's root path (alias: `root`). |

### instance — manage server instances

| Command | What it does |
|---------|--------------|
| `instance list` | List instances in the active profile; the active one is tagged `(active)`. |
| `instance bulk <start\|stop\|restart\|delete> <name>... [--concurrency <1-8>] [--confirm <token>]` | Operate on an explicit nonempty set in the active consumer, with four concurrent workers by default. Validates every target before any mutation, skips ineligible states/locked deletions, and reports each outcome. Start/restart are headless. Delete first prints the exact required confirmation token; repeat with `--confirm` to apply. Partial failures return nonzero. |
| `instance current` | Print the active instance name. |
| `instance create <name> [--isolated]` | Create a blank instance (no jar wired up). `--isolated` skips shared drop-ins, Iris packs, and plugin ops; Remote Pull uses this mode so copied servers cannot inherit unrelated Local shared state. |
| `instance clone <source> <target>` | Copy an instance verbatim, then re-wire shared links. |
| `instance activate <name>` | Make this instance the default target. |
| `instance path [name]` | Print the on-disk path. Active instance if omitted. |
| `instance open [name]` | Open the instance folder in the host file manager. |
| `instance update <name> [--mc <v>] [--jar <path>] [--type <t>] [--loader <v>] [--installer <v>] [--auto-build]` | Prepare and validate the replacement before shutdown, create a backup, and apply the jar or installer payload. Restart and check readiness when the instance was running; restore the previous state on failure. |
| `instance safe-update <name> [--mc <v>] [--jar <path>] [--auto-build] [--type <t>] [--loader <v>] [--installer <v>] [--promote] [--cleanup] [--keep-staging] [--label <label>] [--timeout <s>]` | Prepare one immutable candidate, back up, and validate it on isolated loopback staging. `--promote` applies that exact candidate and verifies the original; otherwise staging is kept stopped. Promotion removes staging unless `--keep-staging`; `--cleanup` removes staging after a successful validation-only run. |
| `instance isolated [name] [true\|false]` | Read the flag (no value) or toggle it. Turning it off re-links shared Iris packs and merges shared ops. |
| `instance lock <name> [--pin <digits>]` | Lock the instance so it cannot be deleted or factory-reset. Prompts for a 4–12 digit PIN (or pass `--pin`). The PIN is stored salted+hashed in `.server-source` and survives factory reset. Settings stay editable. |
| `instance unlock <name> [--pin <digits>]` | Verify the PIN and unlock, re-enabling delete and factory reset. |
| `instance locked [name]` | Print `true`/`false` for the lock state. |
| `instance port [instance] [port]` | Read or set `server-port` in `server.properties`. |
| `instance motd-style [name\|--all]` | Apply the styled MOTD template (alias: `motd-style`). |
| `instance reset <name>` | Wipe worlds/config/plugins/mods/logs back to baseline. Keeps the launch artifacts and the isolated flag, and re-applies the styled MOTD for the server type. Refused while the instance is locked. |
| `instance delete <name>` | Delete the instance entirely (stops running processes first), automatically removing network membership and updating routes. Deleting a proxy or the last backend also removes its network definition. Refused while the instance is locked. |
| `instance delete-all [--force]` | Delete every instance in the active profile and clean up its networks automatically. Asks for `DELETE` confirmation unless `--force`. Locked instances are skipped and left untouched. |
| `instance delete-all --everywhere [--force]` | Wipe every instance across plugin/forge/fabric/neoforge and clean up networks in one call. Asks for a double y/N confirmation unless `--force`. Locked instances are skipped. |

### server — first-time jar wiring

| Command | What it does |
|---------|--------------|
| `server create <name> --type <type> [--mc <v>] [--auto-build] [--isolated] [--mod-dropins] [--plugin-dropins] [--artifact <dropin.jar> ...]` | Create + wire `server.jar` from the build cache (or refresh upstream first if `--auto-build`). Mohist defaults to persistently tracking both sources; pass either dropin flag alone to track only that source, or `--isolated` for neither. Other isolated types can repeat `--artifact` for one-time local copies. |
| `server create <name> --jar <path> [--type label] [--isolated] [--mod-dropins] [--plugin-dropins] [--artifact <dropin.jar> ...]` | Create + wire an explicit jar. `--type mohist` accepts the same persistent source choices; isolated instances can receive one-time selected artifact copies. |
| `server create-many --types <a,b,c> [--prefix N] [--mc <v>] [--auto-build] [--isolated]` | Create up to four instances in parallel, with a distinct port reserved for each. Each instance is named after its type (or `<prefix>-<type>` if `--prefix` is set) and routed to the correct consumer (plugin types → plugin profile, modded types → their own). Skips collisions and resolution failures without aborting the batch. |

Single `server create` and `build <type>` commands must run under the consumer that owns the selected server type. Use `--consumer fabric`, `--consumer forge`, or `--consumer neoforge` for modded types; plugin-family types use `plugin`. `server create-many` remains the cross-consumer batch command.

`<type>` is one of: `paper`, `purpur`, `folia`, `canvas`, `leaf`, `spigot`, `forge`, `mohist`, `fabric`, `neoforge`. `leaf` is a high-performance Paper fork. Mohist is a Forge/Bukkit hybrid owned by the `forge` consumer and launches directly from its downloaded jar. For `forge` / `neoforge`, an installer jar triggers args-file launch mode automatically.

### network — Velocity proxy and connected servers

Networks currently support the Local `plugin` consumer with Paper, Purpur, Folia, Canvas, and Leaf backends on Minecraft 1.19 or newer. Spigot, custom servers, mod consumers, and Remote backends are not supported. Velocity uses modern player forwarding and a generated secret shared with its backends. The proxy authenticates players; backends use offline authentication and bind to loopback so players cannot bypass the proxy from another machine.

Creation requires stopped backend instances. It creates a proxy instance named `<name>-proxy`, downloads Velocity unless `--jar` is supplied, assigns distinct backend ports, and preserves the backend settings it changes. Networks default to `127.0.0.1:25565`; use `--bind 0.0.0.0` for LAN access and connect with the host computer's address. `--offline` is restricted to isolated loopback QA and cannot expose an unauthenticated LAN proxy.

| Command | What it does |
|---------|--------------|
| `network list [--json]` | List network definitions in the plugin consumer. Bare `network` runs this command. |
| `network candidates [--json]` | List stopped, compatible backends that do not already belong to a network. |
| `network recover` | Restore the original files after an interrupted configuration operation. All affected instances must be stopped. |
| `network create <name> --members <a,b> --default <alias> [--proxy velocity] [--port <port>] [--bind <127.0.0.1\|0.0.0.0>] [--fallback <a,b>] [--jar <path>] [--proxy-version <version>] [--offline]` | Create the proxy and configure modern forwarding for the selected backends. Initial routing aliases match instance names. |
| `network add <name> <instance> [--alias <alias>] [--port <port>]` | Add a stopped compatible backend, with an optional routing alias and fixed backend port. |
| `network remove <name> <alias>` | Stop the network, detach any backend, restore its saved settings, and update routing references. Removing the last backend deletes the network definition. Instance files are retained. |
| `network configure <name> [--default <alias>] [--fallback <a,b>] [--port <port>] [--bind <127.0.0.1\|0.0.0.0>]` | Change entry/fallback routing and proxy listening settings. Use `--fallback none` to clear fallback servers. |
| `network start <name> [--timeout <seconds>]` | Validate configuration, start stopped backends, wait for readiness, then start the proxy. Already running members remain running. |
| `network stop <name>` | Stop the proxy before stopping its backends. |
| `network restart <name> [--timeout <seconds>]` | Stop and restart the network in dependency order. |
| `network status <name> [--json]` | Show network and process states, ports, connected players from the proxy, and detected issues. JSON `playersOnline` is `null` when unavailable. |
| `network check <name> [--json]` | Validate membership, forwarding configuration, and ports. |
| `network repair <name>` | Reapply managed network settings after configuration drift. Requires stopped members and an intact forwarding secret; preserves unrelated keys and original backend snapshots. |
| `network console <name>` | Open the proxy console. |
| `network plugins-sync <name>` | Copy Velocity plugin jars from `consumers/plugin-consumers/dropins/velocity/` into this stopped proxy. Backends may remain running. |
| `network delete <name> --confirm <name>` | Stop the network, restore backend network settings, and delete its definition, including when managed configuration has drifted. Retain backend worlds and proxy files. |

Adding members, editing routing, and configuration repair require the whole network to be stopped. Backend removal, instance deletion, and network deletion stop it automatically. Removing an entry server selects the first surviving fallback, or the first remaining backend; removed aliases are pruned from fallback and forced-host routes. Deleting a proxy or the last backend dissolves the network and retains other instance files. Bulk deletion and workspace wipes perform this cleanup automatically. Plugin sync requires only the proxy to be stopped. Network ports stay fixed; startup reports a conflict instead of silently changing a route. Managed members cannot be reset, cloned, restored, or updated independently until detached. Ordinary runtime controls and logs remain available for each process. Velocity plugins use their own dropin source; Bukkit plugin dropins are never copied into the proxy. Proxy TPS and player counts are omitted from the fleet aggregate to avoid counting the same players twice.

An interrupted configuration operation blocks further network commands until `network recover` restores its original files. The wizard offers recovery and retry when it cannot load networks. Backups containing active network forwarding metadata cannot be restored independently, even after detaching the instance; use a backup made before joining or after leaving a network.

For manual changes to managed settings, stop the network, inspect `network check <name>`, then use `network repair <name>` to reapply its saved routing and forwarding settings. Repair preserves the forwarding secret and does not rotate it. Restore a missing or unreadable secret manually before repair.

### runtime — start, stop, attach

Consumer settings provide defaults. Each instance can override Java, heap, JVM preset, and console settings in `.multiplexor-runtime.env`; `--instance <name>` scopes a settings command to that instance. Resetting instance settings removes only its overrides. Environment variables `JAVA_EXECUTABLE`, `HEAP_SIZE`, `JVM_PROFILE`, and `JVM_ARGS` take precedence.

Before installation or startup, Multiplexor checks the selected Java executable and the known Minecraft minimum. Minecraft 1.17 needs Java 16, 1.18 needs Java 17, 1.20.5 and later 1.x releases need Java 21, and 26.x releases need Java 25. Loader and plugin requirements can be stricter; an unknown Minecraft version is reported as unchecked. `runtime settings check --instance <name>` shows the effective executable and compatibility result.

macOS/Linux runtimes use named `tmux` sessions. `Tab` is passed through to the server; Paper, Purpur, Folia, Canvas, and Leaf retain their native JLine/Brigadier completion for real server/plugin commands and current player names even with Multiplexor's minimal console format. Windows uses a native background host built into `multiplexor.exe`, so the release executable does not require Git Bash, `sh`, `chmod`, or `tmux`. Runtime output is captured under `consumers/<profile>/state/runtime/<instance>.log`; the Minecraft server also writes `logs/latest.log` inside its instance. Windows consoles show live runtime logs in a native terminal grid. Commands use RCON for game servers and an authenticated loopback connection to the native host for Velocity.

Startup preserves the configured server port when it is available and not reserved by another running instance. If a standalone instance conflicts, Multiplexor selects a free port starting at 25565. Network proxy and backend ports remain fixed and conflicts fail startup. Failed bind checks, including Windows address-in-use errors, exclude that port from selection.

In the Windows grid, `Tab` selects the next console; left/right also switch consoles when the command line is empty. Type a command and press `Enter` to send it. `Esc` or `Ctrl-C` returns to the dashboard while the servers keep running. Without an interactive terminal, console commands print the runtime log paths.

| Command | What it does |
|---------|--------------|
| `runtime watch [--once]` | Open the [live monitor](#live-monitor): full-screen charts over every instance, clickable action bars, and the wizard's flows behind the cards and `n` / `b` / `c`. `--once` sweeps metrics once, prints a single colorless frame to stdout, and exits — no TTY needed and no escape bytes, so it pipes and diffs cleanly. |
| `runtime start [instance] [--no-console]` | Safely sync dropins and start the instance, then open its console unless `--no-console`: tmux on macOS/Linux, a native terminal view on Windows. Locally modified instance jars are preserved with a warning. |
| `runtime stop [instance] [--graceful\|--force]` | Send `stop` to game servers or `end` to Velocity, allowing up to five seconds before forcing termination. Commands use tmux on macOS/Linux, or RCON/native host control on Windows. `--graceful` is the default; `--force` skips the wait. Restart, delete, and reset use the same five-second stop policy. |
| `runtime restart [instance] [--no-console]` | Stop and start again, then open its console unless `--no-console`. |
| `runtime console [instance]` | Start the runtime if needed and open its console: tmux on macOS/Linux, native live logs and command input on Windows. |
| `runtime consoles` | Open all running consoles in a tmux grid on macOS/Linux or a native terminal grid on Windows. |
| `runtime consoles-lateral` | Open running consoles side-by-side using tmux on macOS/Linux or the native terminal view on Windows. |
| `runtime status [instance]` | Print the runtime state of one instance. |
| `runtime stats [instance]` | Show live stats for running servers: player count (`online/max`), state, CPU, memory, uptime, port, and version, plus the names of online players. With no instance, scans every consumer for running servers; with an instance, reports that one. Player counts come from a Server List Ping, so neither `enable-query` nor `enable-rcon` is required. `CPU` (`4.2%`) and `MEM` (resident set, e.g. `2.4G`) come from a single batched `ps` over the tracked server pids; `CPU`, `MEM`, and `UPTIME` read `n/a` when the value is unavailable rather than showing a zero. |
| `runtime states` | Print one line per instance: `name<TAB>state<TAB>port<TAB>pid<TAB>locked<TAB>isolated`. State is `stopped` / `starting` / `running` / `stopping` / `restarting`; the final two columns are `locked`/`unlocked` and `isolated`/`shared`. |
| `runtime metrics` | Print one line per instance: `name<TAB>state<TAB>port<TAB>locked<TAB>players<TAB>max<TAB>version<TAB>tps<TAB>isolated<TAB>uptimeSeconds<TAB>cpuPercent<TAB>rssBytes<TAB>logPath<TAB>latencyMs<TAB>diskBytes<TAB>networkRxBytes<TAB>networkTxBytes<TAB>memoryLimitBytes<TAB>diskLimitBytes<TAB>networkRxPackets<TAB>networkTxPackets`. Running servers are pinged (and RCON-queried for TPS) concurrently. Every sweep of the [live monitor](#live-monitor) is one of these. TPS is `-` unless the server is Paper-family and was started with RCON enabled. Uptime is whole seconds since launch; CPU and resident memory come from one batched `ps`; the log path is absolute; latency is the server-list-ping round trip. The resource columns carry Pterodactyl disk/network/limit counters in Remote monitoring. On macOS Local monitoring, one batched `nettop` supplies the network byte and packet counters for each tracked Java pid; unsupported platforms leave them unavailable. The dashboard derives per-second rates from consecutive samples. `cpuPercent` is BSD `ps %cpu` — a lifetime average, not an instantaneous load reading. Any unavailable value is `-`, never a zero. Columns are append-only, so readers written against shorter rows keep working. |
| `runtime list` | Print running instance names. |
| `runtime settings set-java <executable> [--instance <name>]` | Select the Java executable used for installation and startup. Paths containing spaces are supported. |
| `runtime settings check [--instance <name>]` | Inspect Java and check the known Minecraft minimum without starting a server. |
| `runtime settings show [--instance <name>]` | Print the active heap, JVM preset, and flags. |
| `runtime settings presets` | List available JVM presets (`aikar`, `vanilla`, `conservative`). |
| `runtime settings set-heap <2G\|4G\|...> [--instance <name>]` | Set JVM `-Xmx`. |
| `runtime settings set-preset <name> [--instance <name>]` | Apply a JVM preset's flags. |
| `runtime settings set-wrap <on\|off> [--instance <name>]` | Toggle tmux console line wrap on macOS/Linux. Default `off` (long server lines clip at the pane edge instead of wrapping). Takes effect on next `runtime start`. **The `logs/latest.log` file is unaffected** — wrapping is purely a terminal-renderer concern. |
| `runtime settings set-log-format <minimal\|default> [--instance <name>]` | Toggle the console log pattern. Default `minimal` — strips the `[HH:mm:ss INFO]` prefix from the console only, and filters out the `RCON Client … started` / `… shutting down` lines the manager's live TPS polling triggers (from both the console and `logs/latest.log`). `default` restores the server's bundled Log4j pattern (RCON lines reappear). **The `logs/latest.log` file always keeps the full timestamped pattern.** Takes effect on next `runtime start`. |
| `runtime settings reset [--instance <name>]` | Reset consumer defaults, or remove only the named instance's overrides. |

Paper/Spigot/Purpur `/restart` is wired to a per-instance `multiplexor-restart.sh` on macOS/Linux or `multiplexor-restart.cmd` on Windows, so `/restart` re-enters Multiplexor instead of exiting permanently. While that script waits, the instance reports `restarting`.

### gameplay — Mineflayer player-protocol QA

The harness is pinned under `MultiplexorApp/tool/mineflayer/`; `gameplay setup` installs it locally with npm. Offline bots are restricted to stopped, isolated instances: `gameplay prepare` binds the server to loopback, disables online authentication and whitelisting, and removes spawn protection. It never weakens a shared instance. `--start` starts a stopped target, while `--stop-after` only stops an instance that the gameplay command itself started.

The harness package lock is checked in. Setup and launcher installs use `npm ci`; gameplay commands through either launcher refresh an installation when its installed lock is missing or older than the manifest or package lock. An installation failure stops the command with a nonzero exit code. Use `gameplay setup` to repair a damaged installation explicitly, then run `gameplay doctor --json`.

Every gameplay run starts a first-person Prismarine web feed on a free loopback port. The reachable URL is printed as soon as the feed is ready, included under `viewer.url` in the JSON report, and written immediately to `state/gameplay-tests/<instance>/viewer-<port>.json`; the state file changes from `active` to `closed` when the run ends. Use `--viewer-port <port>` when a stable port is useful or `--no-viewer` only when the feed is intentionally unnecessary.

| Command | What it does |
|---------|--------------|
| `gameplay setup` | Install the pinned Mineflayer, pathfinder, and Prismarine Viewer dependencies with `npm ci`. |
| `gameplay doctor [--json]` | Verify Node and the pinned gameplay dependency versions. |
| `gameplay list [--json]` | List built-in scenarios. |
| `gameplay swarm-profiles [--json]` | List the available deterministic swarm behavior profiles. |
| `gameplay sessions validate <profile.json> [--instance <name>] [--network <name>] [--prepare] [--json]` | Validate the profile, routes, identities, and target without changing it. `--prepare` previews offline loopback preparation of a stopped standalone instance. Exactly one target selector is required. |
| `gameplay sessions start <profile.json> [--instance <name>] [--network <name>] [--prepare] [--start] [--stop-after] [--startup-timeout <seconds>] [--viewer-port <port>] [--no-viewer] [--json]` | Start a detached persistent simulation and print its run ID. `--prepare` applies only to a stopped standalone instance. `--start` starts stopped targets; `--stop-after` stops only processes started by this run. Startup timeout defaults to 180 seconds. Exactly one target selector is required. |
| `gameplay sessions list [--json]` | List runs for the selected consumer, with target, population, host state, and artifact paths. |
| `gameplay sessions status <run> [--json]` | Show host cleanup state, player activities and waiting reasons, project progress, measurements, and the current viewer URL. |
| `gameplay sessions stop <run> [--json]` | Request bounded action cancellation, save a checkpoint, disconnect workers, and finish owned runtime cleanup. Waits up to 45 seconds; a nonzero result with `active: true` means cleanup is still pending. |
| `gameplay sessions resume <run> [--json]` | Resume the same identities and evolving world from its checkpoint. Rejects an active run, changed profile, changed target, or reset world identity. Retains the original startup and cleanup policy. |
| `gameplay sessions report <run> [--json]` | Read the final worker report with the supervisor's cleanup result. |
| `gameplay swarm <idle\|wander\|redstone\|workshop\|mixed\|stress\|plan.json> [instance] [--instance <name>] [--bots <1-256>] [--duration <seconds>] [--seed <uint32>] [--join-interval <milliseconds>] [--radius <4-64>] [--prefix <name>] [--build-arena] [--origin <x,y,z>] [--scatter <8-4096>] [--workload <path.json>] [--bounds <minX,minY,minZ:maxX,maxY,maxZ>] [--goals <activity=count,...>] [--completion <duration\|goals>] [--chat] [--prepare] [--start] [--stop-after] [--startup-timeout <seconds>] [--connect-timeout <seconds>] [--action-timeout <seconds>] [--version <version>] [--viewer-port <port>] [--no-viewer] [--json]` | Run a bounded group of ordinary-player bots on an isolated, offline, loopback-only standalone instance. Network members and proxies are refused. |
| `gameplay prepare [instance] [--instance <name>]` | Prepare a stopped, isolated instance for loopback-only offline bot authentication. |
| `gameplay run <scenario> [instance] [flags]` | Run a built-in name or `.mjs` scenario. Supports `--scenario`, `--instance`, `--profiles-folder`, `--version`, `--auth`, `--startup-timeout`, `--connect-timeout`, `--assertion-timeout`, `--prepare`, `--start`, `--stop-after`, `--username`, `--timeout`, `--command`, `--expect`, `--effect`, `--viewer-port`, `--no-viewer`, `--no-op`, and `--json`. |

The built-in `connect` scenario validates login, spawn, position, health, and connection stability. `command` requires `--command` plus an `--expect` regular expression. `effect` optionally runs `--command` and requires the named `--effect`. `circle` walks one eight-block-radius lap beside the initial position; provide clear level terrain and `--timeout 120`. It checks observed angular progress, radius, elevation, and position jumps.

Scenario reports record the installed plugin jar filenames and SHA-256 hashes, the scenario source hash, and the observed server version. To inspect Volmit feature coverage, run `node MultiplexorApp/tool/mineflayer/src/coverage.mjs consumers/plugin-consumers/state/gameplay-tests`. It reads the feature manifest in `tool/mineflayer/suites/volmit.json` and emits JSON with passed, failed, untested, or unsupported features. A second argument selects another manifest. Only the latest completed report for each feature and exact recorded server/plugin build set counts; failures on another build remain visible. Older reports without jar hashes have `plugins: null` and do not establish coverage for a known build. Missing scenarios remain untested; the manifest is a coverage target, not a claim that every listed scenario exists or passes.

The [Volmit suite guide](MultiplexorApp/tool/mineflayer/suites/README.md) maps plugin features to executable scenarios, fixture requirements, and restart phases.

Custom modules default-export `{ name, description, async run(context) }`. The context supplies `bot`, `step`, `expect`, `command`, `waitForEvent`, `waitForMessage`, abortable `sleep`, `waitUntil`, `signal`, and server metadata including the managed instance `directory`. `actions.walkRoute(points, {timeoutMs})`, `actions.walkCircle({center, radius, laps, clockwise, timeoutMs})`, and `actions.attackPlayer(otherBot, {hits, minimumHealth, timeoutMs})` use bounded actions and record observed outcomes. Coordinates are `{x,y,z}` objects. Circles need clear level routes; blocked terrain fails instead of teleporting past it. Combat requires a visible player within three blocks, a server damage event naming the attacking bot, and actual health loss.

`await context.connectActor(username)` returns another context on the same managed offline loopback target. Additional actors cannot reuse existing operator identities; the run owns all connections and fails on any unexpected kick or disconnect. Up to 32 actors including the primary are supported, subject to server capacity and login throttling. Cleanup disconnects every actor on success, failure, or interruption.

For an operation that deliberately disconnects its client, `await context.reconnectAfter(trigger, {timeoutMs})` waits for both the trigger and disconnect, then returns a new context for the same identity. The default deadline is 30 seconds, with a 120-second maximum. The trigger can wait for independent server-log evidence of completion before reconnection. Kicks, errors, missing disconnects, and subsequent unexpected disconnects still fail. Reports retain each connection and the primary viewer's closed/reopened sessions.

With the session observer installed, `await context.observe()` reads a fresh server snapshot. `context.transition(trigger, {worldName, worldId, timeoutMs, position, radius})` verifies a post-trigger server world identity and a loaded client chunk; specify a destination name or UUID. A respawn packet or matching dimension alone does not prove arrival. Missing or stale observations fail explicitly.

Swarm behavior comes from function-based recipes. Built-in profiles idle, wander, interact with redstone, or perform workshop tasks; `mixed` combines activities. JSON plans can coordinate phases of walking, circles, teleportation, mining, building, interaction, and scripted chat. A `circle` phase uses `positions` as centers, plus `radius`, `laps`, and `clockwise`; centers are distributed across actors like other position jobs. It reuses the observed-lap action and needs an action deadline long enough for the requested laps. Custom plans and stress workloads are validated before any server preparation or startup. `--chat` enables scripted progress messages. `--scatter` distributes workers evenly across a grid around the origin and finds the terrain height; it cannot be combined with `--build-arena` or the `stress` profile.

Swarm defaults are 4 bots, 60 seconds, seed 1, a 1,000 ms join interval, radius 16, and origin `0,80,0`. Bot count accepts 1–256. Duration accepts 1–604,800 seconds (seven days); join interval accepts 100–10,000 ms; seeds accept 0–4,294,967,295. Startup, connection, and action timeouts default to 180, 30, and 15 seconds, with limits of 1–3,600, 1–300, and 1–120 respectively. Numeric options use decimal integers. A generated per-run prefix keeps worker names separate; an explicit `--prefix` accepts 1–12 letters, numbers, or underscores, followed by worker suffixes `01` through `256`. Existing operator identities are rejected. One swarm may run on an instance at a time. The server needs enough free player slots for every worker plus one temporary controller when setup requires it.

`workshop` and `mixed` require explicit `--build-arena`. Arena setup replaces a square of `12 × ceil(sqrt(bots))` blocks per side starting at `--origin`: the floor is at origin Y, worker feet are at Y+1, and the five blocks above the floor are cleared. Each worker gets a 12×12 tile with setup materials and an iron pickaxe. These changes remain after the run. Origin coordinates are integers, X/Z within ±29,999,000 and Y from -48 through 256. Use a disposable world or make a stopped backup first.

Workers never receive operator access. Arena, custom-plan, and stress workers use survival mode; other runs retain the server-assigned game mode. Only a separate temporary controller receives operator access for arena setup, scattering, a custom plan, or stress workloads; Multiplexor revokes that access in cleanup, including failed runs. Runs without those operations do not grant operator access. `--stop-after` stops only a server started by the same run. Viewer URLs, reports, and runtime-log references use the existing gameplay artifact directory, and the viewer closes when the run ends.

Ctrl+C and termination signals interrupt the Node runner, wait for its bot/viewer cleanup, then revoke the controller's access. Cancellation returns a nonzero exit code and keeps the same server ownership rules as an ordinary run.

The `stress` profile runs repeated activity jobs for extended tests. Role weights assign workers, and activity weights choose each worker's next job. A shared scheduler tracks completed goals, reserves targets, changes the active worker count on a schedule, and stops stalled or failing workloads. This is a reproducible synthetic workload. It is not a statistical model of average human players or a claim that this machine can sustain 256 clients for seven days.

Without a workload file, `stress` uses patrol, exploration, chat, and idle periods in the existing world. With `--build-arena`, its default workload includes every supported activity. `--workload <path.json>` loads a workload with custom roles, pacing, targets, goals, and load stages. Stress always requires one temporary controller in addition to the worker slots.

Stress controls:

| Control | Meaning |
|---------|---------|
| `--bounds minX,minY,minZ:maxX,maxY,maxZ` | Override the workload's allowed box. Integer X/Z coordinates stay within ±29,999,000, Y within -48–256, and corners must be ordered. The box must include worker feet, head space, and the complete arena when one is requested. |
| `--goals mine=1000,build=1000` | Replace the workload's complete goal map. Counts are aggregate successful activity jobs across all workers, from 1–1,000,000,000 per activity. Every goal needs an enabled activity. |
| `--completion duration` | Run until the duration expires. Goal counts remain acceptance requirements. |
| `--completion goals` | Stop after all goals pass. The duration remains a hard deadline, and unmet goals fail the run. |
| `--workload path.json` | Select a stress workload. This file is separate from a coordinated phase plan. |

These four controls require `stress`. CLI bounds, goals, and completion override the corresponding workload fields. Without explicit bounds, an arena uses its complete footprint and height. An outdoor workload uses origin ± radius in X/Z and Y from -48 to 256. `--scatter` is not available for stress. Use bounds and patrol or exploration jobs to control where activity occurs.

Stress workload JSON requires `schemaVersion: 1`, a printable `name`, and `roles`. The validator rejects unknown fields. Optional fields use these defaults and limits:

| Field | Shape and rules |
|-------|-----------------|
| `bounds` | `{"min":[x,y,z],"max":[x,y,z]}`. Uses the same coordinate limits as `--bounds`. |
| `roles` | 1–32 objects with a unique `name`, a positive `weight` (default 1), and an `activities` map. Role and activity weights accept integers up to 10,000; zero activity weights disable that activity. |
| `goals` | An activity-to-count map, default `{}`. |
| `completion` | `"duration"` (default) or `"goals"`. Goal completion requires a nonempty goal map. |
| `pacing` | `{"minMs":250,"maxMs":1750}`. A seeded pause between jobs, from 0–60,000 ms. |
| `failurePolicy` | `{"maxConsecutive":5,"maxTotal":100}`. Limits consecutive worker failures and total failed jobs. |
| `schedule` | `[{"atSeconds":0,"activeBots":4}]`. Starts at zero and increases by time, with 1–256 stages before the run deadline. Active counts range from zero to `--bots`. |
| `reportIntervalSeconds` | Aggregate report interval, default 10, from 1–3,600 seconds. |
| `stallTimeoutSeconds` | Progress deadline, default 120, from 5–3,600 seconds. |
| `targets` | Maps `mine`, `build`, `redstone`, `farm`, or `storage` to 1–2,048 distinct `[x,y,z]` positions inside bounds. Enabled target activities require positions when no arena is requested. |
| `messages` | 1–128 plain chat messages, at most 160 characters each. Supports `{bot}`, `{index}`, `{role}`, `{activity}`, and `{completed}`. Slash commands are rejected. |

| Activity | Repeated player work |
|----------|----------------------|
| `patrol` | Short local routes of roughly 2–8 blocks. |
| `explore` | Routes of roughly 2–32 blocks that follow headings across the allowed area. |
| `mine` / `build` | Workers share stone targets. Mining frees a target; building refills it. Target leases prevent conflicting edits. |
| `redstone` | Lever, button, and pressure-plate interactions with observed state changes. |
| `farm` | Grow wheat with bone meal when needed, harvest it, and plant seeds again. |
| `craft` | Craft oak planks from logs, then sticks, with inventory confirmations. |
| `storage` | Open a chest or barrel, deposit eight cobblestone, and withdraw it. A target lease covers the full transaction. |
| `chat` | Send a scripted plain message and wait for its server echo. |
| `idle` | Pause between periods of activity. |

Stress workers use survival mode and eat when hungry. The controller supplies missing materials and removes excess test outputs to keep inventories usable. The report separates support operations from successful player activity. The stress arena adds a chest, crafting table, wheat field, water, and shared work blocks to the ordinary tiles. Without `--build-arena`, targets must identify existing fixtures. Farming edits wheat and mining/building edit the supplied stone targets. Block and inventory changes remain after the run.

Final reports and periodic checkpoints include role assignments, active worker counts, goals, successful/skipped/failed jobs, walking distance, and action latency histograms. `newChunkVisits` counts per-worker destination chunks absent from that worker's last 4,096 destinations; it is not a global unique-chunk count. Reported p50/p95 values are histogram bucket upper bounds. Node process memory, CPU, and event-loop measurements describe the load generator. Correlate them with server runtime logs and server metrics to identify the bottleneck. Reports retain bounded event and metric history for long runs.

Goal counts are minimum requirements. Goal mode favors unmet quotas while continuing other enabled activities, so builders can replenish mining targets after their own quota passes. Execution uses the existing [Mineflayer inventory, crafting, and interaction APIs](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md) and [pathfinder movement exclusions](https://github.com/PrismarineJS/mineflayer-pathfinder#exclusionareasstep); role selection and coordination use deterministic functions.

Supported activity keys are `patrol`, `explore`, `mine`, `build`, `redstone`, `farm`, `craft`, `storage`, `chat`, and `idle`. The workload must enable at least one activity other than idle. A schedule changes which connected workers perform jobs. It does not repeatedly reconnect clients. Join pacing remains controlled by `--join-interval`. Workload files cannot exceed 256 KiB.

```json
{
  "schemaVersion": 1,
  "name": "Overnight arena activity",
  "roles": [
    {"name": "builder", "weight": 2, "activities": {"build": 4, "mine": 4, "patrol": 2, "chat": 1}},
    {"name": "operator", "weight": 1, "activities": {"redstone": 4, "farm": 3, "craft": 2, "storage": 2, "patrol": 2}}
  ],
  "pacing": {"minMs": 250, "maxMs": 1500},
  "goals": {"mine": 1000, "build": 1000, "redstone": 1000},
  "completion": "duration",
  "schedule": [
    {"atSeconds": 0, "activeBots": 4},
    {"atSeconds": 300, "activeBots": 8},
    {"atSeconds": 900, "activeBots": 16},
    {"atSeconds": 1800, "activeBots": 32}
  ],
  "failurePolicy": {"maxConsecutive": 5, "maxTotal": 100},
  "reportIntervalSeconds": 10,
  "stallTimeoutSeconds": 120
}
```

Run this workload with `--bots 32 --duration 43200 --build-arena`. The bundled [mixed endurance workload](MultiplexorApp/tool/mineflayer/workloads/mixed-endurance.json) includes three roles and eight hours of load stages. [Outdoor endurance](MultiplexorApp/tool/mineflayer/workloads/outdoor-endurance.json) uses a bounded existing world. [Mixed goals](MultiplexorApp/tool/mineflayer/workloads/mixed-goals.json) stops after its activity quotas pass. Start with a smaller run and compare action throughput, latency, failed jobs, process memory, and server metrics before increasing the population. Bot pathfinding and protocol handling also consume CPU and memory on the generator machine.

Custom JSON plans contain a `name` and 1–128 `phases`. Each phase has an `action`, optional `actors` (distinct worker numbers from 1 through `--bots`), and its action fields below. Omitting `actors` selects every worker. Position jobs are distributed round-robin among the selected workers; the next phase waits until every selected worker has completed its current jobs. `--duration` is a hard deadline for the complete plan.

| Action | Fields | Behavior |
|--------|--------|----------|
| `teleport` | `positions: [[x,y,z], ...]` | Controller teleports workers; Y is the worker's feet coordinate. |
| `walk` | `positions: [[x,y,z], ...]` | Workers pathfind to assigned targets. |
| `mine` | `positions: [[x,y,z], ...]` | Workers receive iron pickaxes and mine the assigned blocks. |
| `build` | `positions: [[x,y,z], ...]`, `block: "stone"` | Controller supplies materials; workers place the assigned block type. |
| `interact` | `positions: [[x,y,z], ...]` | Workers interact with the assigned blocks. |
| `scatter` | `radius: 8–4096` | Controller distributes selected workers over terrain around the run origin. |
| `chat` | `messages: ["Worker {index} ready", ...]` | Workers send plain messages; `{bot}`, `{index}`, and `{phase}` expand to their current values. Slash commands are rejected. |
| `wait` | `seconds: 0.1–300` | Wait before the next coordinated phase. |

Positions are integer world coordinates, bounded like `--origin`, with 1–1,024 distinct positions per phase. Scatter origin plus radius must remain inside the X/Z bounds. Plans use an existing world fixture and cannot pass `--build-arena`; create the fixture in a separate run. The [four-worker coordinated demo](MultiplexorApp/tool/mineflayer/plans/coordinated-demo.json) expects four arena tiles at origin `0,80,0` and includes teleport, walking, building, mining, interaction, and chat phases.

```json
{
  "name": "Two worker readiness",
  "phases": [
    {"action": "teleport", "actors": [1, 2], "positions": [[2, 81, 5], [14, 81, 5]]},
    {"action": "chat", "actors": [1, 2], "messages": ["Worker {index} reached its station."]},
    {"action": "walk", "actors": [1, 2], "positions": [[6, 81, 6], [18, 81, 6]]}
  ]
}
```

The harness pins bleeding-edge [Mineflayer commit `f603758e`](https://github.com/PrismarineJS/mineflayer/commit/f603758e4228a7e61d1337526e6066e79308b976), which identifies itself as version 4.38.0 and requires Node 22+. It supports vanilla Java protocols through 26.1. Minecraft 26.2 and newer are outside its tested protocol range. Gameplay results prove protocol-visible behavior, not client rendering, resource packs, sound, camera behavior, client mods, or human feel.

For protocol QA with this dependency set, create an isolated 1.21.11 server instead of using a 26.2 or 26.3 instance. A passing doctor check verifies the harness installation; it does not make an unsupported server protocol compatible.

#### Persistent player sessions

`gameplay sessions` models persistent identities with separate online sessions. Players join, leave, return, eat, store supplies, gather resources, craft, build verified structures, and visit their social group. A seeded population scheduler controls actual connections independently of action completion. Role functions coordinate through project requirements and bounded reservations. Saved intent survives reconnects; Minecraft remains authoritative for inventory, position, and world state. No AI service is involved.

Session JSON is separate from a swarm plan or stress workload. The validator rejects unknown fields and profiles over 1 MiB. Bundled profiles provide complete world descriptions:

| Profile | Purpose |
|---------|---------|
| [Settlement](MultiplexorApp/tool/mineflayer/session-profiles/settlement.json) | One hour, eight persistent identities, four concurrent players, real resource delivery and construction. Creates a disposable settlement fixture. |
| [Settlement goals](MultiplexorApp/tool/mineflayer/session-profiles/settlement-goals.json) | Four players construct two shelters and meet resource-transfer goals, with a one-hour deadline. |
| [Dispersed established world](MultiplexorApp/tool/mineflayer/session-profiles/dispersed-established.json) | Eight-hour template for two prepared bases separated by 256 blocks. Requires an existing baseline. |
| [Frontier](MultiplexorApp/tool/mineflayer/session-profiles/frontier.json) | Four-hour exploration template for an existing starting base and surrounding terrain. Requires an existing baseline. |
| [Velocity settlement](MultiplexorApp/tool/mineflayer/session-profiles/velocity-settlement.json) | Settlement work through a proxy, with lobby visits and backend switches. Edit `lobby` and `survival` aliases to match the network. |

The existing-world templates describe the fixtures they expect; they do not create a mature server world. Restore a representative baseline before a comparison, and use `resume` to continue the same evolving world. A checkpoint is not a world backup. Each run copies its normalized profile and records world identity markers inside the target's world directory.

| Profile field | Shape and meaning |
|---------------|-------------------|
| `schemaVersion`, `name`, `seed` | Version `1`, a printable name, and a seeded decision stream. Reproduces decisions and schedules, not identical concurrent server execution. |
| `durationSeconds`, `completion`, `goals` | Duration is 1–604,800 seconds. Completion is `duration` or `goals`; duration remains the deadline. Goals are minimum verified counters. |
| `population.identities`, `concurrent` | Persistent roster size, 1–256, and initial intended population. A roster can exceed concurrent connections. |
| `population.usernamePrefix` | Stable 1–12 character letters/digits/underscore prefix; names append `001` onward. Choose distinct prefixes for independent populations. Existing operator identities are refused. |
| `population.arrivalIntervalSeconds` | Minimum spacing between connection attempts, including setup controllers, returning players, and retries. Scheduling is independent of action completion, and slow handshakes can overlap. Choose an interval that respects the configured proxy/server login limit; the Velocity profile uses four seconds. |
| `population.sessionSeconds`, `offlineSeconds` | `[minimum, maximum]` ranges for online sessions and time before returning. |
| `population.stages` | Increasing `{ "atSeconds": 300, "concurrent": 8 }` population stages. Changes connections, including departures when the target falls. |
| `population.groupSize` | Size of stable social groups. Meetings have bounded attendance waits. |
| `population.minimumAchievedFraction` | Optional minimum fraction of requested player-time that must reach the playing state. Leaving it unset records achieved load without making it an acceptance limit. |
| `playerRoles`, `playerWorlds` | Cycling role names and world IDs assigned to roster identities. Roles: `miner`, `lumberjack`, `builder`, `farmer`, `crafter`, `courier`, `explorer`, `social`, `mechanic`. Construction worlds require assigned producers and builders. |
| `pacing` | `minSeconds` and `maxSeconds` pauses between tasks. |
| `recovery` | `maxConsecutiveFailures`, `maxTotalFailures`, `retrySeconds`, and death policy `respawn` or `retire`. Failures remain recorded when a player recovers. |
| `timeouts` | `connectSeconds`, `actionSeconds`, and `settleSeconds`. Expired work must settle before a new owner uses the same target. |
| `checkpointSeconds` | Atomic checkpoint interval, default 10 seconds. |
| `worlds` | 1–32 named world agendas, described below. |
| `network` | `routes` backend aliases and `switchEverySeconds: [minimum, maximum]`. Only valid against a Velocity target. |
| `telemetry` | `required`, `maxAgeSeconds`, `warmupSeconds` (default 60), and optional `maxP95TickMs` / `maxP99TickMs` limits. Missing, stale, or warming-up measurements remain unavailable. |
| `pluginActivities` | Optional command, inventory-menu, movement, and world-transition workflows, described below. |

Supported goal counters are `projectsCompleted`, `blocksVerified`, `resourceTransfers`, `foodCrafted`, `sessionsCompleted`, `joins`, `switches`, `exploredChunks`, `gatherings`, `cropsHarvested`, and `pluginActions`. Counters measure different outcomes and must not be added into a single player-load score. Exploration counts distinct chunks visited by each player, capped at 2,048 per player and world without evicting older visits. It does not prove new terrain generation.

Each world agenda specifies `id`, `backend`, `dimension`, `bounds: {min: [x,y,z], max: [x,y,z]}`, `home`, `storage`, `craftingTable`, and `meetingPoint`. `backend: "standalone"` resolves to the selected standalone or entry backend. `resourceAreas` describe named `mine` or `wood` boxes. `farmAreas`, `protectedAreas`, and `frontiers` describe named boxes. `buildPlots` contain an `id`, `origin`, and supported `blueprint`. `redstone` identifies existing controls and the blocks whose changes must be observed. Use the bundled files as complete examples. Regions constrain movement and edits; surrounding chunk simulation still depends on server settings.

`setup: {"kind":"settlement","origin":[0,80,0]}` authorizes persistent fixture construction in the described area, plus initial starter supplies. `setup: {"kind":"existing"}` uses prepared fixtures and inventory. During the measured workload, workers collect and consume real resources; there is no recurring administrative replenishment or output clearing. Shortages, full storage, depleted resource regions, blocked paths, and completed build plots are visible waiting conditions. Fixture setup is skipped on resume.

Velocity sessions require a managed, offline, loopback network with every proxy and backend isolated. They preserve modern forwarding and join through the proxy port. Destination verification uses fresh server-side routing evidence; a respawn event alone is insufficient. Inventories, reservations, and world agendas stay backend-specific. `--prepare` is refused for networks and their members. A run holds exclusive leases for all its target members and the proxy, shared with swarm ownership checks.

Plugin activities use ordinary player commands and inventory operations. Each activity contains `id`, `backend`, optional `roles`, `everySeconds: [min,max]`, `timeoutSeconds`, and either `command` or `steps`. `expect` is a case-insensitive literal reply substring. `{player}` and `{id}` expand from the player identity. Optional `menu` contains `title`, `clicks: [{slot,item,nextTitle?}]`, and `expect`: every click checks the expected item in that slot; `nextTitle` waits for and verifies a replacement menu before continuing. A menu mutation requires an expected reply. Configure activities for the installed plugins; no claim, economy, or shop behavior is assumed automatically.

Activity `backend: "standalone"` resolves to the selected instance or network entry backend, just as it does for world agendas.

A workflow's `steps` contains 1–32 actions. Each step has one of `command` (with `expect`/`menu`), `route: [{x,y,z},...]`, or `circle: {center:{x,y,z},radius,laps,clockwise}`. Routes allow at most 256 waypoints. Movement reuses the scenario actions and their observed completion checks. An optional `transition: {worldName?,worldId?,position?,radius?}` declares a destination and requires fresh server-observer proof after that step. Specify at least a name or UUID. Persistent workflows must return to their starting world before resuming ordinary tasks. Unexpected respawns still fail; failed declared arrivals close the connection. Both the activity deadline and the profile's action deadline apply, so allow enough time for the complete sequence.

For server measurements, build the optional [session observer](MultiplexorApp/tool/session-observer/README.md) with `gradle -p MultiplexorApp/tool/session-observer clean test jar` and install its jar in the stopped QA proxy and backends. Session runs automatically read each local observer file. Paper supplies tick-time percentiles, loaded chunk/entity totals, chunk events, JVM CPU/heap/GC, and world membership. Folia supplies entity-scheduler player samples, sampled world changes, chunk-event counters, and process metrics; region timings and aggregate loaded chunk/entity totals remain unavailable. Required tick thresholds fail as unavailable on Folia. Performance is reported as `measured` until tick-time acceptance limits are configured. Recorded breaches survive stop and resume. The observer README lists supported APIs and measurement limits.

Artifacts live under `consumers/<profile>/state/gameplay-sessions/<run>/`: the copied `profile.json`, runtime `configuration.json`, supervisor `host.json` and `host.log`, worker `status.json`, atomic `checkpoint.json`, and final `report.json`. Reports separate workload goals, scheduled versus achieved population, operation latency, server performance, generator resources, and cleanup. `status` shows the active viewer URL; the viewer closes during cleanup. Startup failure rolls back processes started by that attempt. Ordinary completion retains started servers unless `--stop-after` was selected, and never stops preexisting servers.

These are synthetic session profiles. Long configured durations are not evidence of endurance, and passing bot counts are not a human-player capacity rating. Compare against aggregate real-session behavior and server profiles on the same world and plugin stack before treating a mix as representative. Running the generator beside the server also shares CPU and memory.

### plugins / mods — dropin sources & sync

The two namespaces are mirrors. Use `plugins` when the active consumer is `plugin`; use `mods` for any of the mod consumers. Both refuse the wrong consumer.

| Command | What it does |
|---------|--------------|
| `plugins show-source` (or `mods show-source`) | Print the absolute dropin folder. |
| `plugins sync [instance\|--all] [--clean]` | Authoritatively copy dropins into one instance or every instance, replacing same-name local jars. `--clean` clears existing jars first. Isolated instances are skipped with `[SKIP]`. `mods sync` on Mohist refreshes every persisted source, including tracked plugin dropins. |
| `plugins copy <isolated-instance> --artifact <dropin.jar> [...]` | Copy only the selected drop-in jars into an existing isolated instance without subscribing it to automatic sync. The `mods` form behaves the same way for mod consumers. |
| `plugins watch-start` | Start a background daemon that re-syncs whenever a dropin jar changes. Untouched previously synchronized jars update automatically; locally modified jars are preserved with a warning. |
| `plugins watch-stop` | Stop the watcher daemon. |
| `plugins watch-status` | Print whether the watcher is running. |
| `plugins iris-packs-path` | Print the shared Iris packs directory (`plugin` consumer only). |
| `plugins iris-packs-link [instance\|--all]` | Symlink the shared Iris packs into an instance's `plugins/iris/packs`. Isolated instances are skipped. |

### backup — restorable instance snapshots

Backups require a stopped instance. A snapshot contains regular files, including copies of launch jars and shared data, so later build pruning cannot remove its dependencies. Verification checks the complete manifest, file sizes, and SHA-256 hashes before restore can stop or replace a target. Restore prepares the replacement beside the target and keeps the original directory until installation succeeds.

Updates and restores allow up to 60 seconds for a clean shutdown. If the server does not stop, the operation fails without force-killing it or taking a snapshot of a running world.

| Command | What it does |
|---------|--------------|
| `backup create [instance] [--label <label>] [--include-logs]` | Snapshot a stopped instance into `consumers/<profile>/backups/<instance>/...`. Active instance if omitted. Logs are skipped unless `--include-logs`. |
| `backup list [instance\|--all]` | List backups in the active consumer. |
| `backup restore [instance] <backup-id> [--instance <name>]` | Verify the complete snapshot before stopping the target, then replace it with rollback on installation failure. Refused if locked. |
| `backup verify [instance] <backup-id> [--instance <name>]` | Verify the backup manifest and file checksums. |
| `backup delete [instance] <backup-id> [--instance <name>]` | Delete one backup. |
| `backup prune [instance] [--keep <n>]` | Keep the newest `n` backups per instance and delete older ones. Default `10`. |

### addons — per-instance plugin and mod checklists

The bundled catalog offers EssentialsX (core), FastAsyncWorldEdit (FAWE), BlueMap, ViaVersion, ViaBackwards, and ProtocolLib. These are server plugins. EssentialsX and FAWE are offered for Paper, Purpur, Leaf, and Spigot; BlueMap, ViaVersion, ViaBackwards, and ProtocolLib also support Folia/Canvas. Forge, Fabric, NeoForge, and Mohist can use explicitly compatible custom entries. Platform restrictions are applied before selection; Modrinth installs require an exact published Minecraft-version match and a stable release, preferring Paper artifacts for Paper derivatives.

New server creation records Minecraft versions before imported jars are renamed into the cache. Existing instances can also resolve the version from their current jar's canonical filename or symlink target. `--mc` overrides detection; `addons list --json` reports the resolved `minecraft` and whether `versionRequired` is still true. A missing version is separate from platform compatibility.

| Command | What it does |
|---------|--------------|
| `addons catalog [--json]` | List the bundled and workspace-local catalog; print the custom registry path in text mode. |
| `addons list [instance] [--mc <version>] [--json]` | Show selected addons and platform eligibility. Uses the active instance if omitted. |
| `addons set [instance] (--select <id,id,...>\|--none) [--mc <version>]` | Apply the complete checked selection, automatically including declared dependencies. Requires a stopped server. |
| `addons update [instance] [--mc <version>]` | Refresh the selected addons from their configured sources. Requires a stopped server. |

Addon metadata resolution and jar download/hash preparation run up to four at a time. Downloads are staged and validated before the selection is committed; dependency checks and the final installation remain ordered. Modrinth hashes and available GitHub asset hashes are verified. Addons install directly into the selected instance's `plugins/` or `mods/` directory; they never write to shared drop-ins. Bundled filenames are `EssentialsX.jar`, `FastAsyncWorldEdit.jar`, `BlueMap.jar`, `ViaVersion.jar`, `ViaBackwards.jar`, and `ProtocolLib.jar`.

Installation replaces an existing matching jar and removes matching version/platform variants, such as `ViaVersion-5.11.0.jar`, so each addon has one plain filename. Replacements are backed up until the whole selection commits and restored if installation fails. Replacing a jar symlink replaces the link itself and leaves its source untouched. Plugin configuration folders and unrelated jars stay in place. Selection and downloaded checksums are recorded in `.multiplexor-addons.json`. You can overwrite a plain jar manually: an unchanged selection keeps that copy, `addons update` replaces it from the configured source, and unchecking removes it. Normal drop-in sync, including `--clean`, preserves selected addons and skips their matching source filenames. Addons work on isolated instances too. Factory reset clears both their jars and selection; clone and backup preserve them.

ProtocolLib uses the official stable `5.4.0` release through Minecraft 1.21.8. For 1.21.9–1.21.11 and 26.1–26.1.2 it uses the official `dev-build` Spigot-compatible artifact, including on Paper. For 26.2 it uses the Paper artifact on Paper derivatives and the Spigot artifact on Spigot. The checklist labels these **ProtocolLib (development)**. The modern Paper artifact requires Paper API 26.2 and cannot be substituted on older servers. These rules are based on [ProtocolLib's artifacts and support declarations](https://github.com/dmulloy2/ProtocolLib). Unknown newer versions need a catalog update before ProtocolLib is offered.

EssentialsX prefers a compatible stable Modrinth release. On Minecraft 26.2 or 26.3, if none exists, it downloads the core jar from the [official EssentialsX CI](https://ci.ender.zone/job/EssentialsX/), which includes [26.2 support](https://github.com/EssentialsX/Essentials/pull/6561) and [26.3 support](https://github.com/EssentialsX/Essentials/pull/6624). The checklist labels this **EssentialsX (development fallback)**. CI downloads pin the successful build number before downloading, so a newer build cannot change the selected artifact mid-install. For 26.3, EssentialsX, BlueMap, ViaVersion, and ViaBackwards have compatible sources. FAWE and ProtocolLib remain unavailable until their upstreams publish verified compatible builds.

BlueMap installs the latest stable, exact-version platform artifact from its [official Modrinth project](https://modrinth.com/plugin/bluemap). On first start it creates `plugins/BlueMap/`; before rendering, set `accept-download: true` in `core.conf` only after accepting the stated Mojang download terms. Its integrated web server defaults to port `8100`, so assign a unique port in `webserver.conf` for every concurrently running BlueMap instance.

#### Adding entries to the checklist

Create `.multiplexor/addons.json` in the workspace. Entries are added alongside the bundled catalog and cannot reuse an existing ID. No code changes or recompilation are needed:

```json
{
  "addons": [
    {
      "id": "my-plugin",
      "name": "My Plugin",
      "fileName": "MyPlugin.jar",
      "description": "My local development plugin",
      "kind": "plugin",
      "serverTypes": ["paper", "purpur"],
      "source": {"type": "file", "path": "external/MyPlugin.jar"}
    },
    {
      "id": "fabric-api",
      "name": "Fabric API",
      "kind": "mod",
      "serverTypes": ["fabric"],
      "source": {"type": "modrinth", "project": "P7dR8mSH"}
    }
  ]
}
```

The required entry fields are `id`, `name`, `kind` (`plugin` or `mod`), `serverTypes`, and `source`. Optional `fileName` sets the installed basename and defaults to `<id>.jar`; it must be a plain jar filename, and two entries cannot target the same file. Optional `dependencies` lists other catalog IDs and installs them first; unknown or cyclic dependencies are rejected. Modrinth-required dependencies must have catalog entries and be declared in this list. Optional `filePrefixes` identifies equivalent jar names to replace inside the instance and skip during shared drop-in sync, for example `["MyPlugin-"]`. Matching requires a name boundary before a version/platform suffix, so `WorldEdit` does not match `WorldEditCUI`.

| Source type | Fields |
|-------------|--------|
| `modrinth` | `project`: project ID or slug; optional `versionId` pins an exact stable version and `loaders` overrides the ordered loader preferences for a verified universal jar. Chooses stable versions for the instance's Minecraft version. |
| `github` | `repo`: `owner/repo`; `asset`: exact jar filename; optional `tag` (defaults to `latest`) and `label` such as `development`. |
| `jenkins` | `url`: job URL; `artifactPattern`: regular expression matching exactly one published jar filename; optional `label`. Downloads from a numbered successful build. |
| `url` | `url`: direct HTTP(S) jar URL; optional `sha256` and `version`. |
| `file` | `path`: local jar, absolute or relative to the workspace. `addons update` recopies it. |

Each source can restrict `serverTypes` and `minecraftVersions` to exact lists. Use these for direct URLs, local jars, GitHub releases, and Jenkins builds whose compatibility is known; those providers do not publish standardized Minecraft compatibility metadata. An entry can use `sources: [...]` instead of `source`, tried in order. If Modrinth has no compatible stable release, resolution proceeds to the next matching source. Network errors, malformed metadata, and checksum failures stop installation. Bundled definitions live in `MultiplexorApp/lib/services/addons/builtin_addons.dart`; catalog validation, provider resolution, and installation are separate modules reused by the CLI and wizard.

### content — Modrinth/URL plugin and mod manager

Content and addons share release selection and artifact verification. Modrinth installation requires an explicit `--mc` or Minecraft metadata on the active instance. Selection retains the requested loader and exact Minecraft version; it never broadens the search to unrelated loaders. Downloads must be valid jars, and Modrinth downloads must match their upstream checksum.

Install, update, and remove stage file and lockfile changes before commit. A failed download or commit restores the previous files and manifest. A filename collision with unmanaged content is rejected.

| Command | What it does |
|---------|--------------|
| `content search <query>` | Search Modrinth for plugin content under the plugin consumer, or mod content under mod consumers. |
| `content install <modrinth-slug\|url> [--mc <v>] [--loader <loader>] [--name <alias>] [--file <filename.jar>] [--sync]` | Download a compatible Modrinth jar or direct jar URL into the active consumer's dropin source and record it in `content-lock.yaml`. |
| `content list` | List managed content entries. |
| `content update [name\|--all] [--sync]` | Re-download managed content, preserving recorded MC/loader compatibility. |
| `content remove <name>` | Remove the manifest entry and downloaded jar. |
| `content sync [instance\|--all] [--clean]` | Reuse the normal plugin/mod sync pipeline for managed and manually added jars. |

### doctor — workspace diagnostics

| Command | What it does |
|---------|--------------|
| `doctor` | Check workspace markers, consumer roots, active instances, key external tools (`dart`, `java`, `git`, `tmux`), duplicate configured ports, source metadata, and active-instance symlinks. Exits non-zero on hard failures. |
| `doctor --fix` | Recreate expected consumer directories and refresh active-instance links before checking. |
| `doctor --json` | Emit a machine-readable diagnostics payload. |

### build — fetch or compile server jars into the cache

| Command | What it does |
|---------|--------------|
| `build <type> [--mc <v>] [--loader <v>] [--installer <v>] [--force]` | Build or download a server jar. Refreshes from upstream every run, then prunes the builds it superseded. Without `--mc`, a platform that has no build for its newest advertised version falls back to the next-newest supported one (Folia trails Paper by a release, so this is its normal path). Spigot resolves the upstream Jenkins build first and reuses a matching cached jar instead of recompiling; if that lookup fails it compiles rather than trust a jar of unknown age, and `--force` runs BuildTools regardless. |
| `build latest <type>` | Print the latest supported MC version for `<type>`. |
| `build versions [type]` | Print all supported versions. |
| `build cache-info [type] [--mc <v>]` | Machine-readable jar-cache report: one `<type>\t<jar>\t<ageSeconds>` line per cached jar, newest first. Drives the wizard's automatic refresh decisions and its "builds updated" footer. |
| `build list` | Show what's in the active profile's cache. |
| `build list-all [type]` | Show cache contents across profiles. |
| `build test-latest [--spigot-mc <v>]` | Sanity-check the latest of every type with up to four concurrent builds, spigot included. `--spigot-mc` pins spigot to its own version, since it lags the others on a fresh Minecraft release. |
| `build prune [all\|type]` | Sweep every consumer's build cache: drop superseded jars and remove leftover BuildTools work directories. Builds prune themselves, so this is only needed to clean up history. |

Minecraft 26.3 uses the same provider discovery and download commands as earlier versions. Availability comes from each upstream; a new Minecraft release does not imply every platform has a build. NeoForge maps loader versions such as `26.3.0.7-beta` to Minecraft `26.3` and selects loaders for the exact game version. Explicit version requests and cache filters match the whole version, so `26.3` cannot select a `26.3.1` jar. Alpha and beta server builds can appear when those are the available upstream releases.

**Build caches keep one jar per Minecraft version.** Every successful build deletes the older builds of that same version, so upstream build-number churn stops accumulating. Two things are never pruned: a jar an instance still launches from (instances stay pinned to whatever they were created with until you update them), and the newest jar of every *other* Minecraft version — switching back to an older version still hits the cache instead of re-downloading or, for spigot, recompiling.

BuildTools uses the Java executable selected in consumer runtime settings and checks its compatibility before compiling. Its combined output is saved under the consumer's `state/build-logs/`; failures include the exit code, relevant output from both streams, and the log path. BuildTools work directories are roughly 700 MB of decompiled sources each and are only needed while a spigot compile runs. A successful compile removes its own; `build prune` clears any left behind by an interrupted one.

### repos — sync upstream version metadata

| Command | What it does |
|---------|--------------|
| `repos sync [all\|paper\|purpur\|folia\|canvas\|leaf]` | Clone or pull upstream repos used for version discovery, with up to four repos concurrently for `all`. Build commands resolve metadata over HTTP, so this is mostly used for Spigot/BuildTools. |

### config — per-instance config plumbing

| Command | What it does |
|---------|--------------|
| `config localize [instance\|--all]` | Convert shared-config symlinks into per-instance copies so local edits stick. |
| `config status [instance]` | Print which config files are symlinked vs localized. |

## Common Workflows

**Run a reproducible bot swarm**

```bash
./start.sh --consumer plugin server create swarm-qa --type paper --mc 1.21.11 --auto-build --isolated
./start.sh --consumer plugin gameplay swarm wander swarm-qa --bots 8 --duration 120 --seed 42 --prepare --start --stop-after
# Replace a bounded test area with workshop tiles, then exercise ordinary-player actions
./start.sh --consumer plugin gameplay swarm mixed swarm-qa --bots 4 --duration 60 --build-arena --origin 0,80,0 --start --stop-after
# Spread workers through the world and send scripted progress messages
./start.sh --consumer plugin gameplay swarm wander swarm-qa --bots 8 --scatter 128 --chat --start --stop-after
# Build the fixture, then run the bundled coordinated recipe
./start.sh --consumer plugin gameplay swarm idle swarm-qa --bots 4 --duration 1 --build-arena --origin 0,80,0 --start --stop-after
./start.sh --consumer plugin gameplay swarm MultiplexorApp/tool/mineflayer/plans/coordinated-demo.json swarm-qa --bots 4 --duration 60 --start --stop-after
```

**Run extended activity tests with bounds and goals**

```bash
# An eight-hour arena run with repeatable activity selection
./start.sh --consumer plugin gameplay swarm stress swarm-qa --bots 16 --duration 28800 --seed 42 --build-arena --origin 0,80,0 --start --stop-after
# Require completed work, stopping early once both goals pass
./start.sh --consumer plugin gameplay swarm stress swarm-qa --bots 8 --duration 7200 --build-arena --goals mine=1000,build=1000 --completion goals --start --stop-after
# Apply custom roles, pacing, load stages, and acceptance goals
./start.sh --consumer plugin gameplay swarm stress swarm-qa --bots 32 --duration 28800 --workload MultiplexorApp/tool/mineflayer/workloads/mixed-endurance.json --build-arena --start --stop-after
# Keep outdoor movement inside a coordinate box
./start.sh --consumer plugin gameplay swarm stress swarm-qa --bots 8 --duration 3600 --origin 0,80,0 --bounds -128,60,-128:128,120,128 --start --stop-after
```

Increase the isolated server's `max-players` before launch to cover every worker, the controller, and any observers. For long runs, use a persistent terminal session. Final reports and periodic checkpoints stay in the consumer's `state/gameplay-tests/<instance>` directory. World edits remain after the run.

**Run persistent cooperative sessions**

```bash
./start.sh --consumer plugin server create settlement-qa --type paper --mc 1.21.11 --auto-build --isolated
./start.sh --consumer plugin gameplay sessions start MultiplexorApp/tool/mineflayer/session-profiles/settlement-goals.json --instance settlement-qa --prepare --start --stop-after
# With Gloss installed, four ordinary players verify its version, walk a circle, and verify again.
./start.sh --consumer plugin gameplay sessions start MultiplexorApp/tool/mineflayer/session-profiles/plugin-circuits.json --instance settlement-qa --prepare --start --stop-after
# Use the printed run ID for these commands. Closing the wizard does not stop it.
./start.sh --consumer plugin gameplay sessions list
./start.sh --consumer plugin gameplay sessions status <run-id>
./start.sh --consumer plugin gameplay sessions stop <run-id>
./start.sh --consumer plugin gameplay sessions resume <run-id>
./start.sh --consumer plugin gameplay sessions report <run-id> --json
```

For proxy sessions, create isolated `lobby` and `survival` backends and use `network create session-lab --members lobby,survival --default lobby --offline`. Start [Velocity settlement](MultiplexorApp/tool/mineflayer/session-profiles/velocity-settlement.json) with `--network session-lab --start --stop-after`. Do not add `--prepare` to network runs.

**Connect two plugin servers with Velocity**

```bash
./start.sh --consumer plugin server create lobby --type paper --mc 1.21.11 --auto-build
./start.sh --consumer plugin server create survival --type paper --mc 1.21.11 --auto-build
./start.sh --consumer plugin network create dev --members lobby,survival --default lobby
./start.sh --consumer plugin network check dev
./start.sh --consumer plugin network start dev
./start.sh --consumer plugin network status dev
# Join localhost:25565, then use /server survival
./start.sh --consumer plugin network stop dev
```

To allow LAN players, stop the network and run `./start.sh --consumer plugin network configure dev --bind 0.0.0.0`. To return its servers to standalone use, run `./start.sh --consumer plugin network delete dev --confirm dev`. This stops the network and restores saved backend connection settings. To delete a server and its files, run `./start.sh --consumer plugin instance delete lobby`; its network membership and routes update automatically. `./start.sh instance delete-all --everywhere` wipes servers and cleans up their networks in one call, skipping PIN-locked instances.

**Pull, test locally, then push file changes**

```bash
# Stop Remote in the dashboard before pulling its files
./start.sh remote pull LEAF --as LEAF-local
./start.sh runtime start LEAF-local
# Make and test your changes, then stop Local before comparing files
./start.sh runtime stop LEAF-local --graceful
./start.sh remote push LEAF-local
# Review the diff, then repeat with the exact printed token
./start.sh remote push LEAF-local --confirm <token>
```

Update preserves Remote-only changes and uploads only the listed files. If a file changed on both sides, reconcile that file before retrying. Backups and verification still read Remote files; the displayed transfer byte count measures the upload payload.

**Windows consoles**

```powershell
.\multiplexor.exe runtime start demo --no-console
.\multiplexor.exe runtime consoles
```

The Local dashboard's `g` or `G` opens the same grid. Use `Shift+R` to repaint the dashboard or an open wizard menu.

```bash
# Update a downloaded Multiplexor executable
multiplexor update check
multiplexor update
multiplexor update auto on

# Create a paper server on the latest upstream version, refreshing the cache first
./start.sh server create lobby --type paper --auto-build

# Create a server, start it headless, then watch every instance live
./start.sh server create lobby --type paper --auto-build
./start.sh runtime start lobby --no-console
./start.sh runtime watch

# Snapshot the dashboard into a log from a script (no TTY, no escape bytes)
./start.sh runtime watch --once >> monitor.log

# Start or stop only these named Local servers (dashboard: check rows, then START/STOP)
./start.sh instance bulk start lobby survival --concurrency 4
./start.sh instance bulk stop lobby survival

# Preview deletion of only this set, then repeat with the printed exact token
./start.sh instance bulk delete lobby survival
# ./start.sh instance bulk delete lobby survival --confirm "DELETE lobby,survival"

# Create an isolated test server (won't pick up your dropins)
./start.sh server create vanilla-test --type purpur --isolated

# Later, copy selected drop-ins into it once without enabling shared sync
./start.sh plugins copy vanilla-test --artifact Spark.jar --artifact ViaVersion.jar

# Create a Leaf server (high-performance Paper fork) on the latest stable build
./start.sh server create leaf --type leaf --auto-build

# Create a Mohist hybrid that keeps both Forge mods and plugin dropins synced
./start.sh --consumer forge server create hybrid --type mohist --auto-build --mod-dropins --plugin-dropins

# Create plugin flavors in parallel with distinct ports at the same MC version
./start.sh server create-many --types paper,purpur,canvas,spigot --mc 1.21.11 --auto-build

# Wipe every instance across every consumer (asks for a double y/N confirmation)
./start.sh instance delete-all --everywhere

# Cache a Minecraft 26.3 server build
./start.sh --consumer plugin build paper --mc 26.3

# Test and promote an update with a restore point
./start.sh instance safe-update lobby --mc 1.21.11 --auto-build --promote

# Create a restore point before experimenting
./start.sh runtime stop lobby
./start.sh backup create lobby --label before-plugin-test

# Give one server its own Java and heap settings
./start.sh runtime settings set-java /absolute/path/to/java --instance lobby
./start.sh runtime settings set-heap 6G --instance lobby
./start.sh runtime settings check --instance lobby

# Install managed content from Modrinth, then sync it everywhere
./start.sh content search luckperms
./start.sh content install luckperms --mc 1.21.11 --sync

# Choose addons for this server; ViaBackwards also installs ViaVersion
./start.sh runtime stop lobby
./start.sh addons set lobby --select essentialsx,fawe,bluemap,viabackwards,protocollib
./start.sh addons list lobby
./start.sh runtime start lobby

# Refresh the checked addons while stopped, or uncheck all of them
./start.sh runtime stop lobby
./start.sh addons update lobby
./start.sh addons set lobby --none

# Run diagnostics when setup or runtime behavior looks suspicious
./start.sh doctor

# Inspect and monitor a Pterodactyl panel without mutating it
./start.sh remote verify
./start.sh remote list
./start.sh remote stats --all
./start.sh remote nodes
./start.sh remote console <server>

# Operate on an explicit remote fleet with bounded, visible results
./start.sh remote bulk start --all --state offline
./start.sh remote bulk restart lobby survival --concurrency 2
./start.sh remote create-many --template lobby --prefix event- --count 3 --concurrency 4

# Bootstrap the first server on an empty Pterodactyl panel
./start.sh remote catalog
./start.sh remote create survival --egg paper --memory 4096 --disk 0

# Pull Remote to a linked Local instance, then preview and confirm a safe push back
./start.sh remote stop survival
./start.sh remote pull survival --as survival-local --consumer plugin
./start.sh remote push survival-local --consumer plugin
# Repeat the printed command with its exact --confirm token

# Create a stopped Remote target, upload Local before its first start, then start it
./start.sh remote push survival-local --new survival-staging --egg paper --start --consumer plugin
# Repeat the printed command with its exact --confirm token
# survival-local keeps its existing link; add --link only to replace it

# Install one local drive containing every accessible Pterodactyl server
./start.sh remote drive install     # verify fingerprints, mount, open Finder
./start.sh remote drive status
./start.sh remote drive open <server>

# Install Mineflayer once, then run a self-cleaning player-protocol smoke test
./start.sh gameplay setup
./start.sh server create gameplay-qa --jar /absolute/path/paper-1.21.11.jar --type paper --isolated
./start.sh gameplay run connect gameplay-qa --prepare --start --stop-after

# Build an isolated arena, walk a measured circle, and exchange two-player damage
./start.sh gameplay run MultiplexorApp/tool/mineflayer/examples/circle-and-combat.mjs gameplay-qa --prepare --start --stop-after --timeout 180

# Try an update safely on staging before touching the original
./start.sh instance safe-update lobby --mc 1.21.11 --auto-build

# Lock a server so it can't be deleted or factory-reset (settings stay editable)
./start.sh instance lock lobby --pin 4827
# ...later, to allow destructive ops again
./start.sh instance unlock lobby --pin 4827

# Watch dropins and sync them into every non-isolated instance live
./start.sh plugins watch-start

# Switch profiles and start a mod server
./start.sh consumer use fabric
./start.sh server create modded --type fabric --mc 1.21.11 --auto-build
./start.sh runtime start modded
```

## Layout

```
consumers/<profile>/              # plugin-consumers, forge-mod-consumers, ...
  builds/<type>/                  # cached server jars
  backups/<instance>/              # restorable snapshots + manifest/checksums
  dropins/plugins or dropins/mods   # dropin jars (manual and content-managed)
  instances/<name>/                 # one server's worldroot
    .server-source                # type, launch mode, jar path, isolation/subscriptions
    .multiplexor-runtime.env       # per-instance Java/JVM/console overrides
    .multiplexor-remote.json      # durable link after pull, first new push, or --link
    .multiplexor-dropins.json     # last synchronized jar hashes
    .multiplexor-addons.json      # this instance's checked addons and jar hashes
    server.jar                    # symlink into builds/
    plugins/ or mods/             # Mohist can track both source kinds
  shared-plugin-data/             # plugin-only: iris packs + merged ops.json
  state/runtime/                  # tmux logs, pid files
  state/trends/                   # per-instance metric history for the monitor
  state/content-lock.yaml          # managed plugin/mod manifest
  state/gameplay-tests/             # ignored Mineflayer JSON reports
.multiplexor/addons.json            # optional custom checklist entries
.multiplexor/workspace.yaml         # workspace marker
.multiplexor/pterodactyl-profiles.yaml # non-secret remote panel metadata
.manager-state/pterodactyl/         # remote monitor trend history
MultiplexorApp/tool/mineflayer/      # pinned Mineflayer harness and scenarios
active-instance                   # symlink to the active instance
```

## Building from source

```bash
cd MultiplexorApp
dart pub get
dart analyze
dart test
dart run tool/build_exe.dart      # outputs ../multiplexor
```

Before pushing, also run the checks below from the repository root. The Dart suite does not run the Node harness or launcher tests. A failure in either blocks the GitHub release even when every executable compiles.

```bash
(cd MultiplexorApp/tool/mineflayer && npm ci --no-audit --no-fund && npm test && npm run doctor -- --json)
/bin/bash MultiplexorApp/tool/test_launcher.sh  # macOS
```

CI uses Dart 3.10.0 and Node 22, and checks macOS, Windows, and Linux. Local checks cover the current host; the GitHub matrix verifies the other platforms.

End-to-end testing always goes through the root entrypoint:

```bash
./start.sh <command>
```

On macOS, `./start.sh` builds the extensionless `multiplexor` executable and uses tmux for runtime consoles. If tmux is missing and Homebrew is available, the launcher runs `brew install tmux`. A failed compilation preserves the previous executable and removes the partial build. The Windows executable, PowerShell launcher, and MSYS tooling are not required on macOS.

Run `/bin/bash MultiplexorApp/tool/test_launcher.sh` from the repository root for isolated launcher regression checks. The tests use temporary tools and fixtures, including the Darwin startup path, without installing dependencies or starting Minecraft. CI runs this suite with macOS's `/bin/bash`, plus Mineflayer installation, tests, and diagnostics on both Apple Silicon and Intel macOS runners. The existing macOS executable builds and Dart tests remain enabled.

Windows PowerShell uses the native entrypoint:

```powershell
.\start.ps1 --version
.\start.ps1 gameplay doctor --json
.\start.ps1 --consumer plugin server create gameplay-qa --type paper --mc 1.21.11 --auto-build --isolated
.\start.ps1 --consumer plugin gameplay run connect gameplay-qa --prepare --start --stop-after --json
.\start.ps1 --consumer plugin instance delete gameplay-qa
```

If `dart` resolves to a Flutter launcher that stalls, use its cached `bin/cache/dart-sdk/bin/dart.exe` for the Dart development commands above. Both root launchers select it automatically. Run the harness unit tests from `MultiplexorApp/tool/mineflayer` with `npm ci`, then `npm test` and `npm run doctor`. `npm test` runs only `test/**/*_test.mjs`; local live-server probes are excluded.
