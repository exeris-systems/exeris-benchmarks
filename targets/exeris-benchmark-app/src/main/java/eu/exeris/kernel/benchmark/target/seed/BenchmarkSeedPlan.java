package eu.exeris.kernel.benchmark.target.seed;

import java.util.Map;
import java.util.Objects;

public record BenchmarkSeedPlan(
        String datasetId,
        BenchmarkResetPolicy resetPolicy,
        Map<String, String> parameters) {

    public BenchmarkSeedPlan {
        datasetId = Objects.requireNonNull(datasetId, "datasetId");
        resetPolicy = Objects.requireNonNull(resetPolicy, "resetPolicy");
        parameters = Map.copyOf(Objects.requireNonNull(parameters, "parameters"));
    }
}