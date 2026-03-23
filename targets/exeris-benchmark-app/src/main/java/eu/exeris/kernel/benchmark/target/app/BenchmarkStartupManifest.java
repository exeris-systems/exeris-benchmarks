package eu.exeris.kernel.benchmark.target.app;

import java.util.Objects;

public record BenchmarkStartupManifest(
        String manifestId,
        String executionMode,
        String host,
        int port,
        String readinessPath,
        String benchmarkBasePath) {

    public BenchmarkStartupManifest {
        manifestId = Objects.requireNonNull(manifestId, "manifestId");
        executionMode = Objects.requireNonNull(executionMode, "executionMode");
        host = Objects.requireNonNull(host, "host");
        readinessPath = Objects.requireNonNull(readinessPath, "readinessPath");
        benchmarkBasePath = Objects.requireNonNull(benchmarkBasePath, "benchmarkBasePath");
    }
}