package dev.multiplexor.observer;

import com.destroystokyo.paper.event.server.ServerTickEndEvent;
import java.io.IOException;
import java.util.ArrayList;
import java.time.Instant;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.bukkit.Location;
import org.bukkit.World;
import org.bukkit.entity.Entity;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.entity.PlayerDeathEvent;
import org.bukkit.event.player.PlayerChangedWorldEvent;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.event.world.ChunkLoadEvent;
import org.bukkit.plugin.java.JavaPlugin;

public final class PaperObserver extends JavaPlugin implements Listener {
    private final Measurements measurements = new Measurements();
    private final Map<UUID, Long> generatedChunks = new ConcurrentHashMap<>();
    private final Map<UUID, Long> chunkLoads = new ConcurrentHashMap<>();
    private final Map<UUID, Map<String, Object>> playerSamples = new ConcurrentHashMap<>();
    private final Set<UUID> scheduledPlayers = ConcurrentHashMap.newKeySet();
    private SnapshotWriter writer;
    private boolean folia;
    private volatile Map<String, Object> lastSnapshot;

    @Override public void onEnable() {
        try { writer = new SnapshotWriter(getDataFolder().toPath(), message -> getLogger().warning(message)); }
        catch (IOException exception) {
            getLogger().severe("Cannot open observer snapshots: " + exception.getMessage());
            getServer().getPluginManager().disablePlugin(this);
            return;
        }
        folia = isFolia();
        getServer().getPluginManager().registerEvents(this, this);
        if (folia) {
            getServer().getGlobalRegionScheduler().runAtFixedRate(this, task -> {
                for (Player player : getServer().getOnlinePlayers()) schedulePlayer(player);
                publish();
            }, 1, 100);
        } else {
            getServer().getScheduler().runTaskTimer(this, this::publish, 1, 100);
        }
    }

    @Override public void onDisable() {
        if (writer == null) return;
        Map<String, Object> stopped = lastSnapshot == null
            ? measurements.snapshot("paper", "stopped") : new LinkedHashMap<>(lastSnapshot);
        stopped.put("status", "stopped");
        stopped.put("observedAt", Instant.now().toString());
        writer.finish(stopped);
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onTick(ServerTickEndEvent event) { if (!folia) measurements.tick(event.getTickDuration()); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onChunk(ChunkLoadEvent event) {
        UUID world = event.getWorld().getUID();
        chunkLoads.merge(world, 1L, Long::sum);
        if (event.isNewChunk()) generatedChunks.merge(world, 1L, Long::sum);
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onJoin(PlayerJoinEvent event) {
        measurements.event("join", identity(event.getPlayer()));
        if (folia) schedulePlayer(event.getPlayer());
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onQuit(PlayerQuitEvent event) {
        measurements.event("quit", identity(event.getPlayer()));
        removePlayer(event.getPlayer().getUniqueId());
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onDeath(PlayerDeathEvent event) { measurements.event("death", identity(event.getEntity())); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onWorld(PlayerChangedWorldEvent event) {
        if (folia) samplePlayer(event.getPlayer());
        else measurements.event("world-change", identity(event.getPlayer()));
    }

    private static boolean isFolia() {
        try {
            Class.forName("io.papermc.paper.threadedregions.RegionizedServer");
            return true;
        } catch (ClassNotFoundException exception) {
            return false;
        }
    }

    private void publish() {
        lastSnapshot = snapshot("running");
        writer.submit(lastSnapshot);
    }

    private void schedulePlayer(Player player) {
        UUID id = player.getUniqueId();
        if (!scheduledPlayers.add(id)) return;
        if (player.getScheduler().runAtFixedRate(this, task -> samplePlayer(player),
                () -> removePlayer(id), 1, 100) == null) removePlayer(id);
    }

    private void removePlayer(UUID id) {
        playerSamples.remove(id);
        scheduledPlayers.remove(id);
    }

    private void samplePlayer(Player player) {
        Map<String, Object> sample = playerSnapshot(player);
        Map<String, Object> previous = playerSamples.put(player.getUniqueId(), sample);
        if (previous != null && !previous.get("world").equals(sample.get("world"))) {
            Map<String, Object> transition = new LinkedHashMap<>(identity(player));
            transition.put("source", "entity-sample");
            measurements.event("world-change", transition);
        }
    }

    private Map<String, Object> playerSnapshot(Player player) {
        Map<String, Object> entry = new LinkedHashMap<>(identity(player));
        Location location = player.getLocation();
        entry.put("chunkX", location.getBlockX() >> 4);
        entry.put("chunkZ", location.getBlockZ() >> 4);
        entry.put("pingMs", player.getPing());
        entry.put("observedAt", Instant.now().toString());
        return Map.copyOf(entry);
    }

    private Map<String, Object> identity(Player player) {
        return Map.of("username", player.getName(), "uuid", player.getUniqueId().toString(),
            "world", player.getWorld().getUID().toString());
    }

    private Map<String, Object> snapshot(String status) {
        long started = System.nanoTime();
        Map<String, Object> snapshot = measurements.snapshot("paper", status);
        snapshot.put("serverVersion", getServer().getVersion());
        snapshot.put("platform", folia ? "folia" : "paper");
        snapshot.put("capabilities", Map.of("globalTickTimings", !folia, "regionTickTimings", false,
            "loadedChunkCounts", !folia, "entityCounts", !folia, "playerMembership", true,
            "chunkEventCounts", true, "processMetrics", true));
        if (folia) snapshot.put("tick", null);
        List<Map<String, Object>> players = new ArrayList<>();
        if (folia) {
            Instant oldest = Instant.now().minusSeconds(15);
            for (Map<String, Object> sample : playerSamples.values()) {
                if (players.size() == 4096) break;
                if (Instant.parse((String) sample.get("observedAt")).isBefore(oldest)) continue;
                players.add(sample);
            }
        } else {
            for (Player player : getServer().getOnlinePlayers()) {
                if (players.size() == 4096) break;
                players.add(playerSnapshot(player));
            }
        }
        List<Map<String, Object>> worlds = new ArrayList<>();
        for (World world : getServer().getWorlds()) {
            if (worlds.size() == 256) break;
            Map<String, Integer> entities = new LinkedHashMap<>();
            if (!folia) {
                for (Entity entity : world.getEntities()) entities.merge(entity.getType().name(), 1, Integer::sum);
            }
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("id", world.getUID().toString());
            entry.put("name", world.getName());
            entry.put("dimension", world.getEnvironment().name());
            entry.put("loadedChunks", folia ? null : world.getLoadedChunks().length);
            entry.put("tickingChunks", null);
            entry.put("generatedChunks", generatedChunks.getOrDefault(world.getUID(), 0L));
            entry.put("chunkLoads", chunkLoads.getOrDefault(world.getUID(), 0L));
            entry.put("counterScope", "since-observer-enable");
            entry.put("entities", folia ? null : entities);
            entry.put("players", folia ? players.stream().filter(player ->
                world.getUID().toString().equals(player.get("world"))).count() : world.getPlayers().size());
            entry.put("playerCountScope", folia ? "recent-entity-samples" : "world-snapshot");
            entry.put("viewDistance", world.getViewDistance());
            entry.put("simulationDistance", world.getSimulationDistance());
            worlds.add(entry);
        }
        snapshot.put("worlds", worlds);
        snapshot.put("players", players);
        snapshot.put("captureMs", (System.nanoTime() - started) / 1_000_000.0);
        return snapshot;
    }
}
