package eu.exeris.kernel.benchmark.target.http;

import java.util.List;
import java.util.Optional;

public interface BenchmarkRouteBinder {

    List<BenchmarkRoute> routes();

    Optional<BenchmarkHttpHandler> bind(String routeId);
}