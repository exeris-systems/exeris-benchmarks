package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.common.jpa.EntityManagerProvider;
import org.axonframework.common.transaction.TransactionManager;
import org.axonframework.eventhandling.tokenstore.TokenStore;
import org.axonframework.eventhandling.tokenstore.jpa.JpaTokenStore;
import org.axonframework.eventsourcing.eventstore.EmbeddedEventStore;
import org.axonframework.eventsourcing.eventstore.EventStorageEngine;
import org.axonframework.eventsourcing.eventstore.EventStore;
import org.axonframework.eventsourcing.eventstore.jpa.JpaEventStorageEngine;
import org.axonframework.modelling.saga.repository.SagaStore;
import org.axonframework.modelling.saga.repository.jpa.JpaSagaStore;
import org.axonframework.serialization.Serializer;
import org.axonframework.spring.messaging.unitofwork.SpringTransactionManager;
import org.axonframework.springboot.util.RegisterDefaultEntities;
import org.axonframework.springboot.util.jpa.ContainerManagedEntityManagerProvider;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

/**
 * CONTRACT-v2 §9(e): the embedded shape of the Axon arm — event store, token store and
 * saga store in the SHARED Postgres, command bus in-process, no Axon Server.
 *
 * <h2>Why this class exists at all</h2>
 *
 * Turning {@code axon.axonserver.enabled} off is not sufficient. Axon's Spring Boot
 * starter then has no event store to fall back to and the context dies at startup with
 * <em>"Default configuration requires the use of event sourcing. Either configure an
 * Event Store to use, or configure a specific repository implementation"</em> while
 * building the {@code OrderAggregate} repository. The JPA stores are wired here
 * explicitly rather than hoped for.
 *
 * <h2>Why the entity registration is a separate annotation</h2>
 *
 * Axon's JPA entities live in Axon's own packages, which the application's
 * {@code @EntityScan} does not cover. {@link RegisterDefaultEntities} adds them to the
 * persistence unit WITHOUT displacing the application's own entity scanning — plain
 * {@code @EntityScan} would replace it and silently drop the app's entities.
 *
 * <p>Gated so it cannot affect the Axon Server arm: {@code axon.axonserver.enabled=false}
 * AND {@code exeris.axon.enabled=true}. The two arms run the same jar, so an ungated bean
 * here would change the three-process arm's measurement too.
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")
@ConditionalOnProperty(name = "axon.axonserver.enabled", havingValue = "false")
@RegisterDefaultEntities(packages = {
        "org.axonframework.eventsourcing.eventstore.jpa",
        "org.axonframework.eventhandling.tokenstore.jpa",
        "org.axonframework.modelling.saga.repository.jpa"
})
public class EmbeddedAxonStoreConfig {

    /**
     * Axon's bridge to the container's {@code EntityManager}. Not auto-configured here:
     * the starter registers it as part of the JPA autoconfiguration that only engages when
     * it is also supplying the stores, so with the stores declared above the provider has
     * to come with them.
     */
    @Bean
    @ConditionalOnMissingBean
    public EntityManagerProvider entityManagerProvider() {
        return new ContainerManagedEntityManagerProvider();
    }

    @Bean
    @ConditionalOnMissingBean
    public TransactionManager axonTransactionManager(PlatformTransactionManager platformTransactionManager) {
        return new SpringTransactionManager(platformTransactionManager);
    }

    /**
     * The event store engine. Serializers come from the Spring context so this arm and the
     * Axon Server arm serialize identically (Jackson — XStream cannot handle Java records
     * on this JDK, see application.properties).
     */
    @Bean
    public EventStorageEngine eventStorageEngine(EntityManagerProvider entityManagerProvider,
                                                 TransactionManager transactionManager,
                                                 @Qualifier("eventSerializer") Serializer eventSerializer,
                                                 Serializer snapshotSerializer) {
        return JpaEventStorageEngine.builder()
                .entityManagerProvider(entityManagerProvider)
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
     * shape sends elsewhere — a row lock per segment per claim, with §9(d)'s 16 segments —
     * and making it visible on the shared database is the point of this arm, not a defect.
     */
    @Bean
    public TokenStore tokenStore(EntityManagerProvider entityManagerProvider,
                                 @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JpaTokenStore.builder()
                .entityManagerProvider(entityManagerProvider)
                .serializer(eventSerializer)
                .build();
    }

    @Bean
    public SagaStore<Object> sagaStore(EntityManagerProvider entityManagerProvider,
                                       @Qualifier("eventSerializer") Serializer eventSerializer) {
        return JpaSagaStore.builder()
                .entityManagerProvider(entityManagerProvider)
                .serializer(eventSerializer)
                .build();
    }
}
