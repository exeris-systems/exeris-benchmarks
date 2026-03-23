package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.api.BenchmarkGraph;
import eu.exeris.kernel.benchmark.target.api.BenchmarkHttpServer;
import eu.exeris.kernel.benchmark.target.api.BenchmarkPersistence;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntime;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntimeDescriptor;
import eu.exeris.kernel.benchmark.target.api.BenchmarkScenarioCatalog;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSchemaProvisioner;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedDataset;
import eu.exeris.kernel.benchmark.target.api.BenchmarkTelemetry;

import java.util.Objects;
import java.util.Optional;

public final class SpiCoreBenchmarkRuntime implements BenchmarkRuntime {

    private final BenchmarkRuntimeDescriptor descriptor;
    private final BenchmarkCapabilities capabilities;
    private final SpiCoreBenchmarkLifecycle lifecycle;
    private final BenchmarkHttpServer httpServer;
    private final BenchmarkSeedDataset seedDataset;
    private final BenchmarkScenarioCatalog scenarioCatalog;

    public SpiCoreBenchmarkRuntime(
            BenchmarkRuntimeDescriptor descriptor,
            BenchmarkCapabilities capabilities,
            SpiCoreBenchmarkLifecycle lifecycle,
            BenchmarkHttpServer httpServer,
            BenchmarkSeedDataset seedDataset,
            BenchmarkScenarioCatalog scenarioCatalog) {
        this.descriptor = Objects.requireNonNull(descriptor, "descriptor");
        this.capabilities = Objects.requireNonNull(capabilities, "capabilities");
        this.lifecycle = Objects.requireNonNull(lifecycle, "lifecycle");
        this.httpServer = Objects.requireNonNull(httpServer, "httpServer");
        this.seedDataset = Objects.requireNonNull(seedDataset, "seedDataset");
        this.scenarioCatalog = Objects.requireNonNull(scenarioCatalog, "scenarioCatalog");
    }

    @Override
    public BenchmarkRuntimeDescriptor descriptor() {
        return descriptor;
    }

    @Override
    public BenchmarkCapabilities capabilities() {
        return capabilities;
    }

    @Override
    public SpiCoreBenchmarkLifecycle lifecycle() {
        return lifecycle;
    }

    @Override
    public Optional<BenchmarkHttpServer> httpServer() {
        return Optional.of(httpServer);
    }

    @Override
    public Optional<BenchmarkPersistence> persistence() {
        return Optional.empty();
    }

    @Override
    public Optional<BenchmarkGraph> graph() {
        return Optional.empty();
    }

    @Override
    public Optional<BenchmarkTelemetry> telemetry() {
        return Optional.empty();
    }

    @Override
    public Optional<BenchmarkSchemaProvisioner> schemaProvisioner() {
        return Optional.empty();
    }

    @Override
    public Optional<BenchmarkSeedDataset> seedDataset() {
        return Optional.of(seedDataset);
    }

    @Override
    public Optional<BenchmarkScenarioCatalog> scenarioCatalog() {
        return Optional.of(scenarioCatalog);
    }
}