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

`server create` supports cached or custom jars:

```bash
./start.sh server create <name> --jar <path-to-server-jar> [--type label]
./start.sh server create <name> --type <paper|purpur|folia|canvas|spigot|forge|fabric|neoforge> [--mc <version>]
```

For `--type`, the jar is resolved from the consumer build cache under `consumers/<consumer>/builds/<type>`.

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
./start.sh runtime list
```

Notes:

- `runtime start` auto-opens console by default.
- Use `--no-console` for background/bulk starts.
- `runtime console` auto-targets the server when exactly one is running.

Wizard IA:

- Main sections: `Run`, `Instances`, `Build/JVM`, `Exit`.
- `Run -> Start one stopped instance` auto-opens that console.
- `Run -> Open console` skips picker when exactly one server is running.
- `Run -> Start all stopped instances` starts in background and opens console view once at the end.

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

- `forge` / `neoforge` build commands cache installer jars and `server create --type ...` auto-installs to args-file launch mode.
- If the workspace path contains `[` or `]`, mod consumer instances (`forge`/`fabric`/`neoforge`) are automatically stored in `~/.multiplexor/instance-store/<workspace-hash>/<consumer>` to keep launcher/runtime paths valid.
