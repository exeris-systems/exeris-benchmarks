package eu.exeris.benchmarks.targets.quarkusapp.axon.event;

public record OrderSagaCompletedEvent(
        String orderId,
        String sagaId,
        String userId
) {
}