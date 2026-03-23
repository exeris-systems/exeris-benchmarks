package eu.exeris.benchmarks.targets.springruntime;

import eu.exeris.kernel.benchmark.target.app.BenchmarkTargetMain;
import org.springframework.boot.Banner;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication(proxyBeanMethods = false)
public class SpringRuntimeAdapterApplication {

    public static void main(String[] args) {
        ConfigurableApplicationContext context = new SpringApplicationBuilder(SpringRuntimeAdapterApplication.class)
                .bannerMode(Banner.Mode.OFF)
                .logStartupInfo(false)
                .lazyInitialization(true)
                .web(WebApplicationType.NONE)
                .run(args);

        try {
            BenchmarkTargetMain.main(args);
        } finally {
            context.close();
        }
    }
}
