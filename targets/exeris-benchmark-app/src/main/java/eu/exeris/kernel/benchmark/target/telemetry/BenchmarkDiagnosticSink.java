package eu.exeris.kernel.benchmark.target.telemetry;

public interface BenchmarkDiagnosticSink {

    void publish(BenchmarkDiagnosticSnapshot snapshot);
}