package eu.exeris.kernel.benchmark.target.api;

import java.util.Optional;

public interface BenchmarkRuntime {

    BenchmarkRuntimeDescriptor descriptor();

    BenchmarkCapabilities capabilities();

    BenchmarkLifecycle lifecycle();

    Optional<BenchmarkHttpServer> httpServer();

    Optional<BenchmarkPersistence> persistence();

    Optional<BenchmarkGraph> graph();

    Optional<BenchmarkTelemetry> telemetry();

    Optional<BenchmarkSchemaProvisioner> schemaProvisioner();

    Optional<BenchmarkSeedDataset> seedDataset();

    Optional<BenchmarkScenarioCatalog> scenarioCatalog();
}