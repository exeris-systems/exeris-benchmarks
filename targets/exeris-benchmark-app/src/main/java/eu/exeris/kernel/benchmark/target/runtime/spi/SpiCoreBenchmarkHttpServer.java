package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkHttpServer;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRouteBinder;

import java.io.IOException;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Logger;

public final class SpiCoreBenchmarkHttpServer implements BenchmarkHttpServer {

    private static final Logger LOGGER = Logger.getLogger(SpiCoreBenchmarkHttpServer.class.getName());
    private static final AtomicBoolean ENTITY_ROUTE_MISS_LOGGED = new AtomicBoolean(false);
    private static final AtomicBoolean ENTITY_ROUTE_MATCH_LOGGED = new AtomicBoolean(false);

    private final SpiCoreBenchmarkLifecycle lifecycle;
    private final BenchmarkRouteBinder routeBinder;

    public SpiCoreBenchmarkHttpServer(SpiCoreBenchmarkLifecycle lifecycle, BenchmarkRouteBinder routeBinder) {
        this.lifecycle = Objects.requireNonNull(lifecycle, "lifecycle");
        this.routeBinder = Objects.requireNonNull(routeBinder, "routeBinder");
    }

    @Override
    public List<BenchmarkRoute> routes() {
        return routeBinder.routes();
    }

    @Override
    public BenchmarkRouteBinder routeBinder() {
        return routeBinder;
    }

    @Override
    public Optional<BenchmarkResponse> dispatch(BenchmarkRequestContext request) throws IOException {
        Objects.requireNonNull(request, "request");
        List<BenchmarkRoute> routes = routeBinder.routes();
        Optional<BenchmarkRoute> route = routes.stream()
                .filter(candidate -> candidate.method().equalsIgnoreCase(request.method()))
                .filter(candidate -> matchesPath(candidate.path(), request.path()))
                .findFirst();
        if (route.isEmpty()) {
            if (request.path().contains("entities") && ENTITY_ROUTE_MISS_LOGGED.compareAndSet(false, true)) {
                List<String> routeTemplates = routes.stream().map(BenchmarkRoute::path).toList();
                LOGGER.warning(() -> "Entity route miss: method=" + request.method()
                        + ", path=" + request.path()
                        + ", routeTemplates=" + routeTemplates);
            }
            return Optional.empty();
        }
        BenchmarkRoute matchedRoute = route.get();
        if (matchedRoute.routeId().startsWith("entity-read-by-id")
                && ENTITY_ROUTE_MATCH_LOGGED.compareAndSet(false, true)) {
            LOGGER.info(() -> "Entity route matched: method=" + request.method()
                    + ", path=" + request.path()
                    + ", routePath=" + matchedRoute.path());
        }
        Optional<BenchmarkHttpHandlerAdapter> adapter = routeBinder.bind(matchedRoute.routeId())
                .map(BenchmarkHttpHandlerAdapter::new);
        if (adapter.isEmpty()) {
            return Optional.empty();
        }
        return Optional.of(adapter.get().handle(request));
    }

    @Override
    public boolean isReady() {
        return lifecycle.isReady();
    }

    private static boolean matchesPath(String routePath, String requestPath) {
        if (routePath.equals(requestPath)) {
            return true;
        }
        if (routePath.indexOf('{') < 0) {
            return false;
        }
        String[] routeSegments = routePath.split("/");
        String[] requestSegments = requestPath.split("/");
        if (routeSegments.length != requestSegments.length) {
            return false;
        }
        for (int i = 0; i < routeSegments.length; i++) {
            String routeSegment = routeSegments[i];
            String requestSegment = requestSegments[i];
            boolean wildcardSegment = routeSegment.length() >= 2
                    && routeSegment.startsWith("{")
                    && routeSegment.endsWith("}");
            if (wildcardSegment) {
                if (requestSegment.isEmpty()) {
                    return false;
                }
                continue;
            }
            if (!routeSegment.equals(requestSegment)) {
                return false;
            }
        }
        return true;
    }

    private record BenchmarkHttpHandlerAdapter(eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler handler) {

        private BenchmarkResponse handle(BenchmarkRequestContext request) throws IOException {
            return handler.handle(request);
        }
    }
}