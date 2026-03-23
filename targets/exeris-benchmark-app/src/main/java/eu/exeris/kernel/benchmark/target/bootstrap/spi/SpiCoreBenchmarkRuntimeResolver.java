package eu.exeris.kernel.benchmark.target.bootstrap.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.api.BenchmarkMode;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntime;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntimeDescriptor;
import eu.exeris.kernel.benchmark.target.api.BenchmarkScenarioCatalog;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedDataset;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapRequest;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkRuntimeResolver;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkHttpServer;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkLifecycle;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkRuntime;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkRouteBinder;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkScenarioCatalog;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkSeedDataset;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkHttpExchangeHandler;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkHttpBridgeRegistry;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreLogicalBenchmarkSeeder;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreSeedExecutionState;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreSeedPlanFactory;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;

import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

public final class SpiCoreBenchmarkRuntimeResolver implements BenchmarkRuntimeResolver {

    private final SpiCoreBenchmarkCapabilitySelector capabilitySelector = new SpiCoreBenchmarkCapabilitySelector();

    @Override
    public BenchmarkRuntime resolve(BenchmarkBootstrapRequest request) {
        return prepare(request).runtime();
    }

    public SpiCoreResolvedRuntime prepare(BenchmarkBootstrapRequest request) {
        BootstrapSelector selector = resolveSelector(request.config());
        BenchmarkCapabilities availableCapabilities = inferCapabilities(request, selector);
        BenchmarkCapabilities selectedCapabilities = capabilitySelector.select(request, availableCapabilities);
        BenchmarkScenarioCatalog scenarioCatalog = new SpiCoreBenchmarkScenarioCatalog();
        BenchmarkRuntimeDescriptor descriptor = new BenchmarkRuntimeDescriptor(
                request.config().getOrDefault(SpiCoreConfigKeys.CONFIG_TIER, SpiCoreConfigKeys.DEFAULT_TIER),
                request.runtimeFamily(),
                SpiCoreBenchmarkCapabilitySelector.normalizeProtocolMode(request.protocolMode()),
                request.implementationVariant(),
                "spi-core-bootstrap",
                "phase-6",
                scenarioCatalog.catalogVersion(),
                "none",
                "phase-6-bootstrap");

        BenchmarkSeedPlan seedPlan = new SpiCoreSeedPlanFactory().create(request, descriptor, selectedCapabilities,
                scenarioCatalog, selector);
        BenchmarkSeedResult seedResult = new SpiCoreLogicalBenchmarkSeeder().seed(seedPlan);
        SpiCoreSeedExecutionState seedState = new SpiCoreSeedExecutionState(seedResult);

        SpiCoreBenchmarkLifecycle lifecycle = new SpiCoreBenchmarkLifecycle(selector, request.config(), seedPlan, seedState);
        SpiCoreBenchmarkRouteBinder routeBinder = new SpiCoreBenchmarkRouteBinder(lifecycle);
        SpiCoreBenchmarkHttpServer httpServer = new SpiCoreBenchmarkHttpServer(lifecycle, routeBinder);
        SpiCoreBenchmarkHttpBridgeRegistry.install(new SpiCoreBenchmarkHttpExchangeHandler(httpServer));

        BenchmarkSeedDataset seedDataset = new SpiCoreBenchmarkSeedDataset(seedState);
        BenchmarkRuntime runtime = new SpiCoreBenchmarkRuntime(
                descriptor,
                selectedCapabilities,
                lifecycle,
                httpServer,
                seedDataset,
                scenarioCatalog);
        return new SpiCoreResolvedRuntime(runtime, lifecycle, selector, request.config(), seedPlan, seedState);
    }

    private static BenchmarkCapabilities inferCapabilities(
            BenchmarkBootstrapRequest request,
            BootstrapSelector selector) {
        Set<String> supportedProtocolModes = parseProtocolModes(request.config());
        Set<BenchmarkMode> supportedBenchmarkModes = parseBenchmarkModes(request.config(), request.runtimeFamily());
        return new BenchmarkCapabilities(
                supportedProtocolModes,
                supportedBenchmarkModes,
                selector.includes("http"),
                selector.includes("persistence"),
                false,
                false,
                false);
    }

    private static BootstrapSelector resolveSelector(Map<String, String> config) {
        String configuredSubsystems = config.get(SpiCoreConfigKeys.PROP_SUBSYSTEMS);
        if (configuredSubsystems != null && !configuredSubsystems.isBlank()) {
            String[] names = Arrays.stream(configuredSubsystems.split(","))
                    .map(String::trim)
                    .filter(token -> !token.isEmpty())
                    .map(token -> token.toLowerCase(Locale.ROOT))
                    .toArray(String[]::new);
            if (names.length == 0) {
                throw new IllegalArgumentException(
                        SpiCoreConfigKeys.PROP_SUBSYSTEMS + " must contain at least one subsystem name");
            }
            return BootstrapSelector.forNames(names);
        }

        if (isPersistenceConfigured(config)) {
            return BootstrapSelector.forNames("http", "persistence");
        }
        return BootstrapSelector.forNames("http");
    }

    private static boolean isPersistenceConfigured(Map<String, String> config) {
        String propertyValue = config.get(SpiCoreConfigKeys.PROP_PERSISTENCE_JDBC_URL);
        if (propertyValue != null && !propertyValue.isBlank()) {
            return true;
        }
        String envValue = config.get(SpiCoreConfigKeys.ENV_PERSISTENCE_JDBC_URL);
        return envValue != null && !envValue.isBlank();
    }

    private static Set<String> parseProtocolModes(Map<String, String> config) {
        String rawModes = config.getOrDefault(
                SpiCoreConfigKeys.CONFIG_SUPPORTED_PROTOCOL_MODES,
                SpiCoreConfigKeys.DEFAULT_SUPPORTED_PROTOCOL_MODES);
        LinkedHashSet<String> modes = new LinkedHashSet<>();
        Arrays.stream(rawModes.split(","))
                .map(String::trim)
                .filter(token -> !token.isEmpty())
                .map(String::toUpperCase)
                .forEach(modes::add);
        if (modes.isEmpty()) {
            modes.add(SpiCoreConfigKeys.DEFAULT_PROTOCOL_MODE_SELECTED);
        }
        return Set.copyOf(modes);
    }

    private static Set<BenchmarkMode> parseBenchmarkModes(Map<String, String> config, String runtimeFamily) {
        String rawModes = config.get(SpiCoreConfigKeys.CONFIG_SUPPORTED_BENCHMARK_MODES);
        LinkedHashSet<BenchmarkMode> modes = new LinkedHashSet<>();
        if (rawModes != null && !rawModes.isBlank()) {
            Arrays.stream(rawModes.split(","))
                    .map(String::trim)
                    .filter(token -> !token.isEmpty())
                    .map(SpiCoreBenchmarkRuntimeResolver::parseBenchmarkMode)
                    .forEach(modes::add);
        }
        if (modes.isEmpty()) {
            if (runtimeFamily.toLowerCase(Locale.ROOT).contains("compat")) {
                modes.add(BenchmarkMode.COMPATIBILITY);
            } else {
                modes.add(BenchmarkMode.PURE);
            }
            modes.add(BenchmarkMode.REGRESSION_GUARD);
            modes.add(BenchmarkMode.EXPLORATORY);
        }
        return Set.copyOf(modes);
    }

    private static BenchmarkMode parseBenchmarkMode(String value) {
        return BenchmarkMode.valueOf(value.trim().replace('-', '_').replace(' ', '_').toUpperCase(Locale.ROOT));
    }
}