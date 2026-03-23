package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntime;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;

import java.util.List;
import java.util.Objects;

public record BenchmarkApplicationAssembly(
        BenchmarkRuntime runtime,
        BenchmarkStartupManifest startupManifest,
        BenchmarkReadinessProbe readinessProbe,
        List<BenchmarkRoute> routes,
        BenchmarkSeedFingerprint seedFingerprint) {

    public BenchmarkApplicationAssembly {
        runtime = Objects.requireNonNull(runtime, "runtime");
        startupManifest = Objects.requireNonNull(startupManifest, "startupManifest");
        readinessProbe = Objects.requireNonNull(readinessProbe, "readinessProbe");
        routes = List.copyOf(Objects.requireNonNull(routes, "routes"));
        seedFingerprint = Objects.requireNonNull(seedFingerprint, "seedFingerprint");
    }
}