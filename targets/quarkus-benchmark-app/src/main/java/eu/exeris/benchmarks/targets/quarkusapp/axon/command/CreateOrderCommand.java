package eu.exeris.benchmarks.targets.quarkusapp.axon.command;

public record CreateOrderCommand(
        String orderId,
        String sagaId,
        String userId,
        String cartId,
        String paymentMethod,
        // CONTRACT-v2 §9(a): the coordinator-minted LRA id for this saga, bound to the
        // order row so the coordinator can identify it on a later @Compensate.
        String lraId
) {
}