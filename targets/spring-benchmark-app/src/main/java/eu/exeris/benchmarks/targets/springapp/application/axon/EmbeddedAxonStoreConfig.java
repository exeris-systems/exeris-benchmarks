package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.common.jdbc.ConnectionProvider;
import org.axonframework.common.jdbc.UnitOfWorkAwareConnectionProviderWrapper;
import org.axonframework.common.transaction.TransactionManager;
import org.axonframework.eventhandling.tokenstore.TokenStore;
import org.axonframework.eventhandling.tokenstore.jdbc.JdbcTokenStore;
import org.axonframework.eventhandling.tokenstore.jdbc.TokenSchema;
import org.axonframework.eventsourcing.eventstore.EmbeddedEventStore;
import org.axonframework.eventsourcing.eventstore.EventStorageEngine;
import org.axonframework.eventsourcing.eventstore.EventStore;
import org.axonframework.eventsourcing.eventstore.jdbc.EventSchema;
import org.axonframework.eventsourcing.eventstore.jdbc.JdbcEventStorageEngine;
import org.axonframework.modelling.saga.repository.SagaStore;
import org.axonframework.modelling.saga.repository.jdbc.JdbcSagaStore;
import org.axonframework.modelling.saga.repository.jdbc.PostgresSagaSqlSchema;
import org.axonframework.modelling.saga.repository.jdbc.SagaSchema;
import org.axonframework.modelling.saga.repository.jdbc.SagaSqlSchema;
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
 * <em>Default configuration requires the use of event sourcing.</em>
 *
 * <p>Gated on {@code axon.axonserver.enabled=false} AND {@code exeris.axon.enabled=true}:
 * the two Axon arms run the same jar, so an ungated bean here would change the
 * three-process arm's measurement too.
 *
 * <h2>Why every table and column is named explicitly</h2>
 *
 * Axon's JDBC schemas default to entity-style identifiers — {@code TokenEntry},
 * {@code processorName}, {@code DomainEventEntry}, {@code metaData} — which Axon emits
 * unquoted, so PostgreSQL folds them to {@code tokenentry} and {@code processorname}. The
 * seed declares the snake_case names Axon's JPA mapping produces ({@code token_entry},
 * {@code processor_name}), and both Axon arms share those tables. Left at their defaults
 * the stores come up and then die on first use with <em>Could not load segments for
 * processor [...]: relation "tokenentry" does not exist</em> — the saga never advances and
 * every session ends unresolved, a failure indistinguishable at the k6 level from the JPA
 * large-object stall this configuration replaced. Naming the schema here is what keeps the
 * physical schema identical across both Axon arms, so the only variable between them is
 * where events go.
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
                .schema(seedEventSchema())
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
                .schema(seedTokenSchema())
                .build();
    }

    /**
     * {@link JdbcSagaStore} is configured with a {@link SagaSqlSchema} rather than a bare
     * {@link SagaSchema}, and the PostgreSQL variant is the correct one: it is the dialect
     * whose association-value key is {@code bigserial} — the generic variant declares a
     * MySQL {@code AUTO_INCREMENT} column — and whose saga load takes {@code FOR UPDATE}.
     */
    @Bean
    public SagaStore<Object> sagaStore(ConnectionProvider connectionProvider,
                                       @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JdbcSagaStore.builder()
                .connectionProvider(connectionProvider)
                .serializer(eventSerializer)
                .sqlSchema(new PostgresSagaSqlSchema(seedSagaSchema()))
                .build();
    }

    private static EventSchema seedEventSchema() {
        return EventSchema.builder()
                .eventTable("domain_event_entry")
                .snapshotTable("snapshot_event_entry")
                .globalIndexColumn("global_index")
                .timestampColumn("time_stamp")
                .eventIdentifierColumn("event_identifier")
                .aggregateIdentifierColumn("aggregate_identifier")
                .sequenceNumberColumn("sequence_number")
                .typeColumn("type")
                .payloadTypeColumn("payload_type")
                .payloadRevisionColumn("payload_revision")
                .payloadColumn("payload")
                .metaDataColumn("meta_data")
                .build();
    }

    private static TokenSchema seedTokenSchema() {
        return TokenSchema.builder()
                .setTokenTable("token_entry")
                .setProcessorNameColumn("processor_name")
                .setSegmentColumn("segment")
                .setTokenColumn("token")
                .setTokenTypeColumn("token_type")
                .setTimestampColumn("timestamp")
                .setOwnerColumn("owner")
                .build();
    }

    private static SagaSchema seedSagaSchema() {
        return SagaSchema.builder()
                .sagaEntryTable("saga_entry")
                .sagaIdColumn("saga_id")
                .sagaTypeColumn("saga_type")
                .revisionColumn("revision")
                .serializedSagaColumn("serialized_saga")
                .associationValueEntryTable("association_value_entry")
                .associationKeyColumn("association_key")
                .associationValueColumn("association_value")
                .build();
    }
}
