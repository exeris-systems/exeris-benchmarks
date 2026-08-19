package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.common.jdbc.ConnectionProvider;
import org.axonframework.common.jdbc.UnitOfWorkAwareConnectionProviderWrapper;
import org.axonframework.common.transaction.TransactionManager;
import org.axonframework.eventhandling.tokenstore.TokenStore;
import org.axonframework.eventhandling.tokenstore.jdbc.JdbcTokenStore;
import org.axonframework.eventsourcing.eventstore.EmbeddedEventStore;
import org.axonframework.eventsourcing.eventstore.EventStorageEngine;
import org.axonframework.eventsourcing.eventstore.EventStore;
import org.axonframework.eventsourcing.eventstore.jdbc.JdbcEventStorageEngine;
import org.axonframework.modelling.saga.repository.SagaStore;
import org.axonframework.modelling.saga.repository.jdbc.JdbcSagaStore;
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
 * CONTRACT-v2 §9(e): the embedded shape of the Axon arm — event store, token store and
 * saga store in the SHARED Postgres over plain JDBC, command bus in-process, no Axon
 * Server. §1 deployment unit is two processes (target JVM + Postgres) against the Axon
 * Server shape's three.
 *
 * <h2>JDBC, not JPA — and that is a fairness rule, not a preference</h2>
 *
 * Every arm in this scenario is measured on JDBC because Exeris uses JDBC; an ORM on one
 * side of a comparison is a second variable. Axon ships first-class JDBC storage engines,
 * so the Axon arm does not need Hibernate to have a durable saga engine, and this
 * configuration uses them.
 *
 * <p>It also removes a whole class of schema hazard the JPA path walked into: Hibernate
 * mapped Axon's {@code @Lob byte[]} to PostgreSQL large-object OIDs (so tokens silently
 * failed to persist against BYTEA columns, and TRUNCATE leaked the objects), and resolved
 * {@code @GeneratedValue} to a sequence the seed did not declare. Axon's own JDBC schema
 * is BYTEA with a plain identity column — the seed matches it directly.
 *
 * <h2>Why anything has to be declared at all</h2>
 *
 * Turning {@code axon.axonserver.enabled} off leaves Axon's Spring Boot starter with no
 * event store, and the context dies while building the {@code OrderAggregate} repository:
 * <em>"Default configuration requires the use of event sourcing."</em>
 *
 * <p>Gated on {@code axon.axonserver.enabled=false} AND {@code exeris.axon.enabled=true}:
 * the two Axon arms run the same jar, so an ungated bean here would change the
 * three-process arm's measurement too.
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")
@ConditionalOnProperty(name = "axon.axonserver.enabled", havingValue = "false")
public class EmbeddedAxonStoreConfig {

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

    @Bean
    public EventStorageEngine eventStorageEngine(ConnectionProvider connectionProvider,
                                                 TransactionManager transactionManager,
                                                 @Qualifier("eventSerializer") Serializer eventSerializer,
                                                 Serializer snapshotSerializer) {
        return JdbcEventStorageEngine.builder()
                .connectionProvider(connectionProvider)
                .transactionManager(transactionManager)
                .eventSerializer(eventSerializer)
                .snapshotSerializer(snapshotSerializer)
                .build();
    }

    @Bean
    public EventStore eventStore(EventStorageEngine eventStorageEngine) {
        return EmbeddedEventStore.builder()
                .storageEngine(eventStorageEngine)
                .build();
    }

    /**
     * Tracking-processor tokens in Postgres. This is the write traffic the Axon Server
     * shape sends elsewhere — a row claim per segment, with §9(d)'s 16 segments — and
     * making it visible on the shared database is the point of this arm, not a defect.
     */
    @Bean
    public TokenStore tokenStore(ConnectionProvider connectionProvider,
                                 @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JdbcTokenStore.builder()
                .connectionProvider(connectionProvider)
                .serializer(eventSerializer)
                .build();
    }

    @Bean
    public SagaStore<Object> sagaStore(ConnectionProvider connectionProvider,
                                       @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JdbcSagaStore.builder()
                .connectionProvider(connectionProvider)
                .serializer(eventSerializer)
                .build();
    }
}
