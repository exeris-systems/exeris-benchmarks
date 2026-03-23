package eu.exeris.kernel.benchmark.target.http;

import java.util.Objects;

public record BenchmarkRoute(String routeId, String method, String path) {

    public BenchmarkRoute {
        routeId = Objects.requireNonNull(routeId, "routeId");
        method = Objects.requireNonNull(method, "method");
        path = Objects.requireNonNull(path, "path");
    }
}