package eu.exeris.kernel.benchmark.target.api;

import java.util.Objects;
import java.util.Set;

public record BenchmarkCapabilities(
        Set<String> supportedProtocolModes,
        Set<BenchmarkMode> supportedBenchmarkModes,
        boolean httpSupported,
        boolean persistenceSupported,
        boolean graphSupported,
        boolean telemetrySupported,
        boolean schemaProvisioningSupported) {

    public BenchmarkCapabilities {
        supportedProtocolModes = Set.copyOf(Objects.requireNonNull(supportedProtocolModes, "supportedProtocolModes"));
        supportedBenchmarkModes = Set.copyOf(Objects.requireNonNull(supportedBenchmarkModes, "supportedBenchmarkModes"));
    }
}