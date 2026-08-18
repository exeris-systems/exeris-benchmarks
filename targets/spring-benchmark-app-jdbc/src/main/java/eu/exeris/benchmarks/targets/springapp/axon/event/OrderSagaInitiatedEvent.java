package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record OrderSagaInitiatedEvent(
        String orderId,
        String userId,
        String cartId,
        String sagaId,
        String paymentMethod
) {
}