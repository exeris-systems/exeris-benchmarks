package eu.exeris.benchmarks.micro;

import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpRequest;
import eu.exeris.kernel.spi.http.HttpVersion;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Benchmarks the overhead of Exeris request wrapper construction.
 *
 * The request wrapper is constructed on every inbound request. Its construction
 * cost directly adds to baseline latency. On the zero-copy / zero-alloc claim
 * path, wrapper construction must not allocate on the heap beyond initial setup.
 *
 * Run:
 *   java -jar target/benchmarks.jar RequestWrapper -prof gc -wi 5 -i 10 -f 3
 */
@BenchmarkMode({Mode.AverageTime, Mode.SampleTime})
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Benchmark)
@Warmup(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 2, timeUnit = TimeUnit.SECONDS)
@Fork(value = 3, jvmArgsAppend = {
    "-XX:+UseG1GC",
    "-XX:+AlwaysPreTouch",
    "-XX:+PreserveFramePointer",
    "-Xms256m", "-Xmx256m"
})
public class RequestWrapperBenchmark {

    private static final String REQUEST_PATH = "/api/v1/health";

    private List<HttpHeader> headers;
    private HttpRequest prebuiltRequest;

    @Setup(Level.Trial)
    public void setup() {
        headers = List.of(
                new HttpHeader("Host", "localhost:8080"),
                new HttpHeader("Accept", "application/json"),
                new HttpHeader("X-Request-Id", "bench-0001"),
                new HttpHeader("User-Agent", "jmh-request-wrapper")
        );
        prebuiltRequest = HttpRequest.noBody(HttpMethod.GET, REQUEST_PATH, HttpVersion.HTTP_1_1, headers);
    }

    @Benchmark
    public void wrapRequest(Blackhole bh) {
        HttpRequest wrapped = HttpRequest.noBody(HttpMethod.GET, REQUEST_PATH, HttpVersion.HTTP_1_1, headers);
        bh.consume(wrapped);
    }

    @Benchmark
    public void accessHeader(Blackhole bh) {
        bh.consume(prebuiltRequest.firstHeader("X-Request-Id"));
    }

    @Benchmark
    public void wrapAndAccess(Blackhole bh) {
        HttpRequest wrapped = HttpRequest.noBody(HttpMethod.GET, REQUEST_PATH, HttpVersion.HTTP_1_1, headers);
        bh.consume(wrapped.firstHeader("X-Request-Id"));
    }
}
