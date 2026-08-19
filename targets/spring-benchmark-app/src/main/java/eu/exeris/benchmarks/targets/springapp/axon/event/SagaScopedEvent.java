package eu.exeris.benchmarks.targets.springapp.application.axon.event;

/**
 * Every event in the order-fulfilment saga names the saga instance it belongs to.
 *
 * <p>The interface exists so that {@code SagaSequencingConfiguration} can route events to
 * processor segments by saga instance <em>totally</em> — a new event type that forgets to
 * carry a saga id is a compile error here, rather than an event that silently routes to a
 * random segment. That distinction is not hypothetical: the default policy's fallback is
 * exactly such a silent misroute, and it stranded every saga on the embedded Axon arm.
 */
public interface SagaScopedEvent {

    String sagaId();
}
