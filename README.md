# Minecraft Dev Manager

This repo is now Dart-native. The only root script is `./start.sh`, which just runs the Dart CLI.

## Entrypoint

```bash
./start.sh
```

Everything (wizard + commands) is implemented in `MultiplexorApp`.

## Consumer Profiles (isolated)

- `plugin` -> `consumers/plugin-consumers`
- `forge` -> `consumers/forge-mod-consumers`
- `fabric` -> `consumers/fabric-mod-consumers`
- `neoforge` -> `consumers/neoforge-mod-consumers`

Isolation rules:

- No shared config files between instances except plugin `ops.json`.
- Mod consumers are fully isolated from plugin consumers.
- `shared-plugin-data` is used only by `plugin` (for Iris packs).
- Plugin instances share operators via `shared-plugin-data/ops/ops.json`.
- No archive workflow.

## Quick Start

```bash
./start.sh consumer show
./start.sh consumer use plugin
./start.sh
```

## Compile Output Targets

Plugin jars source:

```bash
./start.sh --consumer plugin plugins show-source
```

Mod jars sources:

```bash
./start.sh --consumer forge mods show-source
./start.sh --consumer fabric mods show-source
./start.sh --consumer neoforge mods show-source
```

## Server Targets

`server create` supports cached, auto-built/downloaded, or custom jars:

```bash
./start.sh server create <name> --jar <path-to-server-jar> [--type label]
./start.sh server create <name> --type <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>]
./start.sh server create <name> --type <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>] --auto-build
```

For `--type`, the jar is resolved from the consumer build cache under `consumers/<consumer>/builds/<type>`.
Use `--auto-build` when you want `server create` to refresh from the upstream source first instead of using the current cache.

## Runtime

`tmux` is required for background runtime + live console attach.

```bash
./start.sh runtime start [instance] [--no-console]
./start.sh runtime start [--instance <name>] [--no-console]
./start.sh runtime console [instance|--instance <name>]
./start.sh runtime consoles
./start.sh runtime consoles-lateral
./start.sh runtime stop [instance]
./start.sh runtime status [instance]
./start.sh runtime states
./start.sh runtime list
```

Notes:

- `runtime start` auto-opens console by default.
- Use `--no-console` for background/bulk starts.
- `runtime console` auto-targets the server when exactly one is running.
- In a console, the mouse wheel scrolls and drag-selecting text copies it to the system clipboard. `Esc` detaches and the server keeps running.
- `runtime states` prints one line per instance: `name<TAB>state<TAB>port<TAB>pid`, where state is `stopped`, `starting`, `running`, `stopping`, or `restarting`.
- `runtime start`, `server create`, `instance clone`, and `instance reset` maintain a per-instance `multiplexor-restart.sh` and wire `spigot.yml` so Paper/Spigot/Purpur `/restart` starts the instance back through Multiplexor instead of exiting permanently. While that script waits, the instance reports `restarting`.

Wizard:

- One dashboard lists every instance with a live state badge, port, and `active` marker.
- Selecting an instance opens a single state-aware action menu: console/restart/stop while up; start/factory reset/delete while stopped; activate/port/MOTD always.
- Global actions have single-key shortcuts: `n` new instance, `s` start all, `k` stop all, `g` all consoles, `b` build & tuning, `c` switch consumer, `r` refresh, `q` quit.
- Menus take keyboard and mouse: arrows or wheel to move, Enter or click to activate, Esc to go back.
- Keys pressed while a build/start/sync is running are swallowed and discarded, never executed.

Instance reset:

```bash
./start.sh instance reset <name>
```

- Resets worlds/config/plugins/mods/logs to baseline.
- Keeps launch artifacts so the instance remains launchable.

Runtime JVM settings (wizard-backed):

```bash
./start.sh runtime settings show
./start.sh runtime settings presets
./start.sh runtime settings set-heap 6G
./start.sh runtime settings set-preset aikar
./start.sh runtime settings reset
```

Plugin watcher commands:

```bash
./start.sh plugins watch-start
./start.sh plugins watch-status
./start.sh plugins watch-stop
```

## Repo/Cache Utilities

```bash
./start.sh repos sync [all|paper|purpur|folia|canvas]
./start.sh build <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>] [--loader <version>] [--installer <version>]
./start.sh build test-latest [--spigot-mc <version>]
./start.sh build list
./start.sh build list-all [type]
./start.sh build latest <type>
./start.sh build versions [type]
```

Notes:

- Latest version and loader resolution reads upstream metadata on each run.
- Spigot builds refresh `BuildTools.jar` from the Spigot Jenkins source before running, falling back to a cached copy only if refresh fails.
- `forge` / `neoforge` build commands cache installer jars and `server create --type ...` auto-installs to args-file launch mode.
- If the workspace path contains `[` or `]`, mod consumer instances (`forge`/`fabric`/`neoforge`) are automatically stored in `~/.multiplexor/instance-store/<workspace-hash>/<consumer>` to keep launcher/runtime paths valid.
