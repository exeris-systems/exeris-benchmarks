package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.common.jdbc.ConnectionProvider;
import org.axonframework.common.transaction.TransactionManager;
import org.axonframework.eventsourcing.eventstore.EmbeddedEventStore;
import org.axonframework.eventsourcing.eventstore.EventStorageEngine;
import org.axonframework.eventsourcing.eventstore.EventStore;
import org.axonframework.eventsourcing.eventstore.jdbc.JdbcEventStorageEngine;
import org.axonframework.serialization.Serializer;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * CONTRACT-v2 §9(e): the embedded shape of the Axon arm — the EVENT STORE in the shared
 * Postgres over plain JDBC, command bus in-process, no Axon Server. §1 deployment unit is
 * two processes (target JVM + Postgres) against the Axon Server shape's three.
 *
 * <p>Only the event store is declared here. Tracking tokens and saga state are durable on
 * BOTH arms and live in {@link AxonJdbcStateStoreConfig} — see that class for why the Axon
 * Server arm needs them too. What remains in this class is exactly the axis the two arms
 * differ on: where events go.
 *
 * <h2>JDBC, not JPA — and that is a fairness rule, not a preference</h2>
 *
 * Every arm in this scenario is measured on JDBC because Exeris uses JDBC; an ORM on one
 * side of a comparison is a second variable. Axon ships first-class JDBC storage engines,
 * so the Axon arm does not need Hibernate to have a durable event store.
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
 * <em>Default configuration requires the use of event sourcing.</em>
 *
 * <p>Gated on {@code axon.axonserver.enabled=false} AND {@code exeris.axon.enabled=true}:
 * the two Axon arms run the same jar, so an ungated event-store bean here would replace the
 * three-process arm's Axon Server event store and erase the difference being measured.
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")
@ConditionalOnProperty(name = "axon.axonserver.enabled", havingValue = "false")
public class EmbeddedAxonStoreConfig {

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
                .schema(AxonSeedSchemas.events())
                .build();
    }

    @Bean
    public EventStore eventStore(EventStorageEngine eventStorageEngine) {
        return EmbeddedEventStore.builder()
                .storageEngine(eventStorageEngine)
                .build();
    }
}
