package eu.exeris.kernel.benchmark.target.api;

import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRouteBinder;

import java.io.IOException;
import java.util.List;
import java.util.Optional;

public interface BenchmarkHttpServer {

    List<BenchmarkRoute> routes();

    BenchmarkRouteBinder routeBinder();

    Optional<BenchmarkResponse> dispatch(BenchmarkRequestContext request) throws IOException;

    boolean isReady();
}