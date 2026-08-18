package eu.exeris.benchmarks.targets.springapp.api;

import com.fasterxml.jackson.annotation.JsonAlias;

public record CreateOrderRequest(
        @JsonAlias("cart_id") String cartId,
        @JsonAlias("payment_method") String paymentMethod,
        // CONTRACT-v2 §3: optional client-generated orderId (deterministic seeded
        // population — prerequisite for the §4.1 exact decline oracle). When absent,
        // the app generates a UUID as before.
        @JsonAlias("order_id") String orderId
) {
}
