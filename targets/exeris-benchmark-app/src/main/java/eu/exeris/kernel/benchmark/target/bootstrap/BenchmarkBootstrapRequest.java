package eu.exeris.kernel.benchmark.target.bootstrap;

import eu.exeris.kernel.benchmark.target.api.BenchmarkMode;

import java.util.Map;
import java.util.Objects;

public record BenchmarkBootstrapRequest(
        BenchmarkMode requestedBenchmarkMode,
        String runtimeFamily,
        String protocolMode,
        String implementationVariant,
        String executionClass,
        String seedDatasetId,
        Map<String, String> config) {

    public BenchmarkBootstrapRequest {
        requestedBenchmarkMode = Objects.requireNonNull(requestedBenchmarkMode, "requestedBenchmarkMode");
        runtimeFamily = Objects.requireNonNull(runtimeFamily, "runtimeFamily");
        protocolMode = Objects.requireNonNull(protocolMode, "protocolMode");
        implementationVariant = Objects.requireNonNull(implementationVariant, "implementationVariant");
        executionClass = Objects.requireNonNull(executionClass, "executionClass");
        seedDatasetId = Objects.requireNonNull(seedDatasetId, "seedDatasetId");
        config = Map.copyOf(Objects.requireNonNull(config, "config"));
    }
}