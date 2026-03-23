package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult;

import java.util.Objects;
import java.util.concurrent.atomic.AtomicReference;

public final class SpiCoreSeedExecutionState {

    private final AtomicReference<BenchmarkSeedResult> current;

    public SpiCoreSeedExecutionState(BenchmarkSeedResult initial) {
        this.current = new AtomicReference<>(Objects.requireNonNull(initial, "initial"));
    }

    public BenchmarkSeedResult current() {
        return current.get();
    }

    public void update(BenchmarkSeedResult result) {
        current.set(Objects.requireNonNull(result, "result"));
    }
}