# Session observers

This optional jar records server measurements for persistent player simulations. It supports Paper 1.21.11 and Velocity 3.4 API targets. Verify other versions with a connection test before relying on their measurements. The Paper observer uses the main server loop and does not support Folia region timing.

Build with Java 21 or newer and Gradle:

```sh
gradle -p MultiplexorApp/tool/session-observer clean test jar
```

Copy `MultiplexorApp/tool/session-observer/build/libs/multiplexor-observer.jar` into the `plugins/` directory of each stopped, isolated QA backend and its stopped Velocity proxy. Use `./start.sh instance path <name>` to resolve each directory. The same jar contains both plugin entrypoints. Restart those QA processes to load it.

Each process writes `plugins/MultiplexorObserver/metrics.json`. Session runs read these files automatically. The observer opens no network listener and issues no gameplay commands. Remove the jar while the process is stopped to disable it.

Paper captures snapshots every 100 server ticks. Velocity captures every two seconds. JSON writes run on a separate thread, and only one write can be pending. Each snapshot holds at most 256 session events and 4,096 player observations. Paper records at most 256 worlds. Snapshot age remains visible when the server cannot keep up.

Measurements include:

- Main-loop tick duration percentiles over the latest 1,200 ticks, total ticks, and ticks longer than 50 ms.
- JVM heap use, cumulative GC count/time, and CPU use between samples. CPU uses one core as 100 percent.
- Loaded chunks, chunk-load events, and newly generated chunks since observer startup.
- Entity counts by type, coarse player chunk positions, player ping, view distance, and simulation distance.
- Player joins, departures, deaths, world changes, and confirmed Velocity backend connections.
- Paper snapshot capture time, so the cost of observation is visible.

Ticking-chunk counts, disk/network throughput, individual GC pauses, and plugin database timings are not measured by this observer. Missing measurements remain unavailable. Use bounded spark or JVM profiling windows for those investigations. A newly received client chunk is not proof of terrain generation.

Snapshots describe all players on the QA target. They include usernames and UUIDs but do not record chat text. Observer installation does not make a workload representative of human players. Compare the workload and server profiles against measured sessions on the same server configuration.

API references: [Paper setup](https://docs.papermc.io/paper/dev/project-setup/), [Paper tick event](https://jd.papermc.io/paper/1.21.11/com/destroystokyo/paper/event/server/ServerTickEndEvent.html), and [Velocity backend event](https://jd.papermc.io/velocity/3.4.0/com/velocitypowered/api/event/player/ServerPostConnectEvent.html).
