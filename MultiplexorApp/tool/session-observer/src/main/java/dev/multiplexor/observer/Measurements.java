package dev.multiplexor.observer;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.time.Instant;

final class Measurements {
    private final double[] ticks = new double[1200];
    private int tickPosition;
    private int tickSamples;
    private long tickCount;
    private long longTicks;
    private final ArrayDeque<Map<String, Object>> events = new ArrayDeque<>();
    private long eventCount;
    private long previousCpu = -1;
    private long previousTime = System.nanoTime();

    synchronized void tick(double milliseconds) {
        if (!Double.isFinite(milliseconds) || milliseconds < 0) return;
        ticks[tickPosition] = milliseconds;
        tickPosition = (tickPosition + 1) % ticks.length;
        tickSamples = Math.min(tickSamples + 1, ticks.length);
        tickCount++;
        if (milliseconds > 50) longTicks++;
    }

    synchronized void event(String type, Map<String, Object> values) {
        Map<String, Object> event = new LinkedHashMap<>(values);
        event.put("type", type);
        event.put("at", Instant.now().toString());
        event.put("sequence", ++eventCount);
        events.addLast(event);
        while (events.size() > 256) events.removeFirst();
    }

    synchronized Map<String, Object> snapshot(String kind, String status) {
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("schemaVersion", 1);
        snapshot.put("kind", kind);
        snapshot.put("status", status);
        snapshot.put("observedAt", Instant.now().toString());
        snapshot.put("processId", ProcessHandle.current().pid());
        snapshot.put("uptimeMs", ManagementFactory.getRuntimeMXBean().getUptime());
        snapshot.put("process", process());
        snapshot.put("events", new ArrayList<>(events));
        snapshot.put("eventCount", eventCount);
        if (kind.equals("paper")) snapshot.put("tick", tickSnapshot());
        return snapshot;
    }

    private Map<String, Object> process() {
        MemoryUsage heap = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        long gcCount = 0;
        long gcTime = 0;
        boolean gcAvailable = false;
        for (GarbageCollectorMXBean collector : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (collector.getCollectionCount() >= 0) {
                gcAvailable = true;
                gcCount += collector.getCollectionCount();
                gcTime += Math.max(0, collector.getCollectionTime());
            }
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("heapUsedBytes", heap.getUsed());
        result.put("heapCommittedBytes", heap.getCommitted());
        result.put("heapMaxBytes", heap.getMax());
        result.put("gcCount", gcAvailable ? gcCount : null);
        result.put("gcTimeMs", gcAvailable ? gcTime : null);
        if (ManagementFactory.getOperatingSystemMXBean() instanceof com.sun.management.OperatingSystemMXBean system) {
            long currentCpu = system.getProcessCpuTime();
            long currentTime = System.nanoTime();
            result.put("cpuPercent", previousCpu < 0 || currentCpu < previousCpu ? null :
                100.0 * (currentCpu - previousCpu) / Math.max(1, currentTime - previousTime));
            result.put("cpuScope", "interval-one-core");
            previousCpu = currentCpu;
            previousTime = currentTime;
        }
        return result;
    }

    private Map<String, Object> tickSnapshot() {
        double[] sorted = Arrays.copyOf(ticks, tickSamples);
        Arrays.sort(sorted);
        return Map.of("count", tickCount, "windowSamples", tickSamples, "scope", "main-server-loop",
            "p50Ms", percentile(sorted, 0.50), "p95Ms", percentile(sorted, 0.95),
            "p99Ms", percentile(sorted, 0.99), "maxMs", percentile(sorted, 1), "longTicks", longTicks);
    }

    static double percentile(double[] sorted, double quantile) {
        return sorted.length == 0 ? 0 : sorted[Math.min(sorted.length - 1, Math.max(0, (int) Math.ceil(sorted.length * quantile) - 1))];
    }
}
