package dev.multiplexor.observer;

import static org.junit.jupiter.api.Assertions.*;
import java.util.List;
import java.util.Map;
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

    @Test void jsonEscapesProtocolStringsAndRejectsUnknownObjects() {
        assertEquals("\"line\\n\\\"\\\\\\u0001\"", SnapshotWriter.json("line\n\"\\\u0001"));
        assertEquals("null", SnapshotWriter.json(Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> SnapshotWriter.json(new Object()));
    }
}
