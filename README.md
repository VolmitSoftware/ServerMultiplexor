# Multiplexor

A Dart-native Minecraft server workspace manager. One workspace holds many server instances across four isolated **consumer profiles** (plugin, forge, fabric, neoforge), each with its own build cache, dropin folder, and instance store.

Everything is driven through `./start.sh` — either the interactive wizard (no args) or a direct CLI command. There is no separate build step: `start.sh` compiles `MultiplexorApp/` to the `multiplexor` binary whenever a `.dart` source, `pubspec.yaml`, or `pubspec.lock` is newer than the binary, then execs it. Unchanged sources skip straight to the binary. A failed compile leaves the previous binary in place and exits non-zero rather than running stale-but-working code silently. Set `MULTIPLEXOR_REBUILD=1` to force a recompile; everything `start.sh` itself prints goes to stderr, so stdout stays parseable.

Every branch push runs the executable workflow. It assigns the build a monotonically increasing semantic patch version, embeds that version in the CLI, and uploads versioned Apple Silicon macOS, Intel macOS, and Windows archives as GitHub Actions artifacts retained for 30 days. The checked-in version remains the release baseline, so CI never adds surprise commits to a branch. Tag pushes matching `v*` must match that baseline and continue to publish the archives as a GitHub Release.

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

`./start.sh runtime watch` opens the full-screen monitor; `./start.sh` with no args lands on the same screen. `Tab` switches between the Local workspace and the saved Pterodactyl Remote fleet. Local sweeps `runtime metrics` every two seconds. Remote uses Pterodactyl's resource API at a rate-aware interval of at least 20 seconds and automatically slows down for large panels. Both views keep per-server history seeded from their own trend stores so charts survive a restart. History is kept at full resolution for 24 hours, rolled up into five-minute means for a week, and dropped after that.

The landing view is a `MULTIPLEXOR` header, a KPI strip (`FLEET` servers-up and players, a fleet `TPS` sparkline, a `HOST` memory and CPU card), a full-width `SERVERS` table (state, players, TPS, a trend sparkline, memory, CPU and uptime per row — narrow terminals drop the rightmost readings whole), and a compact card for the selected server. The card is sized by the selection's own state: a running server expands into small side-by-side charts (TPS, CPU, memory as width allows) over a facts line, while a stopped one collapses to a single line and leaves the rows to the table. Under them sit two action bars — the selected server's, then the workspace's — over the key hint footer.

Everything on those bars is a button. Pressing lights a chip in the accent tone; a click activates on release, so a press that drifts onto another chip before it lifts does nothing. Chips that cannot apply — `RESTART` on a stopped server, `DELETE` on a locked one — are drawn faint and are not clickable at all. `START`, on the bar or on the card, is a background start: the dashboard stays up and watches the server come alive, and `CONSOLE` is one click away once it is running. The range badge on the selected panel (`running · 15m`) is a button too, and cycles the chart window.

Clicking a row in `SERVERS` selects it; clicking the selected row again opens its **card**, as do `enter` and `[ MORE ]`. `[ MORE ]` on the workspace bar, or `w`, opens the workspace card instead: build & tuning, pull builds, create many, start all, stop all, wipe. A card is modal — click a button to run it, click elsewhere on the card for nothing, click outside it or press `esc` to dismiss. Nothing behind a card is clickable while it is up.

Mouse support needs a terminal that reports SGR mouse events, which every current one does (Terminal.app, iTerm2, kitty, WezTerm, tmux, the VS Code terminal). The monitor uses click-only reporting (`?1000` with `?1006` SGR coordinates), so passive pointer movement does not repaint the screen. Reporting is turned off again on exit, so the terminal is left as it was found.

| Key | What it does |
|-----|--------------|
| `tab` | Switch between Local and Pterodactyl Remote fleets. |
| `↑` `↓`, wheel | Move the selection. The wheel outside the servers panel cycles the chart window instead. |
| `enter`, click | Open the selected server's card (a second click on the selected row, or `[ MORE ]`, does the same). |
| `d` | Detail screen for the selected server. |
| `R` `S` `X` `O` | Restart, stop (graceful), kill (force), open console — on the selected server. Uppercase on purpose, so a slipped key can never fire one. |
| `g` | Open every running console in a tmux grid. |
| `n` | Create a new instance. Isolated servers offer a checkbox list of drop-in artifacts, plus Select All and Deselect All controls, for one-time local copies. |
| `b` | Open Remote bulk actions, or Local Build & tuning. The remaining workspace actions live behind `[ MORE ]`. |
| `w` | Open the workspace card — the keyboard twin of `[ MORE ]` on the workspace bar. Landing view only. |
| `c` | Switch consumer profile (rebuilds the dashboard against the new one). |
| `r` | Cycle the chart window: `15m` → `1h` → `6h` → `24h` → `7d`. |
| `q`, `ctrl-c` | Quit. |

The detail screen (`d`) gives one server the whole frame: `TPS`, `CPU %`, `MEM MiB`, and `PLAYERS` charts over the same window, plus a live `LOG` tail of its runtime log. `esc` returns to the landing view; `esc` on the landing view quits. Below 80×24 the frame is replaced by a resize prompt rather than a squeezed layout.

`./start.sh runtime watch --once` prints a single frame to stdout and exits — colorless, zero escape bytes, no TTY required — so it is safe to pipe, log, or diff from a script.

## Interactive Wizard

`./start.sh` with no args lands on the live monitor above. Everything the monitor does not do itself it hands back to the wizard, on a suspended terminal, returning to the dashboard when the flow finishes or when you press Esc. Local keeps the existing state-aware server and workspace actions. Remote exposes permission-aware power, console, history, account, lifecycle, settings, creation, transfer, and Multiplexor Drive workflows. **Pull to Local** copies a Remote server into a new, stopped Local instance and links the pair. **Push to Remote** shows a file diff before it can update the linked server, another existing server, or a newly created stopped server. Remote creation can clone an existing configuration or build directly from a Panel egg, so a completely empty panel can create its first server. Its workspace card includes Create many and Bulk actions; `b` opens the bulk selector directly, with all/selected/running/stopped presets, per-server toggles, bounded execution, progress, and an outcome for every target. Suspended, installing, maintenance, unavailable, and otherwise non-runnable servers retain their rows but have mutating actions disabled. Mirror push, kill, reinstall, and delete default to no and require typed confirmation.

The Remote console has a persistent server/resource header, severity colors, safe Minecraft `§` formatting, prefix and routine-noise trimming, and batched history rendering. `Esc`, `Ctrl-C`, or `:exit` immediately restores the dashboard without stopping the server.

The Remote server menu's Open folder action repairs or starts Multiplexor Drive when needed, then opens that server's exact local folder in Finder.

The Remote connection card is the guided account surface. It can add, select, rename, repair, rotate, and remove multiple panel accounts. Multiplexor asks for the panel HTTPS origin once, accepts the key through masked terminal input, saves it in macOS Keychain, and verifies it before selecting the account. It never accepts an API key on the command line or writes one into profile state. Standard `ptlc_` and `ptla_` prefixes select the Client or Application role automatically. A root-admin Client key provides the one-key experience on current Pterodactyl releases; a separate Application key is only needed when the Client key cannot reach administrative routes. First-server/egg creation needs Servers read/write plus Users, Nodes, Allocations, Nests, and Eggs read access.

Remote cards show every configured advertised allocation and every bind allocation. DNS A/AAAA results are shown beside configured aliases when resolution succeeds. These are intentionally separate: Pterodactyl does not know an upstream NAT port mapping, so Multiplexor never guesses that a private bind address, node FQDN, and public game endpoint are interchangeable.

The workspace card (`[ MORE ]` on the workspace bar) holds the actions that are not per-instance: Build & tuning, Pull latest builds, Create many, Start all stopped, Stop all running, and Wipe everything. An isolated server's instance card includes **Copy drop-ins**, which opens the same per-artifact checklist for one-time local plugin or mod copies without subscribing the server to future syncs. Destructive prompts (wipe, delete, factory reset) default to no and show that default in red. In Build & tuning, JVM controls include heap, flag preset, console line wrap, and console log format.

Version refresh is automatic — the wizard never asks "refresh from upstream?". Platform and version pickers show when each build was last fetched (`updated 2h ago`, `cached 3d ago`), and a `builds` status footer on the platform picker and Build & tuning menus shows per-platform freshness at a glance. Creates and updates reuse a cached build when it is under 24 hours old and silently fetch a fresh one otherwise (or when nothing is cached). Spigot is the exception: an existing BuildTools jar is always reused no matter its age, since rebuilds take many minutes — force one with `build spigot --force`.

Pull latest builds refreshes the newest build of every platform the active consumer owns, spigot included. Spigot only runs BuildTools when its upstream Jenkins build is newer than the cached jar, so the bulk pull normally stays fast; any platform that fails is named in the summary line.

## Concepts

- **Consumer profile** — one of `plugin`, `forge`, `fabric`, `neoforge`. Each profile has its own instances, dropin sources, and build cache. They never share state. The active profile is set with `consumer use`.
- **Instance** — one server install inside a consumer. Lives at `consumers/<profile>/instances/<name>` (or under `~/.multiplexor/instance-store/...` if the workspace path contains `[` or `]`). Metadata is in `.server-source` (type, launch mode, jar path, isolated flag, and lock state + hashed PIN).
- **Active instance** — the default target when an instance name is omitted. Set with `instance activate`.
- **Dropins** — plugin or mod jars under `consumers/<profile>/dropins/plugins` or `consumers/<profile>/dropins/mods`. On `runtime start` and via the watcher, these jars are copied into every non-isolated instance's `plugins/` (or `mods/`) folder. Automatic sync tracks the last synchronized SHA-256 per instance: it updates untouched jars but preserves and warns about unknown or locally modified jars. An explicit `plugins sync` or `mods sync` remains authoritative and replaces them.
- **Isolated instance** — opts out of all shared state: no dropin sync, no Iris pack symlink, no shared `ops.json` merge. Created with `server create --isolated` or toggled later with `instance isolated <name> true`.
- **Shared plugin data** — `consumers/plugin-consumers/shared-plugin-data/` holds Iris packs and a merged `ops.json` for non-isolated plugin instances.
- **Build cache** — `consumers/<profile>/builds/<type>/` holds versioned server jars. `server create --type ...` resolves jars from here; `--auto-build` refreshes from upstream first.
- **Content lockfile** — `consumers/<profile>/state/content-lock.yaml` tracks jars installed by `content install` so they can be updated, removed, and re-synced through the existing dropin pipeline.
- **Template** — `.multiplexor/templates/<name>.yaml` captures a reusable server blueprint: server type/version, JVM settings, isolation, server.properties overrides, and optional dropin sync behavior.
- **Backup** — `consumers/<profile>/backups/<instance>/<backup-id>/` stores a restorable snapshot with checksums and a manifest. Backups are used manually and by `instance safe-update`.
- **Gameplay test** — a Mineflayer scenario run against an actual instance. Built-ins cover connection, command responses, and status effects; custom `.mjs` scenarios can assert any protocol-visible player behavior. Reports stay under ignored per-consumer state.
- **Remote profile** — non-secret Pterodactyl panel metadata in `.multiplexor/pterodactyl-profiles.yaml`. Client/Application bearer keys live in macOS Keychain under an exact profile+HTTPS-origin identity, never in the YAML file.
- **Remote link** — `.multiplexor-remote.json` inside a pulled, initially paired, or explicitly relinked Local instance records the exact remote account, immutable server identity, display name, Local consumer, and transfer timestamps. `remote push <local>` uses this identity instead of guessing from names.
- **Multiplexor Drive** — the local `~/Multiplexor Drive` folder containing one live folder for every accessible Pterodactyl server, grouped by remote account. Selecting Open folder for a remote server opens its folder here in Finder.

## CLI Reference

Every command is `./start.sh <namespace> <action> [args]`. Global flags: `--consumer <profile>` for a one-shot profile override, `--root <path>` for a different workspace, `--verbose` for arg-normalization debug output. Use `./start.sh help <command>` or `<command> --help` for focused command help.

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
| `remote history <server> [--since <15m\|6h\|7d>] [--limit <n>] [--json] [--profile <id>]` | Read persisted monitor samples without polling the panel. History keeps raw samples for 24 hours and five-minute rollups for seven days. |
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
| `remote start\|stop\|restart\|kill <server> [--profile <id>]` | Send a Pterodactyl power signal. |
| `remote bulk <start\|stop\|restart\|kill\|reinstall\|delete> [servers...] [--all] [--state running\|offline] [--concurrency <1-8>] [--confirm <token>] [--force] [--profile <id>]` | Safely operate on an explicit remote fleet. Every selector is resolved before mutation; state filters use live resource state (`running` includes transitional non-offline states), work is bounded, and every server receives an outcome. Reinstall/delete print the exact token required by `--confirm`. |
| `remote console <server> [--profile <id>]` | Attach to a severity-colored, prefix/noise-trimmed live console with server resource chrome and safe Minecraft `§` formatting. Esc, Ctrl-C, or `:exit` restores the caller without stopping the server. |
| `remote command <server> <command> [--profile <id>]` | Send one console command. |
| `remote pull <server> --as <local> [--profile <id>] [--consumer <profile>]` | Copy the transferable files of a stopped Remote server into a new, stopped Local instance and record its exact remote account/server link. Pull never changes the Remote, refuses a running Remote, and refuses to overwrite an existing Local instance. |
| `remote push <local> [--to <server>] [--mirror] [--link] [--start\|--no-restart] [--confirm <token>] [--profile <id>] [--consumer <profile>]` | Diff a stopped Local instance against its linked Remote, or the existing server selected by `--to`, then push changed/new files. Without `--confirm`, prints the exact token and exits without mutation. The default preserves remote-only files; `--mirror` deletes them and requires the stronger destructive token. A previously running target is stopped for the transfer and restarted after success unless `--no-restart`; `--start` starts a previously stopped target. `--link` records the selected target as the Local instance's new link. After committing files, an unverified explicit `--link` or `--start` outcome returns nonzero so the same idempotent workflow can repair it. |
| `remote push <local> --new <name> (--template <server>\|--egg <id\|name>) [creation flags] [--link] [--start] [--confirm <token>] [--profile <id>] [--consumer <profile>]` | Resolve and show the exact source UUID/egg ID, owner, node, image, startup, environment variable names (values are redacted), resources, features, final power state, and link action before creating anything. The composite confirmation token still binds every exact environment value, the complete creation plan, and the current Local snapshot. The durable intent identity does not change when Local files later change, so a freshly previewed and confirmed retry resumes the same created server instead of allocating another one. The server is created stopped, receives and validates Local files before its first start, then starts only with `--start`. An unlinked Local records the new pairing automatically; an already-linked Local preserves its existing target unless `--link` explicitly replaces it. A failed transfer leaves the new server stopped and prints the exact existing-target retry command. |
| `remote create <name> (--template <server>\|--egg <id\|name>) [--owner <id\|username\|email>] [--node <id\|name>] [--image <label\|value>] [--env <KEY=VALUE,...>] [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--databases <count>] [--allocations <count>] [--backups <count>] [--start] [--profile <id>]` | Create from an existing Application-visible configuration or directly from a Panel egg. Egg creation works on an empty panel, defaults to the connected owner and sole viable node, sends every egg-variable default, and requires explicit values for required blank variables. `--node`, `--image`, `--env`, `--swap`, `--io`, and feature-limit flags apply only to egg creation. |
| `remote create-many (--template <server>\|--egg <id\|name>) (--names <a,b,c>\|--prefix <name> --count <1-100>) [--owner <id\|username\|email>] [--node <id\|name>] [--image <label\|value>] [--env <KEY=VALUE,...>] [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--databases <count>] [--allocations <count>] [--backups <count>] [--start] [--concurrency <1-8>] [--profile <id>]` | Create several servers from one template or egg. Multiplexor validates the full plan and reserves distinct allocations before the first create request, bounds parallelism, and reports every result. The same egg-only flag restriction as `remote create` applies. |
| `remote rename <server> <name> [--description <text>] [--profile <id>]` | Rename or describe a server using Client permission first and Application fallback when enrolled. |
| `remote reinstall <server> --confirm <server> [--profile <id>]` | Request a reinstall through the least-privileged permitted route. The exact server value is required as confirmation. |
| `remote delete <server> --confirm <server> [--force] [--profile <id>]` | Permanently delete a server through the Application route with exact confirmation. |
| `remote variable <server> --key <variable> --value <value> [--profile <id>]` | Change an editable startup variable. |
| `remote image <server> --image <docker-image> [--profile <id>]` | Select an allowed Docker image when `startup.docker-image` is granted. |
| `remote limits <server> [--memory <MiB>] [--swap <MiB>] [--disk <MiB>] [--io <10-1000>] [--cpu <percent>] [--threads <set>\|--clear-threads] [--databases <count>] [--allocations <count>] [--backups <count>] [--allocation <id>] [--add-allocation <id,...>] [--remove-allocation <id,...>] [--oom-disabled\|--oom-enabled] [--profile <id>]` | Modify resource, feature, and allocation limits through the Application API while preserving unspecified values. |
| `remote startup <server> --command <command> [--profile <id>]` | Modify the administrative startup command while preserving the current egg, image, variables, and install-script policy. |

The active account is used when `--profile` is omitted; `--profile` remains available as a one-command override. `ptero` is an alias for `remote`.

Transfers carry worlds, server jars, plugins/mods, and normal configuration while excluding runtime-only `logs/`, `crash-reports/`, `session.lock`, and Multiplexor's own metadata. They reuse Multiplexor Drive account credentials but connect directly to only the selected server over SFTP; they never start or require the cached browsing mount or unrelated profiles. An interactive terminal can add a missing account and approve that target's displayed host fingerprint, while headless use exits with exact `remote drive install --profile ... --no-open` and target-scoped `remote drive trust <server> --profile ...` recovery commands. Push confirmation tokens bind the exact Local snapshot and the Remote overwrite/delete path scope; Create & Push additionally binds every resolved creation field, desired final state, and link decision. A changed input requires a fresh preview. Remote contents are re-read after the server stops, then every non-empty push snapshots the complete Remote tree under `.multiplexor/pterodactyl-transfers/backups/` before applying files, writes a recovery manifest, and rolls back automatically if the upload fails. Create & Push also writes a durable intent under `.multiplexor/pterodactyl-transfers/intents/` and assigns its unique ID as the Panel `external_id`. That stable identity binds the Local consumer and canonical instance path, profile, proposed server name, immutable creation configuration, and requested start/link postconditions, but not the changing file fingerprint. A newly confirmed current snapshot can therefore discover and resume the same committed server after an ambiguous create response, Local edits, or transfer failure. If only its requested durable link or final running state failed and Local is unchanged, the exact retry repairs those postconditions without uploading files again; changed Local files resume the normal diff and transfer against the same server. Ambiguous, duplicated, or mismatched identities stop without another Panel mutation. The CLI prints the relevant intent, backup, and recovery paths.

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
| `instance current` | Print the active instance name. |
| `instance create <name> [--isolated]` | Create a blank instance (no jar wired up). `--isolated` skips shared drop-ins, Iris packs, and plugin ops; Remote Pull uses this mode so copied servers cannot inherit unrelated Local shared state. |
| `instance clone <source> <target>` | Copy an instance verbatim, then re-wire shared links. |
| `instance activate <name>` | Make this instance the default target. |
| `instance path [name]` | Print the on-disk path. Active instance if omitted. |
| `instance open [name]` | Open the instance folder in the host file manager. |
| `instance update <name> [--mc <v>] [--jar <path>] [--auto-build] [--type <t>]` | Re-point `server.jar` at a new version. Stops the instance first. Preserves worlds, dropins, config, and the isolated flag. Jar-launch only — installer-based servers (Forge/NeoForge) must be recreated. |
| `instance safe-update <name> [--mc <v>] [--jar <path>] [--auto-build] [--type <t>] [--promote] [--cleanup] [--timeout <s>]` | Create a backup, clone the instance to staging on a free port, update staging, start it, and wait for a Minecraft ping. Without `--promote`, the original stays unchanged. With `--promote`, the original is updated after staging passes and can be restored from the backup on promotion failure. |
| `instance isolated [name] [true\|false]` | Read the flag (no value) or toggle it. Turning it off re-links shared Iris packs and merges shared ops. |
| `instance lock <name> [--pin <digits>]` | Lock the instance so it cannot be deleted or factory-reset. Prompts for a 4–12 digit PIN (or pass `--pin`). The PIN is stored salted+hashed in `.server-source` and survives factory reset. Settings stay editable. |
| `instance unlock <name> [--pin <digits>]` | Verify the PIN and unlock, re-enabling delete and factory reset. |
| `instance locked [name]` | Print `true`/`false` for the lock state. |
| `instance port [instance] [port]` | Read or set `server-port` in `server.properties`. |
| `instance motd-style [name]` | Apply the styled MOTD template (alias: `motd-style`). |
| `instance reset <name>` | Wipe worlds/config/plugins/mods/logs back to baseline. Keeps the launch artifacts and the isolated flag, and re-applies the styled MOTD for the server type. Refused while the instance is locked. |
| `instance delete <name>` | Delete the instance entirely (kills any running process first). Refused while the instance is locked. |
| `instance delete-all [--force]` | Delete every instance in the active profile. Asks for `DELETE` confirmation unless `--force`. Locked instances are skipped and left untouched. |
| `instance delete-all --everywhere [--force]` | Wipe every instance across plugin/forge/fabric/neoforge in one call. Asks for a double y/N confirmation unless `--force`. Locked instances are skipped. |

### server — first-time jar wiring

| Command | What it does |
|---------|--------------|
| `server create <name> --type <type> [--mc <v>] [--auto-build] [--isolated] [--artifact <dropin.jar> ...]` | Create + wire `server.jar` from the build cache (or refresh upstream first if `--auto-build`). `--isolated` opts the instance out of shared dropins/iris/ops; repeat `--artifact` to make one-time local copies from that consumer's drop-ins folder. |
| `server create <name> --jar <path> [--type label] [--isolated] [--artifact <dropin.jar> ...]` | Create + wire an explicit jar. Isolated instances can receive the same one-time selected artifact copies. |
| `server create-many --types <a,b,c> [--prefix N] [--mc <v>] [--auto-build] [--isolated]` | Spin up one instance per type in a single call. Each instance is named after its type (or `<prefix>-<type>` if `--prefix` is set) and routed to the correct consumer (plugin types → plugin profile, modded types → their own). Skips collisions and resolution failures without aborting the batch. |

Single `server create` and `build <type>` commands must run under the consumer that owns the selected server type. Use `--consumer fabric`, `--consumer forge`, or `--consumer neoforge` for modded types; plugin-family types use `plugin`. `server create-many` remains the cross-consumer batch command.

`<type>` is one of: `paper`, `purpur`, `folia`, `canvas`, `leaf`, `spigot`, `forge`, `fabric`, `neoforge`. `leaf` is a high-performance Paper fork and behaves like any other plugin-family type. For `forge` / `neoforge`, an installer jar triggers args-file launch mode automatically.

### runtime — start, stop, attach

macOS/Linux runtimes use named `tmux` sessions. Windows uses a native background host built into `multiplexor.exe`, so the release executable does not require Git Bash, `sh`, `chmod`, or `tmux`. Runtime output is captured under `consumers/<profile>/state/runtime/<instance>.log`; the Minecraft server also writes `logs/latest.log` inside its instance. Windows start/stop/status, watchers, and `/restart` are supported, while interactive and combined console attachment remain tmux-only.

| Command | What it does |
|---------|--------------|
| `runtime watch [--once]` | Open the [live monitor](#live-monitor): full-screen charts over every instance, clickable action bars, and the wizard's flows behind the cards and `n` / `b` / `c`. `--once` sweeps metrics once, prints a single colorless frame to stdout, and exits — no TTY needed and no escape bytes, so it pipes and diffs cleanly. |
| `runtime start [instance] [--no-console]` | Safely sync dropins and start the instance. On macOS/Linux it attaches the tmux console unless `--no-console`; Windows starts the native background host and prints its log paths. Locally modified instance jars are preserved with a warning. |
| `runtime stop [instance] [--graceful]` | Force-stop the tracked runtime immediately. With `--graceful`, sends `stop` through tmux on macOS/Linux or RCON on Windows, waits up to 60s for a clean world-save shutdown, then force-stops on timeout. |
| `runtime restart [instance] [--no-console]` | Stop and start again. Attaches the tmux console on macOS/Linux unless `--no-console`; Windows prints the background runtime's log paths. |
| `runtime console [instance]` | Attach to a tmux console on macOS/Linux. On Windows, ensure the background runtime is started and print its server and Multiplexor log paths. |
| `runtime consoles` | Open every running console in a tmux grid on macOS/Linux; list Windows runtime log paths. |
| `runtime consoles-lateral` | Open every running console side-by-side on macOS/Linux; list Windows runtime log paths. |
| `runtime status [instance]` | Print the runtime state of one instance. |
| `runtime stats [instance]` | Show live stats for running servers: player count (`online/max`), state, CPU, memory, uptime, port, and version, plus the names of online players. With no instance, scans every consumer for running servers; with an instance, reports that one. Player counts come from a Server List Ping, so neither `enable-query` nor `enable-rcon` is required. `CPU` (`4.2%`) and `MEM` (resident set, e.g. `2.4G`) come from a single batched `ps` over the tracked server pids; `CPU`, `MEM`, and `UPTIME` read `n/a` when the value is unavailable rather than showing a zero. |
| `runtime states` | Print one line per instance: `name<TAB>state<TAB>port<TAB>pid<TAB>locked<TAB>isolated`. State is `stopped` / `starting` / `running` / `stopping` / `restarting`; the final two columns are `locked`/`unlocked` and `isolated`/`shared`. |
| `runtime metrics` | Print one line per instance: `name<TAB>state<TAB>port<TAB>locked<TAB>players<TAB>max<TAB>version<TAB>tps<TAB>isolated<TAB>uptimeSeconds<TAB>cpuPercent<TAB>rssBytes<TAB>logPath<TAB>latencyMs`. Running servers are pinged (and RCON-queried for TPS) concurrently. Every sweep of the [live monitor](#live-monitor) is one of these. TPS is `-` unless the server is Paper-family and was started with RCON enabled. The last five columns extend the row for monitoring: `uptimeSeconds` is whole seconds since the tmux session started, `cpuPercent` and `rssBytes` (resident set, bytes) come from one batched `ps` over the tracked server pids, `logPath` is the absolute path of the instance's runtime log, and `latencyMs` is the server-list-ping round trip in whole milliseconds. Note that `cpuPercent` is BSD `ps %cpu` — a lifetime average over the process's whole run, not an instantaneous load reading. Any unavailable value is `-`, never a zero. Columns are only ever appended, so a reader written against a shorter row keeps working. |
| `runtime list` | Print running instance names. |
| `runtime settings show` | Print the active heap, JVM preset, and flags. |
| `runtime settings presets` | List available JVM presets (`aikar`, `vanilla`, `conservative`). |
| `runtime settings set-heap <2G\|4G\|...>` | Set JVM `-Xmx`. |
| `runtime settings set-preset <name>` | Apply a JVM preset's flags. |
| `runtime settings set-wrap <on\|off>` | Toggle tmux console line wrap on macOS/Linux. Default `off` (long server lines clip at the pane edge instead of wrapping). Takes effect on next `runtime start`. **The `logs/latest.log` file is unaffected** — wrapping is purely a terminal-renderer concern. |
| `runtime settings set-log-format <minimal\|default>` | Toggle the console log pattern. Default `minimal` — strips the `[HH:mm:ss INFO]` prefix from the console only, and filters out the `RCON Client … started` / `… shutting down` lines the manager's live TPS polling triggers (from both the console and `logs/latest.log`). `default` restores the server's bundled Log4j pattern (RCON lines reappear). **The `logs/latest.log` file always keeps the full timestamped pattern.** Takes effect on next `runtime start`. |
| `runtime settings reset` | Restore default runtime settings. |

Paper/Spigot/Purpur `/restart` is wired to a per-instance `multiplexor-restart.sh` on macOS/Linux or `multiplexor-restart.cmd` on Windows, so `/restart` re-enters Multiplexor instead of exiting permanently. While that script waits, the instance reports `restarting`.

### gameplay — Mineflayer player-protocol QA

The harness is pinned under `MultiplexorApp/tool/mineflayer/`; `gameplay setup` installs it locally with npm. Offline bots are restricted to stopped, isolated instances: `gameplay prepare` binds the server to loopback, disables online authentication and whitelisting, and removes spawn protection. It never weakens a shared instance. `--start` starts a stopped target, while `--stop-after` only stops an instance that the gameplay command itself started.

Every gameplay run starts a first-person Prismarine web feed on a free loopback port. The reachable URL is printed as soon as the feed is ready, included under `viewer.url` in the JSON report, and written immediately to `state/gameplay-tests/<instance>/viewer-<port>.json`; the state file changes from `active` to `closed` when the run ends. Use `--viewer-port <port>` when a stable port is useful or `--no-viewer` only when the feed is intentionally unnecessary.

| Command | What it does |
|---------|--------------|
| `gameplay setup` | Install the pinned Mineflayer, pathfinder, and Prismarine Viewer dependencies with `npm ci`. |
| `gameplay doctor [--json]` | Verify Node and the pinned gameplay dependency versions. |
| `gameplay list [--json]` | List built-in scenarios. |
| `gameplay prepare [instance]` | Prepare a stopped, isolated instance for loopback-only offline bot authentication. |
| `gameplay run <scenario> [instance] [flags]` | Run a built-in name or `.mjs` scenario. Supports `--prepare`, `--start`, `--stop-after`, `--username`, `--timeout`, `--command`, `--expect`, `--effect`, `--viewer-port`, `--no-viewer`, `--no-op`, and `--json`. |

The built-in `connect` scenario validates login, spawn, position, health, and connection stability. `command` requires `--command` plus an `--expect` regular expression. `effect` optionally runs `--command` and requires the named `--effect`. Custom modules default-export `{ name, description, async run(context) }`; the context supplies `bot`, `step`, `expect`, `command`, `waitForEvent`, `waitForMessage`, `sleep`, server metadata, and a safe-by-default pathfinder configuration.

The harness pins [Mineflayer commit `aa8fdfaf`](https://github.com/PrismarineJS/mineflayer/commit/aa8fdfaf42d48f0be9d8fbde45eafd40fde4d134), which identifies itself as version 4.37.1 and requires Node 22+. It supports vanilla Java protocols through 26.1. Minecraft 26.2 is outside its tested protocol range. Gameplay results prove protocol-visible behavior, not client rendering, resource packs, sound, camera behavior, client mods, or human feel.

### plugins / mods — dropin sources & sync

The two namespaces are mirrors. Use `plugins` when the active consumer is `plugin`; use `mods` for any of the mod consumers. Both refuse the wrong consumer.

| Command | What it does |
|---------|--------------|
| `plugins show-source` (or `mods show-source`) | Print the absolute dropin folder. |
| `plugins sync [instance\|--all] [--clean]` | Authoritatively copy dropins into one instance or every instance, replacing same-name local jars. `--clean` clears existing jars first. Isolated instances are skipped with `[SKIP]`. |
| `plugins copy <isolated-instance> --artifact <dropin.jar> [...]` | Copy only the selected drop-in jars into an existing isolated instance without subscribing it to automatic sync. The `mods` form behaves the same way for mod consumers. |
| `plugins watch-start` | Start a background daemon that re-syncs whenever a dropin jar changes. Untouched previously synchronized jars update automatically; locally modified jars are preserved with a warning. |
| `plugins watch-stop` | Stop the watcher daemon. |
| `plugins watch-status` | Print whether the watcher is running. |
| `plugins iris-packs-path` | Print the shared Iris packs directory (`plugin` consumer only). |
| `plugins iris-packs-link [instance\|--all]` | Symlink the shared Iris packs into an instance's `plugins/iris/packs`. Isolated instances are skipped. |

### backup — restorable instance snapshots

| Command | What it does |
|---------|--------------|
| `backup create [instance] [--label <label>] [--include-logs]` | Snapshot an instance into `consumers/<profile>/backups/<instance>/...`. Active instance if omitted. Logs are skipped unless `--include-logs`. |
| `backup list [instance\|--all]` | List backups in the active consumer. |
| `backup restore [instance] <backup-id>` | Stop the target if needed, verify checksums, and replace the instance with the snapshot. Refused if the target is locked. |
| `backup verify [instance] <backup-id>` | Verify the backup manifest and file checksums. |
| `backup delete [instance] <backup-id>` | Delete one backup. |
| `backup prune [instance] [--keep <n>]` | Keep the newest `n` backups per instance and delete older ones. Default `10`. |

### template — reusable server blueprints

| Command | What it does |
|---------|--------------|
| `template list` | List templates under `.multiplexor/templates/`. |
| `template init <name> [--type <type>] [--mc <v>] [--heap <size>] [--preset <name>] [--isolated]` | Write a starter YAML template. |
| `template show <name>` | Print the YAML template. |
| `template apply <template> <instance> [--auto-build] [--sync]` | Create an instance from a template, apply server.properties overrides, apply runtime heap/preset settings, and optionally sync dropins. |
| `template export <instance> <template>` | Create a template from an existing instance's source metadata, runtime settings, isolation flag, and `server.properties`. |
| `template delete <name>` | Delete a template file. |

### content — Modrinth/URL plugin and mod manager

| Command | What it does |
|---------|--------------|
| `content search <query>` | Search Modrinth for plugin content under the plugin consumer, or mod content under mod consumers. |
| `content install <modrinth-slug\|url> [--mc <v>] [--loader <loader>] [--name <alias>] [--sync]` | Download a compatible Modrinth jar or direct jar URL into the active consumer's dropin source and record it in `content-lock.yaml`. |
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
| `build test-latest [--spigot-mc <v>]` | Sanity-check the latest of every type, spigot included. `--spigot-mc` pins spigot to its own version, since it lags the others on a fresh Minecraft release. |
| `build prune [all\|type]` | Sweep every consumer's build cache: drop superseded jars and remove leftover BuildTools work directories. Builds prune themselves, so this is only needed to clean up history. |

**Build caches keep one jar per Minecraft version.** Every successful build deletes the older builds of that same version, so upstream build-number churn stops accumulating. Two things are never pruned: a jar an instance still launches from (instances stay pinned to whatever they were created with until you update them), and the newest jar of every *other* Minecraft version — switching back to an older version still hits the cache instead of re-downloading or, for spigot, recompiling.

BuildTools work directories are roughly 700 MB of decompiled sources each and are only needed while a spigot compile runs. A successful compile removes its own; `build prune` clears any left behind by an interrupted one.

### repos — sync upstream version metadata

| Command | What it does |
|---------|--------------|
| `repos sync [all\|paper\|purpur\|folia\|canvas\|leaf]` | Clone or pull upstream repos used for version discovery. Build commands resolve metadata over HTTP, so this is mostly used for Spigot/BuildTools. |

### config — per-instance config plumbing

| Command | What it does |
|---------|--------------|
| `config localize [instance\|--all]` | Convert shared-config symlinks into per-instance copies so local edits stick. |
| `config status [instance]` | Print which config files are symlinked vs localized. |

## Common Workflows

```bash
# Create a paper server on the latest upstream version, refreshing the cache first
./start.sh server create lobby --type paper --auto-build

# Create a server, start it headless, then watch every instance live
./start.sh server create lobby --type paper --auto-build
./start.sh runtime start lobby --no-console
./start.sh runtime watch

# Snapshot the dashboard into a log from a script (no TTY, no escape bytes)
./start.sh runtime watch --once >> monitor.log

# Create an isolated test server (won't pick up your dropins)
./start.sh server create vanilla-test --type purpur --isolated

# Later, copy selected drop-ins into it once without enabling shared sync
./start.sh plugins copy vanilla-test --artifact Spark.jar --artifact ViaVersion.jar

# Create a Leaf server (high-performance Paper fork) on the latest stable build
./start.sh server create leaf --type leaf --auto-build

# Spin up one of every plugin flavor at the same MC version
./start.sh server create-many --types paper,purpur,canvas,spigot --mc 1.21.11 --auto-build

# Wipe every instance across every consumer (asks for a double y/N confirmation)
./start.sh instance delete-all --everywhere

# Update an existing server to a new MC version (worlds may not survive)
./start.sh runtime stop lobby
./start.sh instance update lobby --mc 1.21.11 --auto-build
./start.sh runtime start lobby

# Create a restore point before experimenting
./start.sh backup create lobby --label before-plugin-test

# Apply a reusable server blueprint
./start.sh template init purpur-dev --type purpur --heap 6G --preset aikar
./start.sh template apply purpur-dev dev-lobby --auto-build --sync

# Install managed content from Modrinth, then sync it everywhere
./start.sh content search luckperms
./start.sh content install luckperms --mc 1.21.11 --sync

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
./start.sh remote create-many --template lobby --prefix event- --count 3

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
    .server-source                # type, launch mode, jar path, isolated flag
    .multiplexor-remote.json      # durable link after pull, first new push, or --link
    .multiplexor-dropins.json     # last synchronized jar hashes
    server.jar                    # symlink into builds/
    plugins/ or mods/             # synced from dropin-source
  shared-plugin-data/             # plugin-only: iris packs + merged ops.json
  state/runtime/                  # tmux logs, pid files
  state/trends/                   # per-instance metric history for the monitor
  state/content-lock.yaml          # managed plugin/mod manifest
  state/gameplay-tests/             # ignored Mineflayer JSON reports
.multiplexor/templates/             # reusable server blueprints
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

End-to-end testing always goes through the root entrypoint:

```bash
./start.sh <command>
```
