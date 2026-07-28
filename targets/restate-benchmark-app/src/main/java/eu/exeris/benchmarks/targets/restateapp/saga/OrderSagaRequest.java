package eu.exeris.benchmarks.targets.restateapp.saga;

/**
 * Payload the HTTP facade submits to the Restate ingress
 * (POST /restate/call/OrderSaga/run, idempotency-key = orderId).
 */
public record OrderSagaRequest(
        String orderId,
        String userId,
        String cartId,
        String paymentMethod,
        String sagaId
) {
}
