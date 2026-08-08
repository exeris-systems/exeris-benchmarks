package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record OrderSagaCompensatedEvent(
        String orderId,
        String userId,
        String cartId,
        String sagaId
) {
}
