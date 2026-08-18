package eu.exeris.benchmarks.targets.springapp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;

@SpringBootApplication(proxyBeanMethods = false)
@ComponentScan(
    // The Axon module lives under ...springapp.application.axon (NOT ...springapp.axon).
    // It is always excluded from the base scan and re-included only when
    // exeris.axon.enabled=true, via AxonModuleConfiguration. This keeps Axon off for
    // pure-read scenarios (entity-read-by-id) while leaving e2e-shop-order-saga
    // (EXERIS_AXON_ENABLED=true) unchanged.
    excludeFilters = @ComponentScan.Filter(
        type = FilterType.REGEX,
        pattern = "eu\\.exeris\\.benchmarks\\.targets\\.springapp\\.application\\.axon\\..*"
    )
)
// No @ImportRuntimeHints(HibernateLoggingRuntimeHints.class): Hibernate is not on this
// target's classpath. Persistence is JdbcTemplate over the Spring DataSource.
public class SpringBenchmarkApplication {

    public static void main(String[] args) {
        SpringApplication.run(SpringBenchmarkApplication.class, args);
    }
}
