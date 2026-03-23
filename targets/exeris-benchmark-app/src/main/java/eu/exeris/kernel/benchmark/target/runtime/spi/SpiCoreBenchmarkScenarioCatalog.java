package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkScenarioCatalog;

import java.util.Set;

public record SpiCoreBenchmarkScenarioCatalog() implements BenchmarkScenarioCatalog {

    private static final Set<String> SCENARIO_IDS = Set.of(
            "db-ping",
            "health-probe");

    @Override
    public String catalogVersion() {
        return "spi-core-phase-4-catalog-v1";
    }

    @Override
    public Set<String> scenarioIds() {
        return SCENARIO_IDS;
    }
}