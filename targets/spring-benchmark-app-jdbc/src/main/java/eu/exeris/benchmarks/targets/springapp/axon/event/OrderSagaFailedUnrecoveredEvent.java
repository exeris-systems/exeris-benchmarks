package eu.exeris.benchmarks.targets.springapp.application.axon.event;

/**
 * Terminal failure of the saga's backward recovery: a compensation step
 * exhausted its retry budget (CONTRACT-v2 §5). Surfaced to the status endpoint
 * as FAILED_UNRECOVERED and counted separately (§7 oracle O3) — expected count
 * in fault-only runs is 0.
 */
public record OrderSagaFailedUnrecoveredEvent(
        String orderId,
        String userId,
        String cartId,
        String sagaId
) {
}
