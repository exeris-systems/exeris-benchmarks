package eu.exeris.kernel.benchmark.target.api;

import java.util.Optional;

public interface BenchmarkSeedDataset {

    String datasetId();

    Optional<BenchmarkSeedFingerprint> fingerprint();
}