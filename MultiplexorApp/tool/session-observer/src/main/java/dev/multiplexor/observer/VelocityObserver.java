package dev.multiplexor.observer;

import com.google.inject.Inject;
import com.velocitypowered.api.event.Subscribe;
import com.velocitypowered.api.event.connection.DisconnectEvent;
import com.velocitypowered.api.event.player.ServerPostConnectEvent;
import com.velocitypowered.api.event.proxy.ProxyInitializeEvent;
import com.velocitypowered.api.event.proxy.ProxyShutdownEvent;
import com.velocitypowered.api.plugin.annotation.DataDirectory;
import com.velocitypowered.api.proxy.Player;
import com.velocitypowered.api.proxy.ProxyServer;
import com.velocitypowered.api.scheduler.ScheduledTask;
import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;

public final class VelocityObserver {
    private final ProxyServer server;
    private final Logger logger;
    private final Path directory;
    private final Measurements measurements = new Measurements();
    private SnapshotWriter writer;
    private ScheduledTask task;

    @Inject public VelocityObserver(ProxyServer server, Logger logger, @DataDirectory Path directory) {
        this.server = server;
        this.logger = logger;
        this.directory = directory.resolveSibling("MultiplexorObserver");
    }

    @Subscribe public void onInitialize(ProxyInitializeEvent event) {
        try { writer = new SnapshotWriter(directory, message -> logger.warn("Observer snapshot: {}", message)); }
        catch (IOException exception) {
            logger.error("Cannot open observer snapshots", exception);
            return;
        }
        task = server.getScheduler().buildTask(this, () -> writer.submit(snapshot("running")))
            .repeat(Duration.ofSeconds(2)).schedule();
    }

    @Subscribe public void onConnect(ServerPostConnectEvent event) {
        Map<String, Object> details = identity(event.getPlayer());
        details.put("previousBackend", event.getPreviousServer() == null ? null : event.getPreviousServer().getServerInfo().getName());
        measurements.event("backend-connect", details);
        if (writer != null) writer.submit(snapshot("running"));
    }

    @Subscribe public void onDisconnect(DisconnectEvent event) {
        measurements.event("disconnect", identity(event.getPlayer()));
    }

    @Subscribe public void onShutdown(ProxyShutdownEvent event) {
        if (task != null) task.cancel();
        if (writer != null) writer.finish(snapshot("stopped"));
    }

    private Map<String, Object> identity(Player player) {
        Map<String, Object> entry = new LinkedHashMap<>();
        entry.put("username", player.getUsername());
        entry.put("uuid", player.getUniqueId().toString());
        entry.put("backend", player.getCurrentServer().map(connection -> connection.getServerInfo().getName()).orElse(null));
        return entry;
    }

    private Map<String, Object> snapshot(String status) {
        Map<String, Object> snapshot = measurements.snapshot("velocity", status);
        List<Map<String, Object>> players = new ArrayList<>();
        for (Player player : server.getAllPlayers()) {
            if (players.size() == 4096) break;
            Map<String, Object> entry = identity(player);
            entry.put("pingMs", player.getPing());
            players.add(entry);
        }
        snapshot.put("players", players);
        snapshot.put("serverVersion", server.getVersion().getVersion());
        return snapshot;
    }
}
