package eu.exeris.kernel.benchmark.target.api;

import java.util.Set;

public interface BenchmarkScenarioCatalog {

    String catalogVersion();

    Set<String> scenarioIds();
}