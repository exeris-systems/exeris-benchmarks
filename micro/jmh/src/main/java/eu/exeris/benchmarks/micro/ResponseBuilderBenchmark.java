package eu.exeris.benchmarks.micro;

import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpResponse;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.http.HttpVersion;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Benchmarks the Exeris response builder chain.
 *
 * Every outbound response goes through the response builder. This benchmark
 * measures the cost of the builder call chain: status + headers + body.
 *
 * Run:
 *   java -jar target/benchmarks.jar ResponseBuilder -wi 5 -i 10 -f 3 -prof gc
 */
@BenchmarkMode({Mode.AverageTime, Mode.Throughput})
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Benchmark)
@Warmup(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 2, timeUnit = TimeUnit.SECONDS)
@Fork(value = 3, jvmArgsAppend = {
    "-XX:+UseG1GC",
    "-XX:+AlwaysPreTouch",
    "-Xms256m", "-Xmx256m"
})
public class ResponseBuilderBenchmark {

    private static final HttpStatus UNPROCESSABLE_ENTITY = new HttpStatus(422, "Unprocessable Entity");
    private static final List<HttpHeader> OK_JSON_HEADERS = List.of(
            new HttpHeader("Content-Type", "application/json"),
            new HttpHeader("Cache-Control", "no-store"),
            new HttpHeader("Content-Length", "0")
    );
    private static final List<HttpHeader> ERROR_JSON_HEADERS = List.of(
            new HttpHeader("Content-Type", "application/problem+json"),
            new HttpHeader("X-Error-Code", "validation_failed"),
            new HttpHeader("Content-Length", "0")
    );

    @Benchmark
    public void buildOk(Blackhole bh) {
        HttpResponse response = HttpResponse.noBody(HttpStatus.OK, HttpVersion.HTTP_1_1, OK_JSON_HEADERS);
        bh.consume(response);
    }

    @Benchmark
    public void build404(Blackhole bh) {
        HttpResponse response = HttpResponse.noBody(HttpStatus.NOT_FOUND, HttpVersion.HTTP_1_1);
        bh.consume(response);
    }

    @Benchmark
    public void buildError(Blackhole bh) {
        HttpResponse response = HttpResponse.noBody(UNPROCESSABLE_ENTITY, HttpVersion.HTTP_1_1, ERROR_JSON_HEADERS);
        bh.consume(response);
    }
}
