package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRouteBinder;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class SpiCoreBenchmarkRouteBinder implements BenchmarkRouteBinder {

    private final List<BenchmarkRoute> routes;
    private final Map<String, BenchmarkHttpHandler> handlers;

    public SpiCoreBenchmarkRouteBinder(SpiCoreBenchmarkLifecycle lifecycle) {
        Objects.requireNonNull(lifecycle, "lifecycle");
        routes = List.of(
                new BenchmarkRoute("health", "GET", "/health"),
                new BenchmarkRoute("health-live", "GET", "/health/live"),
                new BenchmarkRoute("health-ready", "GET", "/health/ready"),
                new BenchmarkRoute("db-ping", "GET", "/db/ping"),
                new BenchmarkRoute("entity-read-by-id", "GET", "/api/v1/entities/{id}"),
                new BenchmarkRoute("entity-read-by-id-alias", "GET", "/entities/{id}"));

        LinkedHashMap<String, BenchmarkHttpHandler> boundHandlers = new LinkedHashMap<>();
        boundHandlers.put("health", new SpiCoreHealthHandler(lifecycle));
        boundHandlers.put("health-live", new SpiCoreHealthLiveHandler(lifecycle));
        boundHandlers.put("health-ready", new SpiCoreHealthReadyHandler(lifecycle));
        boundHandlers.put("db-ping", new SpiCoreDbPingHandler(lifecycle));
        SpiCoreEntityReadByIdHandler entityReadByIdHandler = new SpiCoreEntityReadByIdHandler();
        boundHandlers.put("entity-read-by-id", entityReadByIdHandler);
        boundHandlers.put("entity-read-by-id-alias", entityReadByIdHandler);
        handlers = Map.copyOf(boundHandlers);
    }

    @Override
    public List<BenchmarkRoute> routes() {
        return routes;
    }

    @Override
    public Optional<BenchmarkHttpHandler> bind(String routeId) {
        return Optional.ofNullable(handlers.get(routeId));
    }
}