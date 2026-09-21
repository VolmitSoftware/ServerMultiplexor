# Session observers

This optional jar records server measurements for persistent player simulations. It supports Paper 1.21.11 and Velocity 3.4 API targets. Verify other versions with a connection test before relying on their measurements. The Paper observer uses the main server loop. On Folia, it uses entity schedulers for player state and the global scheduler for snapshot assembly; region tick timing is unavailable.

Build with Java 21 or newer and Gradle:

```sh
gradle -p MultiplexorApp/tool/session-observer clean test jar
```

Copy `MultiplexorApp/tool/session-observer/build/libs/multiplexor-observer.jar` into the `plugins/` directory of each stopped, isolated QA backend and its stopped Velocity proxy. Use `./start.sh instance path <name>` to resolve each directory. The same jar contains both plugin entrypoints. Restart those QA processes to load it.

Each process writes `plugins/MultiplexorObserver/metrics.json`. Session runs read these files automatically. The observer opens no network listener and issues no gameplay commands. Remove the jar while the process is stopped to disable it.

Paper captures snapshots every 100 server ticks. Folia assembles snapshots every 100 global ticks and samples each player every 100 ticks on that player’s entity scheduler. Player observations carry their own timestamps; samples older than 15 seconds are omitted. World membership and player counts on Folia describe those recent samples, not a simultaneous global state. Folia world changes are detected between entity samples and carry `source: entity-sample`; transitions completed between samples can be missed. Velocity captures every two seconds. JSON writes run on a separate thread, and only one write can be pending. Each snapshot holds at most 256 session events and 4,096 player observations. Paper records at most 256 worlds. Snapshot age remains visible when the server cannot keep up.

Measurements include:

- Paper only: main-loop tick duration percentiles over the latest 1,200 ticks, total ticks, and ticks longer than 50 ms.
- JVM heap use, cumulative GC count/time, and CPU use between samples. CPU uses one core as 100 percent.
- Chunk-load events and newly generated chunks since observer startup; loaded-chunk totals on Paper only.
- Coarse player chunk positions, player ping, view distance, and simulation distance; entity counts by type on Paper only.
- Player joins, departures, deaths, world changes, and confirmed Velocity backend connections.
- Paper snapshot capture time, so the cost of observation is visible.

Folia snapshots keep `kind: paper` for the backend contract and set `platform: folia`. Their `capabilities` explicitly mark global and region tick timings, loaded-chunk totals, and entity totals unsupported; the corresponding measurements are `null`. Tick percentile thresholds therefore remain unavailable on Folia and fail a required telemetry gate. JVM CPU and GC describe the whole process, not individual regions.

Ticking-chunk counts, disk/network throughput, individual GC pauses, and plugin database timings are not measured by this observer. Missing measurements remain unavailable. Use bounded spark or JVM profiling windows for those investigations. A newly received client chunk is not proof of terrain generation.

Snapshots describe all players on the QA target. They include usernames and UUIDs but do not record chat text. Observer installation does not make a workload representative of human players. Compare the workload and server profiles against measured sessions on the same server configuration.

API references: [Paper setup](https://docs.papermc.io/paper/dev/project-setup/), [Paper tick event](https://jd.papermc.io/paper/1.21.11/com/destroystokyo/paper/event/server/ServerTickEndEvent.html), and [Velocity backend event](https://jd.papermc.io/velocity/3.4.0/com/velocitypowered/api/event/player/ServerPostConnectEvent.html).

The bounded Folia gameplay regression lives at `src/test/gameplay/folia-observer.mjs`. Install this jar on a stopped isolated Folia target, prepare it with Multiplexor, then run:

```sh
./start.sh --consumer plugin gameplay run "$PWD/MultiplexorApp/tool/session-observer/src/test/gameplay/folia-observer.mjs" <instance> --start --stop-after --timeout 180
```

The scenario checks two entity schedulers in separate regions, a cross-world UUID transition, event counters, process measurements, unsupported metrics, and the server log. It does not measure region tick performance.
