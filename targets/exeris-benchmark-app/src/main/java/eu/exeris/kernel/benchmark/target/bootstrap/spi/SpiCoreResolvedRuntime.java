package eu.exeris.kernel.benchmark.target.bootstrap.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntime;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreBenchmarkLifecycle;
import eu.exeris.kernel.benchmark.target.runtime.spi.SpiCoreSeedExecutionState;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;

import java.util.Map;
import java.util.Objects;

public record SpiCoreResolvedRuntime(
        BenchmarkRuntime runtime,
        SpiCoreBenchmarkLifecycle lifecycle,
        BootstrapSelector selector,
        Map<String, String> config,
        BenchmarkSeedPlan seedPlan,
        SpiCoreSeedExecutionState seedState) {

    public SpiCoreResolvedRuntime {
        runtime = Objects.requireNonNull(runtime, "runtime");
        lifecycle = Objects.requireNonNull(lifecycle, "lifecycle");
        selector = Objects.requireNonNull(selector, "selector");
        config = Map.copyOf(Objects.requireNonNull(config, "config"));
        seedPlan = Objects.requireNonNull(seedPlan, "seedPlan");
        seedState = Objects.requireNonNull(seedState, "seedState");
    }
}