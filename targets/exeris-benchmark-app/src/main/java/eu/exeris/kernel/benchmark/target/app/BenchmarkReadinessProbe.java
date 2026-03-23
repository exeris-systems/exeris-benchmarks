package eu.exeris.kernel.benchmark.target.app;

public interface BenchmarkReadinessProbe {

    boolean isReady();

    String readinessPath();
}