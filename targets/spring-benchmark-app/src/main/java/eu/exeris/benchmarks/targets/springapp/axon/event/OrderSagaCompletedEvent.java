package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record OrderSagaCompletedEvent(
        String orderId,
        String userId,
        String cartId,
        String sagaId
) {
}