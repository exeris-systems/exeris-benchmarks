package eu.exeris.benchmarks.targets.quarkusapp.axon.event;

public record OrderSagaCompensatedEvent(
        String orderId,
        String sagaId,
        String userId
) {
}
