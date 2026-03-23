package eu.exeris.kernel.benchmark.target.api;

import java.time.Instant;
import java.util.Objects;

public record BenchmarkSeedFingerprint(
        String datasetId,
        String revision,
        String checksum,
        Instant capturedAt) {

    public BenchmarkSeedFingerprint {
        datasetId = Objects.requireNonNull(datasetId, "datasetId");
        revision = Objects.requireNonNull(revision, "revision");
        checksum = Objects.requireNonNull(checksum, "checksum");
        capturedAt = Objects.requireNonNull(capturedAt, "capturedAt");
    }
}