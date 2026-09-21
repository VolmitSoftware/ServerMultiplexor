package dev.multiplexor.observer;

import static org.junit.jupiter.api.Assertions.*;
import java.util.List;
import java.util.Map;
import java.util.ArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;

final class MeasurementsTest {
    @Test void snapshotsBoundHistoryAndKeepActualTickTail() {
        Measurements measurements = new Measurements();
        for (int index = 0; index < 300; index++) measurements.event("join", Map.of("username", "Player" + index));
        for (int index = 0; index < 1200; index++) measurements.tick(1);
        measurements.tick(90);
        Map<String, Object> snapshot = measurements.snapshot("paper", "running");
        assertEquals(256, ((List<?>) snapshot.get("events")).size());
        Map<?, ?> tick = (Map<?, ?>) snapshot.get("tick");
        assertEquals(1201L, tick.get("count"));
        assertEquals(1L, tick.get("longTicks"));
        assertEquals(90.0, tick.get("maxMs"));
        assertEquals(1.0, tick.get("p95Ms"));
    }

    @Test void regionEventsRemainOrderedAndBoundedUnderConcurrentWriters() throws Exception {
        Measurements measurements = new Measurements();
        try (ExecutorService regions = Executors.newFixedThreadPool(4)) {
            List<Future<?>> tasks = new ArrayList<>();
            for (int region = 0; region < 4; region++) {
                tasks.add(regions.submit(() -> {
                    for (int index = 0; index < 300; index++) {
                        measurements.event("world-change", Map.of("world", "region-world"));
                        SnapshotWriter.json(measurements.snapshot("paper", "running"));
                    }
                }));
            }
            for (Future<?> task : tasks) task.get();
        }
        Map<String, Object> snapshot = measurements.snapshot("paper", "running");
        assertEquals(1200L, snapshot.get("eventCount"));
        List<?> events = (List<?>) snapshot.get("events");
        assertEquals(256, events.size());
        for (int index = 0; index < events.size(); index++) {
            assertEquals(945L + index, ((Map<?, ?>) events.get(index)).get("sequence"));
        }
    }

    @Test void jsonEscapesProtocolStringsAndRejectsUnknownObjects() {
        assertEquals("\"line\\n\\\"\\\\\\u0001\"", SnapshotWriter.json("line\n\"\\\u0001"));
        assertEquals("null", SnapshotWriter.json(Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> SnapshotWriter.json(new Object()));
    }
}
