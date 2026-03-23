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
 * JMH benchmark for Community-tier Exeris TLS engine (B6).
 *
 * <p>Exercises the Community FD-owner TLS path via a real loopback socket pair.
 * See {@link AbstractCommunityTlsBenchmark} for transport model constraints and comparison caveats.
 */
public class ExerisCommunityTlsBenchmark extends AbstractCommunityTlsBenchmark {

    @Override
    protected String tier() {
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