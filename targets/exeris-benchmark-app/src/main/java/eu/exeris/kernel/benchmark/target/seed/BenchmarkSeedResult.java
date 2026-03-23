package eu.exeris.kernel.benchmark.target.seed;

import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;

import java.util.List;
import java.util.Objects;

public record BenchmarkSeedResult(
        String datasetId,
        BenchmarkSeedFingerprint fingerprint,
        boolean applied,
        List<String> notes) {

    public BenchmarkSeedResult {
        datasetId = Objects.requireNonNull(datasetId, "datasetId");
        fingerprint = Objects.requireNonNull(fingerprint, "fingerprint");
        notes = List.copyOf(Objects.requireNonNull(notes, "notes"));
    }
}