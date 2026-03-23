package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapReport;

import java.util.Objects;

public record SpiCoreBootstrapBundle(
        BenchmarkApplicationAssembly assembly,
        BenchmarkBootstrapReport report) {

    public SpiCoreBootstrapBundle {
        assembly = Objects.requireNonNull(assembly, "assembly");
        report = Objects.requireNonNull(report, "report");
    }
}