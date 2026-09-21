# Volmit gameplay suites

These are developer acceptance tests for disposable, isolated Multiplexor instances. The feature targets live in `volmit.json`; plugin-specific scenario source lives beside the corresponding plugin tests in the sibling `VolmitSoftware` workspace. Install the plugin builds being tested before starting the instance. Scenario reports identify installed jars by SHA-256, so a result applies to that build set.

Use `gameplay prepare` on the stopped isolated target, then run modules through the public wrapper:

```bash
./start.sh gameplay prepare plugin-qa
./start.sh gameplay run /absolute/path/to/scenario.mjs plugin-qa --start --stop-after --timeout 300
```

The primary bot provisions fixtures with operator commands. Additional actors are ordinary players. Tests use real commands, menus, movement, placement, mining, and damage. Fixture plugins provision inputs or observe results; they do not synthesize gameplay events or grant the experience being asserted. Keep their separate test jars out of production installations.

## Scenario map

Paths below are relative to `VolmitSoftware`.

| Plugin | Scenario source | Assertions |
| --- | --- | --- |
| Wormholes | `WormholesPlugin/src/test/gameplay/public-portals.mjs` | Place selection blocks, create/name/link portals through wand menus, traverse both ways, delete. |
| Wormholes | `WormholesPlugin/src/test/gameplay/public-dimensional-doors.mjs` | Place and use paired, Personal, and Public dimensional doors. |
| Wormholes | `WormholesPlugin/src/test/gameplay/public-portal-load.mjs`, `public-door-load.mjs` | Concurrent ordinary-player crossings, return trips, cooldowns, and independent movement. |
| Wormholes | `WormholesPlugin/src/test/gameplay/shaped-portals-integration.mjs` | Build and ignite a nonrectangular frame, verify aperture and counterpart, cross, then break the frame. |
| Wormholes | `WormholesPlugin/src/test/gameplay/permission-rejections.mjs`, `public-pocket-rescue.mjs` | Denied mutations, invalid selections, rune refund, and public pocket rescue. |
| Wormholes | `WormholesPlugin/src/test/gameplay/restart-persistence.mjs` | Run once to prepare, restart the same instance, run again to verify persisted IDs/links and crossings. |
| Wormholes | `WormholesPlugin/src/test/gameplay/persistent-workflow.mjs` | Managed session actor follows declared route/command steps through Overworld/Nether portals and returns home. |
| Iris | `Iris/adapters/bukkit/plugin/src/test/gameplay/studio-acceptance.mjs` | Studio hotload/recovery, object save/paste/undo, Jigsaw editing, production generation, restart, and vanilla replacement. See phases below. |
| Iris | `Iris/adapters/bukkit/plugin/src/test/gameplay/editor-ownership.mjs` | Editor ownership, ordinary visitors, second-editor rejection, and owner reconnect. |
| Adapt | `Adapt/src/test/gameplay/all-skills.mjs` | Two-player combat and positive observed XP in all 23 skills. Requires the separate `gameplayFixtureJar` build. |
| Gloss | `Gloss/src/test/gameplay/public-interaction.mjs` | Pasteable inventory/holographic UI, actual clicks, file hotload, and single action dispatch. Fixtures are under its `fixtures/` directory. |
| Gloss | `Gloss/src/test/gameplay/display-authoring.mjs`, `entity-overlays.mjs` | Existing display-authoring and entity-overlay acceptance suites. |
| BileTools / VolmLib | `BileTools/src/test/gameplay/gloss-hotload.mjs` | Repeat Gloss reload and public UI checks; detect stale or duplicated action handlers. |
| HiddenOre | `HiddenOre/src/test/gameplay/mining-load.mjs` | Four players mine deterministic rewards, reject player-placed duplicate rewards, and exercise wrong-tool handling. Install `hiddenore.toml` from that directory before startup. |
| HiddenOre | `HiddenOre/src/test/gameplay/persistence-overflow.mjs` | Run before/after restart with `seeded.toml` and the separate `gameplayFixtureJar`; verify consumption/provenance persistence and full-inventory overflow pickup. |
| React | `React/React/src/test/gameplay/player-load.mjs`, `intervention-comparison.mjs` | Concurrent movement/block work with metrics, then matched intervention-off/on fixtures and conserved logical entities/items. Requires the separate `gameplayObserverJar`. |

The local `examples/circle-and-combat.mjs` is a minimal multi-actor example. `session-profiles/plugin-circuits.json` repeats command/circle/command workflows during persistent sessions. `examples/volmit-endurance.mjs` runs a 30-second warmup, five-minute measured workload, and 20-second recovery with Wormholes, Adapt, Gloss, React, HiddenOre, and MultiplexorObserver installed. Give that scenario at least `--timeout 480`. It records operations, failures, latency, server measurements, and generator measurements. A short soak does not establish long-duration stability or human-player capacity.

Copy the selected HiddenOre fixture to the instance's `plugins/HiddenOre/hiddenore.toml` while stopped. Its persistence scenario infers the phase from its saved marker; use the same instance and primary `--username` for both runs across the restart.

The current PacketEvents runtime deliberately closes connected sockets when Gloss is hotloaded. The Bile suite declares that disconnect, waits for fresh server-log reload completion, reconnects the same bot identity, and repeats all UI checks. It verifies reload and reconnect behavior; it does not claim uninterrupted connections.

## Iris phases

Use a fresh isolated instance with Iris and MultiplexorObserver, local owned `plugins/Iris/packs`, and a disposable vanilla Overworld. Shared pack symlinks are refused. Pass each phase using `--command <phase>` on the same `studio-acceptance.mjs` module:

1. `prepare` (240-second timeout), then restart the server.
2. `studio:3` (1500 seconds), `object` (240 seconds), `jigsaw` (360 seconds), then `world` (300 seconds).
3. Restart, then `world-check` (300 seconds).
4. `replace-stage` (300 seconds), restart, then `replace-check` (300 seconds).

After authoring, run `editor-ownership.mjs --command exercise --timeout 300`, followed by `--command reconnect --timeout 180`. Keep the same primary username and server process between those two phases; do not use `--stop-after` on the first. Production and replacement phases require the preceding persisted fixtures. Use a fresh instance when repeating the full authoring suite.

## Evidence and coverage

Build and install the [MultiplexorObserver](../../session-observer/README.md) for scenarios that assert world identity or server performance. The Folia-specific observer acceptance module is `tool/session-observer/src/test/gameplay/folia-observer.mjs`. Folia region timings and aggregate loaded chunk/entity counts remain unavailable.

```bash
node MultiplexorApp/tool/mineflayer/src/coverage.mjs consumers/plugin-consumers/state/gameplay-tests
```

The matrix retains the latest outcome for each feature and exact server/plugin build set. Old failures on other builds remain visible. Missing runs are `untested`; client rendering/audio fidelity is `unsupported`. Preserve both the JSON report and corresponding server log before deleting a QA instance. A closed viewer is recorded in the report; screenshots and visual fidelity require a real Minecraft client.
