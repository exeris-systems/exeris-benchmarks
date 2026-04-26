package eu.exeris.benchmarks.targets.springapp.api;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.util.List;

public record CartView(
        @JsonProperty("cart_id") String cartId,
        String id,
        @JsonProperty("user_id") String userId,
        List<CartItemView> items,
        @JsonProperty("total_amount") BigDecimal totalAmount
) {
}
