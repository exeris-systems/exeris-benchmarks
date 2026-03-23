package eu.exeris.kernel.benchmark.target.api;

public interface BenchmarkLifecycle {

    void initialize();

    void shutdown();

    boolean isReady();
}