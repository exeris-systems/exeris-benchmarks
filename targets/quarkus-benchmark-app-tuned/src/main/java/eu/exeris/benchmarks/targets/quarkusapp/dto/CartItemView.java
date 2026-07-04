package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;

public record CartItemView(
        @JsonProperty("product_id") String productId,
        int quantity,
        BigDecimal price
) {
}