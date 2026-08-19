package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.event.SagaScopedEvent;
import org.axonframework.config.ConfigurerModule;
import org.axonframework.eventhandling.EventMessage;
import org.axonframework.eventhandling.async.SequencingPolicy;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Routes the order-fulfilment saga's events to processor segments by SAGA INSTANCE, so
 * that one saga's events are handled in order by one thread.
 *
 * <h2>What goes wrong without this</h2>
 *
 * CONTRACT-v2 §9(d) gives the saga processor 16 segments so that distinct sagas advance
 * concurrently. Which segment an event lands on is decided by the processing group's
 * {@link SequencingPolicy}, and Axon's default is {@code SequentialPerAggregatePolicy} —
 * it returns the aggregate identifier for an aggregate-sourced event, and {@code null} for
 * anything else, at which point the processor falls back to the event's own message
 * identifier.
 *
 * <p>Every step of this saga after the first is published as a plain event
 * ({@code eventBus.publish(GenericEventMessage.asEventMessage(...))}) rather than applied
 * to an aggregate, so every one of them takes the fallback and gets a FRESH RANDOM
 * identifier. A single saga's events are therefore sprayed across all 16 segments and
 * handled by 16 threads with no ordering between them.
 *
 * <p>That is a race, and it is lost deterministically on the embedded arm. The saga
 * handler for {@code OrderSagaInitiatedEvent} runs inside the tracking processor's unit of
 * work: it creates the saga, writes the association row, and — via
 * {@code commandGateway.sendAndWait} — appends {@code InventoryReservedEvent}, all in one
 * transaction. Another segment's thread picks that event up, looks for a saga associated
 * with its {@code sagaId}, finds none yet, and drops it. No exception is raised, no error
 * is logged, and the token advances past it: the event is never redelivered and the saga
 * never reaches a terminal state. Measured directly on the embedded arm — 2 events stored,
 * 1 saga row, 1 association row, all 16 tokens at index 2, zero WARN or ERROR lines, and
 * every session stuck at {@code INVENTORY_RESERVED}.
 *
 * <h2>Why it did not show on the Axon Server arm</h2>
 *
 * Same policy, same 16 segments, same race — but events reach the processor by streaming
 * back from Axon Server, so the local transaction has long committed before any segment
 * sees them. The Axon Server arm passes the §3.1 preflight and the correctness gate today.
 * It is winning a race, not avoiding one, so this configuration is registered for BOTH
 * Axon arms: it is a correctness fix in one and a latent-defect fix in the other, and
 * leaving the two arms on different sequencing policies would make them incomparable.
 *
 * <p>Segment-level concurrency is unaffected — distinct sagas still hash to distinct
 * segments. The policy constrains ordering WITHIN a saga, which is what §9(d)'s 16
 * segments were meant to provide in the first place.
 */
@Configuration(proxyBeanMethods = false)
public class SagaSequencingConfiguration {

    /**
     * Axon derives a saga's processing group from the saga type, and the name must match
     * the {@code axon.eventhandling.processors.OrderFulfillmentSagaProcessor.*} keys in
     * {@code application.properties} that give the processor its 16 segments — a
     * mismatched name here would register the policy against a group that does not exist
     * and change nothing.
     */
    static final String SAGA_PROCESSING_GROUP = "OrderFulfillmentSagaProcessor";

    @Bean
    public ConfigurerModule sagaSequencingConfigurerModule() {
        SequencingPolicy<EventMessage<?>> bySagaInstance = SagaSequencingConfiguration::sequenceIdentifierFor;
        return configurer -> configurer.eventProcessing(
                processing -> processing.registerSequencingPolicy(
                        SAGA_PROCESSING_GROUP, configuration -> bySagaInstance));
    }

    /**
     * The message identifier fallback is kept for events this saga does not define — it
     * reproduces the default policy's behaviour rather than collapsing unknown events onto
     * one segment. Every event the saga actually handles implements {@link SagaScopedEvent},
     * so the fallback is unreachable for them by construction.
     */
    private static Object sequenceIdentifierFor(EventMessage<?> event) {
        if (event.getPayload() instanceof SagaScopedEvent sagaScoped) {
            return sagaScoped.sagaId();
        }
        return event.getIdentifier();
    }
}
