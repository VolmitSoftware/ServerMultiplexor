# Multiplexor

A Dart-native Minecraft server workspace manager. One workspace holds many server instances across four isolated **consumer profiles** (plugin, forge, fabric, neoforge), each with its own build cache, dropin folder, and instance store.

Everything is driven through `./start.sh` — either the interactive wizard (no args) or a direct CLI command.

## Requirements

- `dart` 3.10+ (only needed if building from source — `./start.sh` runs `dart run` against `MultiplexorApp/`)
- `java` 17+ (or whatever your target server requires)
- `git`, `tmux` (tmux is required for `runtime start` / `runtime console`)

## Quick Start

```bash
./start.sh                                          # interactive wizard
./start.sh consumer use plugin                      # pick a consumer profile
./start.sh server create demo --type purpur --auto-build
./start.sh runtime start demo                       # starts and attaches console
```

## Interactive Wizard

`./start.sh` with no args opens a dashboard listing every instance with a live state badge, port, and `active` / `isolated` markers. Pick an instance to get a state-aware action menu (console/restart/stop while running; start/update/reset/delete while stopped; activate/port/MOTD/open-folder/toggle-isolation always). Keyboard and mouse both work — arrows/wheel to move, Enter or click to activate, Esc to go back. Keys pressed while a build or sync runs are discarded.

Dashboard shortcuts: `n` new instance, `s` start all, `k` stop all, `g` all consoles, `b` build & tuning, `c` switch consumer, `r` refresh, `q` quit.

## Concepts

- **Consumer profile** — one of `plugin`, `forge`, `fabric`, `neoforge`. Each profile has its own instances, dropin sources, and build cache. They never share state. The active profile is set with `consumer use`.
- **Instance** — one server install inside a consumer. Lives at `consumers/<profile>/instances/<name>` (or under `~/.multiplexor/instance-store/...` if the workspace path contains `[` or `]`). Metadata is in `.server-source` (type, launch mode, jar path, isolated flag).
- **Active instance** — the default target when an instance name is omitted. Set with `instance activate`.
- **Dropins** — plugin or mod jars under `consumers/<profile>/plugin-source` (or `mod-source`). On `runtime start` and via the watcher, these jars are copied into every non-isolated instance's `plugins/` (or `mods/`) folder.
- **Isolated instance** — opts out of all shared state: no dropin sync, no Iris pack symlink, no shared `ops.json` merge. Created with `server create --isolated` or toggled later with `instance isolated <name> true`.
- **Shared plugin data** — `consumers/plugin/shared-plugin-data/` holds Iris packs and a merged `ops.json` for non-isolated plugin instances.
- **Build cache** — `consumers/<profile>/builds/<type>/` holds versioned server jars. `server create --type ...` resolves jars from here; `--auto-build` refreshes from upstream first.

## CLI Reference

Every command is `./start.sh <namespace> <action> [args]`. Global flags: `--consumer <profile>` for a one-shot profile override, `--root <path>` for a different workspace, `--verbose` for arg-normalization debug output.

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
| `instance isolated [name] [true\|false]` | Read the flag (no value) or toggle it. Turning it off re-links shared Iris packs and merges shared ops. |
| `instance port [instance] [port]` | Read or set `server-port` in `server.properties`. |
| `instance motd-style [name]` | Apply the styled MOTD template (alias: `motd-style`). |
| `instance reset <name>` | Wipe worlds/config/plugins/mods/logs back to baseline. Keeps the launch artifacts and the isolated flag. |
| `instance delete <name>` | Delete the instance entirely (kills any running process first). |
| `instance delete-all` | Delete every instance in the active profile. Asks for `DELETE` confirmation. |

### server — first-time jar wiring

| Command | What it does |
|---------|--------------|
| `server create <name> --type <type> [--mc <v>] [--auto-build] [--isolated]` | Create + wire `server.jar` from the build cache (or refresh upstream first if `--auto-build`). `--isolated` opts the instance out of shared dropins/iris/ops. |
| `server create <name> --jar <path> [--type label] [--isolated]` | Create + wire an explicit jar. |

`<type>` is one of: `paper`, `purpur`, `folia`, `canvas`, `spigot`, `forge`, `fabric`, `neoforge`. For `forge` / `neoforge`, an installer jar triggers args-file launch mode automatically.

### runtime — start, stop, attach

`tmux` is required. Every session is named after the consumer + instance and logs to `consumers/<profile>/state/runtime/<instance>.log`.

| Command | What it does |
|---------|--------------|
| `runtime start [instance] [--no-console]` | Start the instance and attach its console. `--no-console` returns immediately. |
| `runtime stop [instance]` | Send a graceful stop. |
| `runtime restart [instance] [--no-console]` | Stop and start again. Attaches console unless `--no-console`. |
| `runtime console [instance]` | Attach to a running console. Esc detaches; the server keeps running. Mouse wheel scrolls; drag-select copies to clipboard. |
| `runtime consoles` | Open every running console in a tmux grid. |
| `runtime consoles-lateral` | Open every running console side-by-side. |
| `runtime status [instance]` | Print the runtime state of one instance. |
| `runtime states` | Print one line per instance: `name<TAB>state<TAB>port<TAB>pid`. State is `stopped` / `starting` / `running` / `stopping` / `restarting`. |
| `runtime list` | Print running instance names. |
| `runtime settings show` | Print the active heap, JVM preset, and flags. |
| `runtime settings presets` | List available JVM presets (`aikar`, `vanilla`, `conservative`). |
| `runtime settings set-heap <2G\|4G\|...>` | Set JVM `-Xmx`. |
| `runtime settings set-preset <name>` | Apply a JVM preset's flags. |
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

### build — fetch or compile server jars into the cache

| Command | What it does |
|---------|--------------|
| `build <type> [--mc <v>] [--loader <v>] [--installer <v>]` | Build or download a server jar. Refreshes from upstream every run; spigot also refreshes `BuildTools.jar`. |
| `build latest <type>` | Print the latest supported MC version for `<type>`. |
| `build versions [type]` | Print all supported versions. |
| `build list` | Show what's in the active profile's cache. |
| `build list-all [type]` | Show cache contents across profiles. |
| `build test-latest [--spigot-mc <v>]` | Sanity-check the latest of every type. |

### repos — sync upstream version metadata

| Command | What it does |
|---------|--------------|
| `repos sync [all\|paper\|purpur\|folia\|canvas]` | Clone or pull upstream repos used for version discovery. Build commands resolve metadata over HTTP, so this is mostly used for Spigot/BuildTools. |

### config — per-instance config plumbing

| Command | What it does |
|---------|--------------|
| `config localize [instance\|--all]` | Convert shared-config symlinks into per-instance copies so local edits stick. |
| `config status [instance]` | Print which config files are symlinked vs localized. |

## Common Workflows

```bash
# Create a paper server on the latest upstream version, refreshing the cache first
./start.sh server create lobby --type paper --auto-build

# Create an isolated test server (won't pick up your dropins)
./start.sh server create vanilla-test --type purpur --isolated

# Update an existing server to a new MC version (worlds may not survive)
./start.sh runtime stop lobby
./start.sh instance update lobby --mc 1.21.11 --auto-build
./start.sh runtime start lobby

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
  plugin-source/ or mod-source/   # dropin jars (your build outputs)
  instances/<name>/               # one server's worldroot
    .server-source                # type, launch mode, jar path, isolated flag
    server.jar                    # symlink into builds/
    plugins/ or mods/             # synced from dropin-source
  shared-plugin-data/             # plugin-only: iris packs + merged ops.json
  state/runtime/                  # tmux logs, pid files
.multiplexor/workspace.yaml       # workspace marker
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
