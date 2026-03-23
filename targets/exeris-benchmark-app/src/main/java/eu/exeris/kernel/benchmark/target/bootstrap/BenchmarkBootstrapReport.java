package eu.exeris.kernel.benchmark.target.bootstrap;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntimeDescriptor;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;

import java.util.List;
import java.util.Objects;

public record BenchmarkBootstrapReport(
        BenchmarkRuntimeDescriptor resolvedDescriptor,
        BenchmarkCapabilities capabilities,
        String executionClass,
        String startupManifestId,
        String readinessPath,
        List<String> routeIds,
    String seedDatasetId,
    boolean seedApplied,
    List<String> seedNotes,
        BenchmarkSeedFingerprint seedFingerprint) {

    public BenchmarkBootstrapReport {
        resolvedDescriptor = Objects.requireNonNull(resolvedDescriptor, "resolvedDescriptor");
        capabilities = Objects.requireNonNull(capabilities, "capabilities");
        executionClass = Objects.requireNonNull(executionClass, "executionClass");
        startupManifestId = Objects.requireNonNull(startupManifestId, "startupManifestId");
        readinessPath = Objects.requireNonNull(readinessPath, "readinessPath");
        routeIds = List.copyOf(Objects.requireNonNull(routeIds, "routeIds"));
        seedDatasetId = Objects.requireNonNull(seedDatasetId, "seedDatasetId");
        seedNotes = List.copyOf(Objects.requireNonNull(seedNotes, "seedNotes"));
        seedFingerprint = Objects.requireNonNull(seedFingerprint, "seedFingerprint");
    }
}