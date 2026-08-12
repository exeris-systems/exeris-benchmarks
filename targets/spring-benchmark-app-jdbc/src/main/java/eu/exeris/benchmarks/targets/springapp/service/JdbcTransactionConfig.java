package eu.exeris.benchmarks.targets.springapp.application;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;

/**
 * spring-boot-starter-jdbc and spring-boot-starter-data-neo4j (the latter present only for the
 * e2e-shop-order-saga scenario's graph path, see GraphShopConfig) each auto-configure their own
 * {@link PlatformTransactionManager} with neither marked {@code @Primary}. Without this bean,
 * {@code @Transactional} on {@code UserService} — a purely JDBC-backed read — resolved to the
 * Neo4j transaction manager and failed with "Could not open a new Neo4j session" whenever Neo4j
 * was not running, even though the method never touches the graph backend. Caught by boot-verify
 * against a live target (2026-08-10): the endpoint returned a misleading 401 via the unauthorized
 * /error forward documented in SecurityConfig, not the underlying transaction failure.
 */
@Configuration
public class JdbcTransactionConfig {

    @Bean
    @Primary
    public PlatformTransactionManager transactionManager(DataSource dataSource) {
        return new DataSourceTransactionManager(dataSource);
    }
}
