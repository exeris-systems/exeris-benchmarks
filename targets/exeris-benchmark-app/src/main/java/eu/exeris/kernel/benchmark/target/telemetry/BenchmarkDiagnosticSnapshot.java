package eu.exeris.kernel.benchmark.target.telemetry;

import java.time.Instant;
import java.util.Map;
import java.util.Objects;

public record BenchmarkDiagnosticSnapshot(
        Instant capturedAt,
        Map<String, Long> counters,
        Map<String, String> attributes) {

    public BenchmarkDiagnosticSnapshot {
        capturedAt = Objects.requireNonNull(capturedAt, "capturedAt");
        counters = Map.copyOf(Objects.requireNonNull(counters, "counters"));
        attributes = Map.copyOf(Objects.requireNonNull(attributes, "attributes"));
    }
}