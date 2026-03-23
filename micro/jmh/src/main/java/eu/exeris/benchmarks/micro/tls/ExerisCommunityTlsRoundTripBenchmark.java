package eu.exeris.benchmarks.micro.tls;

import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.infra.Blackhole;

import java.util.concurrent.TimeUnit;

/**
 * JMH benchmark for Community-tier Exeris TLS full roundtrip (B6b).
 *
 * <p><b>Measurement scope:</b> TLS encrypt + {@code write(2)} via client FD + TCP loopback
 * traversal + {@code read(2)} via server FD + TLS decrypt. Both kernel crossings are included.
 *
 * <p><b>Comparison caveat:</b> NOT directly comparable to Enterprise Memory-BIO roundtrip.
 * Community includes 2 kernel syscalls ({@code write(2)} + {@code read(2)}).
 * Enterprise has 0 kernel crossings. Label explicitly in all reports.
 *
 * <p><b>No drain thread:</b> Unlike {@link ExerisCommunityTlsBenchmark}, this harness does NOT
 * start the drain thread. Server-side consumption is performed exclusively by
 * {@code serverEngine.unwrap()} within the benchmark method body.
 */
public class ExerisCommunityTlsRoundTripBenchmark extends AbstractCommunityTlsBenchmark {

    @Override
    protected String tier() {
        return "community";
    }

    /**
     * Suppress drain thread — {@code SSL_read} inside {@code serverEngine.unwrap()} reads
     * directly from the server FD kernel buffer. A concurrent drain thread would race on
     * the same FD and cause {@code SSL_read} to block indefinitely.
     */
    @Override
    protected void afterHandshakeSetUp() throws Exception {
        // No drain thread for roundtrip harness — SSL_read handles server-side consumption.
    }

    /** Symmetric override: no drain thread was started, nothing to stop. */
    @Override
    protected void beforeTearDownHook() throws Exception {
        // symmetric with afterHandshakeSetUp — no drain thread to stop
    }

    @Benchmark
    @BenchmarkMode({Mode.Throughput, Mode.SampleTime})
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    @Override
    public void wrapUnwrapRoundTrip(Blackhole bh) {
        super.wrapUnwrapRoundTrip(bh);
    }

    @Setup(Level.Iteration)
    public void markMeasurementStart() {
        emitPhaseMarker();
    }
}