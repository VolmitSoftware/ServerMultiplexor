package dev.multiplexor.observer;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Collection;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

final class SnapshotWriter implements AutoCloseable {
    private final Path destination;
    private final Consumer<String> error;
    private final ExecutorService executor = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "multiplexor-observer-writer");
        thread.setDaemon(true);
        return thread;
    });
    private final AtomicBoolean writing = new AtomicBoolean();
    private volatile boolean closed;

    SnapshotWriter(Path directory, Consumer<String> error) throws IOException {
        Files.createDirectories(directory);
        this.destination = directory.resolve("metrics.json");
        this.error = error;
    }

    void submit(Map<String, Object> snapshot) {
        if (closed || !writing.compareAndSet(false, true)) return;
        executor.submit(() -> {
            try { write(snapshot); }
            catch (IOException exception) { error.accept(exception.getMessage()); }
            finally { writing.set(false); }
        });
    }

    private void write(Map<String, Object> snapshot) throws IOException {
        Path temporary = destination.resolveSibling("metrics.json.tmp");
        Files.writeString(temporary, json(snapshot), StandardCharsets.UTF_8);
        try { Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
        catch (AtomicMoveNotSupportedException exception) {
            Files.move(temporary, destination, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    void finish(Map<String, Object> snapshot) {
        close();
        try { write(snapshot); }
        catch (IOException exception) { error.accept(exception.getMessage()); }
    }

    @Override public void close() {
        closed = true;
        executor.shutdown();
        try {
            if (!executor.awaitTermination(3, TimeUnit.SECONDS)) executor.shutdownNow();
        } catch (InterruptedException exception) {
            executor.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }

    static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof String text) {
            StringBuilder result = new StringBuilder("\"");
            for (char character : text.toCharArray()) {
                switch (character) {
                    case '"' -> result.append("\\\"");
                    case '\\' -> result.append("\\\\");
                    case '\n' -> result.append("\\n");
                    case '\r' -> result.append("\\r");
                    case '\t' -> result.append("\\t");
                    default -> {
                        if (character < 32) result.append(String.format("\\u%04x", (int) character));
                        else result.append(character);
                    }
                }
            }
            return result.append('"').toString();
        }
        if (value instanceof Number number) return Double.isFinite(number.doubleValue()) ? number.toString() : "null";
        if (value instanceof Boolean) return value.toString();
        if (value instanceof Map<?, ?> map) {
            StringBuilder result = new StringBuilder("{");
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (result.length() > 1) result.append(',');
                result.append(json(entry.getKey().toString())).append(':').append(json(entry.getValue()));
            }
            return result.append('}').toString();
        }
        if (value instanceof Collection<?> values) {
            StringBuilder result = new StringBuilder("[");
            for (Object entry : values) {
                if (result.length() > 1) result.append(',');
                result.append(json(entry));
            }
            return result.append(']').toString();
        }
        throw new IllegalArgumentException("Unsupported snapshot value: " + value.getClass().getName());
    }
}
