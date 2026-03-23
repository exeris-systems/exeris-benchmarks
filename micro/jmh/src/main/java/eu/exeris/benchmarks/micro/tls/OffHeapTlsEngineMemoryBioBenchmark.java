package eu.exeris.benchmarks.micro.tls;

import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Setup;

/**
 * JMH engine-level benchmark for OffHeapTlsEngine (B5).
 *
 * <p>Uses a neutral in-process Memory-BIO harness as a transport-agnostic lens.
 * Benchmark identity ({@link #tier()}) is {@code "offheap-engine"}; provider
 * resolution ({@link #providerTier()}) uses the enterprise provider configuration.
 * This benchmark is not directly equivalent to the Community fd-owner/socket path.
 * The primary comparator set for this lens is B3/B4.
 */
public class OffHeapTlsEngineMemoryBioBenchmark extends AbstractMemoryBioTlsEngineBenchmark {

    @Override
    protected String tier() {
        return "offheap-engine";
    }

    @Override
    protected String providerTier() {
        return "enterprise";
    }

    @Setup(Level.Iteration)
    public void markMeasurementStart() {
        emitPhaseMarker();
    }
}
