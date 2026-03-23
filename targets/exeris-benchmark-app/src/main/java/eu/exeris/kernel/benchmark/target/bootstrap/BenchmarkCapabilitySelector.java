package eu.exeris.kernel.benchmark.target.bootstrap;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;

public interface BenchmarkCapabilitySelector {

    BenchmarkCapabilities select(BenchmarkBootstrapRequest request, BenchmarkCapabilities availableCapabilities);
}