package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonAlias;

/**
 * {@code orderId} is the CONTRACT-v2 §3 client-generated deterministic orderId
 * (the k6 harness sends {@code order_id}); it is the input to the §4.1
 * deterministic payment-decline rule, so the server must adopt it verbatim
 * rather than mint its own. Optional for pre-v2 clients — the service falls
 * back to the server-generated sequence (decline rate then still holds
 * statistically, but the declined subset is no longer reproducible across runs).
 */
public record CreateOrderRequest(
        @JsonAlias("order_id") String orderId,
        @JsonAlias("cart_id") String cartId,
        @JsonAlias("payment_method") String paymentMethod
) {
}