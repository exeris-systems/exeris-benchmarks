package eu.exeris.kernel.benchmark.target.app;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.api.BenchmarkRuntimeDescriptor;
import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRoute;

import java.util.List;

public interface BenchmarkTargetApplication {

    BenchmarkRuntimeDescriptor descriptor();

    BenchmarkCapabilities capabilities();

    BenchmarkStartupManifest startupManifest();

    BenchmarkReadinessProbe readinessProbe();

    List<BenchmarkRoute> routes();

    BenchmarkSeedFingerprint seedFingerprint();
}