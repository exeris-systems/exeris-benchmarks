package eu.exeris.benchmarks.targets.springapp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

// No @ImportRuntimeHints(HibernateLoggingRuntimeHints.class): there is no Hibernate on this
// target's classpath. Persistence goes through the kernel-native TransactionalExecutor wired in
// ExerisPersistenceConfiguration.
@SpringBootApplication(proxyBeanMethods = false)
public class SpringBenchmarkApplication {

    public static void main(String[] args) {
        SpringApplication.run(SpringBenchmarkApplication.class, args);
    }
}
