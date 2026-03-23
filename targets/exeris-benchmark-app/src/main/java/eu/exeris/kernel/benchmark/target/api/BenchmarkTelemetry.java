package eu.exeris.kernel.benchmark.target.api;

import eu.exeris.kernel.benchmark.target.telemetry.BenchmarkDiagnosticSnapshot;
import eu.exeris.kernel.benchmark.target.telemetry.BenchmarkTelemetryProfile;

public interface BenchmarkTelemetry {

    BenchmarkTelemetryProfile profile();

    BenchmarkDiagnosticSnapshot snapshot();
}