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
 * JMH benchmark for the FD-owner TLS engine ownership model (B6).
 *
 * <p>Exercises a {@link eu.exeris.kernel.spi.crypto.TlsEngine} that owns a real socket
 * file descriptor via a loopback socket pair. See {@link AbstractFdOwnerTlsEngineBenchmark}
 * for the ownership-model contract and Memory-BIO comparison caveats.
 *
 * <p><b>Provider tier:</b> {@code "community"} — preserves existing system-property
 * wiring ({@code -Dexeris.tls.community.cryptoProviderClass}/{@code memoryProviderClass}/
 * {@code certPem}/{@code keyPem}) so manifest configuration continues to work.
 */
public class FdOwnerTlsEngineLoopbackBenchmark extends AbstractFdOwnerTlsEngineBenchmark {

    @Override
    protected String tier() {
        return "fd-owner-engine";
    }

    @Override
    protected String providerTier() {
        return "community";
    }

    @Benchmark
    @BenchmarkMode(Mode.Throughput)
    @OutputTimeUnit(TimeUnit.SECONDS)
    @Override
    public void wrapThroughput(Blackhole bh, TransportAuxCounters counters) {
        super.wrapThroughput(bh, counters);
    }

    @Setup(Level.Iteration)
    public void markMeasurementStart() {
        emitPhaseMarker();
    }
}
