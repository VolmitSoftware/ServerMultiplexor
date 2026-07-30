# Multiplexor

A Dart-native Minecraft server workspace manager. One workspace holds many server instances across four isolated **consumer profiles** (plugin, forge, fabric, neoforge), each with its own build cache, dropin folder, and instance store.

Everything is driven through `./start.sh` — either the interactive wizard (no args) or a direct CLI command. There is no separate build step: `start.sh` compiles `MultiplexorApp/` to the `multiplexor` binary whenever a `.dart` source, `pubspec.yaml`, or `pubspec.lock` is newer than the binary, then execs it. Unchanged sources skip straight to the binary. A failed compile leaves the previous binary in place and exits non-zero rather than running stale-but-working code silently. Set `MULTIPLEXOR_REBUILD=1` to force a recompile; everything `start.sh` itself prints goes to stderr, so stdout stays parseable.

## Requirements

- `dart` 3.10+ (`./start.sh` compiles `MultiplexorApp/` on demand)
- `java` 17+ (or whatever your target server requires)
- `git`, `tmux` (tmux is required for `runtime start` / `runtime console`)

## Quick Start

```bash
./start.sh                                          # interactive wizard
./start.sh consumer use plugin                      # pick a consumer profile
./start.sh server create demo --type purpur --auto-build
./start.sh runtime start demo                       # starts and attaches console
./start.sh runtime watch                            # live monitoring dashboard
```

## Live monitor

`./start.sh runtime watch` opens the full-screen monitor; `./start.sh` with no args lands on the same screen. It sweeps `runtime metrics` every two seconds and keeps a per-instance ring of players, TPS, CPU, and memory, seeded at startup from `consumers/<profile>/state/trends/` so the charts survive a restart. The frame is a `MULTIPLEXOR` header, a `SERVERS` panel with one live row per instance, and — on a tall enough terminal — a TPS chart and a host card for the selected server.

| Key | What it does |
|-----|--------------|
| `↑` `↓`, wheel | Move the selection. The wheel outside the servers panel cycles the chart window instead. |
| `enter`, click | Open the selected server's action menu (a second click on the selected row does the same). |
| `d` | Detail screen for the selected server. |
| `R` `S` `X` `O` | Restart, stop (graceful), kill (force), open console — on the selected server. Uppercase on purpose, so a slipped key can never fire one. |
| `g` | Open every running console in a tmux grid. |
| `n` | Create a new instance. |
| `b` | Workspace menu: build & tuning, pull latest builds, create many, start all stopped, stop all running, wipe everything. |
| `c` | Switch consumer profile (rebuilds the dashboard against the new one). |
| `r` | Cycle the chart window: `15m` → `1h` → `6h` → `24h`. |
| `q`, `ctrl-c` | Quit. |

The detail screen (`d`) gives one server the whole frame: `TPS`, `CPU %`, `MEM MiB`, and `PLAYERS` charts over the same window, plus a live `LOG` tail of its runtime log. `esc` returns to the landing view; `esc` on the landing view quits. Below 80×24 the frame is replaced by a resize prompt rather than a squeezed layout.

`./start.sh runtime watch --once` prints a single frame to stdout and exits — colorless, zero escape bytes, no TTY required — so it is safe to pipe, log, or diff from a script.

## Interactive Wizard

`./start.sh` with no args lands on the live monitor above. Everything the monitor does not do itself it hands back to the wizard, on a suspended terminal, returning to the dashboard when the flow finishes or when you press Esc: Enter opens a server's state-aware action menu (console/restart/stop while running; start/update/reset/delete while stopped; activate/port/MOTD/open-folder/toggle-isolation/lock-or-unlock always), `n` runs the create flow, `b` opens the workspace menu, `c` switches consumer. Delete and factory reset are hidden while an instance is locked. Keys pressed while a build or sync runs are discarded. Without a TTY the wizard prints direct-command hints instead.

The workspace menu (`b`) holds the actions that are not per-instance: Build & tuning, Pull latest builds, Create many, Start all stopped, Stop all running, and Wipe everything. Destructive actions (wipe, delete, factory reset) are shown in red. In Build & tuning, JVM controls include heap, flag preset, console line wrap, and console log format.

Version refresh is automatic — the wizard never asks "refresh from upstream?". Platform and version pickers show when each build was last fetched (`updated 2h ago`, `cached 3d ago`), and a `builds` status footer on the platform picker and Build & tuning menus shows per-platform freshness at a glance. Creates and updates reuse a cached build when it is under 24 hours old and silently fetch a fresh one otherwise (or when nothing is cached). Spigot is the exception: an existing BuildTools jar is always reused no matter its age, since rebuilds take many minutes — force one with `build spigot --force`.

Pull latest builds refreshes the newest build of every platform the active consumer owns, spigot included. Spigot only runs BuildTools when its upstream Jenkins build is newer than the cached jar, so the bulk pull normally stays fast; any platform that fails is named in the summary line.

## Concepts

- **Consumer profile** — one of `plugin`, `forge`, `fabric`, `neoforge`. Each profile has its own instances, dropin sources, and build cache. They never share state. The active profile is set with `consumer use`.
- **Instance** — one server install inside a consumer. Lives at `consumers/<profile>/instances/<name>` (or under `~/.multiplexor/instance-store/...` if the workspace path contains `[` or `]`). Metadata is in `.server-source` (type, launch mode, jar path, isolated flag, and lock state + hashed PIN).
- **Active instance** — the default target when an instance name is omitted. Set with `instance activate`.
- **Dropins** — plugin or mod jars under `consumers/<profile>/dropins/plugins` or `consumers/<profile>/dropins/mods`. On `runtime start` and via the watcher, these jars are copied into every non-isolated instance's `plugins/` (or `mods/`) folder.
- **Isolated instance** — opts out of all shared state: no dropin sync, no Iris pack symlink, no shared `ops.json` merge. Created with `server create --isolated` or toggled later with `instance isolated <name> true`.
- **Shared plugin data** — `consumers/plugin-consumers/shared-plugin-data/` holds Iris packs and a merged `ops.json` for non-isolated plugin instances.
- **Build cache** — `consumers/<profile>/builds/<type>/` holds versioned server jars. `server create --type ...` resolves jars from here; `--auto-build` refreshes from upstream first.
- **Content lockfile** — `consumers/<profile>/state/content-lock.yaml` tracks jars installed by `content install` so they can be updated, removed, and re-synced through the existing dropin pipeline.
- **Template** — `.multiplexor/templates/<name>.yaml` captures a reusable server blueprint: server type/version, JVM settings, isolation, server.properties overrides, and optional dropin sync behavior.
- **Backup** — `consumers/<profile>/backups/<instance>/<backup-id>/` stores a restorable snapshot with checksums and a manifest. Backups are used manually and by `instance safe-update`.

## CLI Reference

Every command is `./start.sh <namespace> <action> [args]`. Global flags: `--consumer <profile>` for a one-shot profile override, `--root <path>` for a different workspace, `--verbose` for arg-normalization debug output. Use `./start.sh help <command>` or `<command> --help` for focused command help.

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
| `instance create <name>` | Create a blank instance (no jar wired up). |
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
| `server create <name> --type <type> [--mc <v>] [--auto-build] [--isolated]` | Create + wire `server.jar` from the build cache (or refresh upstream first if `--auto-build`). `--isolated` opts the instance out of shared dropins/iris/ops. |
| `server create <name> --jar <path> [--type label] [--isolated]` | Create + wire an explicit jar. |
| `server create-many --types <a,b,c> [--prefix N] [--mc <v>] [--auto-build] [--isolated]` | Spin up one instance per type in a single call. Each instance is named after its type (or `<prefix>-<type>` if `--prefix` is set) and routed to the correct consumer (plugin types → plugin profile, modded types → their own). Skips collisions and resolution failures without aborting the batch. |

Single `server create` and `build <type>` commands must run under the consumer that owns the selected server type. Use `--consumer fabric`, `--consumer forge`, or `--consumer neoforge` for modded types; plugin-family types use `plugin`. `server create-many` remains the cross-consumer batch command.

`<type>` is one of: `paper`, `purpur`, `folia`, `canvas`, `leaf`, `spigot`, `forge`, `fabric`, `neoforge`. `leaf` is a high-performance Paper fork and behaves like any other plugin-family type. For `forge` / `neoforge`, an installer jar triggers args-file launch mode automatically.

### runtime — start, stop, attach

`tmux` is required. Every session is named after the consumer + instance and logs to `consumers/<profile>/state/runtime/<instance>.log`.

| Command | What it does |
|---------|--------------|
| `runtime watch [--once]` | Open the [live monitor](#live-monitor): full-screen charts over every instance, with the wizard's flows behind `enter` / `n` / `b` / `c`. `--once` sweeps metrics once, prints a single colorless frame to stdout, and exits — no TTY needed and no escape bytes, so it pipes and diffs cleanly. |
| `runtime start [instance] [--no-console]` | Start the instance and attach its console. `--no-console` returns immediately. |
| `runtime stop [instance] [--graceful]` | Force-stop the instance immediately (kills the tmux session, then SIGTERM/SIGKILL any tracked pids). With `--graceful`, sends `stop` to the server console and waits up to 60s for a clean world-save shutdown, falling back to a force-stop on timeout. |
| `runtime restart [instance] [--no-console]` | Stop and start again. Attaches console unless `--no-console`. |
| `runtime console [instance]` | Attach to a running console. Esc detaches; the server keeps running. Mouse wheel scrolls; drag-select copies to clipboard. |
| `runtime consoles` | Open every running console in a tmux grid. |
| `runtime consoles-lateral` | Open every running console side-by-side. |
| `runtime status [instance]` | Print the runtime state of one instance. |
| `runtime stats [instance]` | Show live stats for running servers: player count (`online/max`), state, CPU, memory, uptime, port, and version, plus the names of online players. With no instance, scans every consumer for running servers; with an instance, reports that one. Player counts come from a Server List Ping, so neither `enable-query` nor `enable-rcon` is required. `CPU` (`4.2%`) and `MEM` (resident set, e.g. `2.4G`) come from a single batched `ps` over the tracked server pids; `CPU`, `MEM`, and `UPTIME` read `n/a` when the value is unavailable rather than showing a zero. |
| `runtime states` | Print one line per instance: `name<TAB>state<TAB>port<TAB>pid<TAB>locked<TAB>isolated`. State is `stopped` / `starting` / `running` / `stopping` / `restarting`; the final two columns are `locked`/`unlocked` and `isolated`/`shared`. |
| `runtime metrics` | Print one line per instance: `name<TAB>state<TAB>port<TAB>locked<TAB>players<TAB>max<TAB>version<TAB>tps<TAB>isolated<TAB>uptimeSeconds<TAB>cpuPercent<TAB>rssBytes<TAB>logPath<TAB>latencyMs`. Running servers are pinged (and RCON-queried for TPS) concurrently. Every sweep of the [live monitor](#live-monitor) is one of these. TPS is `-` unless the server is Paper-family and was started with RCON enabled. The last five columns extend the row for monitoring: `uptimeSeconds` is whole seconds since the tmux session started, `cpuPercent` and `rssBytes` (resident set, bytes) come from one batched `ps` over the tracked server pids, `logPath` is the absolute path of the instance's runtime log, and `latencyMs` is the server-list-ping round trip in whole milliseconds. Note that `cpuPercent` is BSD `ps %cpu` — a lifetime average over the process's whole run, not an instantaneous load reading. Any unavailable value is `-`, never a zero. Columns are only ever appended, so a reader written against a shorter row keeps working. |
| `runtime list` | Print running instance names. |
| `runtime settings show` | Print the active heap, JVM preset, and flags. |
| `runtime settings presets` | List available JVM presets (`aikar`, `vanilla`, `conservative`). |
| `runtime settings set-heap <2G\|4G\|...>` | Set JVM `-Xmx`. |
| `runtime settings set-preset <name>` | Apply a JVM preset's flags. |
| `runtime settings set-wrap <on\|off>` | Toggle tmux console line wrap. Default `off` (long server lines clip at the pane edge instead of wrapping). Takes effect on next `runtime start`. **The `logs/latest.log` file is unaffected** — wrapping is purely a terminal-renderer concern. |
| `runtime settings set-log-format <minimal\|default>` | Toggle the console log pattern. Default `minimal` — strips the `[HH:mm:ss INFO]` prefix from the console only, and filters out the `RCON Client … started` / `… shutting down` lines the manager's live TPS polling triggers (from both the console and `logs/latest.log`). `default` restores the server's bundled Log4j pattern (RCON lines reappear). **The `logs/latest.log` file always keeps the full timestamped pattern.** Takes effect on next `runtime start`. |
| `runtime settings reset` | Restore default runtime settings. |

Paper/Spigot/Purpur `/restart` is wired to a per-instance `multiplexor-restart.sh`, so `/restart` re-enters Multiplexor instead of exiting permanently. While that script waits, the instance reports `restarting`.

### plugins / mods — dropin sources & sync

The two namespaces are mirrors. Use `plugins` when the active consumer is `plugin`; use `mods` for any of the mod consumers. Both refuse the wrong consumer.

| Command | What it does |
|---------|--------------|
| `plugins show-source` (or `mods show-source`) | Print the absolute dropin folder. |
| `plugins sync [instance\|--all] [--clean]` | Copy dropins into one instance or every instance. `--clean` clears existing jars first. Isolated instances are skipped with `[SKIP]`. |
| `plugins watch-start` | Start a background daemon that re-syncs whenever a dropin jar changes. |
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
consumers/<profile>/
  builds/<type>/                  # cached server jars
  backups/<instance>/              # restorable snapshots + manifest/checksums
  dropins/plugins or dropins/mods   # dropin jars (manual and content-managed)
  instances/<name>/                 # one server's worldroot
    .server-source                # type, launch mode, jar path, isolated flag
    server.jar                    # symlink into builds/
    plugins/ or mods/             # synced from dropin-source
  shared-plugin-data/             # plugin-only: iris packs + merged ops.json
  state/runtime/                  # tmux logs, pid files
  state/content-lock.yaml          # managed plugin/mod manifest
.multiplexor/templates/             # reusable server blueprints
.multiplexor/workspace.yaml         # workspace marker
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
