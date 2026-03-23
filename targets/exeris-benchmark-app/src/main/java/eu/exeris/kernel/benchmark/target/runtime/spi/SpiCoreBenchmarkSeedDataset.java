package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedDataset;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;

import java.util.Objects;
import java.util.Optional;

public final class SpiCoreBenchmarkSeedDataset implements BenchmarkSeedDataset {

    private final SpiCoreSeedExecutionState seedState;

    public SpiCoreBenchmarkSeedDataset(SpiCoreSeedExecutionState seedState) {
        this.seedState = Objects.requireNonNull(seedState, "seedState");
    }

    @Override
    public String datasetId() {
        return seedState.current().datasetId();
    }

    @Override
    public Optional<BenchmarkSeedFingerprint> fingerprint() {
        return Optional.of(seedState.current().fingerprint());
    }
}