package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.api.BenchmarkHttpServer;

import java.util.Objects;

public final class SpiCoreReadinessProbe implements BenchmarkReadinessProbe {

    private final BenchmarkHttpServer httpServer;
    private final String readinessPath;

    public SpiCoreReadinessProbe(BenchmarkHttpServer httpServer, String readinessPath) {
        this.httpServer = Objects.requireNonNull(httpServer, "httpServer");
        this.readinessPath = Objects.requireNonNull(readinessPath, "readinessPath");
    }

    @Override
    public boolean isReady() {
        return httpServer.isReady();
    }

    @Override
    public String readinessPath() {
        return readinessPath;
    }
}