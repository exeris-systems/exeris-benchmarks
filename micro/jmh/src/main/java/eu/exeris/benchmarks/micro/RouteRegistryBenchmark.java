package eu.exeris.benchmarks.micro;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRouteRegistry;
import eu.exeris.spring.runtime.web.ExerisServerResponse;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Benchmarks route registry lookup performance.
 *
 * Simulates: method + path → handler resolution as executed
 * by the Exeris kernel route dispatcher.
 *
 * Run:
 *   java -jar target/benchmarks.jar RouteRegistry -wi 5 -i 10 -f 3 -prof gc
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
public class RouteRegistryBenchmark {

    private ExerisRouteRegistry registry;
    private Map<String, ExerisRequestHandler> baselineRegistry;

    private HttpMethod selectedMethod;
    private String selectedPath;

    @Param({"GET /api/v1/users/123", "POST /api/v1/orders", "GET /health"})
    private String route;

    @Setup(Level.Trial)
    public void setup() {
        ExerisRequestHandler usersById = request -> ExerisServerResponse.ok().body("{\"id\":\"123\"}");
        ExerisRequestHandler createOrder = request -> ExerisServerResponse.status(
                new eu.exeris.kernel.spi.http.HttpStatus(201, "Created")).body("created");
        ExerisRequestHandler health = request -> ExerisServerResponse.ok().body("ok");
        ExerisRequestHandler deleteUser = request -> ExerisServerResponse.status(
                eu.exeris.kernel.spi.http.HttpStatus.NO_CONTENT);
        ExerisRequestHandler updateProfile = request -> ExerisServerResponse.ok().body("updated");
        ExerisRequestHandler listProducts = request -> ExerisServerResponse.ok().body("[]");
        ExerisRequestHandler productById = request -> ExerisServerResponse.ok().body("{\"id\":\"456\"}");
        ExerisRequestHandler createProduct = request -> ExerisServerResponse.status(
                new eu.exeris.kernel.spi.http.HttpStatus(201, "Created")).body("product-created");

        ExerisRouteRegistry.Builder builder = ExerisRouteRegistry.builder();
        baselineRegistry = new HashMap<>();
        registerRoute(builder, HttpMethod.GET, "/api/v1/users/123", usersById);
        registerRoute(builder, HttpMethod.POST, "/api/v1/orders", createOrder);
        registerRoute(builder, HttpMethod.GET, "/health", health);
        registerRoute(builder, HttpMethod.DELETE, "/api/v1/users/123", deleteUser);
        registerRoute(builder, HttpMethod.PUT, "/api/v1/users/123/profile", updateProfile);
        registerRoute(builder, HttpMethod.GET, "/api/v1/products", listProducts);
        registerRoute(builder, HttpMethod.GET, "/api/v1/products/456", productById);
        registerRoute(builder, HttpMethod.POST, "/api/v1/products", createProduct);
        registry = builder.build();

        int separator = route.indexOf(' ');
        selectedMethod = HttpMethod.valueOf(route.substring(0, separator));
        selectedPath = route.substring(separator + 1);
    }

    @Benchmark
    public void lookupExact(Blackhole bh) {
        bh.consume(registry.resolve(selectedMethod, selectedPath));
    }

    @Benchmark
    public void lookupMiss(Blackhole bh) {
        bh.consume(registry.resolve(HttpMethod.GET, "/does/not/exist"));
    }

    @Benchmark
    public void baselineHashMapGet(Blackhole bh) {
        bh.consume(baselineRegistry.get(route));
    }

    private void registerRoute(ExerisRouteRegistry.Builder builder,
                               HttpMethod method,
                               String path,
                               ExerisRequestHandler handler) {
        builder.register(method, path, handler);
        baselineRegistry.put(method.name() + " " + path, handler);
    }
}
