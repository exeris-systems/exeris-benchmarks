package eu.exeris.benchmarks.targets.quarkusapp.axon.command;

public record CreateOrderCommand(
        String orderId,
        String sagaId,
        String userId,
        String cartId,
        String paymentMethod
) {
}