package eu.exeris.kernel.benchmark.target.bootstrap;

import java.util.Map;

public interface BenchmarkConfigurationSource {

    Map<String, String> load();
}