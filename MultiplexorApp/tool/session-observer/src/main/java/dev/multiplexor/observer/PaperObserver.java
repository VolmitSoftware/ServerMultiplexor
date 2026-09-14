package dev.multiplexor.observer;

import com.destroystokyo.paper.event.server.ServerTickEndEvent;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
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
    private final Map<UUID, Long> generatedChunks = new HashMap<>();
    private final Map<UUID, Long> chunkLoads = new HashMap<>();
    private SnapshotWriter writer;

    @Override public void onEnable() {
        try { writer = new SnapshotWriter(getDataFolder().toPath(), message -> getLogger().warning(message)); }
        catch (IOException exception) {
            getLogger().severe("Cannot open observer snapshots: " + exception.getMessage());
            getServer().getPluginManager().disablePlugin(this);
            return;
        }
        getServer().getPluginManager().registerEvents(this, this);
        getServer().getScheduler().runTaskTimer(this, () -> writer.submit(snapshot("running")), 1, 100);
    }

    @Override public void onDisable() {
        if (writer != null) writer.finish(snapshot("stopped"));
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onTick(ServerTickEndEvent event) { measurements.tick(event.getTickDuration()); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onChunk(ChunkLoadEvent event) {
        UUID world = event.getWorld().getUID();
        chunkLoads.merge(world, 1L, Long::sum);
        if (event.isNewChunk()) generatedChunks.merge(world, 1L, Long::sum);
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onJoin(PlayerJoinEvent event) { measurements.event("join", identity(event.getPlayer())); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onQuit(PlayerQuitEvent event) { measurements.event("quit", identity(event.getPlayer())); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onDeath(PlayerDeathEvent event) { measurements.event("death", identity(event.getEntity())); }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onWorld(PlayerChangedWorldEvent event) { measurements.event("world-change", identity(event.getPlayer())); }

    private Map<String, Object> identity(Player player) {
        return Map.of("username", player.getName(), "uuid", player.getUniqueId().toString(),
            "world", player.getWorld().getUID().toString());
    }

    private Map<String, Object> snapshot(String status) {
        long started = System.nanoTime();
        Map<String, Object> snapshot = measurements.snapshot("paper", status);
        snapshot.put("serverVersion", getServer().getVersion());
        List<Map<String, Object>> worlds = new ArrayList<>();
        for (World world : getServer().getWorlds()) {
            if (worlds.size() == 256) break;
            Map<String, Integer> entities = new LinkedHashMap<>();
            for (Entity entity : world.getEntities()) entities.merge(entity.getType().name(), 1, Integer::sum);
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("id", world.getUID().toString());
            entry.put("name", world.getName());
            entry.put("dimension", world.getEnvironment().name());
            entry.put("loadedChunks", world.getLoadedChunks().length);
            entry.put("tickingChunks", null);
            entry.put("generatedChunks", generatedChunks.getOrDefault(world.getUID(), 0L));
            entry.put("chunkLoads", chunkLoads.getOrDefault(world.getUID(), 0L));
            entry.put("counterScope", "since-observer-enable");
            entry.put("entities", entities);
            entry.put("players", world.getPlayers().size());
            entry.put("viewDistance", world.getViewDistance());
            entry.put("simulationDistance", world.getSimulationDistance());
            worlds.add(entry);
        }
        List<Map<String, Object>> players = new ArrayList<>();
        for (Player player : getServer().getOnlinePlayers()) {
            if (players.size() == 4096) break;
            Map<String, Object> entry = new LinkedHashMap<>(identity(player));
            Location location = player.getLocation();
            entry.put("chunkX", location.getBlockX() >> 4);
            entry.put("chunkZ", location.getBlockZ() >> 4);
            entry.put("pingMs", player.getPing());
            players.add(entry);
        }
        snapshot.put("worlds", worlds);
        snapshot.put("players", players);
        snapshot.put("captureMs", (System.nanoTime() - started) / 1_000_000.0);
        return snapshot;
    }
}
