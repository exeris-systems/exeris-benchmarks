package eu.exeris.benchmarks.targets.restateapp.api;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.util.List;

/**
 * Wire DTOs of the k6-facing HTTP surface — field names byte-identical to
 * spring-benchmark-app's api records so scenarios/e2e-shop-order-saga/k6.js
 * works unchanged.
 */
public final class Dtos {

    private Dtos() {
    }

    public record RegisterRequest(String username, String email, String password) {}

    public record RegisterResponse(
            String token,
            @JsonProperty("user_id") String userId
    ) {}

    public record ProductView(String id, String name, BigDecimal price, String category) {}

    public record CartAddRequest(
            @JsonAlias("product_id") String productId,
            int quantity
    ) {}

    public record CartItemView(
            @JsonProperty("product_id") String productId,
            int quantity,
            BigDecimal price
    ) {}

    public record CartView(
            @JsonProperty("cart_id") String cartId,
            String id,
            @JsonProperty("user_id") String userId,
            List<CartItemView> items,
            @JsonProperty("total_amount") BigDecimal totalAmount
    ) {}

    public record CreateOrderRequest(
            @JsonAlias("cart_id") String cartId,
            @JsonAlias("payment_method") String paymentMethod,
            // CONTRACT-v2 §3: client-generated orderId (deterministic seeded
            // population — prerequisite for the §4.1 exact decline oracle).
            @JsonAlias("order_id") String orderId
    ) {}

    /**
     * v2 request-response order view: the terminal saga outcome is returned in
     * the POST /api/v1/orders body (status ∈ COMPLETED | COMPENSATED |
     * FAILED_UNRECOVERED), so k6 skips polling (k6.js extractTerminalStatus).
     */
    public record OrderTerminalView(
            @JsonProperty("order_id") String orderId,
            String status,
            @JsonProperty("saga_id") String sagaId
    ) {}

    public record OrderStatusView(
            @JsonProperty("order_id") String orderId,
            String status,
            @JsonProperty("saga_id") String sagaId
    ) {}

    public record ErrorResponse(String error) {}
}
