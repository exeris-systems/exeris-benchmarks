package eu.exeris.benchmarks.targets.quarkusapp.axon.event;

public record OrderSagaInitiatedEvent(
        String orderId,
        String sagaId,
        String userId
) {
}