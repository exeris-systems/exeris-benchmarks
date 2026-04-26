package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonAlias;

public record CreateOrderRequest(
        @JsonAlias("cart_id") String cartId,
        @JsonAlias("payment_method") String paymentMethod
) {
}