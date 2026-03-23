package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.api.BenchmarkHttpServer;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapReport;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapRequest;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreConfigKeys;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreResolvedRuntime;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult;

import java.util.List;
import java.util.stream.Collectors;

public final class SpiCoreApplicationAssembler {

    public SpiCoreBootstrapBundle assemble(SpiCoreResolvedRuntime resolved, BenchmarkBootstrapRequest request) {
                BenchmarkSeedResult seedResult = resolved.seedState().current();
        BenchmarkHttpServer httpServer = resolved.runtime().httpServer()
                .orElseThrow(() -> new IllegalStateException("SPI+CORE benchmark runtime must expose an HTTP server"));
        List<BenchmarkRoute> routes = httpServer.routes();
        SpiCoreReadinessProbe readinessProbe = new SpiCoreReadinessProbe(httpServer, "/health/ready");
        BenchmarkStartupManifest startupManifest = new BenchmarkStartupManifest(
                manifestId(resolved, request),
                resolved.config().getOrDefault(SpiCoreConfigKeys.CONFIG_EXECUTION_MODE,
                        SpiCoreConfigKeys.DEFAULT_EXECUTION_MODE),
                resolved.config().getOrDefault(SpiCoreConfigKeys.PROP_HTTP_BIND_HOST,
                        SpiCoreConfigKeys.DEFAULT_HTTP_BIND_HOST),
                Integer.parseInt(resolved.config().getOrDefault(SpiCoreConfigKeys.PROP_HTTP_PORT,
                        SpiCoreConfigKeys.DEFAULT_HTTP_PORT)),
                readinessProbe.readinessPath(),
                resolved.config().getOrDefault(SpiCoreConfigKeys.CONFIG_BENCHMARK_BASE_PATH,
                        SpiCoreConfigKeys.DEFAULT_BENCHMARK_BASE_PATH));
        BenchmarkApplicationAssembly assembly = new BenchmarkApplicationAssembly(
                resolved.runtime(),
                startupManifest,
                readinessProbe,
                routes,
                seedResult.fingerprint());
        BenchmarkBootstrapReport report = new BenchmarkBootstrapReport(
                resolved.runtime().descriptor(),
                resolved.runtime().capabilities(),
                request.executionClass(),
                startupManifest.manifestId(),
                readinessProbe.readinessPath(),
                routes.stream().map(BenchmarkRoute::routeId).collect(Collectors.toList()),
                                seedResult.datasetId(),
                                seedResult.applied(),
                                seedResult.notes(),
                                seedResult.fingerprint());
        return new SpiCoreBootstrapBundle(assembly, report);
    }

    private static String manifestId(SpiCoreResolvedRuntime resolved, BenchmarkBootstrapRequest request) {
        return String.join(":",
                "spi-core",
                resolved.runtime().descriptor().tier(),
                resolved.runtime().descriptor().runtimeFamily(),
                resolved.runtime().descriptor().protocolModeSelected(),
                request.executionClass());
    }
}