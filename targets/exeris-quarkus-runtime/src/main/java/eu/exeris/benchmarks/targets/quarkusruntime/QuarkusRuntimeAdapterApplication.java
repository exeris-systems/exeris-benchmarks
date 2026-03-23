package eu.exeris.benchmarks.targets.quarkusruntime;

import eu.exeris.kernel.benchmark.target.app.BenchmarkTargetMain;
import io.quarkus.runtime.Quarkus;
import io.quarkus.runtime.QuarkusApplication;
import io.quarkus.runtime.annotations.QuarkusMain;

@QuarkusMain
public class QuarkusRuntimeAdapterApplication implements QuarkusApplication {

    public static void main(String[] args) {
        Quarkus.run(QuarkusRuntimeAdapterApplication.class, args);
    }

    @Override
    public int run(String... args) {
        BenchmarkTargetMain.main(args);
        return 0;
    }
}
