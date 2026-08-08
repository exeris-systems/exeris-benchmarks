package eu.exeris.benchmarks.targets.springapp.application;

import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Config;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Provides a managed Neo4j Driver bean for the graph-backed benchmark path.
 * Active only when exeris.graph.backend.type=neo4j.
 * When exeris.graph.backend.type=pgq (default), this config is skipped and no
 * Driver bean is registered — GraphShopService receives null via ObjectProvider
 * and silently no-ops all graph calls.
 */
@Configuration
@ConditionalOnProperty(name = "exeris.graph.backend.type", havingValue = "neo4j")
public class GraphShopConfig {

    @Bean(destroyMethod = "close")
    public Driver neo4jGraphShopDriver(
            @Value("${exeris.graph.neo4j.uri}") String uri,
            @Value("${exeris.graph.neo4j.user}") String user,
            @Value("${exeris.graph.neo4j.password}") String password,
            @Value("${exeris.graph.neo4j.pool.max-size:100}") int maxPoolSize
    ) {
        var config = Config.builder()
                .withMaxConnectionPoolSize(maxPoolSize)
                .build();
        return GraphDatabase.driver(uri, AuthTokens.basic(user, password), config);
    }
}
