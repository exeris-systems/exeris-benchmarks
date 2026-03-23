package eu.exeris.kernel.benchmark.target.bootstrap;

import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntime;

public interface BenchmarkRuntimeResolver {

    BenchmarkRuntime resolve(BenchmarkBootstrapRequest request);
}