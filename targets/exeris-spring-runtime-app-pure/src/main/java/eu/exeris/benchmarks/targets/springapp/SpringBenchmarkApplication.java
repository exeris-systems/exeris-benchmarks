package eu.exeris.benchmarks.targets.springapp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.ImportRuntimeHints;

@SpringBootApplication(proxyBeanMethods = false)
@ImportRuntimeHints(HibernateLoggingRuntimeHints.class)
public class SpringBenchmarkApplication {

    public static void main(String[] args) {
        SpringApplication.run(SpringBenchmarkApplication.class, args);
    }
}
