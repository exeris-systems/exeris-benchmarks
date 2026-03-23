package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.api.BenchmarkMode;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapRequest;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreBenchmarkConfigurationSource;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreBenchmarkRuntimeResolver;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreConfigKeys;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreResolvedRuntime;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkLifecycle;

import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Collectors;

public final class BenchmarkTargetMain {

    private BenchmarkTargetMain() {
    }

    public static void main(String[] args) {
        Map<String, String> config = new SpiCoreBenchmarkConfigurationSource().load();
        BenchmarkBootstrapRequest request = new BenchmarkBootstrapRequest(
                parseBenchmarkMode(config.get(SpiCoreConfigKeys.CONFIG_BENCHMARK_MODE)),
                config.get(SpiCoreConfigKeys.CONFIG_RUNTIME_FAMILY),
                config.get(SpiCoreConfigKeys.CONFIG_PROTOCOL_MODE_SELECTED),
                config.get(SpiCoreConfigKeys.CONFIG_IMPLEMENTATION_VARIANT),
                config.get(SpiCoreConfigKeys.CONFIG_EXECUTION_CLASS),
                config.get(SpiCoreConfigKeys.CONFIG_SEED_DATASET_ID),
                config);

        SpiCoreBenchmarkRuntimeResolver resolver = new SpiCoreBenchmarkRuntimeResolver();
        SpiCoreResolvedRuntime resolved = resolver.prepare(request);
        SpiCoreBenchmarkLifecycle lifecycle = resolved.lifecycle();
        AtomicBoolean shutdownRequested = new AtomicBoolean(false);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (shutdownRequested.compareAndSet(false, true)) {
                lifecycle.shutdown();
            }
        }, "benchmark-target-shutdown"));

        try {
            lifecycle.initialize();
            SpiCoreBootstrapBundle bundle = new SpiCoreApplicationAssembler().assemble(resolved, request);
            printStartupSummary(bundle);
            lifecycle.awaitShutdown();
        } finally {
            if (shutdownRequested.compareAndSet(false, true)) {
                lifecycle.shutdown();
            }
        }
    }

    private static BenchmarkMode parseBenchmarkMode(String rawMode) {
        String value = rawMode == null ? SpiCoreConfigKeys.DEFAULT_BENCHMARK_MODE : rawMode;
        try {
            return BenchmarkMode.valueOf(value.trim().replace('-', '_').replace(' ', '_').toUpperCase());
        } catch (IllegalArgumentException invalidMode) {
            throw new IllegalArgumentException("Unsupported benchmark mode: " + rawMode, invalidMode);
        }
    }

    private static void printStartupSummary(SpiCoreBootstrapBundle bundle) {
        String routes = bundle.assembly().routes().stream()
                .map(route -> route.path())
                .collect(Collectors.joining(", "));
        System.out.println(
                "Benchmark target bootstrap: "
                        + "tier=" + bundle.report().resolvedDescriptor().tier()
                        + ", runtimeFamily=" + bundle.report().resolvedDescriptor().runtimeFamily()
                        + ", protocolModeSelected=" + bundle.report().resolvedDescriptor().protocolModeSelected()
                        + ", implementationVariant=" + bundle.report().resolvedDescriptor().implementationVariant());
        System.out.println(
                "Startup manifest: executionMode=" + bundle.assembly().startupManifest().executionMode()
                        + ", host=" + bundle.assembly().startupManifest().host()
                        + ", port=" + bundle.assembly().startupManifest().port()
                        + ", readinessPath=" + bundle.assembly().readinessProbe().readinessPath()
                        + ", benchmarkBasePath=" + bundle.assembly().startupManifest().benchmarkBasePath()
                        + ", ready=" + bundle.assembly().readinessProbe().isReady());
        System.out.println("Routes: " + routes);
        boolean ready = bundle.assembly().readinessProbe().isReady();
        boolean hasRoutes = !bundle.assembly().routes().isEmpty();
        System.out.println(
            "Handler binding evidence: routesConfigured=" + hasRoutes
                + ", readinessReportedReady=" + ready
                + ", spiHttpExportExpectedWhenReady=" + ready);
        boolean physicalSeedApplied = bundle.report().seedApplied();
        System.out.println(
                "Seed dataset: datasetId=" + bundle.report().seedDatasetId()
                + ", logicalFingerprintPresent=true"
                + ", physicalManifestApplied=" + physicalSeedApplied
                        + ", fingerprintRevision=" + bundle.assembly().seedFingerprint().revision()
                        + ", fingerprintChecksum=" + bundle.assembly().seedFingerprint().checksum());
    }
}