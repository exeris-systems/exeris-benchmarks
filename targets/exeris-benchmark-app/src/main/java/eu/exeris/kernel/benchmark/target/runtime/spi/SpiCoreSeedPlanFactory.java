package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntimeDescriptor;
import eu.exeris.kernel.benchmark.target.api.BenchmarkScenarioCatalog;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapRequest;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreConfigKeys;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkResetPolicy;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeSet;

public final class SpiCoreSeedPlanFactory {

    public BenchmarkSeedPlan create(
            BenchmarkBootstrapRequest request,
            BenchmarkRuntimeDescriptor descriptor,
            BenchmarkCapabilities capabilities,
            BenchmarkScenarioCatalog scenarioCatalog,
            BootstrapSelector selector) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        parameters.put("bootstrapContractVersion", descriptor.bootstrapContractVersion());
        parameters.put("catalogVersion", scenarioCatalog.catalogVersion());
        parameters.put("executionClass", request.executionClass());
        parameters.put("implementationVariant", descriptor.implementationVariant());
        parameters.put("httpEnabled", Boolean.toString(capabilities.httpSupported()));
        parameters.put("persistenceEnabled", Boolean.toString(capabilities.persistenceSupported()));
        parameters.put("protocolModeSelected", descriptor.protocolModeSelected());
        parameters.put("requestedBenchmarkMode", request.requestedBenchmarkMode().name());
        parameters.put("runtimeFamily", descriptor.runtimeFamily());
        parameters.put("scenarioIds", String.join(",", new TreeSet<>(scenarioCatalog.scenarioIds())));
        parameters.put("subsystems", subsystemSignature(request, capabilities));
        parameters.put("tier", descriptor.tier());
        return new BenchmarkSeedPlan(request.seedDatasetId(), BenchmarkResetPolicy.IF_REQUIRED, Map.copyOf(parameters));
    }

    private static String subsystemSignature(BenchmarkBootstrapRequest request, BenchmarkCapabilities capabilities) {
        String configured = request.config().get(SpiCoreConfigKeys.PROP_SUBSYSTEMS);
        if (configured != null && !configured.isBlank()) {
            return configured;
        }
        return capabilities.persistenceSupported() ? "http,persistence" : "http";
    }
}