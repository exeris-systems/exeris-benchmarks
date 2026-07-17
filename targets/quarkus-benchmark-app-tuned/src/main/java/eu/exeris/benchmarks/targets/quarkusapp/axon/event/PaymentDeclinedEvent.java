package eu.exeris.benchmarks.targets.quarkusapp.axon.event;

/**
 * CONTRACT-v2 §4.1 business-terminal payment decline — deterministic per-orderId,
 * routed to saga compensation, never retried.
 */
public record PaymentDeclinedEvent(
        String orderId,
        String sagaId,
        String userId
) {
}
