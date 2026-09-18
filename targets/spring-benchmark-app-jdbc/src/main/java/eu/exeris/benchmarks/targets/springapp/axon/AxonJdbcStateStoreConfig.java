package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.common.jdbc.ConnectionProvider;
import org.axonframework.common.jdbc.UnitOfWorkAwareConnectionProviderWrapper;
import org.axonframework.common.transaction.TransactionManager;
import org.axonframework.eventhandling.tokenstore.TokenStore;
import org.axonframework.eventhandling.tokenstore.jdbc.JdbcTokenStore;
import org.axonframework.modelling.saga.repository.SagaStore;
import org.axonframework.modelling.saga.repository.jdbc.JdbcSagaStore;
import org.axonframework.modelling.saga.repository.jdbc.PostgresSagaSqlSchema;
import org.axonframework.serialization.Serializer;
import org.axonframework.spring.jdbc.SpringDataSourceConnectionProvider;
import org.axonframework.spring.messaging.unitofwork.SpringTransactionManager;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;

/**
 * Durable tracking tokens and saga state in the shared Postgres, over Axon's own JDBC
 * stores — for BOTH Axon arms.
 *
 * <h2>Why this applies to the Axon Server arm too</h2>
 *
 * Axon Server is an event store. It has no token-store and no saga-store API, and Axon's
 * Spring Boot starter falls back to IN-MEMORY implementations when no bean declares them.
 * Until this configuration existed the Axon Server arm ran exactly that way — its log
 * carried <em>WARN InMemoryTokenStore: An in memory token store is being created</em>, and a
 * live probe (2026-07-17) measured zero writes to {@code saga_entry} /
 * {@code association_value_entry} across two completed sagas.
 *
 * <p>That is not a durable saga engine: a restart loses in-flight saga state, and the
 * tracking position with it. Comparing it against arms that persist saga state — Exeris's
 * outbox, or this stack's own embedded shape — reads a DURABILITY difference as an
 * EFFICIENCY difference, because the in-memory arm simply never pays the writes. CONTRACT-v2
 * §8 forbids collapsing durability tiers, so both Axon arms are put on the same one and the
 * remaining difference between them is the one the comparison is actually about: where
 * EVENTS live (Axon Server vs the shared Postgres, {@link EmbeddedAxonStoreConfig}).
 *
 * <p>The in-memory fallback also hid a real defect for as long as it was in place: with no
 * serialization round-trip the saga is a live Java object, so Jackson's inability to see a
 * saga's private fields — which wrote every saga as {@code {}} — was invisible until a store
 * that actually persists saga state was introduced.
 *
 * <h2>Cost this makes visible</h2>
 *
 * The token store takes a row claim per segment (§9(d): 16 segments), and the saga store
 * writes saga state and association rows per session. On the Axon Server arm that traffic is
 * NEW as of this configuration and lands on the shared Postgres. It is the honest cost of a
 * durable saga engine, not a defect, and any run recorded before this change is not
 * comparable with one recorded after it.
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")
public class AxonJdbcStateStoreConfig {

    @Bean
    @ConditionalOnMissingBean
    public TransactionManager axonTransactionManager(PlatformTransactionManager platformTransactionManager) {
        return new SpringTransactionManager(platformTransactionManager);
    }

    /**
     * Connections come from the same Hikari pool the application uses, wrapped so a
     * connection is bound to the active Unit of Work rather than opened per statement —
     * without the wrapper each Axon store would take its own connection inside a
     * transaction that already holds one, which is both a correctness and a pool-pressure
     * problem.
     */
    @Bean
    @ConditionalOnMissingBean
    public ConnectionProvider axonConnectionProvider(DataSource dataSource) {
        return new UnitOfWorkAwareConnectionProviderWrapper(new SpringDataSourceConnectionProvider(dataSource));
    }

    /**
     * Tracking-processor tokens in Postgres: a row claim per segment, with §9(d)'s 16
     * segments. On the embedded arm this is saga-progression traffic the Axon Server shape
     * used to send elsewhere; on the Axon Server arm it is traffic that previously did not
     * exist at all because the tokens were never written down.
     */
    @Bean
    public TokenStore tokenStore(ConnectionProvider connectionProvider,
                                 @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JdbcTokenStore.builder()
                .connectionProvider(connectionProvider)
                .serializer(eventSerializer)
                .schema(AxonSeedSchemas.tokens())
                .build();
    }

    /**
     * {@link JdbcSagaStore} is configured with a {@code SagaSqlSchema} rather than a bare
     * {@code SagaSchema}, and the PostgreSQL variant is the correct one: it is the dialect
     * whose association-value key is {@code bigserial} — the generic variant declares a
     * MySQL {@code AUTO_INCREMENT} column — and whose saga load takes {@code FOR UPDATE}.
     */
    @Bean
    public SagaStore<Object> sagaStore(ConnectionProvider connectionProvider,
                                       @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JdbcSagaStore.builder()
                .connectionProvider(connectionProvider)
                .serializer(eventSerializer)
                .sqlSchema(new PostgresSagaSqlSchema(AxonSeedSchemas.sagas()))
                .build();
    }
}
